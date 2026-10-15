/// 全局可配置项：主题色 / 字体大小 / 壁纸 / 动效开关，改动即通知并持久化。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'effect_catalog.dart';
import 'theme.dart';

/// 全局配置单例，各页面监听它即时重建 UI。
class AppConfig extends ChangeNotifier {
  AppConfig._();

  static final AppConfig instance = AppConfig._();

  /// 主题色方案索引（稳定槽位：0~39 内置默认，40+ 用户自定义，见 theme.dart）
  int themeIndex = 0;

  /// 用户自定义的主题色（槽位 = kDefaultThemeCount + 下标），运行时可变、持久化。
  List<AccentScheme> customThemes = [];

  /// 被用户删除（隐藏）的内置主题色索引，持久化；「恢复默认」时清空。
  Set<int> hiddenDefaultThemes = {};

  /// 全局字体缩放倍数（0.9 小 / 1.0 标准 / 1.15 大 / 1.3 特大）
  double fontScale = 1.0;

  /// 歌词独立字号倍数：**null = 跟随 [fontScale]（默认）**；
  /// 用户在歌词页手动调过之后就固定用它，不再随主题字号变化。
  double? lyricFontScale;

  /// 歌词实际使用的缩放倍数：独立值优先，否则跟随全局。
  /// 歌词页的行高与字号都乘它，保证放大后行距同步变宽、不会挤成一团。
  double get lyricScale => lyricFontScale ?? fontScale;

  /// 自定义字体：fontFamily 为已加载字体名（空 = 跟随系统默认），fontPath 为字体文件路径。
  /// 用 FontLoader 动态加载，不随手机系统字体变化。
  String fontFamily = '';
  String? fontPath;

  /// 当前壁纸文件绝对路径；null 表示用纯深色背景
  String? wallpaperPath;

  /// 壁纸叠加透明度（0.15~0.7）
  double wallpaperOpacity = 0.35;

  /// 当前是否处于享受页（纯视觉欣赏页）：该页壁纸用原图亮度显示。
  /// 运行时状态，切页时由根页面同步；独立 ValueNotifier 只驱动壁纸层重建，不持久化。
  final ValueNotifier<bool> enjoyActive = ValueNotifier(false);

  /// 「右下角搜索悬浮按钮」开关（prefs 键 `search_fab`，**缺省 false = 关掉就是原来的界面**）。
  ///
  /// ⚠️ **故意用独立 `ValueNotifier`**（照 [enjoyActive] 那个先例，不是普通的 bool 字段）：
  /// 显隐只需重建根页面那颗按钮（`root_page.dart` 里 `ValueListenableBuilder` 包着它），
  /// ⛔ **绝不许 `_bumpRebuild()`** —— 那会让整棵 MaterialApp 重建（本项目铁律：
  /// 连续/开关类配置不许整棵重建，[volumeFadeEnabled]/[crossfadeEnabled] 同理）。
  /// `setSearchFabEnabled` 因此**连 `notifyListeners()` 都不调**：本字段唯一的消费者
  /// 就是这个 ValueNotifier 自己的监听者。
  final ValueNotifier<bool> searchFabEnabled = ValueNotifier(false);

  /// 动效开关：背景爱心（含流苏/边缘线）/ 雨滴 / 播放栏频谱 / 边框
  bool heartEnabled = true;
  bool rainEnabled = true;
  bool spectrumEnabled = true;
  bool edgeEnabled = true;

  /// 音量淡入淡出：切歌/起播渐入、暂停渐出，消掉那一下的爆音（默认开）。
  /// 只影响播放时的音量包络，属于局部参数 —— **刻意不 bump rebuild**。
  bool volumeFadeEnabled = true;

  /// **交叉淡变 + 队列预取（双播放器）**：`true` 时切歌那一瞬间两个播放器重叠约
  /// 300ms（A 淡出 / B 淡入），曲末由位置 tick 提前预取下一首。
  ///
  /// ⚠️ **默认关闭，而且这不是"还没做"** —— 三条硬理由：
  /// 1. **它会改观感**：现在是「上一首硬停 → 下一首从 0 淡入」，交叉淡变是两首重叠
  ///    ~300ms、通知栏/锁屏的曲目信息提前约 300ms 跳下一首；
  /// 2. 双播放器 = **双份解码资源**（CPU/内存/耗电），必须先在真机上量过才敢默认开；
  /// 3. 它还依赖原生侧的 per-player session + 三个引擎的换场重挂，
  ///    这些只有在真机上才验得出来。
  ///
  /// ⇒ 缺省值下第二个播放器**根本不会被创建**（`player_service.dart` 的
  /// `_tickDual()` 第一行就返回，连构造函数都不跑），行为与「没有这个功能」等价；
  /// 穷举证明有单测钉着。
  ///
  /// **刻意不 bump rebuild**（同 [volumeFadeEnabled]：它不是主题/字体那类要整棵重建的配置）。
  /// **有设置页入口**：音效页「交叉淡变」那张卡 —— 没有它的话产品代码里**零调用点**，
  /// 用户在界面上根本打不开这个功能。
  bool crossfadeEnabled = false;

  /// 首次播放时那条「允许后台运行 / 忽略电池优化」的引导**是否已经提示过**。
  /// 一次性的标记：见 `lib/bg_hint.dart`。「一辈子一次」靠这个键落盘，
  /// 不靠内存。⚠️ 它只管弹不弹提示，**刻意不 bump rebuild**（见 [setBgHintShown]）。
  bool bgHintShown = false;

  /// A-B 那颗按钮的「第一次点」提示**是否已经说过了**（一次性）。
  /// 第一次点它时会在**同一条** SnackBar 里补一句「第三下清除」并把停留时间拉长；
  /// 之后恢复成原来那句话。**刻意不 bump rebuild**（同 [bgHintShown]）。
  bool abHintShown = false;

  /// 视觉区域动效类型：0 爱心 / 1 旋转方块 / 2 粒子漩涡 / 3 能量光球 /
  /// 4 粒子聚散 / 5 万花筒 / 6 3D深度球 / 7 歌词逐字
  /// ⚠️ 自「视觉图层」上线后，这个字段的含义变成**当前选中图层的特效索引**
  /// （供目录页高亮 / 视觉方案等老接口使用）；真正画什么由 [visualLayers] 决定。
  int visualEffect = 0;

  /// 视觉区图层表：同一个特效能同时开多个（例：三颗爱心，各自一套位置/大小/颜色），
  /// **绘制顺序 = 列表顺序**（后面的盖在前面上）。至少保留一层。
  final List<VisualLayer> visualLayers = [];

  /// 当前选中的图层槽位（目录页高亮 / 设置页改的是哪一层）。
  int visualLayerSel = 0;

  /// 氛围区域动效类型：0 雨滴 / 1 星空 / 2 阳光 / 3 彩星 / 4 萤火虫 / 5 极光 /
  /// 6 飘雪 / 7 气泡 / 8 烟花 / 10 火焰 / 11 水面 / 12 花瓣 / 13 波纹（9 流星已下架）
  int ambientEffect = 0;

  /// 律动区域动效类型：0 频谱 / 1 波形 / 2 环形 / 3 圆点 / 5 镜像 / 6 3D频谱
  int rhythmEffect = 0;

  /// 边框区域动效类型：0 呼吸边框 / 1 流光边框 / 4 歌词跑马灯 / 5 频谱灯带
  /// （2 节拍VU环绕、3 四角聚光已移除，跳号占位保其它索引稳定；旧存值落默认呼吸边框）
  int edgeEffect = 0;

  /// 每个特效的专属参数（键见 effect_catalog.dart，如 `a0.count` / `v1.spin`）。
  /// **只存用户实际改过的键**：没改过的读的时候回落到注册表默认值，
  /// 这样以后调默认值能立刻作用到所有没动过这一项的用户身上。
  final Map<String, double> fxParams = {};

  /// 「需要重新生成粒子」的参数改动计数：数量/大小/随机度/风斜这类**生成端**属性
  /// 每改一次自增一次，氛围层据此去抖重建粒子列表；速度/亮度这类只在绘制端读的
  /// 参数不动它 —— 拖滑杆时零粒子重建，只重绘。
  final ValueNotifier<int> fxParticleRevision = ValueNotifier(0);

  /// 特效参数的落盘去抖计时器：拖动滑杆时每帧都会 setFx，
  /// 直接每帧写一次 SharedPreferences 太浪费，攒 400ms 写一次。
  Timer? _fxSaveTimer;

  /// 歌单网格布局：1 = 长方形横条（一行一个），2/3/4 = 方形网格每行列数
  int playlistColumns = 2;

  /// 视觉方案缩略图网格每行列数（2~4，默认 3）
  int presetGridColumns = 3;

  /// 是否已完成首次权限引导（首次启动引导开启音乐/通知权限）
  bool onboarded = false;

  /// 「需要重建整个 App」的版本号：主题色 / 自定义字体 / 字体缩放 / 引导完成状态
  /// 变化时自增。main.dart 只监听它来重建 MaterialApp —— 否则拖动壁纸透明度、
  /// 特效数量这类连续参数滑杆时（每帧 notifyListeners），整棵应用树会每帧重建、
  /// ThemeData 每帧重算并触发主题补间。
  final ValueNotifier<int> rebuildRevision = ValueNotifier(0);

  void _bumpRebuild() => rebuildRevision.value++;

  /// 缓存的 SharedPreferences 实例：原先每个 setter 都 await getInstance()
  /// （一次 platform channel 往返），拖动滑杆时每个 tick 都要走一遍，纯属浪费。
  static SharedPreferences? _prefs;

  static Future<SharedPreferences> _sp() async =>
      _prefs ??= await SharedPreferences.getInstance();

  static Future<void> load() async {
    final sp = await _sp();
    instance.themeIndex = sp.getInt('theme_index') ?? 0;
    // 自定义主题色 + 被隐藏的内置主题色（解析失败按空处理，不影响启动）
    final customRaw = sp.getString('custom_themes');
    if (customRaw != null) {
      try {
        instance.customThemes = (jsonDecode(customRaw) as List)
            .map((e) => accentSchemeFromJson(e as Map<String, dynamic>))
            .toList();
      } catch (_) {
        instance.customThemes = [];
      }
    }
    final hiddenRaw = sp.getString('hidden_default_themes');
    if (hiddenRaw != null) {
      try {
        instance.hiddenDefaultThemes =
            (jsonDecode(hiddenRaw) as List).map((e) => e as int).toSet();
      } catch (_) {
        instance.hiddenDefaultThemes = {};
      }
    }
    instance.fontScale = sp.getDouble('font_scale') ?? 1.0;
    // 没存过 = null = 跟随主题字号（默认态）
    instance.lyricFontScale = sp.getDouble('lyric_font_scale');
    instance.fontFamily = sp.getString('font_family') ?? '';
    instance.fontPath = sp.getString('font_path');
    instance.wallpaperPath = sp.getString('wallpaper_path');
    instance.wallpaperOpacity =
        (sp.getDouble('wallpaper_opacity') ?? 0.35).clamp(0.15, 0.7);
    instance.heartEnabled = sp.getBool('fx_heart') ?? true;
    instance.rainEnabled = sp.getBool('fx_rain') ?? true;
    instance.spectrumEnabled = sp.getBool('fx_spectrum') ?? true;
    instance.visualEffect = sp.getInt('fx_visual_effect') ?? 0;
    instance.ambientEffect = sp.getInt('fx_ambient_effect') ?? 0;
    instance.rhythmEffect = sp.getInt('fx_rhythm_effect') ?? 0;
    instance.edgeEffect = sp.getInt('fx_edge_effect') ?? 0;
    instance.edgeEnabled = sp.getBool('fx_edge') ?? true;
    // 视觉区图层表：老版本没有这份数据（只有单选字段 fx_visual_effect）→ 建成「单图层」，
    // 槽位 0 用的还是那套老参数键，所以老用户的画面一个像素都不变。
    instance.visualLayers.clear();
    final layersRaw = sp.getString('fx_visual_layers');
    if (layersRaw != null) {
      try {
        for (final e in jsonDecode(layersRaw) as List) {
          final l = VisualLayer.fromJson(e);
          if (l != null) instance.visualLayers.add(l);
        }
      } catch (_) {
        instance.visualLayers.clear();
      }
    }
    if (instance.visualLayers.isEmpty) {
      instance.visualLayers
          .add(VisualLayer(effect: instance.visualEffect, slot: 0));
    }
    instance.visualLayerSel = sp.getInt('fx_visual_layer_sel') ?? 0;
    // 选中槽位指向已删图层（数据来自老版本 / 被手改）→ 回落第一层
    instance.visualLayerSel = instance.selectedVisualLayer.slot;
    instance.visualEffect = instance.selectedVisualLayer.effect;
    // 每个特效的专属参数：一份 JSON（键 → 值），解析失败按「全部默认」处理
    instance.fxParams.clear();
    final fxRaw = sp.getString('fx_params');
    if (fxRaw != null) {
      try {
        final m = jsonDecode(fxRaw) as Map<String, dynamic>;
        for (final e in m.entries) {
          final v = e.value;
          if (v is num) _putFx(instance.fxParams, e.key, v);
        }
      } catch (_) {
        instance.fxParams.clear();
      }
    }
    instance.playlistColumns = sp.getInt('playlist_columns') ?? 2;
    instance.presetGridColumns = sp.getInt('visual_preset_columns') ?? 3;
    instance.onboarded = sp.getBool('onboarded') ?? false;
    instance.volumeFadeEnabled = sp.getBool('fx_volume_fade') ?? true;
    // 交叉淡变 + 预取（双播放器）：**缺省 false** —— 缺省值下必须与改动前逐项等价，
    // 所以这里读不到键就是关闭（不能写 `?? true`）。
    instance.crossfadeEnabled = sp.getBool('fx_crossfade') ?? false;
    // 「允许后台运行」引导提示过没有（缺省 false = 没提示过，见 lib/bg_hint.dart）
    instance.bgHintShown = sp.getBool('bg_hint_shown') ?? false;
    instance.abHintShown = sp.getBool('ab_hint_shown') ?? false;
    // 右下角搜索悬浮按钮：**缺省 false** —— 读不到键就是「没有那颗按钮」（原来的界面）。
    // ⚠️ 别写 `?? true`：那会让所有老用户在升级后凭空多出一颗按钮。
    instance.searchFabEnabled.value = sp.getBool('search_fab') ?? false;
  }

  /// 恢复备份后整体重读配置并通知重建（load 本身不通知，这里补一次）。
  Future<void> reload() async {
    await load();
    // ⚠️ 必须推一次粒子版本号：备份里的数量/大小/随机度这类**生成端**参数只在
    // fxParticleRevision 变化时才被氛围层采用（MaterialApp 重建不会重造它的 State）。
    // 漏了这句的症状 = 「从备份恢复后，雨滴数量/雪片大小这些要切一次特效才生效」。
    fxParticleRevision.value++;
    notifyListeners();
    _bumpRebuild(); // 恢复备份可能改了主题/字体，整棵 App 需要重建
  }

  Future<void> setThemeIndex(int v) async {
    themeIndex = v;
    notifyListeners();
    _bumpRebuild();
    await _saveThemeIndex();
  }

  /// 新增自定义主题色：追加到列表末尾并立即选中它。
  Future<void> addCustomTheme(AccentScheme scheme) async {
    customThemes.add(scheme);
    themeIndex = kDefaultThemeCount + customThemes.length - 1;
    notifyListeners();
    _bumpRebuild();
    await _saveCustomThemes();
    await _saveThemeIndex();
  }

  /// 删除主题色（按稳定槽位）：内置色做隐藏、自定义色做移除。
  /// 删到当前选中项则回退到第一套默认色；删到选中项之前的自定义项时索引顺移。
  Future<void> removeThemeAt(int stableIndex) async {
    if (stableIndex < kDefaultThemeCount) {
      hiddenDefaultThemes.add(stableIndex);
      if (themeIndex == stableIndex) themeIndex = 0;
    } else {
      final ci = stableIndex - kDefaultThemeCount;
      if (ci >= 0 && ci < customThemes.length) {
        customThemes.removeAt(ci);
        // 特效颜色存的是「稳定槽位」：自定义色删掉中间一个后，后面那些槽位整体前移。
        // 不跟着挪的话，原本选了后面某个自定义色的特效会**悄悄换成另一个颜色**。
        _shiftFxTintSlots(stableIndex);
        if (themeIndex == stableIndex) {
          themeIndex = 0;
        } else if (themeIndex > stableIndex) {
          themeIndex -= 1;
        }
      }
    }
    notifyListeners();
    _bumpRebuild();
    await _saveCustomThemes();
    await _saveThemeIndex();
  }

  /// 自定义主题色被删后，把特效颜色指向的槽位整体前移一格。
  /// 用的正是被删那个 → 回落「跟随主题」；排在它后面的 → 槽位 -1（仍旧是原来那套色）。
  void _shiftFxTintSlots(int removedStableIndex) {
    var changed = false;
    for (final k in fxParams.keys.where((k) => k.endsWith('.tint')).toList()) {
      final v = fxParams[k]!.round();
      if (v == removedStableIndex) {
        fxParams[k] = -1;
        changed = true;
      } else if (v > removedStableIndex) {
        fxParams[k] = (v - 1).toDouble();
        changed = true;
      }
    }
    if (changed) _scheduleFxSave();
  }

  /// 一键恢复：重新显示全部 40 套内置主题色，保留用户自定义主题色。
  Future<void> restoreDefaultThemes() async {
    if (hiddenDefaultThemes.isEmpty) return;
    hiddenDefaultThemes.clear();
    notifyListeners();
    _bumpRebuild();
    await _saveCustomThemes();
  }

  Future<void> _saveThemeIndex() async {
    final sp = await _sp();
    await sp.setInt('theme_index', themeIndex);
  }

  /// 自定义主题色与被隐藏的内置色一起落盘（两者都走这里，避免漏存）。
  Future<void> _saveCustomThemes() async {
    final sp = await _sp();
    await sp.setString(
      'custom_themes',
      jsonEncode(customThemes.map(accentSchemeToJson).toList()),
    );
    await sp.setString(
      'hidden_default_themes',
      jsonEncode(hiddenDefaultThemes.toList()),
    );
  }

  Future<void> setFontScale(double v) async {
    fontScale = v;
    notifyListeners();
    _bumpRebuild();
    final sp = await _sp();
    await sp.setDouble('font_scale', v);
  }

  /// 设置歌词独立字号；传 null = 恢复「跟随主题字号」。
  /// 这是连续参数，**刻意不 bump rebuild**：否则拖滑块会每帧重建整个 MaterialApp
  /// （见本项目「连续参数不要 bump」的不变量）。歌词页自己监听 AppConfig 重绘即可。
  Future<void> setLyricFontScale(double? v) async {
    lyricFontScale = v;
    notifyListeners();
    final sp = await _sp();
    if (v == null) {
      await sp.remove('lyric_font_scale');
    } else {
      await sp.setDouble('lyric_font_scale', v);
    }
  }

  /// 设置自定义字体：family 为已加载字体名、path 为字体文件路径；
  /// 传 null path 表示恢复系统默认字体。
  Future<void> setCustomFont(String family, String? path) async {
    fontFamily = family;
    fontPath = path;
    notifyListeners();
    _bumpRebuild();
    final sp = await _sp();
    if (path == null) {
      await sp.remove('font_family');
      await sp.remove('font_path');
    } else {
      await sp.setString('font_family', family);
      await sp.setString('font_path', path);
    }
  }

  Future<void> setWallpaperPath(String? p) async {
    wallpaperPath = p;
    notifyListeners();
    final sp = await _sp();
    if (p == null) {
      await sp.remove('wallpaper_path');
    } else {
      await sp.setString('wallpaper_path', p);
    }
  }

  Future<void> setWallpaperOpacity(double v) async {
    // 声明范围 0.15~0.7：滑杆值本就可信，但「视觉方案回放」「恢复备份」写入的
    // 值必须兜住，否则会出现几乎全黑/全透的壁纸。
    wallpaperOpacity = v.clamp(0.15, 0.7);
    notifyListeners();
    final sp = await _sp();
    await sp.setDouble('wallpaper_opacity', wallpaperOpacity);
  }

  Future<void> setHeartEnabled(bool v) async {
    heartEnabled = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setBool('fx_heart', v);
  }

  Future<void> setRainEnabled(bool v) async {
    rainEnabled = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setBool('fx_rain', v);
  }

  Future<void> setSpectrumEnabled(bool v) async {
    spectrumEnabled = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setBool('fx_spectrum', v);
  }

  Future<void> setVisualEffect(int v) async {
    // 老接口语义已升级：以前是「视觉区单选特效」，现在是「把**当前选中的图层**
    // 换成特效 v」（图层表为空时补一层）。视觉方案恢复老方案走的就是这条路。
    final i = visualLayers.indexWhere((l) => l.slot == visualLayerSel);
    if (i < 0) {
      visualLayers
        ..clear()
        ..add(VisualLayer(effect: v, slot: 0));
      visualLayerSel = 0;
    } else {
      visualLayers[i] = visualLayers[i].copyWith(effect: v);
    }
    visualEffect = v;
    if (v == 0) {
      _arrangeHeartChainIfLinked();
      _scheduleFxSave(); // 排线是直接写 fxParams 的，自己排落盘
    }
    fxParticleRevision.value++; // 换了特效：粒子列表要按新特效重算
    notifyListeners();
    await _saveVisualLayers();
  }

  /// 「换个特效」：把 [slot] 这一层的特效换成 [effect]。
  ///
  /// **刻意不用「删层 + 加层」**（那是错的写法）：删了再加会**换槽位**
  /// （新层拿 `max+1`）、把这一层**挪到列表末尾**（z 序静默变），调参也全丢。
  /// 这里只改 `effect` 一个字段 + 清掉旧特效**在这一槽位上**留下的参数。
  ///
  /// 参数清理分两条路（⚠️ 别想当然）：
  /// * `slot > 0`：走 [_purgeSlotParams]（按 `#slot.` 前缀清）；
  /// * `slot == 0`：[`_purgeSlotParams`] 是**空操作**（`#0.` 这个前缀永远不存在），
  ///   所以按**旧特效声明的键**逐个删。⛔ 绝不许写 `startsWith('v0.')` ——
  ///   那会连 `v0.link` / `v0.hands` / `v0.knot` 一起删掉，而它们是
  ///   **所有爱心层共用的裸键**（[FxParam.shared]），删了牵手当场坏。
  ///
  /// 返回 false = 这个 slot 不在图层表里（什么都没做）。
  Future<bool> replaceVisualLayerEffect(int slot, int effect) async {
    final i = visualLayers.indexWhere((l) => l.slot == slot);
    if (i < 0) return false;
    final old = visualLayers[i].effect;
    if (old == effect) return true; // 同款：一个字都不动（别 purge）
    visualLayers[i] = visualLayers[i].copyWith(effect: effect);
    if (slot > 0) {
      _purgeSlotParams(slot);
    } else {
      for (final p in Fx.find('v', old)?.params ?? const <FxParam>[]) {
        if (p.shared) continue; // ★ 牵手三项是所有爱心层共用的裸键，跳过
        fxParams.remove(p.key);
      }
    }
    // 只有「爱心集合真的变了」才重排牵手链（离开 / 加入各一次；
    // 两个都不是爱心时集合没变，别去乱动用户手动拖好的位置）。
    if (old == 0 || effect == 0) _arrangeHeartChainIfLinked();
    visualEffect = effect; // 老接口镜像
    // ★ 必需：漏了它 ⇒ 换成漩涡/聚散/3D球后**一片空白**，切一次特效才出来
    //（粒子列表在 fxParticleRevision 变化时才按新图层集重建）。
    fxParticleRevision.value++;
    _scheduleFxSave(); // 参数是上面直接改 map 的，得自己排一次落盘
    notifyListeners();
    await _saveVisualLayers();
    return true;
  }

  // ── 视觉区图层（同一特效能同时开多个）────────────────────────────────────
  /// 当前选中的图层；列表异常为空时给一个只读兜底，调用方不必判空。
  VisualLayer get selectedVisualLayer {
    for (final l in visualLayers) {
      if (l.slot == visualLayerSel) return l;
    }
    return visualLayers.isEmpty
        ? const VisualLayer(effect: 0, slot: 0)
        : visualLayers.first;
  }

  /// 新增一个图层（特效 [effect]）；到达上限 [kMaxVisualLayers] 时不动作，返回 false。
  /// 新图层用**没被用过的槽位**（最大值 +1），删图层会顺手清掉它那套参数，
  /// 所以槽位复用也不会串调参。
  Future<bool> addVisualLayer(int effect) async {
    if (visualLayers.length >= kMaxVisualLayers) return false;
    var next = 0;
    for (final l in visualLayers) {
      if (l.slot >= next) next = l.slot + 1;
    }
    visualLayers.add(VisualLayer(effect: effect, slot: next));
    visualLayerSel = next;
    visualEffect = effect;
    if (effect == 0) {
      // 爱心：开了牵手就顺手把它排进那条链，关着就错开一点免得完全重叠
      if (fxOn('v0.link')) {
        _arrangeHeartChain();
      } else {
        _offsetNewLayer(effect, next);
      }
    } else {
      _offsetNewLayer(effect, next);
    }
    fxParticleRevision.value++; // 多了一层：粒子列表按新图层集重算
    // 排一条线 / 错开位置都会直接写 fxParams（不走 setFx），得自己排一次落盘
    _scheduleFxSave();
    notifyListeners();
    await _saveVisualLayers();
    return true;
  }

  /// 新图层不设位置就会和已有同款图层**完全重叠**（看着像「没加上」），
  /// 按已有同款数量往右错开一点，一眼能看出多了一层。
  void _offsetNewLayer(int effect, int slot) {
    var same = 0;
    for (final l in visualLayers) {
      if (l.effect == effect && l.slot != slot) same++;
    }
    if (same == 0) return;
    final key = fxInstanceKey('v$effect.x', slot);
    if (Fx.param(key) == null) return; // 该特效没有水平位置参数（不该发生）
    fxParams[key] = (0.5 + 0.16 * same - 0.08 * (same - 1)).clamp(0.0, 1.0).toDouble();
  }

  /// 删除图层（最后一个不允许删：视觉区不该被清空，那是总开关的活）。
  Future<void> removeVisualLayer(int slot) async {
    if (visualLayers.length <= 1) return;
    visualLayers.removeWhere((l) => l.slot == slot);
    _purgeSlotParams(slot); // 清了参数也要落盘，否则重启后它又回来了
    if (visualLayerSel == slot) visualLayerSel = visualLayers.first.slot;
    visualEffect = selectedVisualLayer.effect;
    fxParticleRevision.value++;
    _scheduleFxSave();
    notifyListeners();
    await _saveVisualLayers();
  }

  /// 删图层时清掉它自己那套参数 —— 不清的话槽位被复用时，新图层会**继承上一层的调参**。
  void _purgeSlotParams(int slot) {
    final mark = '#$slot.';
    for (final k in fxParams.keys.where((k) => k.contains(mark)).toList()) {
      fxParams.remove(k);
    }
  }

  Future<void> setVisualLayerEnabled(int slot, bool v) async {
    final i = visualLayers.indexWhere((l) => l.slot == slot);
    if (i < 0 || visualLayers[i].enabled == v) return;
    visualLayers[i] = visualLayers[i].copyWith(enabled: v);
    fxParticleRevision.value++;
    notifyListeners();
    await _saveVisualLayers();
  }

  Future<void> selectVisualLayer(int slot) async {
    if (visualLayerSel == slot) return;
    visualLayerSel = slot;
    visualEffect = selectedVisualLayer.effect;
    notifyListeners();
    final sp = await _sp();
    await sp.setInt('fx_visual_layer_sel', slot);
    await sp.setInt('fx_visual_effect', visualEffect);
  }

  /// 整套覆盖图层表（视觉方案恢复用）。数据不合法则保持现状并返回 false。
  Future<bool> applyVisualLayers(Object? raw) async {
    if (raw is! List) return false;
    final list = <VisualLayer>[];
    for (final e in raw) {
      final l = VisualLayer.fromJson(e);
      if (l != null) list.add(l);
    }
    if (list.isEmpty) return false;
    visualLayers
      ..clear()
      ..addAll(list);
    if (!visualLayers.any((l) => l.slot == visualLayerSel)) {
      visualLayerSel = visualLayers.first.slot;
    }
    visualEffect = selectedVisualLayer.effect;
    fxParticleRevision.value++;
    notifyListeners();
    await _saveVisualLayers();
    return true;
  }

  /// 牵手联动：把全部爱心图层排成**一条线** —— 同一个 y（以第一颗为准）、
  /// 横向均匀铺开、间距按 [heartChainGap] 算，整条链正好铺满屏幕中间，
  /// 两端各留一段手拉向屏幕左右边缘。用户描述的「同一排、牵手」一步到位。
  void _arrangeHeartChain() {
    final hearts = [for (final l in visualLayers) if (l.effect == 0) l];
    if (hearts.length < 2) return;
    final n = hearts.length;
    final gap = heartChainGap(n);
    final y = fx(fxInstanceKey('v0.y', hearts.first.slot)).clamp(0.05, 0.95);
    for (var i = 0; i < n; i++) {
      final slot = hearts[i].slot;
      fxParams[fxInstanceKey('v0.y', slot)] = y.toDouble();
      fxParams[fxInstanceKey('v0.x', slot)] =
          (0.5 + (i - (n - 1) / 2) * gap).clamp(0.02, 0.98).toDouble();
    }
  }

  void _arrangeHeartChainIfLinked() {
    if (fxOn('v0.link')) _arrangeHeartChain();
  }

  Future<void> _saveVisualLayers() async {
    final sp = await _sp();
    await sp.setString(
        'fx_visual_layers', jsonEncode(visualLayers.map((l) => l.toJson()).toList()));
    await sp.setInt('fx_visual_layer_sel', visualLayerSel);
    await sp.setInt('fx_visual_effect', visualEffect);
  }

  // ── 特效专属参数（effect_catalog.dart 声明键与范围）──────────────────────

  /// 读某特效参数（缺省回落到注册表默认值）。
  double fx(String key) => fxParams[key] ?? Fx.def(key);

  /// 读整数型参数。
  int fxInt(String key) => fx(key).round();

  /// 读开关型参数。
  bool fxOn(String key) => fx(key) > 0.5;

  /// 写某特效参数：按注册表范围 clamp、去抖落盘、通知重绘。
  /// 键可以是**图层键**（`v0#2.size`）：查范围/默认值时自动剥掉 `#2` 上标。
  /// 只有标了 `particles: true` 的参数才推 [fxParticleRevision]（触发粒子重建）。
  Future<void> setFx(String key, double v) async {
    final p = Fx.param(key);
    if (p != null) v = v.clamp(p.min, p.max);
    if (fxParams[key] == v) return;
    final wasLink = fxParams['v0.link'] ?? Fx.def('v0.link');
    fxParams[key] = v;
    if (p?.particles ?? false) fxParticleRevision.value++;
    // 牵手联动**刚打开**的那一下：立刻把爱心图层排成一条线
    if (key == 'v0.link' && v > 0.5 && wasLink <= 0.5) _arrangeHeartChain();
    notifyListeners();
    _scheduleFxSave();
  }

  /// 把某特效的全部参数恢复默认（从 map 里删掉 = 回落注册表默认值）。
  Future<void> resetFx(Iterable<String> keys) async {
    var changed = false;
    for (final k in keys) {
      if (fxParams.remove(k) != null) changed = true;
    }
    if (!changed) return;
    fxParticleRevision.value++; // 数量/大小可能被重置，统一重建一次
    notifyListeners();
    _scheduleFxSave();
  }

  /// 整套覆盖参数（视觉方案 / 备份恢复用）：传 null 表示「这份数据没带参数」，不动现状。
  Future<void> applyFxParams(Map<String, dynamic>? m) async {
    if (m == null) return;
    fxParams.clear();
    for (final e in m.entries) {
      final v = e.value;
      if (v is num) _putFx(fxParams, e.key, v);
    }
    fxParticleRevision.value++;
    notifyListeners();
    _scheduleFxSave();
  }

  /// 写入一个特效参数：**只收 catalog 里声明过的键**（图层键先剥 `#槽位` 再查），
  /// 并按声明的范围 clamp。方案 / 备份 / 跨版本恢复都走这条路 —— 不 clamp 的话，
  /// 越界值会让滑杆显示（显示端自己 clamp）与绘制端实际取到的值对不上，
  /// 而且因为「值没变」早退，用户不动一下滑杆就永远修不回来。
  static void _putFx(Map<String, double> dst, String key, num value) {
    final p = Fx.param(key);
    if (p == null) return; // 已下架的参数直接丢掉，别留在 map 里
    dst[key] = value.toDouble().clamp(p.min, p.max);
  }

  /// 去抖落盘：拖滑杆时每帧都会写，攒 400ms 一次。
  void _scheduleFxSave() {
    _fxSaveTimer?.cancel();
    _fxSaveTimer = Timer(const Duration(milliseconds: 400), _saveFx);
  }

  Future<void> _saveFx() async {
    final sp = await _sp();
    await sp.setString('fx_params', jsonEncode(fxParams));
  }

  Future<void> setAmbientEffect(int v) async {
    ambientEffect = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setInt('fx_ambient_effect', v);
  }

  Future<void> setRhythmEffect(int v) async {
    rhythmEffect = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setInt('fx_rhythm_effect', v);
  }

  Future<void> setEdgeEnabled(bool v) async {
    edgeEnabled = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setBool('fx_edge', v);
  }

  /// 音量淡入淡出开关：只影响播放时的音量包络，**不 bump rebuild** ——
  /// 它不改主题/字体/引导状态，没有重建整棵 App 的必要。
  Future<void> setVolumeFadeEnabled(bool v) async {
    volumeFadeEnabled = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setBool('fx_volume_fade', v);
  }

  /// 交叉淡变 + 预取（双播放器）开关：只影响切歌那 300ms 的包络与第二个解码器，
  /// **不 bump rebuild**。入口 = 音效页「交叉淡变」（理由见字段注释）。
  Future<void> setCrossfadeEnabled(bool v) async {
    crossfadeEnabled = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setBool('fx_crossfade', v);
  }

  /// 记下「后台运行引导已提示过」：**落盘**是这条规则的全部 ——
  /// 只置内存字段的话，进程一重启 `bgHintShown` 又变回 false，用户每次播放都被弹一遍。
  ///
  /// ⚠️ **绝不 `_bumpRebuild()`**：它不是主题/字体/引导完成那类要整棵重建的配置，
  /// 只是给一次性提示用的一位标记（连续参数 bump 会让每帧重建整个 MaterialApp，
  /// 这里是「播一次就 bump 一次」，同样是不必要的整树重建）。
  Future<void> setBgHintShown(bool v) async {
    bgHintShown = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setBool('bg_hint_shown', v);
  }

  /// 记下「A-B 那颗按钮的第一次提示已经说过了」。
  /// 照 [setBgHintShown] 的样板：靠**落盘**保证「一辈子只说一次」，
  /// 且**刻意不 bump rebuild**（它不关主题/字体，没理由重建整棵树）。
  Future<void> setAbHintShown(bool v) async {
    abHintShown = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setBool('ab_hint_shown', v);
  }

  Future<void> setEdgeEffect(int v) async {
    edgeEffect = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setInt('fx_edge_effect', v);
  }

  Future<void> setPlaylistColumns(int v) async {
    playlistColumns = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setInt('playlist_columns', v);
  }

  Future<void> setPresetGridColumns(int v) async {
    presetGridColumns = v;
    notifyListeners();
    final sp = await _sp();
    await sp.setInt('visual_preset_columns', v);
  }

  /// 右下角搜索悬浮按钮开关（prefs 键 `search_fab`）。
  ///
  /// **落盘 + 只推 [searchFabEnabled] 这一个 ValueNotifier**：
  /// * ⛔ **不 `_bumpRebuild()`** —— 它不是主题/字体那类要整棵重建的配置（同
  ///   [setVolumeFadeEnabled]/[setCrossfadeEnabled]）；
  /// * ⛔ 也**不 `notifyListeners()`** —— 那会让歌单页/设置页等监听 `AppConfig.instance`
  ///   的页面各重建一次，而这次开关只影响根页面那一颗按钮；
  /// * 界面上的开关自己用 `ValueListenableBuilder` 听 [searchFabEnabled]，所以照样即时翻转。
  Future<void> setSearchFabEnabled(bool v) async {
    searchFabEnabled.value = v;
    final sp = await _sp();
    await sp.setBool('search_fab', v);
  }

  Future<void> setOnboarded(bool v) async {
    onboarded = v;
    notifyListeners();
    _bumpRebuild();
    final sp = await _sp();
    await sp.setBool('onboarded', v);
  }
}
