/// 音效增强数据层：低音增强（BassBoost）+ 响度增强（LoudnessEnhancer）
/// 推给原生，并把设备能力（是否支持强度调节 / 增益上限）读回来驱动 UI。
///
/// 与均衡器的关系：两者是各自独立的 AudioEffect，挂在同一个 audio session 上
/// （见 `eq_engine.dart` / `equalizer_page.dart`），互不干扰。原生侧见
/// `android/.../ExtraEffectsEngine.kt`。
///
/// 事实来源：本文件（+ SharedPreferences）说了算；原生只负责「附着 + 落实」。
/// 原生进程重启后不保留任何设置，所以每次开始播放都会 `ensure()` 重新推一遍。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'attach_retry.dart';

/// 音效增强状态快照（不可变，UI 直接渲染）
class ExtraFxState {
  const ExtraFxState({
    this.available = false,
    this.sessionId = -1,
    this.bassSupported = false,
    this.bassEnabled = false,
    this.bassStrength = 0,
    this.loudSupported = false,
    this.loudEnabled = false,
    this.loudGain = 0,
    this.loudMaxGain = 1200,
    this.loudAttachAttempted = false,
    this.loudAttachFailed = false,
    this.loudRetryable = false,
    this.loudRetryExhausted = false,
  });

  /// 原生是否已成功 attach 到播放 session（没播放过时为 false）
  final bool available;

  /// 当前音频会话 id，-1 表示还没建过播放器（UI 据此区分「先放一首歌」与「设备不支持」）
  final int sessionId;

  /// 设备是否支持低音强度调节（个别 ROM 不支持，不支持时开关置灰）
  final bool bassSupported;
  final bool bassEnabled;

  /// 低音强度 0~1000（Android 约定值）
  final int bassStrength;

  /// 设备是否成功挂上响度增强
  final bool loudSupported;
  final bool loudEnabled;

  /// 响度增益，单位**毫贝**（millibel，100 mB = 1 dB），与 Android API 一致
  final int loudGain;
  final int loudMaxGain;

  /// 原生这一轮**真的去挂过**响度（会话就绪、走过了构造）。改前不认识这三个键 ⇒ 恒 false。
  final bool loudAttachAttempted;

  /// 那一次**挂失败了**（`ERROR_NO_INIT` 那类）。⚠️ 只有 [loudAttachAttempted] 为真才有意义。
  final bool loudAttachFailed;

  /// 失败原因**可能只是临时的**（重挂有机会成功）。
  /// `IllegalArgumentException`（= effect 类型不被支持）时为 false ⇒ 不许给假希望。
  final bool loudRetryable;

  /// ★ 原生在这一条 `(playerId, session)` 上的**显式重挂次数已经用满**
  /// （`EffectAttachPolicy.MAX_RETRIES`）。
  ///
  /// ⚠️ 它**只改文案**：⛔ 不许拿它去禁用开关 —— 既定方案是
  /// 「保留响度开关 + 再试一次」，把这一项标成不可用就是换个方向的谎报。
  /// 用满之后原生对重挂请求一律不重建（**0 次**，由离线夹具钉住），
  /// 换一首歌（新 session）自动又是满额 —— 文案要把这件事说清楚。
  /// 原生不回报这个键时 ⇒ 恒 false（此时不做任何限制）。
  final bool loudRetryExhausted;

  /// 响度现在是三态里的哪一个（判定本体在 `attach_retry.dart`，可纯 Dart 单测）。
  AttachState get loudAttachState => attachStateOf(
    supported: loudSupported,
    attachAttempted: loudAttachAttempted,
    attachFailed: loudAttachFailed,
  );

  /// 响度开关**能不能点**。
  ///
  /// 硬支持条件仍是 `available && loudSupported`，只多一条
  /// 「这次挂失败了、且不是硬不支持 ⇒ 允许点一下重挂」⇒ 正常路径行为不变。
  bool get loudSwitchOn => loudSwitchEnabledFor(
    available: available,
    supported: loudSupported,
    state: loudAttachState,
  );

  /// 响度开关**显示成什么**（只认 [loudSupported]）。
  bool get loudSwitchChecked => loudSwitchValueFor(
    supported: loudSupported,
    enabled: loudEnabled,
  );

  /// 卡片说明该走哪一路（`null` = 用改动前那两句原文，保证观感零变化）。
  String? get loudCardOverride {
    final s = loudCardDesc(
      loudAttachState,
      retryable: loudRetryable,
      retryExhausted: loudRetryExhausted,
    );
    return s.isEmpty ? null : s;
  }

  /// 低音强度 → 百分比（UI 显示用）
  int get bassPercent => (bassStrength ~/ 10).clamp(0, 100).toInt();

  /// 毫贝 → 分贝文本：+6.0 / 0.0
  String get loudDbText => '+${(loudGain / 100.0).toStringAsFixed(1)}';

  static ExtraFxState fromMap(Map<Object?, Object?> m) => ExtraFxState(
    available: m['available'] == true,
    sessionId: m['sessionId'] == null ? -1 : _int(m['sessionId']),
    bassSupported: m['bassSupported'] == true,
    bassEnabled: m['bassEnabled'] == true,
    bassStrength: _int(m['bassStrength']),
    loudSupported: m['loudSupported'] == true,
    loudEnabled: m['loudEnabled'] == true,
    loudGain: _int(m['loudGain']),
    loudMaxGain: m['loudMaxGain'] == null ? 1200 : _int(m['loudMaxGain']),
    // 老版本原生不回报这三个键 ⇒ 全 false ⇒ 落回改动前的显示与禁用行为
    loudAttachAttempted: m['loudAttachAttempted'] == true,
    loudAttachFailed: m['loudAttachFailed'] == true,
    loudRetryable: m['loudRetryable'] == true,
    loudRetryExhausted: m['loudRetryExhausted'] == true,
  );

  /// 原生未附着时，用本地缓存设置盖到快照上显示（否则「上次明明开着，进来却显示关闭」）
  ///
  /// ⚠️ 三个 `loudAttach*` 字段**必须一起带过去**：它们描述的是「这次挂成没成」，
  /// 与 [loudEnabled] 这类用户设置无关，漏掉就会把「可重试」悄悄抹成「硬件没有」。
  ExtraFxState copyWith({
    bool? bassEnabled,
    int? bassStrength,
    bool? loudEnabled,
    int? loudGain,
  }) => ExtraFxState(
    available: available,
    sessionId: sessionId,
    bassSupported: bassSupported,
    bassEnabled: bassEnabled ?? this.bassEnabled,
    bassStrength: bassStrength ?? this.bassStrength,
    loudSupported: loudSupported,
    loudEnabled: loudEnabled ?? this.loudEnabled,
    loudGain: loudGain ?? this.loudGain,
    loudMaxGain: loudMaxGain,
    loudAttachAttempted: loudAttachAttempted,
    loudAttachFailed: loudAttachFailed,
    loudRetryable: loudRetryable,
    loudRetryExhausted: loudRetryExhausted,
  );

  static int _int(Object? v) => v is num ? v.toInt() : 0;
}

/// 音效增强引擎（单例）：与原生 `ExtraEffectsEngine.kt` 一对一
class ExtraFxEngine {
  ExtraFxEngine._();

  static final ExtraFxEngine instance = ExtraFxEngine._();

  static const MethodChannel _channel = MethodChannel(
    'com.mubox.mu_box_phone/extra_effects',
  );

  static const String _kBassOn = 'fx_bass_on';
  static const String _kBassStrength = 'fx_bass_strength';
  static const String _kLoudOn = 'fx_loud_on';
  static const String _kLoudGain = 'fx_loud_gain';

  /// 「这是一次**显式**重挂请求」的过桥键（**值 `true` 才作数**）。
  ///
  /// 只有「用户拨开关**打开**这一项」会带上它（[setBassEnabled] / [setLoudnessEnabled]）；
  /// 调强度/增益的滑杆路径（[setBassStrength] / [setLoudnessGain]）**刻意不带**。
  /// 原生侧要 `call.argument<Boolean>(kRetryKey) == true` 才可能调 `open()`
  /// （`ExtraEffectsEngine.kt` 的 `setBass` / `setLoudness`），而且放不放行还要过
  /// `EffectAttachPolicy` 的**冷却 + 次数上限**。
  ///
  /// 为什么要一个显式的键、而不是「带了 playerId 就重挂」：两类调用点都会带
  /// `playerId`（[refresh] 那种），靠参数有无去推断语义迟早会错；而且真机实测过
  /// 反例 —— 不带身份的那两条路走进 `open()` 之后，`alreadyAttached` 的身份比对
  /// 当场失效，整条效果链会被拆掉重建。
  static const String kRetryKey = 'retry';

  /// 当前状态（UI 监听它重建）
  final ValueNotifier<ExtraFxState> state = ValueNotifier(const ExtraFxState());

  bool _inited = false;
  bool _bassOn = false;
  int _bassStrength = 600; // 默认 60%：能听出低音变结实，又不容易糊
  bool _loudOn = false;
  int _loudGain = 400; // 默认 +4 dB：小音量下够明显，留足不削波的余量

  /// 上一次 [ensure] 带上来的播放器身份（`AudioPlayer.playerId`）：
  /// 给「音效页的重新检测」这类拿不到播放器的调用点复用，别让它回落到兼容格子
  /// （双播放器下那可能正指着预取用的、还没出声的播放器）。
  /// 进程内从没播放过时为 null ⇒ 此时只能走兼容格子。见 [refresh]。
  ///
  /// [setBassEnabled] / [setLoudnessEnabled] 也走它（见 [_retarget]）。
  String? _lastPlayerId;

  /// 拨开关时一起带上去的原生参数：**身份是必须的**。
  ///
  /// 原生侧「打开」这一路会顺带**挂载/重试**一次（`setLoudness` → `open(playerId)`），
  /// 不带身份就会挂到兼容格子那个可能已经过期的 session 上 —— 那等于**假重试**：
  /// 原生以为挂上了，实际挂在一个已经死掉的会话上。
  ///
  /// ⚠️ 进程内从没播放过时 `_lastPlayerId == null` ⇒ **键根本不出现**，
  /// 原生回落兼容格子 —— 与改造前逐项一致（改造前 `setBass`/`setLoudness` 本来就不带参数）。
  ///
  /// ★ 注意它是**两条开关路**共用的；调强度/增益那两条路**不走这里**（它们连
  /// [kRetryKey] 都不带 ⇒ 原生一个 effect 都不碰）。
  Map<String, Object?> _retarget(Map<String, Object?> args) => _lastPlayerId == null
      ? args
      : {...args, 'playerId': _lastPlayerId};

  /// 用户是否配置过任意一项（都没配过时播放不必挂 effect，零开销）
  bool get _anyOn => _bassOn || _loudOn;

  /// 读取用户上次设置（App 启动调用一次即可，重复调用无副作用）
  Future<void> init() async {
    if (_inited) return;
    _inited = true;
    final sp = await SharedPreferences.getInstance();
    _bassOn = sp.getBool(_kBassOn) ?? false;
    _bassStrength = (sp.getInt(_kBassStrength) ?? 600).clamp(0, 1000);
    _loudOn = sp.getBool(_kLoudOn) ?? false;
    _loudGain = (sp.getInt(_kLoudGain) ?? 400).clamp(0, 1200);
  }

  /// 播放开始时调用：让原生 attach 到当前 audio session 并应用用户设置。
  ///
  /// 两项都没启用过时直接返回 —— 不挂 effect 更省资源，也少一层和频谱/EQ
  /// 抢 audio session 的风险。音效页会带 [force] 调一次，先让用户看到设备能力。
  ///
  /// [playerId] = **要挂到哪个播放器**上（`AudioPlayer.playerId`）；不带时走原生兼容
  /// 格子。原生侧三种情形见 `ExtraEffectsEngine.kt` 的 `open(playerId)`。
  Future<void> ensure({bool force = false, String? playerId}) async {
    await init();
    if (!force && !_anyOn) return;
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
      'bassEnabled': _bassOn,
      'bassStrength': _bassStrength,
      'loudEnabled': _loudOn,
      'loudGain': _loudGain,
    });
    _publish(applied ?? opened);
  }

  /// 低音增强开关（关闭只旁路，不清强度，下次打开还是原值）
  ///
  /// ⚠️ 打开时原生会顺带挂载/重试一次（见 [_retarget] 与 [kRetryKey]）；关闭时原生**刻意不重挂**。
  Future<void> setBassEnabled(bool value, {int? strength}) async {
    await init();
    _bassOn = value;
    if (strength != null) _bassStrength = strength.clamp(0, 1000);
    _publish(
      await _call(
        'setBass',
        _retarget({
          'enabled': _bassOn,
          'strength': _bassStrength,
          // ★ 只有「拨开关**打开**这一项」才请求原生重挂；调强度那条路不带
          // ⇒ 真机上「拖/点强度滑杆」再也不会把整条效果链拆掉重建。
          if (value) kRetryKey: true,
        }),
      ),
    );
    await _persist();
  }

  /// 低音强度（拖拽结束时提交，避免拖动过程中每帧过桥）
  ///
  /// ★ **纯参数路径**：不带播放器身份、也不带 [kRetryKey] ⇒ 原生一个 effect 都不碰
  /// （不 `release`、不重建）。改造前它会带 `playerId=null` 走进原生的 `open()`，
  /// 那条身份比对当场失效 ⇒ 整条链（连健康的响度一起）在出声中途被拆掉重建。
  Future<void> setBassStrength(int strength) async {
    await init();
    _bassStrength = strength.clamp(0, 1000);
    _publish(
      await _call('setBass', {
        'enabled': _bassOn,
        'strength': _bassStrength,
      }),
    );
    await _persist();
  }

  /// 响度增强开关
  ///
  /// ⚠️ 打开时原生会顺带挂载/重试一次（见 [_retarget] 与 [kRetryKey]）；关闭时原生**刻意不重挂**。
  Future<void> setLoudnessEnabled(bool value, {int? gain}) async {
    await init();
    _loudOn = value;
    if (gain != null) _loudGain = gain.clamp(0, 1200);
    _publish(
      await _call(
        'setLoudness',
        _retarget({
          'enabled': _loudOn,
          'gain': _loudGain,
          // ★ 同上：只有拨开关打开才请求重挂（原生还会再叠一层「冷却 + 次数上限」）。
          if (value) kRetryKey: true,
        }),
      ),
    );
    await _persist();
  }

  /// 响度增益（毫贝）
  ///
  /// ★ **纯参数路径**（理由同 [setBassStrength]）。日志里
  /// `attached … playerId=null bass=true loud=false` 就是这条路打出来的 ——
  /// 它把一个**健康的**响度对象拆了，重建又失败 ⇒ 之后怎么点都回不来。
  Future<void> setLoudnessGain(int gain) async {
    await init();
    _loudGain = gain.clamp(0, 1200);
    _publish(
      await _call('setLoudness', {
        'enabled': _loudOn,
        'gain': _loudGain,
      }),
    );
    await _persist();
  }

  /// 重新检测（音效页的「重新检测」按钮）：顺便再尝试附着一次 ——
  /// 用户可能刚播放过，这时音频会话才存在。
  ///
  /// 带上 [_lastPlayerId]：这个调用点拿不到播放器，但不能因此挂错人
  /// （双播放器下"兼容格子"可能正指着预取用的那个还没出声的播放器）。
  Future<ExtraFxState> refresh() async {
    await ensure(force: true, playerId: _lastPlayerId);
    return state.value;
  }

  Future<void> _persist() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kBassOn, _bassOn);
    await sp.setInt(_kBassStrength, _bassStrength);
    await sp.setBool(_kLoudOn, _loudOn);
    await sp.setInt(_kLoudGain, _loudGain);
  }

  void _publish(Map<Object?, Object?>? info) {
    if (info == null) return;
    final next = ExtraFxState.fromMap(info);
    // 未附着时原生不记得任何设置（它不做持久化）：显示本地缓存的值
    state.value = next.available
        ? next
        : next.copyWith(
            bassEnabled: _bassOn,
            bassStrength: _bassStrength,
            loudEnabled: _loudOn,
            loudGain: _loudGain,
          );
  }

  /// 通道调用：原生未实现/异常时返回 null（音效只是增强功能，不能拖垮播放）
  Future<Map<Object?, Object?>?> _call(
    String method, [
    Map<String, Object?>? args,
  ]) async {
    try {
      final res = await _channel.invokeMethod<Object?>(method, args);
      return res is Map ? res : null;
    } on PlatformException catch (e) {
      debugPrint('ExtraFxEngine.$method failed: ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
