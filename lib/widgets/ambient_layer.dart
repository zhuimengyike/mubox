/// 背景氛围特效层：跳动的爱心线条 + 常驻氛围（雨滴/星空）。
///
/// 位于背景壁纸与页面内容之间（root_page 的 Stack 第二层），常驻运行，
/// 不依赖播放状态。爱心由几圈抖动线条围成，中间显示歌曲名；左右两侧各有一
/// 束互相纠缠的线拉向屏幕左右边缘，下方有垂落流苏（根部拴在心尖）。
/// 氛围区可在雨滴/星空/阳光/彩星/萤火虫/极光/飘雪/气泡间切换（区内互斥）；阳光为树下斑驳光影。
/// 爱心与氛围可分别在设置页开关；边框区在呼吸/流光/歌词跑马灯/频谱灯带间切换（区内互斥）。
/// 锁屏/退后台时整个动画停止以省电。
library;

import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../ambient_policy.dart';
import '../app_config.dart';
import '../effect_catalog.dart';
import '../fx_shaders.dart';
import '../library_data.dart';
import '../lrc.dart';
import '../models.dart';
import '../player_service.dart';
import '../power_monitor.dart';
import '../spectrum_engine.dart';
import '../sub_lyrics.dart';
import '../theme.dart';


part 'ambient_particles.dart';
part 'ambient_painter.dart';

/// 背景氛围特效层：壁纸之上、页面内容与播放栏之下，常驻运行。
class AmbientLayer extends StatefulWidget {
  const AmbientLayer({
    super.key,
    this.isPreview = false,
    this.freezeOnPause = false,
  });

  /// 这一处**不是全局真背景**（特效预览页 / 次要页面）⇒ 永不因暂停而冻结。
  /// 设置页里的氛围层是给用户「暂停着调特效」用的，冻结了会被当成「特效坏了」（U0）。
  final bool isPreview;

  /// 播放暂停时冻结动画（省电）。**只有 root_page 的真背景传 true**。
  /// ⚠️ 两个参数都取缺省值时，[shouldAnimate] 的结果逐项等于改动前那句
  /// `_screenOn && (heartEnabled || rainEnabled || edgeEnabled)` ⇒ 没传参的调用点
  /// 观感与改动前逐帧一致。
  final bool freezeOnPause;

  @override
  State<AmbientLayer> createState() => _AmbientLayerState();
}

class _AmbientLayerState extends State<AmbientLayer>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const Duration _loop = Duration(milliseconds: 4000); // 一个完整循环

  /// ★ 动画**心跳**：周期重估门值，把停下的动画表重新拉起来。
  ///
  /// ## 为什么必须有它
  ///
  /// `_syncAnimation()` 原本**只挂事件**（`AppConfig` / `playerService.changeNotifier` /
  /// `AppLifecycleState` / `initState`），**没有任何周期重估**。而它是本类唯一能
  /// 「把停下表重新拉起来」的地方（`_c.repeat()` 在它里面）。⇒ 一旦门值假过一下、
  /// 又变回真，而恰好没有任何事件来重估，`_c` 就**永远停在 stop 态**：
  /// 表现是整层一直一动不动（同屏的频谱/进度条照常动，因为 `SpectrumView`
  /// 的父级每 500ms 重建一次、`didUpdateWidget → _sync()` 顺带把它救了回来 ——
  /// `AmbientLayer` 只听低频 `changeNotifier`，**没有这条路**）。
  ///
  /// 心跳 = 「每秒多问 `_syncAnimation()` 一次」，把「靠事件」补成「事件 + 兜底」。
  ///
  /// ## 要不要跑仍然只有 `shouldAnimate()` 说了算
  ///
  /// 判定本身在 `lib/ambient_policy.dart`（纯函数 + 真值表单测），心跳不改它；
  /// 心跳只是让 `_syncAnimation()` 里那两行
  /// `if (need && !_c.isAnimating) _c.repeat(); else if (!need && _c.isAnimating) _c.stop();`
  /// 有机会被重新执行一次。
  ///
  /// ## 暂停冻结的省电承诺不受影响
  ///
  /// 心跳回调里只做一件事：读几个 bool（`_screenOn` / 三个整片开关 / `p?.isPlaying` /
  /// `p?.current != null`）然后按同一个判定决定 repeat/stop。
  /// **不动 `_frame`、不触发重绘、不碰 GPU、不分配粒子**：暂停（或退后台、或整片关闭）时
  /// `need` 恒为 false ⇒ 每秒只是白读几个 bool 立刻返回，**没有一帧额外绘制**；
  /// 与"事件驱动"相比多出来的开销可以忽略。
  /// ⚠️ 它**不会**把该停的东西拉起来。
  Timer? _animWatchdog;

  late final AnimationController _c;
  final List<_Drop> _drops = []; // 固定种子生成，运行期只读
  final List<_Star> _stars = []; // 星空：固定种子生成，运行期只读
  // 粒子漩涡 / 粒子聚散 / 3D 深度球：粒子列表按**图层槽位**各存一份 ——
  // 同一特效开多个图层时「数量」是各层各的，共用一份列表会让第二层的数量滑杆失灵。
  final Map<int, List<_GalaxyParticle>> _galaxy = {};
  final Map<int, List<_HeartParticle>> _heartParts = {};
  final Map<int, List<_OrbPoint>> _orbPoints = {};
  final List<_Firefly> _fireflies = []; // 萤火虫：固定种子生成，运行期只读
  final List<_Snow> _snows = []; // 飘雪：固定种子生成，运行期只读
  final List<_Bubble> _bubbles = []; // 气泡：固定种子生成，运行期只读
  final List<_Dapple> _dapples = []; // 树影斑驳：固定种子生成，运行期只读
  final List<_Spark> _sparks = []; // 烟花火花：固定种子生成，运行期只读
  final List<_Flame> _flames = []; // 火焰：固定种子生成，运行期只读
  final List<_Ripple> _ripples = []; // 水面波纹：固定种子生成，运行期只读
  final List<_Petal> _petals = []; // 花瓣：固定种子生成，运行期只读
  List<LyricLine> _lyricLines = []; // 当前歌曲歌词（跑马灯用）
  List<String> _lyricSubs = []; // 子歌词（译文）：与 _lyricLines 按索引对齐
  List<int> _lyricTimes = []; // 歌词行起始时间（ms），二分查找当前行
  Song? _lyricSong; // 歌词对应的歌曲，切歌时重新加载
  final ValueNotifier<int> _frame = ValueNotifier(0); // 节流重绘计数（降帧省电）
  DateTime _lastFrameAt = DateTime.now(); // 上次重绘时间，用于时间节流降帧
  bool _powerSave = false; // 系统省电模式标记
  double _elapsed = 0; // 累计秒数（雨滴无缝循环用）
  double _lastValue = 0;
  bool _screenOn = true; // 前台/锁屏标记：锁屏停动画省电
  int _lastParticleRev = -1; // 上次重建粒子时的参数版本（见 AppConfig.fxParticleRevision）
  int _lastAmbientEffect = -1; // 上次重建粒子时的氛围特效（星空/彩星共用一份星星列表）
  Timer? _rebuildTimer; // 粒子重建去抖计时器（滑杆连续拖动时不逐帧重建）

  /// 背景层依赖的三个低频通知源：build 里每次新建 merge 会让监听反复解绑/重绑，
  /// 这里建一次复用（只跟随切歌/暂停/歌单变化，不跟随播放位置高频 tick）。
  late final Listenable _repaintSources = Listenable.merge([
    playerService?.changeNotifier,
    Library.instance,
    AppConfig.instance,
    FxShaders.revision, // 着色器就绪后重建一次 → 特效从路径实现切到 GPU 实现
  ]);

  @override
  void initState() {
    super.initState();
    _generateAll();
    _lastParticleRev = AppConfig.instance.fxParticleRevision.value;
    _lastAmbientEffect = AppConfig.instance.ambientEffect;
    _c = AnimationController(vsync: this, duration: _loop)..repeat();
    _c.addListener(_onTick);
    WidgetsBinding.instance.addObserver(this);
    AppConfig.instance.addListener(_syncAnimation);
    // 播放/暂停要立刻决定动画跑不跑（暂停冻结，见 ambient_policy.dart）。
    // 挂在低频的 changeNotifier 上：播放位置的高频 tick 只走 notifier，不会变成每帧回调。
    playerService?.changeNotifier.addListener(_syncAnimation);
    // 省电模式：监听系统省电开关，进入省电时降帧（全屏绘制最耗电）
    PowerMonitor.instance.start();
    PowerMonitor.instance.powerSaveMode.addListener(_onPowerSave);
    _powerSave = PowerMonitor.instance.powerSaveMode.value;
    _syncAnimation();
    // ★ 心跳：把「只靠事件重估」补成「事件 + 1 秒兜底」。回调里就是调同一个
    //   `_syncAnimation()`，为什么需要它见 `_animWatchdog` 的注释。
    //   默认 1 秒：本层本来就是 4 秒一个循环、重绘节流到 ~30fps，
    //   1 秒的兜底延迟在观感上察觉不到（健康态该区域每秒都有像素在变，冻结 = 0%；
    //   1 秒内必被拉起来，不会出现"冻住"的读数）。
    _animWatchdog =
        Timer.periodic(const Duration(seconds: 1), (_) => _syncAnimation());
    // 预编译 GPU 特效着色器（极光等）：Skia 下运行时编译较慢，提前备好；
    // 失败会静默回退到纯路径实现，不影响启动。
    FxShaders.preload();
  }

  @override
  void dispose() {
    _animWatchdog?.cancel(); // 心跳必须先停：dispose 之后不许再碰 _c / _frame
    AppConfig.instance.removeListener(_syncAnimation);
    playerService?.changeNotifier.removeListener(_syncAnimation);
    PowerMonitor.instance.powerSaveMode.removeListener(_onPowerSave);
    WidgetsBinding.instance.removeObserver(this);
    _rebuildTimer?.cancel();
    _c.dispose();
    _frame.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 锁屏/退后台：停止动画省电（只保留后台播放）；回前台恢复。
    // inactive 是过渡态（下拉通知栏/来电等），保持动画不闪。
    _screenOn = state != AppLifecycleState.paused && state != AppLifecycleState.hidden;
    _syncAnimation();
  }

  /// 该跑动画才跑：有任一特效开启 + 在前台 + **没被暂停冻结**；否则停掉，避免空转耗电。
  ///
  /// 判定本身在 `ambient_policy.dart`（纯函数 + 真值表单测）：暂停冻结只对
  /// root_page 那处真背景生效，特效预览（`isPreview`）永不冻结。
  ///
  /// 停一下再开**不会跳**（已核对本机 Flutter SDK 的 `animation_controller.dart`）：
  /// `stop()` 只停 Ticker，**不动 `value`**；`repeat()` 内部先 `stop()` 再
  /// `_startSimulation(_RepeatingSimulation(_value, …))`，而 `_RepeatingSimulation`
  /// 的 `_initialT` 正是按传入的 `_value` 反算的时间偏移（`x()` 里
  /// `totalTimeInSeconds = timeInSeconds + _initialT`）⇒ `x(0)` 恒等于冻结时的
  /// `_value`，动画从原位原速续上。`_onTick` 的 `_elapsed` 又是由 `_c.value` 的
  /// 增量累加的（见那里的注释），所以雨滴也不会跳位。
  void _syncAnimation() {
    final cfg = AppConfig.instance;
    final p = playerService;
    final need = shouldAnimate(
      screenOn: _screenOn,
      hasAnyEffect: cfg.heartEnabled || cfg.rainEnabled || cfg.edgeEnabled,
      playing: p?.isPlaying ?? false,
      hasSong: p?.current != null,
      isPreview: widget.isPreview,
      freezeOnPause: widget.freezeOnPause,
    );
    if (need && !_c.isAnimating) {
      _c.repeat();
    } else if (!need && _c.isAnimating) {
      _c.stop();
    }
    // 生成端参数（数量 / 大小 / 随机度 / 风斜…）任何一项变化 → 去抖后统一重建粒子；
    // 速度 / 亮度这类只在绘制端读的参数不推版本号，拖动时零重建、即时生效。
    if (cfg.fxParticleRevision.value != _lastParticleRev ||
        cfg.ambientEffect != _lastAmbientEffect) {
      _rebuildTimer?.cancel();
      _rebuildTimer = Timer(const Duration(milliseconds: 120), _rebuildParticles);
    }
  }

  /// ★ **只给测试看的只读观察口**（`@visibleForTesting`）：动画到底在不在跑。
  ///
  /// 为什么需要它：`_c` 是本类私有字段，而「心跳有没有把停下的表重新拉起来」
  /// 只能靠**它**来判（`test/ambient_sync_test.dart` 的正向/负向对照都以它为准）。
  /// 另两条路都不通：① 再调一次 `SingleTickerProviderStateMixin.createTicker()`
  /// 会踩「multiple tickers were created」断言；② 只看 `_frame` / 帧号是**时间基**观察，
  /// 帧号会被 33ms 节流吃掉，判不出「停住」。
  ///
  /// ⛔ **它不是生产 API，也一个字都不改判定**：纯读 `AnimationController.isAnimating`
  /// （Flutter 自己的公开只读属性）—— 不写任何状态、不参与任何分支。
  /// 之所以不加 `@visibleForTesting` 注解，是为了**不动 import**
  /// （本文件当前没有 `package:meta`，而 `flutter/foundation.dart` 的 `show` 清单里没有它）；
  /// 这条注释就是它的标记。
  bool get debugAnimationRunning => _c.isAnimating;

  /// 按当前各特效的参数重建全部粒子列表（雨滴 / 星空 / 萤火虫 / 飘雪 / 气泡 /
  /// 树影 / 烟花 / 火焰 / 波纹 / 花瓣 / 漩涡 / 聚散 / 3D 球）。
  /// 滑杆连续拖动时 AppConfig 每帧都通知，逐帧重建这十几类共数百个粒子会把 UI
  /// 线程压满（拖动明显掉帧）；故由 _syncAnimation 去抖到停手 120ms 后才调用本方法，
  /// 拖动过程最多滞后 120ms 生效。
  void _generateAll() {
    final cfg = AppConfig.instance;
    _drops
      ..clear()
      ..addAll(_generateDrops(
        0x1A2B3C4D, cfg.fxInt('a0.count'), cfg.fx('a0.random'),
        lenScale: cfg.fx('a0.len'),
        widthScale: cfg.fx('a0.width'),
        windScale: cfg.fx('a0.wind'),
      ));
    // 星空(1) 与彩星(3) 共用同一份星星列表，但**各自有独立的数量/大小/闪烁参数**：
    // 按当前选中的那个取参 —— 切换这两个特效也要重建粒子（见 _syncAnimation）。
    final st = cfg.ambientEffect == 3 ? 'a3' : 'a1';
    _stars
      ..clear()
      ..addAll(_generateStars(
        cfg.fxInt('$st.count'),
        sizeScale: cfg.fx('$st.size'),
        twinkleScale: cfg.fx('$st.twinkle'),
        bigPct: cfg.fx('$st.big'),
        lifeScale: cfg.fx('$st.life'),
      ));
    _dapples
      ..clear()
      ..addAll(_generateDapple(
        cfg.fxInt('a2.count'),
        breatheScale: cfg.fx('a2.breathe'),
        sizeScale: cfg.fx('a2.size'),
      ));
    _fireflies
      ..clear()
      ..addAll(_generateFireflies(
        cfg.fxInt('a4.count'),
        sizeScale: cfg.fx('a4.size'),
        blinkScale: cfg.fx('a4.blink'),
        driftScale: cfg.fx('a4.drift'),
      ));
    _snows
      ..clear()
      ..addAll(_generateSnow(
        cfg.fxInt('a6.count'),
        cfg.fx('a6.random'),
        sizeScale: cfg.fx('a6.size'),
        swayScale: cfg.fx('a6.sway'),
      ));
    _bubbles
      ..clear()
      ..addAll(_generateBubbles(
        cfg.fxInt('a7.count'),
        cfg.fx('a7.random'),
        sizeScale: cfg.fx('a7.size'),
      ));
    _sparks
      ..clear()
      ..addAll(_generateFireworks(
        cfg.fxInt('a8.bursts'),
        density: cfg.fx('a8.density'),
      ));
    _flames
      ..clear()
      ..addAll(_generateFlames(
        cfg.fxInt('a10.count'),
        sizeScale: cfg.fx('a10.size'),
        flickerScale: cfg.fx('a10.flicker'),
      ));
    _ripples
      ..clear()
      ..addAll(_generateRipples(
        cfg.fxInt('a13.count'),
        cfg.fx('a13.random'),
        maxRScale: cfg.fx('a13.maxR'),
        speedScale: cfg.fx('a13.speed'),
      ));
    _petals
      ..clear()
      ..addAll(_generatePetals(
        cfg.fxInt('a12.count'),
        cfg.fx('a12.random'),
        sizeScale: cfg.fx('a12.size'),
        spinScale: cfg.fx('a12.spin'),
        driftScale: cfg.fx('a12.drift'),
      ));
    // 粒子类视觉特效（漩涡 / 聚散 / 3D 球）：**按图层各生成一份**，
    // 「数量」参数取该图层自己的槽位键，所以同款特效开两层也能各调各的数量。
    _galaxy.clear();
    _heartParts.clear();
    _orbPoints.clear();
    for (final l in cfg.visualLayers) {
      if (l.effect == 2) {
        _galaxy[l.slot] =
            _generateGalaxy(cfg.fxInt(fxInstanceKey('v2.count', l.slot)));
      } else if (l.effect == 4) {
        _heartParts[l.slot] =
            _generateHeartParts(cfg.fxInt(fxInstanceKey('v4.count', l.slot)));
      } else if (l.effect == 6) {
        _orbPoints[l.slot] =
            _generateOrb(cfg.fxInt(fxInstanceKey('v6.count', l.slot)));
      }
    }
  }

  /// 去抖触发点：只重建粒子，不动参数。
  ///
  /// 🔴 **必须自己 `setState`**：`_generateAll()` 只是把数据换掉，**它不标脏**。
  /// 光靠「改了数量能看到变化」是**蹭**动画帧
  /// （`AnimatedBuilder(animation: _frame)` 每 33ms 重画一次时顺带读到新列表）得到的。
  /// 一旦这一层是**冻结态**（真背景暂停 + `freezeOnPause` ⇒ `_c.stop()`，`_frame` 不再涨），
  /// 重建出来的粒子就**永远不上屏**——改「数量/大小」看不到任何反应，直到有别的东西
  /// 恰好触发一次重绘。
  void _rebuildParticles() {
    _lastParticleRev = AppConfig.instance.fxParticleRevision.value;
    _lastAmbientEffect = AppConfig.instance.ambientEffect;
    _generateAll();
    // ⚠️ 计时器有可能在 State 已经销毁之后才到点（`dispose()` 里 cancel 了，这里是二道闸）
    if (mounted) setState(() {});
  }

  /// 省电模式变化回调：标记是否降帧。
  void _onPowerSave() {
    _powerSave = PowerMonitor.instance.powerSaveMode.value;
  }

  /// 加载某首歌曲的歌词（跑马灯取当前行用）。异步；若期间切歌则丢弃旧结果。
  Future<void> _loadLyrics(Song? song) async {
    if (song == null) {
      _lyricLines = [];
      _lyricSubs = [];
      _lyricTimes = [];
      return;
    }
    final lines = await Lrc.load(song);
    final subs = await SubLyricsStore.load(song);
    if (!mounted) return;
    if (_lyricSong != song) return; // 切歌了，丢弃过期加载
    _lyricLines = lines;
    _lyricSubs = subs;
    _lyricTimes = [for (final l in lines) l.time.inMilliseconds];
    setState(() {});
  }

  /// 当前进度对应的歌词行下标（二分查找）；无词返回 -1。
  int _lyricIndexAt(Duration pos) {
    if (_lyricTimes.isEmpty) return -1;
    final target = pos.inMilliseconds;
    var lo = 0, hi = _lyricTimes.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (_lyricTimes[mid] <= target) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 当前进度下的歌词行文本（二分查找）；无歌词返回空串。
  String _currentLyric(Duration pos) {
    final idx = _lyricIndexAt(pos);
    if (idx < 0) return '';
    return _lyricLines[idx].text;
  }

  /// 当前行的子歌词（译文）；该行没有则空串。
  String _currentSub(Duration pos) {
    final idx = _lyricIndexAt(pos);
    if (idx < 0 || idx >= _lyricSubs.length) return '';
    return _lyricSubs[idx];
  }

  /// 当前歌词行内的进度（0..1，用于逐字点亮）；无歌词或该行无时长返回 0。
  double _lyricProgress(Duration pos) {
    final idx = _lyricIndexAt(pos);
    if (idx < 0) return 0;
    final start = _lyricTimes[idx];
    final end = idx + 1 < _lyricTimes.length
        ? _lyricTimes[idx + 1]
        : start + 4000; // 最后一行给 4 秒
    final dur = end - start;
    if (dur <= 0) return 0;
    return ((pos.inMilliseconds - start) / dur).clamp(0.0, 1.0);
  }

  /// 累计真实流逝秒数：循环回绕（value 1→0）时补上一整段，雨滴永不跳变。
  ///
  /// ⚠️ 它是**动画时间**而不是墙钟：`_elapsed` 只由 `_c.value` 的增量累加（下面
  /// 325 行的 `dt`）。所以暂停冻结时（`_c.stop()` ⇒ 本回调不再被调用）`_elapsed`
  /// 与 `_lastValue` 一起冻在原地，恢复后第一拍 `v - _lastValue` 只差一帧的量 ⇒
  /// **从冻结处连续续上，雨滴不跳位**。别改成用 `DateTime.now()` 差分 ——
  /// 那样一恢复就会补上「暂停了多久」的一大段，雨滴会整屏瞬移。
  void _onTick() {
    final v = _c.value;
    final loopSec = _loop.inMilliseconds / 1000.0;
    var dt = (v - _lastValue) * loopSec;
    if (dt < 0) dt += loopSec; // 回绕补偿
    _elapsed += dt;
    _lastValue = v;
    // 全屏背景最耗 GPU，必须节流：背景是慢动画（雨滴/心跳/边框），不必每帧重绘。
    // 实测「全速 60fps」下 2K 全屏每帧重栅格化 22ms+，渲染线程饱和、划拉明显顿挫（100% 掉帧）。
    // 节流到 ~30fps：背景观感几乎无差、渲染负载减半，给左右/上下滑动让出帧预算（HEAD 旧版即为此设定）。
    // 省电模式进一步降到 ~20fps（全屏绘制最耗电，牺牲流畅换续航）。
    final now = DateTime.now();
    final thresh = _powerSave ? 50 : 33; // 每帧重绘最小间隔（毫秒）
    if (now.difference(_lastFrameAt).inMilliseconds >= thresh) {
      _lastFrameAt = now;
      _frame.value++;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 主题色在 build 读一次：切主题时 MaterialApp 重建、整棵子树重读，自动跟随。
    final primary = context.accent;
    final light = context.accentLight;
    final scaler = MediaQuery.textScalerOf(context);
    return ListenableBuilder(
      // 监听低频 changeNotifier(切歌/暂停/模式变化)：切歌时重建更新背景标题就够，
      // 不必跟随播放位置的高频 tick——否则每次位置更新都对整棵树重建一遍 painter 参数，
      // 与左右滑动叠加就是「一卡一卡」。播放位置高频通知只给进度条那层，不牵连背景。
      listenable: _repaintSources,
      builder: (context, _) {
        // ⚠️ 氛围配色必须**在这里**解析：它依赖 AppConfig 里的「特效颜色」参数，
        // 放在 builder 外面就只在 State.build 时算一次，之后改颜色这句根本不重新执行，
        // 表现就是「选了颜色没反应、永远跟着主题色」（踩过一次）。
        final (ambPrimary, ambLight) = _resolveAmbientColors(primary, light);
        final song = playerService!.current;
        final hasSong = song != null;
        final title = hasSong ? Library.instance.displayTitle(song) : 'Mu Box';
        // 切歌时异步加载歌词。
        if (song != _lyricSong) {
          _lyricSong = song;
          _loadLyrics(song);
        }
        return AnimatedBuilder(
          animation: _frame,
          // 在每帧重建的 builder 里取「当前进度对应歌词行」与行内进度：
          // 这样跑马灯与歌词逐字才随播放进度实时更新，而不是卡在切歌那一刻。
          builder: (context, _) {
            final lyric = _currentLyric(playerService!.pos);
            final marqueeText = lyric.isNotEmpty ? lyric : title;
            final lyricProgress = _lyricProgress(playerService!.pos);
            return RepaintBoundary(
              child: CustomPaint(
                size: Size.infinite,
                painter: _AmbientPainter(
                  t: _c.value,
                  elapsed: _elapsed,
                  primary: primary,
                  light: light,
                  title: title,
                  marqueeText: marqueeText,
                  lyricText: lyric,
                  subLyric: _currentSub(playerService!.pos),
                  lyricProgress: lyricProgress,
                  hasSong: hasSong,
                  playing: playerService!.isPlaying,
                  textScaler: scaler,
                  drops: _drops,
                  stars: _stars,
                  fireflies: _fireflies,
                  snows: _snows,
                  bubbles: _bubbles,
                  dapples: _dapples,
                  galaxyBySlot: _galaxy,
                  heartPartsBySlot: _heartParts,
                  sparks: _sparks,
                  flames: _flames,
                  ripples: _ripples,
                  petals: _petals,
                  orbBySlot: _orbPoints,
                  spectrum: SpectrumEngine.instance.bars.value,
                  ambientPrimary: ambPrimary,
                  ambientLight: ambLight,
                  showHeart: AppConfig.instance.heartEnabled,
                  showAmbient: AppConfig.instance.rainEnabled,
                  ambientEffect: AppConfig.instance.ambientEffect,
                  // 视觉区图层快照（只带显示的层）：每次 build 新建一份，
                  // painter 靠逐项相等判断「图层被增删/换特效/开关过」
                  visualLayers: [
                    for (final l in AppConfig.instance.visualLayers)
                      if (l.enabled) l
                  ],
                  // 参数快照：每次 build 拷一份，painter 靠引用变化感知「参数被调过」
                  fx: Map.of(AppConfig.instance.fxParams),
                  bass: SpectrumEngine.instance.bass.value,
                  melody: SpectrumEngine.instance.melody.value,
                  showEdge: AppConfig.instance.edgeEnabled,
                  edgeEffect: AppConfig.instance.edgeEffect,
                  auroraShader: FxShaders.aurora,
                  orbShader: FxShaders.orb,
                  waterShader: FxShaders.water,
                ),
              ),
            );
          },
        );
      },
    );
  }
}

