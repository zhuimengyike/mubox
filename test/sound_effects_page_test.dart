/// 音效页「交叉淡变（曲末 + 队列预取）」开关的**接线断言**。
///
/// 背景：「双播放器 + 队列预取 + 曲末交叉淡变」做完了，但
/// `AppConfig.setCrossfadeEnabled` 在**产品代码里零调用点**（只有测试调它）
/// ⇒ 界面上没有入口 ⇒ 在真机上**打不开**这个功能。
/// 这个文件钉的就是那根接线，不是那套时序（时序的断言在
/// `player_service_crossfade_test.dart`，别在这儿重复测它）。
///
/// 每条都有正/负一对：
/// 1. **开关真的在音效页上**，且缺省显示为关（不碰它 = 原来的行为）；
/// 2. **只是打开这一页不许偷偷落盘**（渲染这张卡 = 零副作用）；
/// 3. **正向**：点开 ⇒ `AppConfig.crossfadeEnabled` 当场 true + 落盘 `fx_crossfade`；
/// 4. **负向**：再点关 ⇒ 回到 false 且落盘 false（**两半都要**，别只测开）；
/// 5. **初值读 `AppConfig.instance.crossfadeEnabled`**：只改内存、不动 prefs ⇒ 开关跟着走
///    （区分"读 AppConfig"与"UI 自己再读一遍 SharedPreferences"）；
/// 6. **文案说清副作用**：开态那段必须写出「重叠 ~300ms」和「队列预取」
///    （只写「交叉淡变」四个字 = 用户不知道会改观感、也不知道预取只有它开着才有）；
/// 7. **不 bump rebuild**（同 `volumeFadeEnabled`：它不是主题/字体那类要整棵重建的配置）。
///
/// ⚠️ **这个文件第一次跑是在接线之前** —— 当时第 1、3、4、5、6 条**必须是红的**
/// （这就是"负向对照有牙"的证明）；接上那根线之后才转绿。
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/pages/sound_effects_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `lib/power_monitor.dart` 在这个通道上 `receiveBroadcastStream()`。
/// 测试环境里没人实现它 ⇒ `MissingPluginException` 会**异步**冒出来，
/// 落在哪一拍不确定 ⇒ 用例会「偶尔红」。这里给它挂一个哑 handler，把不确定性掐掉。
const MethodChannel _kPowerSaveChannel =
    MethodChannel('com.mubox.mu_box_phone/power_save');

/// 哑播放器：本文件只渲染页面，一次原生调用都不许发生
/// （`noSuchMethod` 兜住 `AudioPlayer` 的全部成员，与 `player_service_test.dart`
/// 的假播放器同一个约定；这里只多要一个"不炸的壳"）。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 开关的锚点。**字面量与 `lib/pages/sound_effects_page.dart` 里那行 `Switch` 的
/// `key:` 一致**。刻意**不** import 那个常量：接线还没做时本文件也要能编译
/// —— 那样红灯才是"找不到开关"，而不是"找不到符号"的编译错。
const ValueKey<String> _kCrossfadeSwitch = ValueKey<String>('switch_crossfade');

/// 页面上那个开关（找不到就是没接上）。
Finder get _sw => find.byKey(_kCrossfadeSwitch);

/// 开态那段文案（关态也要提到预取，所以两段断言分开写）。
Finder get _descOn => find.textContaining('重叠约 300ms');

Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: SoundEffectsPage()));
  // ⚠️ 只能 `pump`：这页的氛围层是常驻动画（`repeat()` 的 AnimationController），
  // `pumpAndSettle` 会一直等下去。
  await tester.pump();
}

/// 收尾：把树拆掉，让氛围层的 Ticker / 全局监听全部 dispose，
/// 否则用例结束时报 "A Ticker was active when the test ended"。
Future<void> _dropTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppConfig.instance.crossfadeEnabled = false; // 每个用例都从缺省值起步
    // 这一页的氛围层读**全局** `playerService`（`ambient_layer.dart:401` 的
    // `playerService!`）。App 里它在 `main()` 一定存在，`flutter test` 里没人建
    // ⇒ 必须先在场放一副哑牌，否则页面在测试环境里 build 就抛
    // `Null check operator used on a null value`（环境问题，不是这一页的 bug）。
    // **不调 `init()`** ⇒ 不碰任何插件、不落任何盘。
    playerService = PlayerService(player: _StubPlayer());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSaveChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSaveChannel, null);
    playerService = null;
  });

  testWidgets('★ 开关真的在音效页上，且缺省显示为关（不碰它 = 原来的行为）',
      (tester) async {
    await AppConfig.load(); // 与冷启动同一条路：空 prefs
    expect(AppConfig.instance.crossfadeEnabled, isFalse,
        reason: '前置：缺省值必须还是 false（这条不许被这次改动动过）');

    await _pumpPage(tester);

    expect(find.textContaining('交叉淡变'), findsWidgets,
        reason: '界面上要看得见「交叉淡变」这几个字');
    expect(_sw, findsOneWidget, reason: '★ 找不到开关 = 这根线没接上');
    expect(tester.widget<Switch>(_sw).value, isFalse,
        reason: '缺省 false ⇒ 开关必须显示为关');
    expect(find.text('音量淡入淡出'), findsOneWidget,
        reason: '同一页原来那个开关不许被挤掉（它是这一页的样板）');

    await _dropTree(tester);
  });

  testWidgets('★ 只是打开这一页：不许偷偷写 fx_crossfade（渲染 = 零副作用）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.load();

    await _pumpPage(tester);

    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('fx_crossfade'), isNull,
        reason: '光是渲染这张卡不许落盘：一旦落盘，"缺省值不变"就没有证据了');

    await _dropTree(tester);
  });

  testWidgets('★ 正向：点开 ⇒ 内存当场 true（不用重启）+ 落盘 fx_crossfade=true',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.load();
    await _pumpPage(tester);
    expect(_sw, findsOneWidget);
    final rev = AppConfig.instance.rebuildRevision.value;

    await tester.tap(_sw);
    await tester.pump();

    expect(tester.widget<Switch>(_sw).value, isTrue, reason: '点一下要立刻翻过去');
    expect(AppConfig.instance.crossfadeEnabled, isTrue,
        reason: '★ 写的必须是 player_service 每拍读的那个字段（AppConfig.instance）');
    expect(AppConfig.instance.rebuildRevision.value, rev,
        reason: '它不是"要重建整棵 App"的配置（同 volumeFadeEnabled）');

    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('fx_crossfade'), isTrue, reason: '要记得住');
    await AppConfig.load();
    expect(AppConfig.instance.crossfadeEnabled, isTrue, reason: '重启后仍是开的');

    await _dropTree(tester);
  });

  testWidgets('★ 负向：再点一下 ⇒ 回到 false，且落盘也是 false（两半都要）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.load();
    await AppConfig.instance.setCrossfadeEnabled(true); // 先开着进页面
    await _pumpPage(tester);
    expect(tester.widget<Switch>(_sw).value, isTrue, reason: '前置：进来时是开的');

    await tester.tap(_sw);
    await tester.pump();

    expect(tester.widget<Switch>(_sw).value, isFalse);
    expect(AppConfig.instance.crossfadeEnabled, isFalse);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('fx_crossfade'), isFalse,
        reason: '关也要落盘 —— 否则重启又自己开回来');
    await AppConfig.load();
    expect(AppConfig.instance.crossfadeEnabled, isFalse, reason: '重启后仍是关的');

    await _dropTree(tester);
  });

  testWidgets('★ 初值来自 AppConfig.instance.crossfadeEnabled（UI 不自己再读一遍 prefs）',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.load();
    // **只改内存**、一个字节都不落盘：prefs 里 fx_crossfade 仍是空的。
    AppConfig.instance.crossfadeEnabled = true;

    await _pumpPage(tester);

    expect(tester.widget<Switch>(_sw).value, isTrue,
        reason: '开关必须跟着 AppConfig 的内存值走；读 prefs 的写法在这里会显示成关');
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('fx_crossfade'), isNull, reason: '前置：prefs 确实是空的');

    await _dropTree(tester);
  });

  testWidgets('★ 文案说清副作用：开态写出「重叠约 300ms」+「队列预取」+ 双解码器代价',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.load();
    AppConfig.instance.crossfadeEnabled = true;

    await _pumpPage(tester);

    expect(_descOn, findsOneWidget,
        reason: '只说「交叉淡变」四个字 = 用户不知道会改观感');
    expect(find.textContaining('队列预取'), findsOneWidget,
        reason: '预取只有这个开关开着才有，必须说出来');
    expect(find.textContaining('解码'), findsOneWidget,
        reason: '两个解码器同时跑 = 更费电，代价要说清');

    await _dropTree(tester);
  });

  testWidgets('★ 关态也要说清"没有预取、是原来的行为"', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await AppConfig.load();

    await _pumpPage(tester);

    expect(find.textContaining('队列预取'), findsOneWidget,
        reason: '关态文案也要提到预取（用户是看着关态决定要不要开的）');
    expect(find.textContaining('原来的行为'), findsOneWidget);

    await _dropTree(tester);
  });
}
