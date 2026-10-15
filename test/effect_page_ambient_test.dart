/// 氛围区「调参数毫无变化」—— **端到端**断言（真卡片入口 → 真参数页 → 真滑杆 → 真画布）。
///
/// ## 要复现的故障
/// 氛围特效的参数页上拖滑杆，**画面毫无变化**，各种各样的参数都试过都一样。
///
/// ## 🔴 本文件**没有渲染级断言**（做不到，理由在下面 —— 诚实 > 假绿）
/// 原来有两条「画布真的变了」的渲染级断言（★2 默认配置 / ★4 只剩 slot 3），
/// **已删除**：它们在全量上下文里**间歇性假红**（实测连跑 5 次全量，4 次红，
/// 红的恰好是这两条），根因是**相位**，不是代码：
/// * 萤火虫会**明灭**：低谷时那一只 alpha 掉到 `_kInk` 阈值以下就**不算墨**
///   ⇒「120 只处在低谷」可以比「26 只处在峰值」**还少**（实测 `Expected >688.5 / Actual 446`）；
/// * `toImage()` 必须包 `tester.runAsync` ⇒ **真实时间在流走**，全量下真实耗时不可预测
///   ⇒ 量在哪一段相位是**随机量**。
///
/// 四条修法都试过、都**没能**做成确定性：
/// ① 墨迹**像素总数**（对重排免疫）→ 仍随相位飘；
/// ② **连通块个数** → 在 24/25/26 游走，间歇假红；
/// ③ **并集窗口**（16 帧 × 250ms = 4s = `_loop` 一整轮，理论上相位不变量）→ 单文件 10 次里**仍红 8 次**；
/// ④ **把夹具钉成"冻结"** → **更糟**：冻在低谷就整轮都在低谷（单文件连红 10 次）。
/// ⇒ 结论：**删掉渲染级断言**，⛔ 不许用「放宽阈值/删断言」兜底。
/// **复现能力由下面的键级断言保住**（它们每次全绿、且把 `_k` 那套收起来就当场红）。
///
/// ## 本文件在钉什么（键级 + 夹具自证）
/// 1. **参数落点**：从氛围卡片进参数页拖真滑杆之后，`AppConfig.fxParams` 里出现的键
///    **必须就是画布会去读的那个基键**（`a4.count`），且**不许**出现任何带图层上标的
///    `a4#3.count` —— 这就是这个故障的全部形状（画布只读基键）；
/// 2. **夹具自证**：★0 断言"默认配置确实有 slot 0 的层""真入口走得到 a4 参数页""画布上有墨"；
/// 3. **波及面**：律动区 / 边框区在同样条件下也不许写上标键。
///
/// ⚠️ 断言刻意**走真入口**：`CustomPage()`（四张区卡）→ 点「氛围」→ 点该特效卡右半
/// `Icons.tune` → 真 `EffectPage`。⛔ 不手搓「已经打开某个页面」这种状态 ——
/// 手搓很容易绕过真 bug。
///
/// ## 量具纪律（这套东西踩过的坑，别再踩）
/// * ⛔ **不许 `pumpAndSettle`**：这一页挂着氛围层的常驻 `repeat()` 动画，settle 不了；
/// * ⛔ **不许 override `FlutterError.onError`**：用 `tester.takeException()` 取走已知噪音；
/// * ⛔ **`toImage()` 必须包 `tester.runAsync`**：它在引擎光栅线程上完成，
///   在 fake-async 里第二次调用**永远不返回**；
/// * ⛔ 收尾要把 `AppConfig` 那个 400ms 落盘去抖计时器跑掉，否则判「A Timer is still pending」；
/// * ⚠️ 夹具态**每次量之前都要断言并打进日志**（`_expectFixtureState`）——
///   "失败了看不出是哪条前置破了"本身就是一种坏断言。
library;

import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/effect_catalog.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/pages/custom_page.dart';
import 'package:mu_box_phone/pages/effect_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:mu_box_phone/widgets/ambient_layer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 哑播放器：本文件只渲染界面，一次原生调用都不许发生。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// `AmbientLayer.initState` 里 `PowerMonitor` 会 listen 一条 EventChannel；
/// 测试里没有原生实现 ⇒ `MissingPluginException` 会把用例判红。给个哑 handler。
void _wirePowerChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.mubox.mu_box_phone/power_save'),
    (call) async => null,
  );
}

// ─────────────────────── 渲染量具 ───────────────────────

const int _w = 400; // 逻辑视口宽（下面 physicalSize/dpr 也按它配）
const int _h = 900; // 逻辑视口高
final GlobalKey _shotKey = GlobalKey();

/// 墨迹阈值：任一通道 ≥ 40。氛围层的粒子是亮点，未画到的像素是**全透明**（0,0,0,0）。
///
/// **现在只服务 ★0 的那条量具自证**（「默认 count=26 时画布上必须有墨」——
/// 否则后面一切"墨迹"读数都是空谈）。它**不再**参与任何相位敏感的判定。
///
/// ⚠️ 阈值取 40、**刻意不下调**到 8~12：`_AmbientPainter` 底层那点旋律辉光
/// （α=0.05 ⇒ 单通道 ≤ 13）会被算成墨（先例：`fx_layer_render_test.dart` 的 `_kInk`）。
/// ⛔ 曾经用来兜"明灭相位"的那套并集窗口**已随渲染级断言一起删除**（见文件头），
/// **别再指向它**；相位问题在本文件里已无解，所以本文件不再做渲染级判定。
const int _kInk = 40;

Future<ui.Image> _grabImage(WidgetTester tester) async {
  final out = await tester.runAsync(() async {
    final b =
        _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return b.toImage();
  });
  return out!;
}

Future<Uint8List> _pixels(WidgetTester tester) async {
  final img = await _grabImage(tester);
  final bd = await tester.runAsync(
      () async => img.toByteData(format: ui.ImageByteFormat.rawRgba));
  final bytes = bd!.buffer.asUint8List();
  img.dispose();
  return bytes;
}

int _ink(Uint8List px, int w, int h) {
  var n = 0;
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final i = (y * w + x) * 4;
      if (px[i] >= _kInk || px[i + 1] >= _kInk || px[i + 2] >= _kInk) n++;
    }
  }
  return n;
}

/// 已知噪音：`SurfaceCard`（带底色）里装 `SwitchListTile`/`ListTile` ⇒ debug 下每次 build 报一条
/// `ListTile background color or ink splashes may be invisible.`（assert-only、release 一条没有）。
/// flutter_test 在 debug 下会把**同一批**聚成一条 `Multiple exceptions (N) …` 再交出来
/// —— 单条拿不到 ⇒ 只能按聚合串的形状过滤（同 `effect_page_position_test.dart`）。
bool _isKnownNoise(String s) =>
    s.contains('ListTile background color') ||
    (s.startsWith('Multiple exceptions (') &&
        s.endsWith('and at least one was unexpected.'));

/// 把已知噪音取走（`tester.takeException()` 是框架给的正路；⛔ 别 override `FlutterError.onError`）。
/// 返回**非噪音**异常列表 —— 必须为空。
List<Object> _drainNoise(WidgetTester tester) {
  final leaked = <Object>[];
  Object? e;
  while ((e = tester.takeException()) != null) {
    if (_isKnownNoise('$e')) continue;
    leaked.add(e!);
  }
  return leaked;
}

Future<void> _expectNoLeak(WidgetTester tester, String where) async =>
    expect(_drainNoise(tester), isEmpty, reason: '$where 漏出了非噪音异常');

// ─────────────────────── 宿主 ───────────────────────

/// 起 App：真 `AppConfig` + 假播放器 + 哑电源通道。
///
/// 🔴 **为什么这里必须手工把参数表清空**（这是测试隔离，不是"绕过 bug"）：
/// `AppConfig` 自己**缓存了一份 `SharedPreferences` 实例**（`app_config.dart:161-164`
/// 的 `static SharedPreferences? _prefs`）⇒ `SharedPreferences.resetStatic()` +
/// `setMockInitialValues({})` 只能换掉插件那侧的实例，**换不掉 AppConfig 手里那份**
/// ⇒ 上一条用例拖出来的参数会整份漏进下一条
/// （**历史观察，当时的用例已被删**：那时 ★3 一进来就带着上一条渲染用例留下的 `a4.count=71.0`；
///  现在本文件仍有 ★1/★3/★5 会写参数，所以这条清理照旧必须做）。
/// `layers` 由调用方给：默认那份 = `app_config.dart:219-222`（`[VisualLayer(effect: 0, slot: 0)]`）。
Future<void> _boot(WidgetTester tester, {List<VisualLayer>? layers}) async {
  tester.view.physicalSize = const Size(_w * 3, _h * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  _wirePowerChannel();
  await AppConfig.load();
  final cfg = AppConfig.instance;
  cfg.fxParams.clear();
  cfg.visualLayers
    ..clear()
    ..addAll(layers ?? const [VisualLayer(effect: 0, slot: 0)]);
  cfg.visualLayerSel = cfg.visualLayers.first.slot;
}

/// 挂**真入口**：`MaterialApp.builder` 里放一块**永远在树上**的氛围画布（供出图），
/// `home` 是真 `CustomPage()`（四张区卡）。
///
/// ⚠️ 两处刻意的对齐（都不是"绕过 bug"，是为了忠实还原真环境）：
/// 1. `CustomPage()`（**不带 group**）自己**没有 Scaffold** —— 它是给
///    `root_page.dart:191` 内嵌用的（`:126` 那句 `if (g == null) return body;`）。
///    所以这里补一层 `Scaffold`，与根页面给它的环境一致；
/// 2. 画布放 `builder` 而不是 `home` 里：路由 push 之后 `home` 会被盖住，
///    而 `builder` 那层与 `Navigator` 平级、每一帧都在画 ⇒ 出图稳定。
///
/// ## 夹具态：**动画在跑**（现在的事实，以及为什么）
/// 历史：曾经把这块画布钉成"冻结"想求稳定，结果**更糟** —— 冻在明灭低谷就**整轮都在低谷**
/// （实测单文件连红 10 次）。⇒ 现在一律**不冻结**（`AmbientLayer()` 缺省参数），
/// `_expectFixtureState`（`:207` 调用）在每次挂载后**显式断言并打印**"动画在跑 / isPlaying /
/// count / rev"，破了当场红。
///
/// 🔴 **但要说清：这条"不冻结"已经不再是为某个渲染断言服务的。**
/// 曾经用它去喂「并集窗口」（`N` 帧墨迹并集）那套相位不变量，**那套已随渲染级断言一起删除**
/// （文件头有全案：单文件 10 次里红 8 次，做不到确定性），**那个并集窗口助手已经删了、
/// 本文件里不存在这个符号**。
/// 保留"夹具在跑 + 自证"的理由只剩两条：① ★0 的「画布有墨」要在动画跑着时量才有意义；
/// ② 夹具态写进日志，失败了能一眼看出是哪条前置破了。
Future<void> _mount(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    builder: (context, child) => Stack(
      children: [
        Positioned.fill(
          child: RepaintBoundary(
            key: _shotKey,
            child: const AmbientLayer(),
          ),
        ),
        if (child != null) Positioned.fill(child: child),
      ],
    ),
    home: const Scaffold(
      backgroundColor: Colors.black,
      body: CustomPage(),
    ),
  ));
  await tester.pump();
  await _pumpFrames(tester, 6); // 让 `_elapsed` 涨起来、萤火虫亮起来
  _expectFixtureState(tester);
  await _expectNoLeak(tester, '挂载目录页');
}

/// ★ **夹具自证**：量之前显式断言「这一拍到底是什么态」，并把结果打进日志。
/// 破了就当场红 —— ⛔ 不许让断言在两种态下混着跑，也不许"失败了看不出是哪条前置破了"。
void _expectFixtureState(WidgetTester tester) {
  final st = tester.state(find.descendant(of: find.byKey(_shotKey), matching: find.byType(AmbientLayer)));
  final running = (st as dynamic).debugAnimationRunning as bool;
  // ignore: avoid_print
  print('A4: 夹具态 动画在跑=$running isPlaying=${playerService!.isPlaying} '
      'count=${AppConfig.instance.fx('a4.count')} '
      'rev=${AppConfig.instance.fxParticleRevision.value}');
  expect(running, isTrue,
      reason: '★ 夹具自证：画布必须**在跑**（实测 动画在跑=$running）—— '
          '并集窗口要扫过完整一轮明灭，停着就扫不到了');
}

/// 把出图相关之外的区关掉，让「墨迹」只由氛围区决定（量具卫生，不是绕过 bug）。
void _isolateAmbient(AppConfig cfg, int effect) {
  cfg.heartEnabled = false;
  cfg.spectrumEnabled = false;
  cfg.edgeEnabled = false;
  cfg.rainEnabled = true;
  cfg.ambientEffect = effect;
}

/// 真入口导航：区卡「氛围」→ 该特效卡右半的 `Icons.tune` → 落到真 `EffectPage`。
Future<void> _openAmbientFromCards(WidgetTester tester, String effectName) async {
  expect(find.text('氛围'), findsOneWidget,
      reason: '量具自证：目录页上「氛围」这张区卡必须恰好一张');
  await tester.tap(find.text('氛围'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400)); // 路由动画
  await tester.pump(const Duration(milliseconds: 400));
  await _expectNoLeak(tester, '进氛围区列表');

  final effects = Fx.of('a');
  final idx = effects.indexWhere((e) => e.name == effectName);
  expect(idx, isNonNegative,
      reason: '量具自证：氛围区特效表里要有「$effectName」（实际：'
          '${[for (final e in effects) e.name].join('/')}）');

  // ⚠️ 不能拿「含特效名的那一行 Row」当卡片锚点：名字在卡片**左半**的内层 Row 里，
  //    而 `Icons.tune` 在右半那个兄弟分支上 —— 那样找必然 0 命中（实测踩过）。
  //    改成**按网格序**取：`_effectGrid` 里每张卡一颗 `Icons.tune`，顺序 = `Fx.of('a')`。
  final tunes = find.byIcon(Icons.tune);
  expect(tunes, findsNWidgets(effects.length),
      reason: '量具自证：氛围区列表里每张特效卡右半各一颗 `Icons.tune`'
          '（${effects.length} 个特效）');
  await tester.tap(tunes.at(idx));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await _expectNoLeak(tester, '进参数页');
  expect(find.byType(EffectPage), findsOneWidget, reason: '前置：真的进了参数页');
}

/// 参数行里的那颗滑杆：靠**标签文字**定位它的那一列（标签→同列里的 Slider）。
Finder _sliderOf(String label) {
  final col = find.ancestor(of: find.text(label), matching: find.byType(Column));
  expect(col, findsWidgets, reason: '量具自证：参数「$label」那一行要在');
  return find.descendant(of: col.first, matching: find.byType(Slider));
}

/// 拖一颗滑杆到明显更大的值，并把去抖 / 粒子重建的计时器推过去。
Future<void> _dragSlider(WidgetTester tester, Finder slider) async {
  expect(slider, findsOneWidget, reason: '量具自证：要拖的那颗滑杆必须唯一');
  await tester.drag(slider, const Offset(140, 0));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200)); // 粒子重建 120ms 去抖
  await tester.pump(const Duration(milliseconds: 100));
  await _expectNoLeak(tester, '拖滑杆之后');
}

/// 推 [n] 帧（每帧 250ms）：让「粒子重建 120ms 去抖」与「重建后的重绘」**都稳稳落地**。
///
/// ⚠️ 为什么不是两三拍：实测「重建了但还没画上屏」会让读数停在上一个值
/// （`_rebuildParticles` 曾经不 `setState`，只能蹭动画帧）。多推几拍把
/// 「计时器到点 → 标脏 → 重绘」这条链走完，读数才不再靠运气。
Future<void> _pumpFrames(WidgetTester tester, int n) async {
  for (var i = 0; i < n; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
  await _expectNoLeak(tester, '推 $n 帧之后');
}

/// 带图层上标的键（`a4#3.count` 这类）—— 本次事故的形状。
List<String> _hashedKeys(AppConfig cfg) =>
    [for (final k in cfg.fxParams.keys) if (k.contains('#')) k];

/// 走几拍稳定态（把重绘节流与粒子去抖都推过去）。
Future<void> _settleFrame(WidgetTester tester) async => _pumpFrames(tester, 4);

/// 收尾：把 `_scheduleFxSave` 的 400ms 去抖计时器跑掉 + 拆树。
Future<void> _teardown(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

/// 事故条件：图层表里**只剩一个 slot 3 的层**（= 用户删过第一层之后的形状）。
const List<VisualLayer> _kOnlySlot3 = [VisualLayer(effect: 3, slot: 3)];

// ─────────── ★6 专用夹具：冻结态 + 「这一拍到底画没画」帧闩 ───────────
//
// 断言路线 = **数「有没有帧被画出来」**，不是数像素。
// 依据（Flutter SDK 的 `flutter_test/lib/src/binding.dart`，`pump` 的实现）：
//     if (duration != null) _currentFakeAsync!.elapse(duration);   // ← 120ms 去抖定时器在这里跑掉
//     _phase = newPhase;
//     if (hasScheduledFrame) { handleBeginFrame(...); handleDrawFrame(); }   // ← 排上帧才真画
// ⇒ `setState`（标脏）⇒ 排上帧 ⇒ 那一拍**真的画了一帧**；没有 ⇒ **一帧都不画**。
// 观测手段 = `SchedulerBinding.addPersistentFrameCallback`：它只由 `handleDrawFrame()` 调用
// ⇒ 计数就是「真的画了几帧」，且**与相位/明灭/像素无关**（⛔ 本文件头部血写的
// `toImage()`/像素/连通块那条路**一个字节都不碰**）。

/// ★6 用歌：`filePath` 指向不存在的文件是**故意的** —— `Lrc.load` / `SubLyricsStore.load`
/// 内部都 `exists()` 为假即返回空，不会把异步异常漏出来（同 `test/ambient_sync_test.dart:64-74`）。
Song _songStar6() => Song(
      id: -1006,
      title: '判据用歌',
      artist: 'test',
      durationMs: 200000,
      uri: 'file:///nonexistent/star6.mp3',
      filePath: '/nonexistent/star6.mp3',
    );

/// 帧闩：`handleDrawFrame()` 每画一帧回调一次。
///
/// ⚠️ 本机 SDK 的 `SchedulerBinding` **只有 `addPersistentFrameCallback`、没有 remove**
/// （persistent 回调按设计就是永久的）⇒ 这里用 `active` 自锁：`detach()` 之后回调还在
/// 表里，但一个数都不加。★6 是本文件最后一条用例，残留一个空转回调无副作用。
class _FrameLatch {
  int n = 0;
  bool active = false;
  void attach() {
    active = true;
    SchedulerBinding.instance.addPersistentFrameCallback(_tick);
  }

  void detach() => active = false;
  void _tick(Duration _) {
    if (active) n++;
  }
}

/// 当前动画在不在跑（`_c.isAnimating`）。私有 State 只能经 `dynamic` 取，只读。
bool _runningStar6(WidgetTester tester) =>
    (tester.state(find.byType(AmbientLayer)) as dynamic).debugAnimationRunning
        as bool;

/// ★6 的树：**只有一块冻结的画布**，刻意不挂 `CustomPage`/`EffectPage`。
///
/// 🔴 为什么必须只挂这一块（这是本条断言成立的前提，不是图省事）：
/// 「数帧」这条路线的前提是「冻结态下没有别的帧源」。`EffectPage` 里那块预览
/// `AmbientLayer(isPreview: true)` 是**永不冻结**的（`ambient_policy.dart:33`），
/// 它挂着一个常驻 `repeat()` ⇒ 每拍 `hasScheduledFrame` 恒为真 ⇒ 帧闩变成恒 1，
/// **修复在不在都绿**（假绿）。所以这里只留被测的那一块，并用下面的
/// 「量具自证②」把结论**当场量出来**，而不是靠嘴保证。
Future<void> _mountFrozenStar6(WidgetTester tester) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: const RepaintBoundary(child: AmbientLayer(freezeOnPause: true)),
    ),
  ));
  await tester.pump();
  await _expectNoLeak(tester, '挂冻结态画布');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // ⚠️ **必须先 `resetStatic()`**：`SharedPreferences` 会把实例与它那份内存快照缓存起来，
    //    只调 `setMockInitialValues` 的话 `AppConfig._sp()` 拿到的还是**上一轮那个实例**
    //    ⇒ 上一条用例拖出来的 `a4.count` 会漏进下一条
    //    （**历史观察，当时的用例已被删**：那时 ★3 一进来就带着上一条留下的 `71.0`；
    //     现在 ★1/★3/★5 仍会写参数，所以这条清理照旧必须做）。
    SharedPreferences.resetStatic();
    SharedPreferences.setMockInitialValues({});
    playerService = PlayerService(player: _StubPlayer());
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.mubox.mu_box_phone/power_save'), null);
    playerService = null;
  });

  // ───────── 一、前置与量具自证 ─────────

  testWidgets('★0 前置：默认配置确实有 slot 0 的层；真入口能走到 a4 参数页；画布有墨',
      (tester) async {
    await _boot(tester);
    final cfg = AppConfig.instance;

    // 量具自证：默认配置的图层表里**有** slot 0 —— 这是「默认路径不受槽位影响」的前提
    expect(cfg.visualLayers.any((l) => l.slot == 0), isTrue,
        reason: '前置：默认配置必须有一层 slot 0（`app_config.dart:219-222`）');
    expect(cfg.rainEnabled, isTrue, reason: '前置：氛围总开关默认是开的');

    _isolateAmbient(cfg, 4);
    await _mount(tester);
    await _openAmbientFromCards(tester, '萤火虫');

    expect(_sliderOf('萤火虫数量'), findsOneWidget,
        reason: '前置：真参数页上「萤火虫数量」那颗滑杆要在');

    await _settleFrame(tester);
    final img = await _grabImage(tester);
    // ignore: avoid_print
    print('A4: 出图尺寸 ${img.width}x${img.height}');
    final px = await _pixels(tester);
    final ink = _ink(px, img.width, img.height);
    // ⚠️ `toImage()` 默认 `pixelRatio = 1` ⇒ 出的是**逻辑尺寸**（400×900），不是 1200×2700。
    expect(img.width, _w, reason: '量具自证：出图宽度 = 逻辑宽（toImage 默认 pixelRatio 1）');
    expect(img.height, _h, reason: '量具自证：出图高度 = 逻辑高');
    expect(ink, greaterThan(0),
        reason: '★ 量具自证：默认（count=26）下画布上必须有墨 —— 否则后面「墨迹变了」是恒真废话');

    await _teardown(tester);
  });

  // ───────── 二、默认配置：端到端两条 ─────────

  testWidgets('★1 端到端·默认配置：拖「萤火虫数量」⇒ 落点是基键 a4.count，且没有任何 # 上标键',
      (tester) async {
    await _boot(tester);
    final cfg = AppConfig.instance;
    _isolateAmbient(cfg, 4);
    await _mount(tester);
    await _openAmbientFromCards(tester, '萤火虫');

    final before = cfg.fx('a4.count');
    await _dragSlider(tester, _sliderOf('萤火虫数量'));
    final after = cfg.fx('a4.count');
    // ignore: avoid_print
    print('A4: 默认配置 拖前=$before 拖后=$after '
        'fxParams=${cfg.fxParams} 上标键=${_hashedKeys(cfg)}');

    expect(after, isNot(before), reason: '前置：拖动必须真的改了值（否则下面两条是恒真）');
    expect(cfg.fxParams.containsKey('a4.count'), isTrue,
        reason: '★ 画布读的是基键 `a4.count`（`ambient_layer.dart:319` 的 `cfg.fxInt(\'a4.count\')`）'
            '⇒ 写进去的必须就是它');
    expect(_hashedKeys(cfg), isEmpty,
        reason: '★ 氛围参数**没有「一层一套」这回事** ⇒ 不许出现 `a4#N.count` 这类带图层上标的键');

    await _teardown(tester);
  });

  // ───────── 三、触发条件：图层表里没有 slot 0 ─────────

  testWidgets('★3 触发条件（图层表只剩 slot 3）：拖滑杆的落点仍必须是基键 a4.count', (tester) async {
    await _boot(tester, layers: _kOnlySlot3);
    final cfg = AppConfig.instance;
    _isolateAmbient(cfg, 4);
    await _mount(tester);
    await _openAmbientFromCards(tester, '萤火虫');

    final before = cfg.fx('a4.count');
    await _dragSlider(tester, _sliderOf('萤火虫数量'));
    final after = cfg.fx('a4.count');
    // ignore: avoid_print
    print('A4: 只剩 slot3 拖前=$before 拖后=$after '
        'fxParams=${cfg.fxParams} 上标键=${_hashedKeys(cfg)}');

    expect(after, isNot(before),
        reason: '★ 画布读的基键 `a4.count` 必须真的被改到 —— 没改到就是「调了没反应」的根因');
    expect(_hashedKeys(cfg), isEmpty,
        reason: '★ 氛围页不许往 `a4#3.count` 写：画布一个字节都不会去读它');

    await _teardown(tester);
  });

  // ───────── 四、波及面：律动区 / 边框区 ─────────

  for (final g in const [('r', '律动'), ('e', '边框')]) {
    testWidgets('★5 波及面·${g.$2}区（只剩 slot 3）：参数落点也必须是基键、不许带上标',
        (tester) async {
      await _boot(tester, layers: _kOnlySlot3);
      final cfg = AppConfig.instance;
      final effect = Fx.of(g.$1).first;
      await tester.pumpWidget(
          MaterialApp(home: EffectPage(group: g.$1, index: effect.index)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      final sliders = find.byType(Slider);
      expect(sliders, findsWidgets,
          reason: '量具自证：${g.$2}区「${effect.name}」页上至少得有一颗滑杆（否则本用例是空转）');
      await tester.drag(sliders.first, const Offset(140, 0));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await _expectNoLeak(tester, '${g.$2}区拖滑杆之后');

      // ignore: avoid_print
      print('${g.$1}: ${effect.name} fxParams=${cfg.fxParams} 上标键=${_hashedKeys(cfg)}');
      expect(cfg.fxParams, isNotEmpty,
          reason: '前置：这一拖必须真的写了值（否则"没有上标键"是恒真）');
      expect(_hashedKeys(cfg), isEmpty,
          reason: '★ ${g.$2}区参数同样没有「一层一套」⇒ 不许写 ${g.$1}N#M.k 这类键');

      await _teardown(tester);
    });
  }

  // ───────── 五、冻结态：粒子参数也必须上屏（⛔ 不靠动画帧兜底）─────────

  testWidgets('★6 冻结态：推粒子参数 ⇒ 必须真的重绘一次（`_rebuildParticles` 的 `setState` 标脏）',
      (tester) async {
    await _boot(tester);
    final cfg = AppConfig.instance;
    // 冻结三条件（`ambient_policy.dart:32-36`）：有歌 + **暂停** + `freezeOnPause`
    // （= `root_page.dart` 那处**唯一真背景**传的 true）。
    cfg.heartEnabled = true;
    cfg.rainEnabled = false;
    cfg.edgeEnabled = false;
    cfg.spectrumEnabled = false;
    cfg.ambientEffect = 4;
    playerService!.current = _songStar6();
    playerService!.isPlaying = false;
    await _mountFrozenStar6(tester);

    // ── 量具自证①：真的冻结了（`_c` 真停）──
    // 没有这一条，下面「一帧都没画」可能只是因为**根本不需要画**（比如整片关掉了）。
    expect(_runningStar6(tester), isFalse,
        reason: '★ 量具自证①：有歌 + 暂停 + freezeOnPause ⇒ `_c` 必须真的停住'
            '（`ambient_layer.dart:220-224` 的 `_c.stop()`）—— 否则本用例量的不是冻结态');

    final latch = _FrameLatch()..attach();
    addTearDown(latch.detach);

    // ── 量具自证②：冻结态下**没有别的帧源** ──
    // 推 1.25 秒（跨过 1 秒心跳），一帧都不许画；画了就说明帧闩不是干净的量具。
    final quiet = latch.n;
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    // ignore: avoid_print
    print('★6: 冻结静默期 250ms×5 画了 ${latch.n - quiet} 帧（期望 0）');
    expect(latch.n - quiet, 0,
        reason: '★ 量具自证②：冻结态下推时钟必须**一帧都不画**（实测画了 '
            '${latch.n - quiet} 帧）—— 有别的帧源（比如另一块永不冻结的画布）时，'
            '「有没有重绘」这条读数就恒为真、判据恒绿，必须当场红');
    await _expectNoLeak(tester, '冻结静默期');

    // ── 推粒子参数 ──
    // 走**生产同一条路**：参数页滑杆的 `onChanged` 就是 `AppConfig.instance.setFx(...)`
    // （`pages/effect_page.dart` 的滑杆回调；`app_config.dart:656-667`）⇒ 里面
    // `:662` 推 `fxParticleRevision`（`a4.count` 在 `effect_catalog.dart:530` 标了
    // `particles: true`）⇒ 氛围层 `_syncAnimation`（`ambient_layer.dart:227-231`）
    // 起 120ms 去抖 ⇒ `_rebuildParticles()`（`:397-403`）。
    final revBefore = cfg.fxParticleRevision.value;
    final before = cfg.fx('a4.count');
    await cfg.setFx('a4.count', before + 30);
    expect(cfg.fx('a4.count'), isNot(before), reason: '前置：这一推必须真的改了值');
    expect(cfg.fxParticleRevision.value, greaterThan(revBefore),
        reason: '前置：`a4.count` 是粒子参数 ⇒ 必须推 `fxParticleRevision`');

    // ⚠️ `setFx` 自己会 `notifyListeners()`（`:665`）⇒ `ListenableBuilder` 被标脏 ⇒
    //    这一拍**必然**画一帧，**与本次修复无关**（修不修都有）。先把它放掉再取基准，
    //    否则负向对照下也会 +1 ⇒ 假绿。
    await tester.pump();
    final base = latch.n;

    // ── 推过 120ms 去抖：`_rebuildParticles` 到点 ──
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }
    final drew = latch.n - base;
    // ignore: avoid_print
    print('★6: 去抖重建后重绘 $drew 帧（期望 ≥1）；running=${_runningStar6(tester)} '
        'count=${cfg.fx('a4.count')} rev=${cfg.fxParticleRevision.value}');

    // ★ 本条断言：去抖到点这一拍**必须画出一帧**。
    //   修在位 ⇒ `_rebuildParticles` 里的 `if (mounted) setState(() {});` 标脏 ⇒ 排帧 ⇒ 画。
    //   把那行删掉 ⇒ 只换数据、不标脏 ⇒ 冻结态下**一帧都不画** ⇒ 0 ⇒ 当场红。
    expect(drew, greaterThan(0),
        reason: '★ 冻结态下推粒子参数必须**真的重绘一次**：`_generateAll()` 只换数据'
            '（`ambient_layer.dart:287-386`，全程不 `setState`），平时靠 '
            '`AnimatedBuilder(animation: _frame)` 蹭动画帧；冻结时 `_frame` 不再涨 '
            '⇒ 唯一的标脏就是 `_rebuildParticles` 结尾那句 `if (mounted) setState(() {});`'
            '（`:402`）。实测去抖后重绘 $drew 帧 ⇒ 那行没了就是 0');
    await _expectNoLeak(tester, '★6 结束');

    await _teardown(tester);
  });

}
