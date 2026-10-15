/// 均衡器数据层：把用户设置推给原生 `android.media.audiofx.Equalizer`
/// （attach 在自己播放器的 audio session 上），并把设备能力（频段数 / 增益范围 /
/// 预设名）读回来驱动 UI。
///
/// 与频谱的关系：两者各自是独立的 AudioEffect，挂在同一个 sessionId 上（见
/// `spectrum_engine.dart` / `SpectrumEngine.kt`），互不干扰。EQ 不需要麦克风权限，
/// 只要清单里的 `MODIFY_AUDIO_SETTINGS`（普通权限，装完即有）。
///
/// 事实来源：本文件（+ SharedPreferences）说了算；原生只负责「附着 + 落实」。
/// 因为原生进程重启后不保留任何设置，每次开始播放都会 `ensure()` 重新推一遍。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'eq_presets.dart';

/// 设备自带的一个预设（Normal / Rock / Jazz …），名字由 ROM 决定
class EqPreset {
  const EqPreset({required this.index, required this.name});

  final int index;
  final String name;
}

/// 均衡器状态快照（不可变，UI 直接渲染）
class EqState {
  const EqState({
    this.available = false,
    this.enabled = false,
    this.bands = 0,
    this.minLevel = -1500,
    this.maxLevel = 1500,
    this.centerFreqs = const [],
    this.levels = const [],
    this.presets = const [],
    this.currentPreset = -1,
  });

  /// 原生是否已成功 attach 到播放 session（没播放过时为 false）
  final bool available;
  final bool enabled;
  final int bands;

  /// 增益上下限，单位**毫贝**（millibel，100 mB = 1 dB），与 Android API 一致
  final int minLevel;
  final int maxLevel;

  /// 各频段中心频率，单位毫赫兹（mHz）
  final List<int> centerFreqs;

  /// 各频段当前增益，单位毫贝
  final List<int> levels;

  final List<EqPreset> presets;
  final int currentPreset;

  bool get hasBands => bands > 0;

  /// 只在「原生未附着」时用：把本地缓存设置盖到快照上显示
  EqState copyWith({bool? enabled, List<int>? levels}) => EqState(
    available: available,
    enabled: enabled ?? this.enabled,
    bands: bands,
    minLevel: minLevel,
    maxLevel: maxLevel,
    centerFreqs: centerFreqs,
    levels: levels ?? this.levels,
    presets: presets,
    currentPreset: currentPreset,
  );

  /// 毫贝 → 分贝，UI 显示用
  static double toDb(int millibel) => millibel / 100.0;

  static EqState fromMap(Map<Object?, Object?> m) {
    final bands = _int(m['bands']);
    return EqState(
      available: m['available'] == true,
      enabled: m['enabled'] == true,
      bands: bands,
      minLevel: m['minLevel'] == null ? -1500 : _int(m['minLevel']),
      maxLevel: m['maxLevel'] == null ? 1500 : _int(m['maxLevel']),
      centerFreqs: _ints(m['centerFreqs']),
      levels: _ints(m['levels']),
      presets: [
        for (final p in (m['presets'] as List<Object?>? ?? const []))
          if (p is Map)
            EqPreset(index: _int(p['index']), name: '${p['name']}'),
      ],
      currentPreset: m['currentPreset'] == null ? -1 : _int(m['currentPreset']),
    );
  }

  static int _int(Object? v) => v is num ? v.toInt() : 0;

  static List<int> _ints(Object? v) =>
      v is List ? [for (final e in v) _int(e)] : const [];
}

/// 均衡器引擎（单例）：与原生 `EqualizerEngine.kt` 一对一
class EqEngine {
  EqEngine._();

  static final EqEngine instance = EqEngine._();

  static const MethodChannel _channel =
      MethodChannel('com.mubox.mu_box_phone/equalizer');

  static const String _kEnabled = 'eq_enabled';
  static const String _kLevels = 'eq_levels';

  /// 用户自定义预设（「我的预设」）的 prefs 键：JSON 字符串，见 [userPresets]
  static const String _kPresets = 'eq_presets';

  /// 当前状态（UI 监听它重建）
  final ValueNotifier<EqState> state = ValueNotifier(const EqState());

  bool _inited = false;
  bool _enabled = false;
  List<int> _levels = const [];

  /// 上一次 [ensure] 带上来的播放器身份（`AudioPlayer.playerId`）。
  /// 给「EQ 页的重新检测」这类**拿不到播放器**的调用点复用：不带身份地 `open` 会让
  /// 原生回落到兼容格子（= 最后一次 setSource 的那个播放器，双播放器下可能就是正在
  /// 预取、还没出声的那一个）⇒ effect 挂错人、静默失效。
  /// 进程内从没播放过时为 null ⇒ 此时只能走兼容格子。
  String? _lastPlayerId;

  /// 用户自定义预设（「我的预设」）的**内存镜像**，真身在 prefs 的 [EqUserPreset]。
  ///
  /// ⚠️ 存 SharedPreferences 而不是文件是**实测结论**（不是偏好）：
  /// `backup_service.dart` 的 `createBackup` 把 prefs **全量**打进 `prefs.json`
  /// （`:48-58` 遍历 `sp.getKeys()`）、恢复侧 `sp.clear()` 后全量写回
  /// （`:190-199`）⇒ 存 prefs 就自动进备份；而 `createBackup` 只特殊处理
  /// `songs.json`（`:64-65`）、只遍历 `kBackupDirs` 里的**目录**（`:71-81`）⇒
  /// 单文件如 `docs/eq_presets.json` **不会进备份**，换机/重装必丢（H4 同一类事故）。
  List<EqUserPreset> _userPresets = const [];

  /// 「我的预设」列表（UI 读它渲染 chip；改动只经 [saveCurrentAs] / [removeNamed]）。
  List<EqUserPreset> get userPresets => _userPresets;

  /// 读取用户上次设置（App 启动调用一次即可，重复调用无副作用）
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    final sp = await SharedPreferences.getInstance();
    _enabled = sp.getBool(_kEnabled) ?? false;
    _levels = [
      for (final s in sp.getStringList(_kLevels) ?? const <String>[])
        if (int.tryParse(s) != null) int.parse(s),
    ];
    await _loadPresets(sp);
  }

  /// 读用户预设（[init] 与 [reloadPresets] 共用同一条路）。
  ///
  /// 损坏隔离照 `Store._decode` 的规矩：**解析失败当空、绝不抛**；并且先把原始串
  /// 留一份现场到 `eq_presets_corrupt` —— 否则下一次「保存 / 删除」会把坏值永久
  /// 盖掉（「读坏」就变成「永久没了」）。已有现场时不覆盖（留最早那次）。
  Future<void> _loadPresets(SharedPreferences sp) async {
    final raw = sp.getString(_kPresets);
    final parsed = parseEqPresets(raw);
    _userPresets = parsed.items;
    if (parsed.damaged && raw != null && !sp.containsKey('${_kPresets}_corrupt')) {
      await sp.setString('${_kPresets}_corrupt', raw);
    }
  }

  /// 恢复备份后重新读一遍用户预设（`AppConfig.instance.reload()` 的同伴）。
  ///
  /// [init] 有 `_inited` 早退：恢复完备份不重读，内存里还是恢复**之前**那份列表 ——
  /// 用户接着点一次「保存 / 删除」就会拿旧列表把刚恢复出来的 `eq_presets` 覆盖掉。
  Future<void> reloadPresets() async {
    final sp = await SharedPreferences.getInstance();
    await _loadPresets(sp);
  }

  /// 把**当前曲线**存成一套命名预设。同名（忽略首尾空格/大小写）⇒ 覆盖那套的曲线。
  /// 返回 true = 存下了；false = 名字空白或没波段（什么都没做）。
  Future<bool> saveCurrentAs(String name) async {
    await init();
    if (name.trim().isEmpty) return false;
    final s = state.value;
    final levels = s.bands > 0
        ? clampLevels(fitLevels(_levels, s.bands),
            min: s.minLevel, max: s.maxLevel)
        : List<int>.of(_levels);
    if (levels.isEmpty) return false;
    _userPresets = savePreset(_userPresets, name: name, levels: levels);
    await _persistPresets();
    return true;
  }

  /// 套用一套「我的预设」：**走已有的 [setBands]** —— 与手动拖曲线同一条路，
  /// 保证落盘（`_persist`）和频段数对齐（`_fit`）的行为完全一致。
  ///
  /// 与设备预设（[applyPreset]）保持一致：选预设即视为「要听」，顺手打开总开关 ——
  /// 关着总开关时点了没反应会被当成「预设坏了」。
  Future<void> applyNamed(String id) async {
    await init();
    final p = presetById(_userPresets, id);
    if (p == null) return;
    final s = state.value;
    final levels = s.bands > 0
        ? clampLevels(
            fitLevels(p.levels, s.bands),
            min: s.minLevel,
            max: s.maxLevel,
          )
        : List<int>.of(p.levels);
    if (!_enabled) await setEnabled(true);
    await setBands(levels);
  }

  /// 删除一套「我的预设」；id 不存在时什么都不做（幂等）。
  Future<void> removeNamed(String id) async {
    await init();
    final next = removePreset(_userPresets, id);
    if (next.length == _userPresets.length) return;
    _userPresets = next;
    await _persistPresets();
  }

  /// 播放开始时调用：让原生 attach 到当前 audio session 并应用用户设置。
  ///
  /// 从没启用过均衡器时直接返回 —— 不挂 effect 更省资源，也少一层和频谱抢
  /// audio session 的风险。EQ 页会带 [force] 调一次，先让用户看到设备能力。
  /// session 还没建好时原生返回 available=false，安静收场，下次播放再试。
  ///
  /// [playerId] = **要挂到哪个播放器**上（`AudioPlayer.playerId`）。不带（`null`）时
  /// 走原生的兼容格子 —— 双播放器下必须带，否则原生只认得出
  /// "最后一次 setSource 的那个播放器"（可能是正在预取的、还没出声的那个）。
  /// 原生侧的三种情形（同播放器同 session / 同播放器新 session / **换了播放器**）
  /// 由 `EqualizerEngine.kt` 的 `open(playerId)` 处理。
  Future<void> ensure({bool force = false, String? playerId}) async {
    await init();
    if (!force && !_enabled) return;
    if (playerId != null) _lastPlayerId = playerId;
    final opened = await _call(
      'open',
      playerId == null ? null : {'playerId': playerId},
    );
    if (opened == null) return;
    if (opened['available'] != true) {
      _publish(opened);
      return;
    }
    final applied = await _call('applyAll', {
      'enabled': _enabled,
      'levels': _fit(opened, _levels),
    });
    _publish(applied ?? opened);
  }

  /// 开关 EQ（关闭时只旁路，不清增益，下次打开还是原曲线）
  Future<void> setEnabled(bool value) async {
    await init();
    _enabled = value;
    _publish(await _call('setEnabled', {'enabled': value}));
    await _persist();
  }

  /// 提交整条增益曲线（拖拽结束时调用，避免拖动过程中每帧过桥）
  Future<void> setBands(List<int> levels) async {
    await init();
    _levels = List<int>.of(levels);
    _publish(await _call('setBands', {'levels': _levels}));
    await _persist();
  }

  /// 套用设备预设；预设会改写各段增益，回读后落到本地，保证下次进来曲线一致
  Future<void> applyPreset(int index) async {
    await init();
    final info = await _call('setPreset', {'index': index});
    _publish(info);
    final levels = state.value.levels;
    if (levels.isNotEmpty) _levels = levels;
    if (!_enabled) _enabled = true; // 选预设即视为「要听」，顺手打开开关
    await _persist();
  }

  /// 全部拉平到 0 dB
  Future<void> reset() async {
    await init();
    final bands = state.value.bands;
    if (bands <= 0) return;
    await setBands(List<int>.filled(bands, 0));
  }

  /// 重新检测（EQ 页的「重新检测」按钮）：顺便再尝试附着一次 ——
  /// 用户可能刚播放过，这时音频会话才存在。
  ///
  /// 带上 [EqEngine._lastPlayerId]：这个调用点拿不到播放器，但不能因此挂错人
  /// （双播放器下"兼容格子"可能正指着预取用的那个还没出声的播放器）。
  Future<EqState?> refresh() async {
    await ensure(force: true, playerId: _lastPlayerId);
    return state.value;
  }

  /// 把持久化的曲线对齐到设备实际频段数（换设备/换 ROM 时长度可能不同）
  List<int> _fit(Map<Object?, Object?> info, List<int> levels) {
    final bands = EqState.fromMap(info).bands;
    if (bands <= 0) return levels;
    return List<int>.generate(
      bands,
      (i) => i < levels.length ? levels[i] : 0,
    );
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kEnabled, _enabled);
    await sp.setStringList(_kLevels, [for (final v in _levels) '$v']);
  }

  /// 只写「我的预设」这一个键。
  ///
  /// **刻意不并进 `_persist()`**：那条路每次动 EQ（开关 / 拖曲线）都会跑，
  /// 让它顺手写 `eq_presets`，就会在用户还没保存过任何预设时把
  /// 「读坏了当空」的现场直接固化掉（原始串被 `[]` 盖掉）。
  Future<void> _persistPresets() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPresets, encodeEqPresets(_userPresets));
  }

  void _publish(Map<Object?, Object?>? info) {
    if (info == null) return;
    final next = EqState.fromMap(info);
    // 未附着时原生不记得任何设置（它不做持久化）：显示本地缓存的值，
    // 免得「上次明明开着，进来却显示关闭」。
    state.value = next.available
        ? next
        : next.copyWith(enabled: _enabled, levels: _levels);
  }

  /// 通道调用：原生未实现/异常时返回 null（EQ 只是增强功能，不能拖垮播放）
  Future<Map<Object?, Object?>?> _call(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      final res = await _channel.invokeMethod<Object?>(method, args);
      return res is Map ? res : null;
    } on PlatformException catch (e) {
      debugPrint('EqEngine.$method failed: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
