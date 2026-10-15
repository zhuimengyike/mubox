/// 「四大区块折叠」+「图层 ＋（选择器）/－」+「整卡进设置页」+「同特效切层」的断言。
///
/// ## 要解决的是什么
/// 症状一：**选了一个特效之后不让选第二种特效**。
/// 症状二：**开启了第二个就无法调整第一个了** —— 想要的是「弄了多个之后可以单独调整任意一个」。
/// 做法：一个加号，点一下**从 8 个特效中选一个**。
///
/// * **一级 = 四张区入口卡**（`CustomPage()`，仍嵌在根页面里，**不铺自己的背景**）；
/// * **二级 = 区专属页**（`CustomPage(group: 'v')`，`push` 出来）：
///   ★ **必须自带壁纸 + 氛围层**，否则 push 出来是黑底 —— 第 2 条钉这个；
/// * ★★ **「＋」= 弹出「从 8 个视觉特效里挑一个」的选择器**（`FxEffectPickerSheet`，
///   两处共用）—— **不再**是「给当前特效再加一层同款」；挑中哪个就
///   `addVisualLayer(那个)`。⚠️ 列的是**全部 8 个**、不是只列还没开的
///   （挑当前这个 = 再叠一层同款，两条需求都要满足）；
/// * ★★ **点一张视觉特效卡（整张卡）= 进它自己的设置页**：已经有层就进它那一层
///   （选中的是它就进它那层，否则进它的第一层）；**一层都没有 ⇒ 先加一层再进**
///   —— ⛔ 旧版那句「长按这张卡把它换到当前层」的**死胡同**提示不许再出现；
/// * **长按 = 把当前层换成它**（正式手势，保留）；**到上限仍先拒绝 + 说话**；
/// * **同一特效的多层**能在它自己的设置页里切换（`◀ 第 n/m 层 ▶`），
///   ⛔ 别的特效的层不混进来、⛔ 切换不改层表的顺序/槽位。
///
/// ⚠️ 量具纪律同 `fx_layer_render_test.dart`：**禁 `pumpAndSettle`**（这些页面挂着
/// 常驻 `repeat()` 动画）、**别 override `FlutterError.onError`**（用 `takeException`）、
/// 收尾把 `AppConfig` 的 400ms 去抖计时器跑掉、每个用例有显式超时。
library;

import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/effect_catalog.dart';
import 'package:mu_box_phone/pages/custom_page.dart';
import 'package:mu_box_phone/pages/effect_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:mu_box_phone/widgets/ambient_layer.dart';
import 'package:mu_box_phone/widgets/fx_effect_picker.dart';
import 'package:mu_box_phone/widgets/wallpaper_layer.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void _mockPowerChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
    const MethodChannel('com.mubox.mu_box_phone/power_save'),
    (call) async => null,
  );
}

void _clearPowerChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('com.mubox.mu_box_phone/power_save'), null);
}

/// 已知噪音：`SurfaceCard`（带底色）里装开关 ⇒ debug 下每次 build 报一条
/// `ListTile background color …`，而 flutter_test 会把同一批聚成一条
/// `Multiple exceptions (N) …`（单条拿不到）。详见 `fx_layer_render_test.dart`。
bool _isKnownNoise(String s) =>
    s.contains('ListTile background color') ||
    (s.startsWith('Multiple exceptions (') &&
        s.endsWith('and at least one was unexpected.'));

List<Object> _drainNoise(WidgetTester tester) {
  final leaked = <Object>[];
  Object? e;
  while ((e = tester.takeException()) != null) {
    if (_isKnownNoise('$e')) continue;
    leaked.add(e!);
  }
  return leaked;
}

/// 把 `AppConfig._scheduleFxSave` 的 400ms 去抖计时器跑掉（否则框架判
/// 「A Timer is still pending」）。⚠️ 会推进动画时钟 ⇒ 只在最后调。
Future<void> _flush(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

/// 把当前那条 SnackBar **彻底送走**（连同排在它后面的队列）。
///
/// ⛔ 不能用 `pumpAndSettle`：这些页面挂着常驻 `repeat()` 动画，永远 settle 不了。
/// ⚠️ 也**不能只 `pump(3s)` 或固定 20 帧**：`ScaffoldMessenger` 的自动隐藏计时器是
/// **在 `build()` 里才挂上的**（`scaffold.dart:614-627`，条件是
/// `_snackBarController.isCompleted && _snackBarTimer == null`），而每一条的进场/退场
/// 各要单独的帧 ⇒ **一条 ≈ 2s + 几帧**；`_toast` 又是 `clearSnackBars()` + `showSnackBar()`
/// （当前那条要先退场，新的才轮到），于是「上一条还挂在树上、新的一条排在它后面」
/// —— 实测固定 20 帧时 `已加上…` 那条还在，导致新提示量不到。
/// 所以这里**轮询到树上没有 SnackBar 为止**（有界 120 帧 = 12s，防死循环）。
Future<void> _clearToasts(WidgetTester tester) async {
  await tester.pump(const Duration(seconds: 4));
  for (var i = 0; i < 120; i++) {
    if (find.byType(SnackBar).evaluate().isEmpty) return;
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 把**推路由**或**底部弹层**的进场动画跑完（各约 250~300ms）。
/// ⛔ 同样不能用 `pumpAndSettle`（常驻动画）。固定推进 400ms 足够。
Future<void> _routeIn(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// 把 `Config` 摆成「视觉区一个图层表」的确定状态。
void _resetVisual(List<VisualLayer> layers, {int sel = 0}) {
  final cfg = AppConfig.instance;
  cfg.fxParams.clear();
  cfg.visualLayers
    ..clear()
    ..addAll(layers);
  cfg.visualLayerSel = sel;
  cfg.visualEffect = layers.first.effect;
  cfg.heartEnabled = true;
}

/// `AppConfig.instance` 的快捷取法。
AppConfig get _cfg => AppConfig.instance;

/// 图层表的「槽位:特效」快照 —— 判「别的层一个都不许变」用。
List<String> _shape(AppConfig cfg) =>
    [for (final l in cfg.visualLayers) '${l.slot}:${l.effect}'];

/// 特效**卡片**上的名字。
/// ⚠️ 视觉区页面里**图层胶囊**也会写同样的字（同一个特效开了两层就有两颗胶囊），
/// 所以要保证点的是卡片时得限定在网格里 —— 否则 `ensureVisible` 报
/// "Too many elements"。
Finder _card(String name) =>
    find.descendant(of: find.byType(GridView), matching: find.text(name));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _mockPowerChannel();
    playerService = PlayerService(player: _StubPlayer());
    _resetVisual([const VisualLayer(effect: 0, slot: 0)]);
  });

  tearDown(() {
    playerService = null;
    _clearPowerChannel();
  });

  // ─────────── 1. 一级 = 四张区入口卡；特效卡一张都没有 ───────────

  testWidgets('1 目录页只剩四个区的入口卡（特效卡一张都不在）', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: CustomPage()),
    ));
    await tester.pump();
    expect(_drainNoise(tester), isEmpty);

    // 四个区名各一张
    for (final g in kFxGroups) {
      expect(find.text(g.title), findsOneWidget, reason: '区「${g.title}」的入口卡');
    }
    // 四个区总开关
    expect(find.byType(Switch), findsNWidgets(kFxGroups.length));
    // ★ 特效卡**一张都没有**：特效网格在二级页里
    expect(find.byType(GridView), findsNothing,
        reason: '★ 一级页只该有 4 张入口卡，特效网格必须搬进各区自己的页面');
    // 一级页**不铺自己的背景**（嵌在根页面里，铺了会盖住真背景）
    expect(find.byType(AmbientLayer), findsNothing);
    expect(find.byType(WallpaperLayer), findsNothing);
    // ignore: avoid_print
    print('MuBox 判据·四区折叠1：一级页 4 张入口卡、4 个开关、0 张特效卡、不自带背景 ✅');
  });

  // ─────────── 2. 二级 = 只渲染那一个区 + 自带预览 ───────────

  testWidgets('2 区页面只渲染那一个区，且自带壁纸+氛围预览（不然是黑底）',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: CustomPage(group: 'v'),
    ));
    await tester.pump();
    expect(_drainNoise(tester), isEmpty);

    // 视觉区的特效卡在（爱心 / 粒子漩涡…）
    // ⚠️ 「爱心」会出现两次：特效卡一次 + 图层条那一层的胶囊一次 —— 所以用 findsWidgets。
    expect(find.text('爱心'), findsWidgets);
    expect(find.text('粒子漩涡'), findsOneWidget);
    expect(find.byType(GridView), findsOneWidget);
    // 别的区一个都不在（律动区的「频谱」、边框区的…）
    expect(find.text('频谱'), findsNothing, reason: '★ 二级页只渲染自己那一个区');
    expect(find.text('雨滴'), findsNothing);
    // ★ 自带预览：push 出来才有背景可看
    expect(find.byType(WallpaperLayer), findsOneWidget,
        reason: '★ 区页面必须自带 WallpaperLayer，否则 push 出来是黑底');
    expect(find.byType(AmbientLayer), findsOneWidget,
        reason: '★ 区页面必须自带 AmbientLayer(isPreview)');
    // 视觉区多一条图层条 + 层数控件（＋/－ 与设置页共用同一个控件）
    expect(find.textContaining('图层 '), findsWidgets);
    expect(_drainNoise(tester), isEmpty);
    // ignore: avoid_print
    print('MuBox 判据·四区折叠2：视觉区页 只含视觉区 + 自带 Wallpaper/Ambient 各 1 ✅');
  });

  // ─────────── 3. ★★ 点整张卡 = 进它自己的设置页（没层就先加一层）───────────

  testWidgets('3 ★★ 一层都没有的特效：点它的卡 ⇒ 恰好 +1 层（effect 就是它）'
      '、别的层一个都不动、并进了它的设置页', (tester) async {
    final cfg = _cfg;
    _resetVisual([
      const VisualLayer(effect: 0, slot: 0),
      const VisualLayer(effect: 5, slot: 2),
    ]);
    await tester.pumpWidget(const MaterialApp(
      home: CustomPage(group: 'v'),
    ));
    await tester.pump();
    _drainNoise(tester);

    expect(cfg.visualLayers.length, 2, reason: '起手两层（爱心 / 万花筒）');
    expect(cfg.visualLayers.any((l) => l.effect == 2), isFalse,
        reason: '前置：「粒子漩涡」一层都没有');
    final before = _shape(cfg);

    await tester.ensureVisible(_card('粒子漩涡'));
    await tester.pump();
    await tester.tap(_card('粒子漩涡'));
    await _routeIn(tester); // 加层那几个 await + 路由进场

    // ① ★ 恰好新增 1 条，且那条的 effect 就是它
    expect(cfg.visualLayers.length, before.length + 1,
        reason: '★ 点一张没层的卡 = **加恰好一层**');
    expect(cfg.visualLayers.last.effect, 2,
        reason: '★ 加的那层必须是**点的这个特效**');
    expect(cfg.visualLayerSel, cfg.visualLayers.last.slot,
        reason: '★ 新加的那层要自动选中');
    // ② ★ 别的层逐项不变（槽位 + 特效 + 顺序）
    expect(_shape(cfg).take(before.length).toList(), before,
        reason: '★ 别的层的 effect / 槽位 / z 序一个都不许变');
    // ③ ★ 进了它的设置页，且页面认的就是这个特效、这一层
    expect(find.byType(EffectPage), findsOneWidget,
        reason: '★ 点卡必须直接进它的设置页');
    final page = tester.widget<EffectPage>(find.byType(EffectPage));
    expect(page.index, 2, reason: '★ 进的是「粒子漩涡」自己的页');
    expect(page.slot, cfg.visualLayers.last.slot, reason: '★ 进的是刚加的那一层');
    expect(find.textContaining('粒子漩涡 · 第 1 层'), findsOneWidget,
        reason: '★ 页面标题要对得上（这是它自己的第 1 层）');
    // ④ ★ 旧版那条死胡同提示不许再出现
    expect(find.textContaining('长按这张卡'), findsNothing,
        reason: '★「长按这张卡把它换到当前层」是用户报的死胡同，必须消失');
    expect(_drainNoise(tester), isEmpty);
    // ignore: avoid_print
    print('MuBox 判据·点卡进页3：层表 ${before.join(",")} ⇒ ${_shape(cfg).join(",")}；'
        '进了 EffectPage(index=${page.index}, slot=${page.slot}) ✅');
    await _flush(tester);
  });

  testWidgets('3a 已经有层的特效：点它的卡 ⇒ **不加层**，进它的那一层'
      '（选中的是它就进它那层，否则进它的第一层）', (tester) async {
    final cfg = _cfg;
    // 爱心@0（选中）· 万花筒@2 · 万花筒@4
    _resetVisual([
      const VisualLayer(effect: 0, slot: 0),
      const VisualLayer(effect: 5, slot: 2),
      const VisualLayer(effect: 5, slot: 4),
    ]);
    await tester.pumpWidget(const MaterialApp(
      home: CustomPage(group: 'v'),
    ));
    await tester.pump();
    _drainNoise(tester);
    final before = _shape(cfg);

    // ① 选中的不是它 ⇒ 进它的**第一层**（slot 2），层数不变
    await tester.ensureVisible(_card('万花筒'));
    await tester.pump();
    await tester.tap(_card('万花筒'));
    await _routeIn(tester);
    expect(cfg.visualLayers.length, 3, reason: '★ 已经有层 ⇒ 一个都不许加');
    expect(_shape(cfg), before, reason: '★ 层表逐项不变');
    expect(cfg.visualLayerSel, 2, reason: '★ 选中的不是它 ⇒ 进它的第一层');
    var page = tester.widget<EffectPage>(find.byType(EffectPage));
    expect(page.index, 5);
    expect(page.slot, 2);
    expect(find.textContaining('万花筒 · 第 1/2 层'), findsOneWidget);

    // ② 退回目录页，改成「选中的就是它」⇒ 再点它 = 进**当前选中的那一层**
    await tester.tap(find.byTooltip('返回'));
    await _routeIn(tester);
    await cfg.selectVisualLayer(4); // 选中它的第 2 层
    await tester.pump();
    await tester.ensureVisible(_card('万花筒'));
    await tester.pump();
    await tester.tap(_card('万花筒'));
    await _routeIn(tester);
    expect(cfg.visualLayers.length, 3, reason: '仍然不许加层');
    expect(_shape(cfg), before, reason: '层表照旧逐项不变');
    page = tester.widget<EffectPage>(find.byType(EffectPage));
    expect(page.slot, 4, reason: '★ 选中的就是它 ⇒ 进当前选中的那一层');
    expect(find.textContaining('万花筒 · 第 2/2 层'), findsOneWidget);
    // ignore: avoid_print
    print('MuBox 判据·点卡进页3a：层表 ${_shape(cfg).join(",")}（未变）；'
        '先进 slot=2、再进 slot=${page.slot} ✅');
    await _flush(tester);
    // ⚠️ 两次进页各重建一遍 ⇒ 已知的 ListTile 噪音又攒了一批，收尾必须取走
    expect(_drainNoise(tester), isEmpty);
  });

  testWidgets('3b 长按一张卡 = 把当前选中层换成它（层数不变）', (tester) async {
    final cfg = _cfg;
    await tester.pumpWidget(const MaterialApp(
      home: CustomPage(group: 'v'),
    ));
    await tester.pump();
    _drainNoise(tester);

    await tester.ensureVisible(_card('粒子漩涡'));
    await tester.pump();
    await tester.longPress(_card('粒子漩涡'));
    await tester.pump();

    expect(cfg.visualLayers.length, 1, reason: '长按是「换特效」，不是「加层」');
    expect(cfg.visualLayers.single.effect, 2, reason: '当前那一层换成了漩涡');
    expect(cfg.visualLayers.single.slot, 0, reason: '★ 槽位不许变（变了 z 序/参数全乱）');
    expect(find.textContaining('已换成'), findsWidgets, reason: '换了要说一句');
    // ignore: avoid_print
    print('MuBox 判据·四区折叠3b：长按后 层数=1 effect=2 slot=0 ✅');
    await _flush(tester);
  });

  // ─────────── 3c/3d. ★★ 「＋」= 从 8 个特效里挑一个的选择器 ───────────

  testWidgets('3c ★★ 「＋」弹出选择器：列出**全部 8 个**视觉特效（含各自层数），'
      '挑一个不同的 ⇒ 新增那条就是它、原来的层还在', (tester) async {
    final cfg = _cfg;
    _resetVisual([const VisualLayer(effect: 2, slot: 0)]); // 漩涡一层
    await tester.pumpWidget(const MaterialApp(
      home: CustomPage(group: 'v'),
    ));
    await tester.pump();
    _drainNoise(tester);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await _routeIn(tester); // 弹层进场
    expect(find.byType(FxEffectPickerSheet), findsOneWidget,
        reason: '★ 「＋」= 挑一个特效的选择器（不是「加同款一层」）');

    // ① ★ 8 个视觉特效**一个不少**（不是只列没开的）
    final all = Fx.of('v');
    expect(all.length, 8, reason: '前置：视觉区就是 8 个特效');
    for (final e in all) {
      expect(find.byKey(ValueKey('fxpick_${e.index}')), findsOneWidget,
          reason: '★ 选择器里必须有「${e.name}」这一行');
    }
    // ② 每行都写着它**现在有几层**
    Finder inSheet(String t) => find.descendant(
        of: find.byType(FxEffectPickerSheet), matching: find.text(t));
    expect(inSheet('已开 1 层'), findsOneWidget, reason: '漩涡那行要写「已开 1 层」');
    expect(inSheet('还没有层'), findsNWidgets(7),
        reason: '★ 没开的 7 个也要**列出来**并标明「还没有层」');

    // ③ 挑一个**不同**的特效
    await tester.tap(find.byKey(const ValueKey('fxpick_5')));
    await _routeIn(tester);
    expect(find.byType(FxEffectPickerSheet), findsNothing, reason: '挑完要关掉');
    expect(cfg.visualLayers.length, 2);
    expect(cfg.visualLayers.last.effect, 5, reason: '★ 新增那条 = 挑的那个特效');
    expect(cfg.visualLayerSel, cfg.visualLayers.last.slot);
    // ④ ★ 原来的层还在、一个字节没动
    expect(cfg.visualLayers.first.effect, 2, reason: '★ 原来的层还在');
    expect(cfg.visualLayers.first.slot, 0, reason: '★ 原层的槽位没变');
    expect(_shape(cfg), ['0:2', '1:5']);
    expect(find.textContaining('已加上「万花筒」'), findsWidgets, reason: '加完说一句');
    // ignore: avoid_print
    print('MuBox 判据·选择器3c：8 行全在（漩涡「已开 1 层」+ 7 个「还没有层」）；'
        '挑万花筒后层表 ${_shape(cfg).join(",")} ✅');
    await _clearToasts(tester);
    await _flush(tester);
  });

  testWidgets('3d ★ 「＋」里挑**当前这个特效** = 等价于「给它再加一层同款」',
      (tester) async {
    final cfg = _cfg;
    _resetVisual([const VisualLayer(effect: 2, slot: 0)]);
    await tester.pumpWidget(const MaterialApp(
      home: CustomPage(group: 'v'),
    ));
    await tester.pump();
    _drainNoise(tester);

    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await _routeIn(tester);
    await tester.tap(find.byKey(const ValueKey('fxpick_2'))); // 还是漩涡
    await _routeIn(tester);

    expect(cfg.visualLayers.length, 2, reason: '挑当前这个 = 再叠一层同款（老需求也留着）');
    expect([for (final l in cfg.visualLayers) l.effect], [2, 2]);
    expect([for (final l in cfg.visualLayers) l.slot], [0, 1],
        reason: '★ 新层拿**没被用过的槽位**，原层槽位不动');
    expect(cfg.visualLayerSel, 1, reason: '新层自动选中');
    // ignore: avoid_print
    print('MuBox 判据·选择器3d：挑同款 ⇒ 层表 ${_shape(cfg).join(",")} ✅');
    await _clearToasts(tester);
    await _flush(tester);
  });

  // ─────────── 4. ★★ 同一特效的多层：能在它自己的页里切换 ───────────

  testWidgets('4 ★★ 同特效多层：◀▶ 能在**它自己的各层**之间切换，'
      '切换不改层表顺序/槽位，参数各写各的', (tester) async {
    final cfg = _cfg;
    // 爱心@0 · 万花筒@2 · 爱心@3 —— 爱心自己两层，中间夹着别的特效
    _resetVisual([
      const VisualLayer(effect: 0, slot: 0),
      const VisualLayer(effect: 5, slot: 2),
      const VisualLayer(effect: 0, slot: 3),
    ]);
    await tester.pumpWidget(const MaterialApp(
      home: EffectPage(group: 'v', index: 0, slot: 0),
    ));
    await tester.pump();
    _drainNoise(tester);
    final before = _shape(cfg);

    // ① 入口在，且数的是**本特效**的层（2 层，不是全区的 3 层）
    expect(find.textContaining('本特效共 2 层'), findsOneWidget,
        reason: '★ 切层入口只数这个特效自己的层');
    expect(find.text('第 1/2 层'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    // ② 切到它的第 2 层（slot 3，**不是**紧挨着的 slot 2 —— 那是万花筒的层）
    await tester.tap(find.byIcon(Icons.chevron_right));
    await tester.pump();
    expect(cfg.visualLayerSel, 3,
        reason: '★ 只在本特效自己的层之间走 —— 不跳到别的特效的层上');
    expect(find.text('第 2/2 层'), findsOneWidget);
    expect(_shape(cfg), before, reason: '★ 切换**不许**改层表顺序/槽位');

    // ③ ★ 切过去之后，参数写的是那一层自己的键（各调各的）
    await tester.drag(find.byType(Slider).first, const Offset(-60, 0));
    await tester.pump();
    expect(cfg.fxParams.containsKey('v0#3.x'), isTrue,
        reason: '★ 切到第 2 层后拖「水平位置」必须写 `v0#3.x`（这一层自己的键）');
    expect(cfg.fxParams.containsKey('v0.x'), isFalse,
        reason: '★ 不许写到第 1 层的裸键上（写了就是「改到了别层」）');
    expect(_shape(cfg), before, reason: '拖参数同样不许动层表');

    // ④ 往回切（环绕）回到第 1 层
    await tester.tap(find.byIcon(Icons.chevron_left));
    await tester.pump();
    expect(cfg.visualLayerSel, 0);
    expect(find.text('第 1/2 层'), findsOneWidget);
    expect(_shape(cfg), before);
    expect(_drainNoise(tester), isEmpty, reason: '整页只允许那条已知 ListTile 噪音');
    // ignore: avoid_print
    print('MuBox 判据·同特效切层4：层表 ${_shape(cfg).join(",")} 未变；'
        '切到第 2 层写入 v0#3.x=${cfg.fxParams['v0#3.x']}（v0.x 未被写）✅');
    await _flush(tester);
    expect(_drainNoise(tester), isEmpty);
  });

  testWidgets('4b 单层时**没有**切层入口（不摆一个点不动的控件）', (tester) async {
    _resetVisual([
      const VisualLayer(effect: 5, slot: 0),
      const VisualLayer(effect: 0, slot: 3),
    ]);
    await tester.pumpWidget(const MaterialApp(
      home: EffectPage(group: 'v', index: 5, slot: 0),
    ));
    await tester.pump();
    _drainNoise(tester);
    expect(find.textContaining('本特效共'), findsNothing,
        reason: '只有 1 层（slot 3 是爱心的）⇒ 不显示切层入口');
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.chevron_left), findsNothing);
    await _flush(tester);
  });

  // ─────────── 4c. ★ 源码守卫：`＋` 里 onChanged 的顺序（真机抓出来的坑）───────

  test('4c ★ 源码守卫：`＋` 里 `onChanged` 必须在任何 `context.mounted` 之前，'
      'messenger 必须在第一个 `await` 之前抓好', () {
    final src = File('lib/widgets/layer_stepper.dart').readAsStringSync();
    final start = src.indexOf('Future<void> _add(BuildContext context)');
    expect(start, greaterThan(0), reason: '前置：找得到 `_add`');
    final add = src.substring(start, src.indexOf('Future<void> _remove('));
    final iOnChanged = add.indexOf('onChanged?.call()');
    expect(iOnChanged, greaterThan(0), reason: '`＋` 加完层要通知页面跟到新层');
    final iMounted = add.indexOf('context.mounted');
    // ⚠️ 修好后这一版 `_add` 里**一个 `context.mounted` 都没有**（-1）：那也满足
    // 「不许有守卫挡在 onChanged 前面」。真写回来了就必须排在它后面。
    expect(iMounted == -1 || iOnChanged < iMounted, isTrue,
        reason: '★ 不许把 `if (!context.mounted) return;` 放在 `onChanged` 前面');
    // ★★ 这一条的由来（**真机实测**，widget 测试环境复现不了）：
    // `addVisualLayer` 会 `await _saveVisualLayers()`（真机上是一次真实的 prefs 往返
    // = 好几帧），这期间 `notifyListeners()` 已经让设置页重建、**「切层入口」插进了
    // `ListView`**（子项无 key）⇒ `LayerStepper` 的 element 被重建、它的 context 失效。
    // 于是「先 `if (!context.mounted) return;` 再 onChanged」会把 onChanged 一起吞掉：
    // 真机现象 = 标题停在「万花筒 · 第 1 层」，而同一帧里切层入口已经写着「第 1/2 层」。
    // ⚠️ widget 测试里 `pump` 先排干 microtask 再建帧 ⇒ **这个先手顺序永远是 true**，
    // 所以只能把「顺序」本身钉成源码守卫（同 `custom_page_mic_hint_test.dart` ★4 的手法）。
    // 反面证据也量到了：从 **2 层加到 3 层**（切层入口**不需要插**）那时标题是跟得上的。
    expect(add.indexOf('ScaffoldMessenger.of(context)'), lessThan(add.indexOf('await ')),
        reason: '★ `messenger` 必须在第一个 `await` 之前抓好（element 重建后 '
            '`ScaffoldMessenger.of(context)` 不一定还拿得到）');
    expect(add.indexOf('ScaffoldMessenger.of(context)'), lessThan(iOnChanged),
        reason: 'messenger 也要在 onChanged 之前就抓好');
  });

  // ─────────── 5. replaceVisualLayerEffect：不动槽位/z序/别层/shared ───────────

  group('5 AppConfig.replaceVisualLayerEffect', () {
    test('① 找不到 slot ⇒ false，且一个字都不动', () async {
      _resetVisual([
        const VisualLayer(effect: 0, slot: 0),
        const VisualLayer(effect: 2, slot: 1),
      ]);
      final cfg = AppConfig.instance;
      final before = cfg.visualLayers.toList();
      expect(await cfg.replaceVisualLayerEffect(9, 5), isFalse);
      expect(cfg.visualLayers, before);
    });

    test('② 同款 ⇒ true 且**不 purge**（参数一个都不许丢）', () async {
      _resetVisual([const VisualLayer(effect: 0, slot: 0)]);
      final cfg = AppConfig.instance;
      await cfg.setFx('v0.x', 0.9);
      await cfg.setFx('v0.size', 1.4);
      final keys = cfg.fxParams.keys.toSet();
      expect(await cfg.replaceVisualLayerEffect(0, 0), isTrue);
      expect(cfg.fxParams.keys.toSet(), keys, reason: '同款换同款 ⇒ 不许清参数');
      expect(cfg.fxParams['v0.x'], 0.9);
    });

    test('③ 不换槽位、不挪 z 序、不动别层', () async {
      _resetVisual([
        const VisualLayer(effect: 0, slot: 0),
        const VisualLayer(effect: 2, slot: 1),
        const VisualLayer(effect: 5, slot: 4),
      ], sel: 1);
      final cfg = AppConfig.instance;
      await cfg.setFx('v0.x', 0.2);
      await cfg.setFx('v2#1.x', 0.8);
      expect(await cfg.replaceVisualLayerEffect(1, 6), isTrue);
      expect([for (final l in cfg.visualLayers) l.slot], [0, 1, 4],
          reason: '★ 槽位不许变');
      expect([for (final l in cfg.visualLayers) l.effect], [0, 6, 5],
          reason: '★ z 序（列表顺序）不许变，别的层一个都不许动');
      expect(cfg.fxParams['v0.x'], 0.2, reason: '第 1 层的参数不许被动');
      expect(cfg.visualLayerSel, 1, reason: '选中的还是这一层');
    });

    test('④ ★ shared 三键（牵手）绝不许被删 —— 它们是所有爱心层共用的裸键',
        () async {
      _resetVisual([const VisualLayer(effect: 0, slot: 0)]);
      final cfg = AppConfig.instance;
      await cfg.setFx('v0.x', 0.9);
      await cfg.setFx('v0.size', 1.4);
      await cfg.setFx('v0.link', 1); // 牵手联动
      await cfg.setFx('v0.hands', 2);
      await cfg.setFx('v0.knot', 1.5);
      expect(cfg.fxParams['v0.link'], 1, reason: '前置：牵手是开着的');

      // 把 slot 0 从爱心换成漩涡
      expect(await cfg.replaceVisualLayerEffect(0, 2), isTrue);
      expect(cfg.fxParams.containsKey('v0.x'), isFalse,
          reason: '旧特效（爱心）的专属键要清掉');
      expect(cfg.fxParams.containsKey('v0.size'), isFalse);
      // ★ 这三条是**所有爱心层共用**的裸键 ⇒ ⛔ 绝不许用 `startsWith('v0.')` 清
      expect(cfg.fxParams['v0.link'], 1,
          reason: '★ 牵手联动是所有爱心层共用的裸键，删了牵手当场坏');
      expect(cfg.fxParams['v0.hands'], 2, reason: '★ 每只手线条：同上');
      expect(cfg.fxParams['v0.knot'], 1.5, reason: '★ 牵手结大小：同上');
    });

    test('⑤ slot>0 清的是**这个槽位**的键，裸键与别的槽位一个都不许动',
        () async {
      _resetVisual([
        const VisualLayer(effect: 0, slot: 0),
        const VisualLayer(effect: 2, slot: 1),
      ], sel: 1);
      final cfg = AppConfig.instance;
      await cfg.setFx('v0.x', 0.2);
      await cfg.setFx('v0.link', 1);
      await cfg.setFx('v2#1.x', 0.8);
      await cfg.setFx('v2#1.size', 1.3);
      expect(await cfg.replaceVisualLayerEffect(1, 6), isTrue);
      expect(cfg.fxParams['v2#1.x'], isNull, reason: '这个槽位自己的键要清');
      expect(cfg.fxParams['v2#1.size'], isNull);
      expect(cfg.fxParams['v0.x'], 0.2, reason: '别的槽位/裸键不许被动');
      expect(cfg.fxParams['v0.link'], 1);
    });

    test('⑥ ★ 必须推 fxParticleRevision（漏了 ⇒ 换漩涡后一片空白）', () async {
      _resetVisual([const VisualLayer(effect: 0, slot: 0)]);
      final cfg = AppConfig.instance;
      final before = cfg.fxParticleRevision.value;
      expect(await cfg.replaceVisualLayerEffect(0, 2), isTrue);
      expect(cfg.fxParticleRevision.value, greaterThan(before),
          reason: '★ 粒子列表只在版本号变化时按新图层集重建 —— '
              '漏了这句，换成漩涡/聚散/3D球后**一片空白**，切一次特效才出来');
    });
  });

  // ─────────── 6. ＋/－ 挂在「视觉特效」开关下面；两个边界都要说话 ───────────

  testWidgets('6 特效设置页：开关下面有 ＋/－；＋ 弹选择器、两个边界都要说话',
      (tester) async {
    final cfg = _cfg;
    _resetVisual([const VisualLayer(effect: 0, slot: 0)]);
    await tester.pumpWidget(const MaterialApp(
      home: EffectPage(group: 'v', index: 0, slot: 0),
    ));
    await tester.pump();
    _drainNoise(tester);

    expect(find.textContaining('当前特效「爱心」'), findsOneWidget,
        reason: '★ 那一行必须自我说明：它说的是**当前特效的层数**，'
            '跟上面那个「整片视觉区」的开关是两件事');
    expect(find.textContaining('共 1 层'), findsOneWidget);
    expect(find.text('1/$kMaxVisualLayers'), findsOneWidget);

    // ① 只剩一层时点 −：**必须先拒绝 + 说一句话**，层数不许变
    await tester.tap(find.byIcon(Icons.remove_circle_outline));
    await tester.pump();
    expect(cfg.visualLayers.length, 1, reason: '整区至少要留一层');
    expect(find.textContaining('至少要留一层'), findsWidgets,
        reason: '★ ⛔ 不许做成「点了没反应的死按钮」');
    await _clearToasts(tester); // 送走它，别让下一条排在它后面

    // ② 点 ＋：**弹选择器**；挑「爱心」（当前这个）⇒ 加一层 + 自动选中新那层
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    await _routeIn(tester);
    expect(find.byType(FxEffectPickerSheet), findsOneWidget,
        reason: '★ 「＋」必须是**挑一个特效**的选择器');
    await tester.tap(find.byKey(const ValueKey('fxpick_0')));
    await _routeIn(tester);
    expect(cfg.visualLayers.length, 2);
    expect(cfg.visualLayers.last.effect, 0, reason: '挑的是当前特效 ⇒ 加的是它的层');
    expect(cfg.visualLayerSel, cfg.visualLayers.last.slot,
        reason: '★ 加完必须自动选中新那层');
    expect(find.textContaining('当前特效「爱心」· 共 2 层'), findsOneWidget,
        reason: '★ 页面要跟着新层走（否则「加了层但调的是旧那层」）');
    expect(find.textContaining('本特效共 2 层'), findsOneWidget,
        reason: '★ 爱心自己有 2 层 ⇒ 切层入口出现（这就是用户要的「单独调整任意一个」）');
    // ★ 标题也必须跟着新层走。
    // ⚠️ 这一条是真机抓出来的：加层会让切层入口**插进 ListView**（子项没有 key）⇒
    // `LayerStepper` 的 element 被重建、它的 context 失效；当时 `_add` 里
    // 「先 `if (!context.mounted) return;` 再 onChanged」把那句回调**吞掉了**
    // ⇒ 标题停在「第 1 层」而切层入口写着「第 1/2 层」（同一个 frame 里自相矛盾）。
    expect(find.text('爱心 · 第 2/2 层'), findsOneWidget,
        reason: '★ 加完层，标题必须跟到新那层（context 守卫吞掉 onChanged 的坑）');
    expect(find.text('第 2/2 层'), findsOneWidget, reason: '切层入口也指到第 2 层');
    // ★ 而且**真的在调新那层**：拖滑杆必须写新层的键 `v0#1.x`，不是第 1 层的 `v0.x`
    await tester.drag(find.byType(Slider).first, const Offset(-60, 0));
    await tester.pump();
    expect(cfg.fxParams.containsKey('v0#1.x'), isTrue,
        reason: '★ 加完层要真的在调新那层（写 `v0#1.x`）');
    expect(cfg.fxParams.containsKey('v0.x'), isFalse,
        reason: '★ 不许写第 1 层的裸键（写了就是「加了层但调的是旧那层」）');
    expect(find.textContaining('已加上「爱心」'), findsWidgets,
        reason: '加完要说一句（提示不能因为 element 重建就被吞掉）');
    expect(_drainNoise(tester), isEmpty);
    await _clearToasts(tester);

    // ③ 加到上限再点 ＋：同样**先拒绝 + 说话**，而且**不弹选择器**
    while (cfg.visualLayers.length < kMaxVisualLayers) {
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await _routeIn(tester);
      await tester.tap(find.byKey(const ValueKey('fxpick_0')));
      await _routeIn(tester);
    }
    expect(cfg.visualLayers.length, kMaxVisualLayers);
    await _clearToasts(tester);
    await tester.tap(find.byIcon(Icons.add_circle_outline));
    // ⚠️ `_add` 里先判断再弹提示 ⇒ 多跑两拍把 microtask 链（SharedPreferences 打桩那几跳）排干
    await tester.pump();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(cfg.visualLayers.length, kMaxVisualLayers, reason: '到上限不许再加');
    expect(find.byType(FxEffectPickerSheet), findsNothing,
        reason: '★ 到上限先拒绝（弹了选择器却加不上 = 骗人）');
    expect(find.textContaining('最多叠'), findsWidgets,
        reason: '★ 到上限也要说一句话（⛔ 不做点了没反应的死按钮）');
    expect(_drainNoise(tester), isEmpty);
    // ignore: avoid_print
    print('MuBox 判据·层数控件6：− 到下限有提示、＋ 弹选择器并自动选中新层、'
        '到上限先拒绝（不弹选择器）且有提示（共 ${cfg.visualLayers.length} 层）✅');
    await _flush(tester);
    expect(_drainNoise(tester), isEmpty);
  });

  // ─────────── 7. A-B 可发现性 ───────────

  group('7 A-B 按钮', () {
    test('① abHintShown 落盘往返（一辈子只说一次靠它）', () async {
      _resetVisual([const VisualLayer(effect: 0, slot: 0)]);
      final cfg = AppConfig.instance;
      expect(cfg.abHintShown, isFalse, reason: '缺省 = 没说过');
      await cfg.setAbHintShown(true);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('ab_hint_shown'), isTrue, reason: '★ 必须落盘');
      // 反面对照：换个键名就查不到 —— 证明上面那条查的确实是这个键
      expect(sp.getBool('ab_hint_shown_typo'), isNull);
    });

    test('② 接线：Tooltip 包住那颗按钮；提示**只在同一条** SnackBar 里合并', () {
      final bar = File('lib/widgets/player_bar.dart').readAsStringSync();
      // 源码守卫（这仓的既有手法，见 custom_page_mic_hint_test.dart ★4）：
      // ⚠️ 切片要**精确到 `_tapAb` 这个方法体**（下一个 `@override` 之前）——
      // 切到下一个方法名会连整个 `build()` 一起圈进来，`showSnackBar(` 计数就假了。
      final tapStart = bar.indexOf('void _tapAb()');
      final tap = bar.substring(tapStart, bar.indexOf('@override', tapStart));
      expect(RegExp(r'Tooltip\(').hasMatch(bar), isTrue,
          reason: '★ 那颗 TextButton 没有 tooltip 参数 ⇒ 必须在外面包一层 Tooltip');
      expect('A-B 片段循环'.allMatches(bar).isNotEmpty, isTrue);
      // ★ 只有一条 showSnackBar（别弹第二条 —— clearSnackBars 会互相抹掉）
      expect(RegExp(r'showSnackBar\(').allMatches(tap).length, 1,
          reason: '★ 第一次点的提示要**并进现有一条** SnackBar，⛔ 不许再弹第二条');
      expect(tap.contains('clearSnackBars'), isTrue);
      expect(tap.contains('第三下清除'), isTrue, reason: '合并的那句话');
      expect(tap.contains('3200'), isTrue, reason: '停留时间要够读完');
      expect(tap.contains('1800'), isTrue, reason: '之后恢复原来的 1800ms');
      // ⛔ 不许重复它已经说过的「再点一下打 B 点」
      expect('再点一下打 B 点'.allMatches(tap).isEmpty, isTrue,
          reason: '★ 那句话由 cycleAbLoop 的返回串提供，不许在界面里再写一遍');
    });

    test('③ 防回退：cycleAbLoop 的三句返回串逐字符不变；ab_loop.dart 没被碰', () {
      final svc = File('lib/player_service.dart').readAsStringSync();
      for (final s in [
        "'A 点已打：\${_ab.label}（再点一下打 B 点）'",
        "'A-B 循环中：\${_ab.label}'",
        "'已退出 A-B 循环'",
      ]) {
        expect(svc.contains(s), isTrue, reason: '★ 这三句是验收锚点，逐字符不许变：$s');
      }
      // ab_loop.dart 一个字节都没动（它那 15 项单测是判定逻辑的唯一防线）
      final ab = File('lib/ab_loop.dart').readAsStringSync();
      expect(ab.contains('class AbLoop'), isTrue);
      expect(ab.contains('markA'), isTrue);
      expect(ab.contains('markB'), isTrue);
    });
  });
}
