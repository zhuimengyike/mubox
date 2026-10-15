/// **设置页上的位置调节接线**（`lib/pages/effect_page.dart` 的 `_divisions` +
/// `_paramTile` 里的 −/+ 按钮）。
///
/// ## 要解决的是什么
/// 症状：**视觉特效的位置调整精细度不够，会跳过一些想要放置的地方**。
///
/// 病灶在设置页的 `_divisions()`：它按显示格式定档，位置参数原来是 `percent`
/// ⇒ **50 档、一格 2%**。本文件断言的就是「页面这一侧真的变成了 1000 档 + 一对按钮」，
/// 不是判常量本身（那在 `fx_position_test.dart`）也不是判按钮自己
/// （那在 `fx_step_button_test.dart`）。
///
/// ## 每条断言在钉什么
/// - ★1 位置那两行的滑杆 `divisions == 1000`（0~1 / 0.001），**其余参数一行都不是**
///   （顺手把「谁被改宽了」这条也堵上）；
/// - ★2 位置两行各配一对 `FxStepButton`（`v0` 共 4 颗）、带稳定 key，
///   且**滑杆被 `Expanded` 夹在中间**（行宽 − 96 = 滑杆宽 ⇒ 没被挤出屏幕）；
/// - ★3 点「+」⇒ `AppConfig.instance.fx('v0.x')` **恰好 0.501**（两半都测：
///   再点「−」回到 0.5），且滑杆跟着走、y 一点没被牵连；
/// - ★4 读数里出现 `50.0%`（一位小数），点完变 `50.1%`；
/// - ★5 ★ **近失手**：贴着「+」按钮外缘 3px、以及距外缘 40px 各点一下，
///   都必须**恰好挪一格**、绝不许变成 `1.0`。⚠️ 这条是「命中区必须是 48
///   （Material 最小触摸目标）」的断言：36 时那 4px 偏出界，落点变成滑杆最右端，
///   `_getValueFromGlobalPosition` 把值夹到 **1.0** ⇒ 特效直接飞到屏幕右边
///   （实测：把 `_kTouch` 改回 36 ⇒ `Expected: <0.501> / Actual: <1.0>`）；
/// - ★6 行高：这对按钮**没把位置行撑高**（与「手绘抖动」那行等高、且行高仍等于滑杆高）。
///
/// ## ⚠️ 量具纪律（本仓踩过的两条）
/// 1. **禁 `pumpAndSettle`**：这一页挂着氛围层的常驻 `repeat()` 动画，settle 不了；
/// 2. 收尾必须把树拆掉（否则报 "A Ticker was active"），并把 `setFx` 的 400ms
///    落盘去抖推过去（否则报 "A Timer is still pending"）。
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/effect_catalog.dart';
import 'package:mu_box_phone/pages/effect_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:mu_box_phone/widgets/fx_step_button.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `lib/power_monitor.dart` 在这个通道上 `receiveBroadcastStream()`；
/// 测试环境里没人实现它 ⇒ `MissingPluginException` 会**异步**冒出来、落在哪一拍
/// 不确定 ⇒ 用例会「偶尔红」。挂个哑 handler 把不确定性掐掉（同 `sound_effects_page_test.dart`）。
const MethodChannel _kPowerSaveChannel =
    MethodChannel('com.mubox.mu_box_phone/power_save');

/// 哑播放器：本文件只渲染页面，一次原生调用都不许发生。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 位置参数那对按钮的 key（`_k(p)` 在槽位 0 上就是裸键 ⇒ `fx_step_v0.x_up`）。
/// ⚠️ 字面量必须与 `effect_page.dart` 的 `_stepButton` 逐字一致（那是被测的锚点）。
ValueKey<String> _up(String k) => ValueKey<String>('fx_step_${k}_up');
ValueKey<String> _down(String k) => ValueKey<String>('fx_step_${k}_down');

/// 已知噪音：`SurfaceCard`（带底色）里装 `SwitchListTile` ⇒ debug 下每次 build 报一条
/// `ListTile background color or ink splashes may be invisible.`（assert-only、release 一条没有）。
/// flutter_test 在 debug 下会把**同一批**聚成一条 `Multiple exceptions (N) …` 再交给
/// `takeException()` —— 单条拿不到 ⇒ 只能按聚合串的形状过滤（同 `fx_layer_render_test.dart`）。
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

/// 开页面：**照抄 `sound_effects_page_test.dart` 的 harness**（mock prefs + `AppConfig.load`
/// + 全局 `playerService` 放一副哑牌 + `power_save` 哑 handler）。
Future<void> _openPage(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 2700); // 逻辑 400×900：参数区不用滚动就都在视口里
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.reset);

  await AppConfig.load();
  final cfg = AppConfig.instance;
  cfg.fxParams.clear();
  cfg.visualLayers
    ..clear()
    ..add(const VisualLayer(effect: 0, slot: 0)); // v0 爱心，槽位 0（老键）
  cfg.visualLayerSel = 0;
  cfg.visualEffect = 0;
  cfg.heartEnabled = true;
  cfg.rainEnabled = false; // 氛围/律动/边框全关：页面里只留视觉区
  cfg.spectrumEnabled = false;
  cfg.edgeEnabled = false;

  await tester.pumpWidget(
      const MaterialApp(home: EffectPage(group: 'v', index: 0)));
  // ⚠️ 只能 `pump`：这一页有常驻动画（氛围层的 `repeat()`），pumpAndSettle 会一直等下去
  await tester.pump();
  await tester.pump();
  await _expectNoLeak(tester, '挂载');
}

/// 点一颗 −/+ 按钮并走一拍（顺手把已知噪音取走）。
Future<void> _tapStep(WidgetTester tester, ValueKey<String> key) async {
  await tester.tap(find.byKey(key));
  await tester.pump();
  await _expectNoLeak(tester, '点击 ${key.value} 之后');
}

/// 把 `AppConfig._scheduleFxSave` 的 400ms 去抖计时器跑掉（否则报 "A Timer is still pending"）。
Future<void> _flushFxSave(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
  await _expectNoLeak(tester, '落盘去抖之后');
}

/// 收尾：把树拆掉，让氛围层的 Ticker / 全局监听全部 dispose。
Future<void> _dropTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  await _expectNoLeak(tester, '拆树');
}

/// 取全部滑杆（v0 的滑块型参数）。
List<Slider> _sliders(WidgetTester tester) =>
    tester.widgetList<Slider>(find.byType(Slider)).toList();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 氛围层读**全局** `playerService`（App 里它在 main() 一定存在）；
    // **不调 init()** ⇒ 不碰任何插件、不落任何盘。
    playerService = PlayerService(player: _StubPlayer());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSaveChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSaveChannel, null);
    playerService = null;
  });

  // ─────────────── 一、档数：1000 档，且只改了位置那两行 ───────────────

  testWidgets('★1 位置两行的滑杆恰好 1000 档（0~1 / 0.001），别的参数一行都不是',
      (tester) async {
    await _openPage(tester);

    final sliders = _sliders(tester);
    expect(sliders.length, 12,
        reason: '⚠️ 量具自证：v0 的 14 个参数里颜色走色卡、牵手走开关 ⇒ 应有 12 个滑杆；'
            '数量不对说明页面结构变了，下面的下标断言全部失效');

    expect(sliders[0].divisions, 1000,
        reason: '★ 第一行 = 「水平位置」：必须 1000 档（原来 50 档 / 2% 一格）');
    expect(sliders[0].min, 0, reason: '屏幕比例位置的下界');
    expect(sliders[0].max, 1, reason: '屏幕比例位置的上界');
    expect(sliders[0].value, 0.5, reason: '缺省值仍是 0.5（画面逐帧一致）');
    expect(sliders[1].divisions, 1000, reason: '★ 第二行 = 「垂直位置」');
    expect(sliders[1].value, 0.47, reason: '缺省值仍是 0.47（不是 0.5！）');

    // 负向：其余 10 个滑杆一个都不许变成 1000 档
    expect([for (final s in sliders) if (s.divisions == 1000) s].length, 2,
        reason: '★ 全页只有两行是 1000 档');
    for (var i = 2; i < sliders.length; i++) {
      expect(sliders[i].divisions, isNot(1000), reason: '第 $i 个滑杆不该被改成 1000 档');
    }

    await _flushFxSave(tester);
    await _dropTree(tester);
  });

  testWidgets('★2 位置两行各配一对 −/+ 按钮（v0 共 4 颗），滑杆被 Expanded 夹在中间',
      (tester) async {
    await _openPage(tester);

    expect(find.byType(FxStepButton), findsNWidgets(4),
        reason: '★ v0 有「水平位置 / 垂直位置」两行 ⇒ 每行一对 = 4 颗'
            '（任务书里写「两个」是按"一行两个"说的）');
    for (final k in ['v0.x', 'v0.y']) {
      expect(find.byKey(_up(k)), findsOneWidget, reason: '★ 锚点 key：fx_step_${k}_up');
      expect(find.byKey(_down(k)), findsOneWidget, reason: '★ 锚点 key：fx_step_${k}_down');
    }

    // 每一行里恰好两颗按钮，且滑杆包在 Expanded 里（否则滑杆会被挤出屏幕）
    for (final k in ['v0.x', 'v0.y']) {
      final row = find
          .ancestor(of: find.byKey(_up(k)), matching: find.byType(Row))
          .first; // 最近的 Row = 这一行本身
      expect(find.descendant(of: row, matching: find.byType(FxStepButton)),
          findsNWidgets(2),
          reason: '$k 那一行');
      final rowW = tester.getSize(row).width;
      final sliderW =
          tester.getSize(find.descendant(of: row, matching: find.byType(Slider)))
              .width;
      expect(sliderW, closeTo(rowW - 96, 0.5),
          reason: '★ 两侧各 48 ⇒ 滑杆宽 = 行宽 - 96（说明是 Row[按钮, Expanded(滑杆), 按钮]）');
    }

    // ⚠️ 别的参数那一行**一个像素都不许变**：滑杆仍是铺满，宽度恰好比位置行多 96
    final posW = tester.getSize(find.byType(Slider).at(0)).width;
    final plainW = tester.getSize(find.byType(Slider).at(2)).width;
    expect(plainW - posW, closeTo(96, 0.5),
        reason: '★ 只有位置行两侧各占 48；非位置行仍是滑杆直接铺满');
    for (var i = 2; i < _sliders(tester).length; i++) {
      expect(tester.getSize(find.byType(Slider).at(i)).width, closeTo(plainW, 0.5),
          reason: '第 $i 行（非位置参数）的滑杆宽度不许变');
    }

    await _flushFxSave(tester);
    await _dropTree(tester);
  });

  // ─────────────── 二、点一下真的挪了（写进哪个键） ───────────────

  testWidgets('★3 点「+」⇒ fx(v0.x) 恰好 0.501；再点「−」⇒ 回到 0.5（y 不被牵连）',
      (tester) async {
    await _openPage(tester);
    final cfg = AppConfig.instance;

    expect(cfg.fx('v0.x'), 0.5, reason: '前置：缺省 0.5');
    expect(cfg.fx('v0.y'), 0.47, reason: '前置：缺省 0.47');
    expect(cfg.fxParams.containsKey('v0.x'), isFalse,
        reason: '前置：用户没动过 ⇒ 一个键都没存（缺省回落 catalog）');

    await _tapStep(tester, _up('v0.x'));

    expect(cfg.fx('v0.x'), 0.501, reason: '★ 点一下「+」= 挪 0.1%');
    expect(cfg.fxParams['v0.x'], 0.501,
        reason: '★ 真的写进了 fxParams（不是只改了 UI 上的数字）');
    expect(_sliders(tester).first.value, 0.501,
        reason: '★ 滑杆跟着走（页面与 AppConfig 同一个真相源）');
    expect(cfg.fx('v0.y'), 0.47, reason: '★ 只动 x：y 一个字节都不许被牵连');

    await _tapStep(tester, _down('v0.x'));

    expect(cfg.fx('v0.x'), 0.5, reason: '★ 再点一下「−」正好回到 0.5');
    expect(_sliders(tester).first.value, 0.5);
    expect(cfg.fx('v0.y'), 0.47);

    await _flushFxSave(tester);
    await _dropTree(tester);
  });

  testWidgets('★4 读数带一位小数：进来是 50.0%，点一下就变 50.1%', (tester) async {
    await _openPage(tester);

    expect(find.text('50.0%'), findsOneWidget, reason: '★ 位置读数：50.0%（原来显示 50%）');
    expect(find.text('47.0%'), findsOneWidget, reason: '★ 垂直位置缺省 0.47 ⇒ 47.0%');

    await _tapStep(tester, _up('v0.x'));

    expect(find.text('50.1%'), findsOneWidget, reason: '★ 挪一格之后读数跟着走');
    expect(find.text('50.0%'), findsNothing, reason: '旧读数不该还留在页面上');

    await _flushFxSave(tester);
    await _dropTree(tester);
  });

  // ─────────── 三、命中区：近失手不许把特效甩到屏幕边上 ───────────

  /// 这一行（`v0.x` 那条）的矩形。
  Rect posRowRect(WidgetTester tester, String k) => tester.getRect(
      find.ancestor(of: find.byKey(_up(k)), matching: find.byType(Row)).first);

  testWidgets('★5 ★ 近失手：贴着「+」外缘 3px、以及距外缘 40px，都只许挪一格（不许变 1.0）',
      (tester) async {
    await _openPage(tester);
    final cfg = AppConfig.instance;

    // ⚠️ 几何只**记下来**、断言放到两个探针**之后**：命中区退化时，先红的必须是
    // 「值被滑杆夹到 1.0」这条主断言，而不是先卡在几何前置上（那样报不出 1.0）。
    var row = posRowRect(tester, 'v0.x');
    final up = tester.getRect(find.byKey(_up('v0.x')));
    final down = tester.getRect(find.byKey(_down('v0.x')));

    // ── ① 最外侧 3px：贴着按钮外缘点 ⇒ 必须算点中按钮 ──
    await tester.tapAt(Offset(row.right - 3, row.center.dy));
    await tester.pump();
    expect(cfg.fx('v0.x'), 0.501, reason: '★ 贴着外缘 3px 也要恰好挪一格');
    expect(cfg.fx('v0.x'), isNot(1.0),
        reason: '★ 绝不许变成 1.0（那是"点到滑杆最右端"的值）');

    // 复位，免得两次探针叠在一起数不清
    await cfg.setFx('v0.x', 0.5);
    await tester.pump();
    expect(cfg.fx('v0.x'), 0.5, reason: '前置：复位到 0.5');
    row = posRowRect(tester, 'v0.x');

    // ── ② 近失手点：距外缘 40px（在 48 命中区内 / 在 36 命中区外）──
    final miss = Offset(row.right - 40, row.center.dy);
    await tester.tapAt(miss);
    await tester.pump();
    expect(cfg.fx('v0.x'), 0.501,
        reason: '★ 用户想点「+」偏出去 4px 时必须仍算点中按钮。'
            '命中区若是 36，这一点落在滑杆最右端 ⇒ 值被夹到 1.0（特效直接飞到屏幕右边）');
    expect(cfg.fx('v0.x'), isNot(1.0),
        reason: '★ 这条就是这个返工的全部理由：差一点点没点中 ≠ 把特效甩到屏幕边上');

    // ── 几何与量具自证（放在探针之后，见上面那条说明）──
    expect(up.right, closeTo(row.right, 0.5), reason: '前置：+ 按钮贴着这一行的右缘');
    expect(up.width, 48, reason: '★ 命中区必须是 48（Material 最小触摸目标）');
    expect(down.width, 48, reason: '★ 「−」的命中区同样必须是 48（左侧对称的那一半）');
    expect(up.contains(miss), isTrue,
        reason: '★ 量具自证：探针 $miss 必须落在 + 按钮的命中框 $up 内（不是"碰巧值对了"）');

    await _flushFxSave(tester);
    await _dropTree(tester);
  });

  testWidgets('★6 行高：这对按钮没把位置行撑高（与「手绘抖动」那行等高）', (tester) async {
    await _openPage(tester);

    // 整块参数行 = label 行 + 滑杆（或 滑杆行）+ hint
    final posTile = find
        .ancestor(of: find.text('水平位置'), matching: find.byType(Column))
        .first;
    final plainTile = find
        .ancestor(of: find.text('手绘抖动'), matching: find.byType(Column))
        .first;
    final posRow = find
        .ancestor(of: find.byKey(_up('v0.x')), matching: find.byType(Row))
        .first;

    final sliderH = tester.getSize(find.byType(Slider).at(0)).height;
    final posRowH = tester.getSize(posRow).height;
    final posTileH = tester.getSize(posTile).height;
    final plainTileH = tester.getSize(plainTile).height;

    // ignore: avoid_print
    print('MuBox 判据·位置行高：位置行=$posRowH｜位置 tile=$posTileH｜'
        '抖动 tile=$plainTileH｜滑杆高=$sliderH');

    expect(posTileH, closeTo(plainTileH, 0.5),
        reason: '★ 位置行与非位置参数行**等高** ⇒ 那对按钮没把行撑高'
            '（实测 位置 $posTileH / 抖动 $plainTileH）');
    expect(posRowH, closeTo(sliderH, 0.5),
        reason: '★ 按钮不高于滑杆 ⇒ 行高仍由滑杆决定'
            '（实测 行 $posRowH / 滑杆 $sliderH）');

    await _flushFxSave(tester);
    await _dropTree(tester);
  });
}
