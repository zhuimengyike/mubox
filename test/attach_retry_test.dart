/// 音效「挂载失败 vs 硬件没有」的断言（**这个文件第一次跑时第 5、7 组必须是红的**
/// —— 那两组正是用来证明「修复不在了就会红」的负向对照）。
///
/// ## 现场
/// `LoudnessEnhancer` 挂到**新建的音频会话**上会**间歇性**失败：
/// ```
/// W/ExtraEffects: loudness attach failed: Cannot initialize effect engine for type:
///                 fe3199be-aed0-413f-87bb-11260eb63cf1 Error: -3
/// D/ExtraEffects: attached, sessionId=5697 playerId=de98df96-… bass=true loud=false
/// ```
/// `-3` = `AudioEffect.ERROR_NO_INIT`（AOSP：bad object initialization）。
/// **同一台机器、同一个 effect 型号**另一个 session 上挂成功了
/// （`dumpsys media.audio_flinger`：session 5681 的 `Loudness Enhancer` / `fa415329-…`
/// 注册成功，session 5697 那个 `Registered=n`）⇒ **不是「这台设备没有这个接口」**。
///
/// ## 改前的两个真缺陷（本文件钉的就是它们）
/// **改前**这两种情况在 UI 上是同一张脸：原生 `info()` 只给 `loudSupported = (loud != null)`，
/// 页面据此 ① 开关显示 off、② `onChanged: null`（**点不动**）、③ 卡片写
/// 「这台设备没有提供响度增强接口」⇒ **误导 + 用户失去自救入口**。
/// 而 Dart 侧 `setLoudness` 走的是原生 `setLoudness`，**它不调 `open()`** ⇒
/// 就算开关能点也补救不了。**两处一起修**。
///
/// ## 断言（每条都带正负一对）
/// 1. `attachStateOf` 的三态真值表（含"`supported` 赢过 `failed`"的优先级）；
/// 2. **正常路径逐项等价改动前** —— `unknown`（没试过）与 `ok`（挂上了）时的
///    开关可点性/显示值/文案 = **改前那两条公式**；
/// 3. ★ **负向有牙**：`failed` 时**改前那两条公式**给出的正是原症状（禁用 + 谎报）
///    ⇒ 本文件的第 5、7 组在改动前**必然红**；
/// 4. 硬不支持（`loudRetryable == false`）时**不许**给「再试一次」的假希望；
/// 5. ★ **接线**：`setLoudnessEnabled` / `setBassEnabled` 真的把 `playerId` 带上过桥
///    （不带 = 假重试：挂到一个已经死掉的兼容格子 session 上）；
/// 6. 线上 UI：正常路径两颗开关的可点性与文案**逐项等于改动前**。
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/attach_retry.dart';
import 'package:mu_box_phone/extra_effects.dart';
import 'package:mu_box_phone/pages/sound_effects_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─────────────────────────────────────────────────────────────────────────────
// ★ 改动前的两条公式（**逐字**抄自改动前的 sound_effects_page.dart:_loudCard）。
//   本文件把它们当成"负向对照"的基准：正常路径必须与它们相等，
//   而失败路径必须与它们**不同**（不同 = 改动真的有牙）。
// ─────────────────────────────────────────────────────────────────────────────
bool _oldSwitchOn(ExtraFxState s) => s.loudSupported;
bool _oldSwitchChecked(ExtraFxState s) => s.loudSupported && s.loudEnabled;
String _oldDesc(ExtraFxState s) => s.loudSupported
    ? '把整体响度往上提，小音量下细节更清楚（近似「夜间模式」的反面）'
    : '这台设备没有提供响度增强接口';

/// 页面那个响度开关。**字面量与 `sound_effects_page.dart` 里那行的 `key:` 一致**
/// （刻意不 import 常量：没接线时本文件也要能编译 —— 红灯才是"找不到开关"）。
const ValueKey<String> _kLoudSwitch = ValueKey<String>('switch_loud');

const MethodChannel _kExtraFx = MethodChannel(
  'com.mubox.mu_box_phone/extra_effects',
);
const MethodChannel _kPowerSaveChannel = MethodChannel(
  'com.mubox.mu_box_phone/power_save',
);

/// 原生 `info()` / `applyAll` 会回报的一整份快照（页面靠它渲染）。
Map<Object?, Object?> _snapshot({
  bool available = true,
  bool supported = false,
  bool enabled = false,
  bool attempted = false,
  bool failed = false,
  bool retryable = false,
  bool exhausted = false,
}) => <Object?, Object?>{
  'available': available,
  'sessionId': 5681,
  'bassSupported': true,
  'bassEnabled': false,
  'bassStrength': 600,
  'loudSupported': supported,
  'loudEnabled': enabled,
  'loudGain': 400,
  'loudMaxGain': 1200,
  'loudAttachAttempted': attempted,
  'loudAttachFailed': failed,
  'loudRetryable': retryable,
  'loudRetryExhausted': exhausted,
};

ExtraFxState _state({
  bool available = true,
  bool supported = false,
  bool enabled = false,
  bool attempted = false,
  bool failed = false,
  bool retryable = false,
  bool exhausted = false,
}) => ExtraFxState.fromMap(
  _snapshot(
    available: available,
    supported: supported,
    enabled: enabled,
    attempted: attempted,
    failed: failed,
    retryable: retryable,
    exhausted: exhausted,
  ),
);

/// 哑播放器：本文件只渲染页面，一次真实播放调用都不许发生。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 记录过桥的 `setBass`/`setLoudness` 调用（接线那几条断言靠它）。
/// 每项 = `{'method': …, …参数}`；`open` / `applyAll` 不进这个表（它们不是开关路径）。
List<Map<String, Object?>> _fxCalls = [];

/// 给 `extra_effects` 通道装一个会记账的桩：`open` / `applyAll` 返回 [snapshot]，
/// 两条开关路径把参数记进 [_fxCalls] 再返回 [snapshot]。
void _installFxMock(Map<Object?, Object?> snapshot) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kExtraFx, (call) async {
    if (call.method == 'setBass' || call.method == 'setLoudness') {
      final args = call.arguments is Map
          ? Map<String, Object?>.from(call.arguments as Map)
          : <String, Object?>{};
      _fxCalls.add(<String, Object?>{'method': call.method, ...args});
    }
    return snapshot;
  });
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required Map<Object?, Object?> snapshot,
}) async {
  _installFxMock(snapshot);
  await tester.pumpWidget(const MaterialApp(home: SoundEffectsPage()));
  await tester.pump(); // initState 的 refresh() 回来
  await tester.pump(); // 让它落地
}

Future<void> _dropTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _fxCalls = [];
    playerService = PlayerService(player: _StubPlayer());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSaveChannel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kExtraFx, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSaveChannel, null);
    playerService = null;
  });

  // ── 1. 三态真值表 ──────────────────────────────────────────────────────────
  group('★1 三态真值表 attachStateOf', () {
    test('挂上了 ⇒ ok（不管另两个键说什么）', () {
      expect(
        attachStateOf(supported: true, attachAttempted: true, attachFailed: true),
        AttachState.ok,
        reason: 'supported 必须赢过 failed：真挂着就不许说失败',
      );
      expect(
        attachStateOf(supported: true, attachAttempted: false, attachFailed: false),
        AttachState.ok,
      );
    });

    test('没挂上 + 试过 + 失败 ⇒ failed', () {
      expect(
        attachStateOf(supported: false, attachAttempted: true, attachFailed: true),
        AttachState.failed,
      );
    });

    test('★ 没试过 ⇒ unknown（**不是** failed）—— 这是"观感零变化"的地基', () {
      expect(
        attachStateOf(supported: false, attachAttempted: false, attachFailed: false),
        AttachState.unknown,
      );
      // 半截数据（老原生只回报了 failed、没回报 attempted）也必须落回 unknown：
      // 没有"试过"的证据就不许断言失败。
      expect(
        attachStateOf(supported: false, attachAttempted: false, attachFailed: true),
        AttachState.unknown,
        reason: 'attached 没试过时，failed 这个键没有意义，不许单独生效',
      );
    });
  });

  // ── 2. 可重试性 ───────────────────────────────────────────────────────────
  group('★2 只有 failed 可重试', () {
    test('正向：failed ⇒ 可重试', () {
      expect(loudRetryable(AttachState.failed), isTrue);
    });

    test('负向：ok / unknown ⇒ 不可重试', () {
      expect(loudRetryable(AttachState.ok), isFalse);
      expect(loudRetryable(AttachState.unknown), isFalse);
    });
  });

  // ── 3. ★ 正常路径逐项等价改动前 ────────────────────────────────────────────
  group('★3 正常路径 == 改动前的两条公式（观感零变化）', () {
    test('unknown（没试过、没挂上）⇒ 开关可点性/显示值/文案逐项相同', () {
      final s = _state(available: true);
      expect(s.loudAttachState, AttachState.unknown);
      expect(s.loudSwitchOn, _oldSwitchOn(s), reason: '可点性必须一样（改前=禁用）');
      expect(s.loudSwitchChecked, _oldSwitchChecked(s), reason: '显示值必须一样');
      expect(s.loudCardOverride, isNull, reason: '★ 文案必须走改动前那句原文');
      expect(_oldDesc(s), '这台设备没有提供响度增强接口');
      expect(s.loudSwitchOn, isFalse, reason: '改前是禁用，现在也是禁用');
    });

    test('ok（挂上了）⇒ 开关可点性/显示值/文案逐项相同', () {
      final s = _state(available: true, supported: true, enabled: true);
      expect(s.loudAttachState, AttachState.ok);
      expect(s.loudSwitchOn, _oldSwitchOn(s));
      expect(s.loudSwitchChecked, _oldSwitchChecked(s));
      expect(s.loudCardOverride, isNull);
      expect(s.loudSwitchOn, isTrue);
      expect(s.loudSwitchChecked, isTrue);
    });

    test('ok 但用户没开 ⇒ 显示为关（与改动前一致）', () {
      final s = _state(available: true, supported: true, enabled: false);
      expect(s.loudSwitchChecked, isFalse);
      expect(s.loudSwitchChecked, _oldSwitchChecked(s));
    });

    test('不到场（available=false）⇒ 开关不可点（与改动前一致）', () {
      final s = _state(available: false);
      expect(s.loudSwitchOn, isFalse);
      expect(s.loudSwitchOn, _oldSwitchOn(s));
    });

    test('★ 老原生（不回报三个新键）⇒ 落回改动前的行为', () {
      // 只给改动前那套键（模拟旧版 APK 的原生 info()）
      final s = ExtraFxState.fromMap(<Object?, Object?>{
        'available': true,
        'loudSupported': false,
        'loudEnabled': true, // 用户开着，但挂失败了
      });
      expect(s.loudAttachAttempted, isFalse);
      expect(s.loudAttachFailed, isFalse);
      expect(s.loudRetryable, isFalse);
      expect(s.loudAttachState, AttachState.unknown);
      expect(s.loudSwitchOn, _oldSwitchOn(s), reason: '老原生下必须与改动前逐项相同');
      expect(s.loudSwitchChecked, _oldSwitchChecked(s));
      expect(s.loudCardOverride, isNull);
    });
  });

  // ── 4. ★★ 负向有牙：失败路径在改动前**就是**原症状 ──────────────────────────
  group('★4 负向有牙（改动前这两条的断言必然红）', () {
    test('★ failed ⇒ 新行为与改动前**必须不同**，且改动前正是「禁用 + 谎报没有接口」', () {
      final s = _state(
        available: true,
        attempted: true,
        failed: true,
        retryable: true,
      );
      expect(s.loudAttachState, AttachState.failed);

      // ① 改动前：开关禁用（`onChanged: null`）⇒ 用户拨不动 ⇒ 补救不了
      expect(_oldSwitchOn(s), isFalse, reason: '改动前那个公式在失败时禁用开关');
      // ① 改后：必须可点（点一下 = 一次真实重挂）
      expect(s.loudSwitchOn, isTrue, reason: '★ failed 时开关必须可点，否则用户没有自救入口');
      expect(s.loudSwitchOn, isNot(_oldSwitchOn(s)), reason: '★ 与改动前必须不同 = 有牙');

      // ② 改动前：文案写「这台设备没有提供响度增强接口」= **谎报**（硬件其实支持）
      expect(_oldDesc(s), '这台设备没有提供响度增强接口');
      // ② 改后：必须换成真话，且**不许**出现"没有提供"这几个字
      expect(s.loudCardOverride, isNotNull, reason: '★ 失败必须有专属文案');
      expect(s.loudCardOverride, isNot(contains('没有提供')), reason: '★ 不许谎报硬件没有');
      expect(s.loudCardOverride, contains('再试一次'), reason: '要告诉用户怎么办');
    });

    test('★ 硬不支持（不 retryable）⇒ 文案回到「没有提供」，且开关仍可点（点了也无害）', () {
      final s = _state(
        available: true,
        attempted: true,
        failed: true,
        retryable: false,
      );
      // 三态只回答「这一次挂成没成」；「要不要给重试」由 `retryable` 单独回答。
      expect(s.loudAttachState, AttachState.failed);

      // ★ `retryable` 的**唯一**作用是文案分流：
      //   不 retryable ⇒ 不许劝人「再试一次」（那是假希望），
      //   但也不许把「其实支持、只是这次没起来」说成「支持」—— 这个分支进不来。
      expect(s.loudCardOverride, isNull,
          reason: '硬不支持 ⇒ 走改动前那句「这台设备没有提供响度增强接口」（在这个分支上它是真话）');
      expect(_oldDesc(s), '这台设备没有提供响度增强接口');
      expect(s.loudSwitchOn, isTrue,
          reason: '★ 开关**不**按 retryable 关：判断"值不值得重挂"要看会话，不是看上一次的错。'
              '而且 `ERROR_BAD_VALUE` 只在整套 effect 库都不可用时才出现，那种机器上开关本来就没意义；'
              '为了一个说不准的猜测把开关又锁死，就是把这次修的东西又还回去了。');
      expect(s.loudSwitchChecked, isFalse, reason: '没挂上 ⇒ 不许显示成开');
    });
  });

  // ── 5. ★ 接线：重试必须带上播放器身份 ──────────────────────────────────────
  group('★5 接线：拨开关时 playerId 必须过桥', () {
    test('★ 带过身份（进程内播放过）⇒ setLoudness / setBass 的参数里必须有 playerId',
        () async {
      SharedPreferences.setMockInitialValues({});
      _installFxMock(_snapshot(available: true));
      await ExtraFxEngine.instance.init();
      // 先让引擎记住身份（这是 player_service._retargetEffects 每轮都做的事）
      await ExtraFxEngine.instance.ensure(force: true, playerId: 'uuid-A');
      _fxCalls = [];

      await ExtraFxEngine.instance.setLoudnessEnabled(true);
      await ExtraFxEngine.instance.setBassEnabled(true);

      expect(_fxCalls, hasLength(2), reason: '两条开关各过桥一次');
      expect(_fxCalls[0]['method'], 'setLoudness');
      expect(_fxCalls[0]['enabled'], isTrue);
      expect(_fxCalls[0]['playerId'], 'uuid-A',
          reason: '★ 不带身份 = 原生挂到兼容格子那个可能已死的 session 上 = 假重试');
      expect(_fxCalls[1]['method'], 'setBass');
      expect(_fxCalls[1]['playerId'], 'uuid-A');
    });

    test('★ 负向对照：只改增益那条路不带身份（它不触发重挂）⇒ 证明上一条不是恒真',
        () async {
      SharedPreferences.setMockInitialValues({});
      _installFxMock(_snapshot(available: true));
      await ExtraFxEngine.instance.init();
      await ExtraFxEngine.instance.ensure(force: true, playerId: 'uuid-A');
      _fxCalls = [];

      await ExtraFxEngine.instance.setLoudnessGain(500);

      expect(_fxCalls.single['method'], 'setLoudness');
      expect(_fxCalls.single.containsKey('playerId'), isFalse,
          reason: '★ 这一路本来就不带身份 ⇒ 证明「带了」是重挂那条路**特意**加的');
      expect(_fxCalls.single.containsKey('retry'), isFalse,
          reason: '★ 也不带 retry ⇒ 原生一个 effect 都不碰（真机上这一枪曾经拆掉整条链）');
    });

    // ── ★5b 重挂请求的显式键（真机「连点风暴」那个故障）──────────────────────
    test('★★ 拨开关「打开」⇒ 必须带 retry:true（原生据此才可能重挂）', () async {
      SharedPreferences.setMockInitialValues({});
      _installFxMock(_snapshot(available: true));
      await ExtraFxEngine.instance.init();
      await ExtraFxEngine.instance.ensure(force: true, playerId: 'uuid-A');
      _fxCalls = [];

      await ExtraFxEngine.instance.setLoudnessEnabled(true);
      await ExtraFxEngine.instance.setBassEnabled(true);

      expect(_fxCalls[0]['retry'], isTrue, reason: '响度开关打开必须请求重挂');
      expect(_fxCalls[1]['retry'], isTrue, reason: '低音开关打开同样');
    });

    test('★ 拨开关「关闭」⇒ **不带** retry（关功能不该反向多构造一次 effect）', () async {
      SharedPreferences.setMockInitialValues({});
      _installFxMock(_snapshot(available: true));
      await ExtraFxEngine.instance.init();
      await ExtraFxEngine.instance.ensure(force: true, playerId: 'uuid-A');
      _fxCalls = [];

      await ExtraFxEngine.instance.setLoudnessEnabled(false);
      await ExtraFxEngine.instance.setBassEnabled(false);

      expect(_fxCalls[0]['enabled'], isFalse);
      expect(_fxCalls[0].containsKey('retry'), isFalse);
      expect(_fxCalls[1].containsKey('retry'), isFalse);
    });

    test('★★ 负向有牙：两条滑杆路都**不带** retry（改了 run 现在就该红）', () async {
      SharedPreferences.setMockInitialValues({});
      _installFxMock(_snapshot(available: true));
      await ExtraFxEngine.instance.init();
      await ExtraFxEngine.instance.ensure(force: true, playerId: 'uuid-A');
      // 先把两项都打开，滑杆才可拖（也就才可能走上「参数路」）
      await ExtraFxEngine.instance.setLoudnessEnabled(true);
      await ExtraFxEngine.instance.setBassEnabled(true);
      _fxCalls = [];

      await ExtraFxEngine.instance.setLoudnessGain(700);
      await ExtraFxEngine.instance.setBassStrength(800);

      expect(_fxCalls, hasLength(2));
      for (final c in _fxCalls) {
        expect(c.containsKey('retry'), isFalse,
            reason: '★ 拖滑杆不许请求重挂：真机上每一枪都是 release() + 重建整条效果链');
        expect(c.containsKey('playerId'), isFalse,
            reason: '★ 也不带身份（带了反而坐实"这是一次挂载"）');
      }
      expect(_fxCalls[0]['method'], 'setLoudness');
      expect(_fxCalls[1]['method'], 'setBass');
    });

    // ── 5c. 身份不许被抹掉 ────────────────────────────────────────────────
    test('★ `ensure` 不带身份时**不覆盖**已记住的身份（纯播放路径不许把身份抹掉）',
        () async {
      SharedPreferences.setMockInitialValues({});
      _installFxMock(_snapshot(available: true));
      await ExtraFxEngine.instance.init();
      await ExtraFxEngine.instance.ensure(force: true, playerId: 'uuid-A');
      await ExtraFxEngine.instance.ensure(force: true); // 不带身份那一半
      _fxCalls = [];

      await ExtraFxEngine.instance.setLoudnessEnabled(true);

      expect(_fxCalls.single['playerId'], 'uuid-A',
          reason: '★ 抹掉身份 = 下一次重挂会打到兼容格子那个可能已死的 session 上');
    });

    test('★ 关闭开关也带上身份（原生侧只在打开时才真重挂）', () async {
      SharedPreferences.setMockInitialValues({});
      _installFxMock(_snapshot(available: true));
      await ExtraFxEngine.instance.init();
      await ExtraFxEngine.instance.ensure(force: true, playerId: 'uuid-B');
      _fxCalls = [];

      await ExtraFxEngine.instance.setLoudnessEnabled(false);
      expect(_fxCalls.single['enabled'], isFalse);
      expect(_fxCalls.single['playerId'], 'uuid-B');
    });
  });

  // ── 6. 线上 UI ───────────────────────────────────────────────────────────
  group('★6 音效页上的响度卡片', () {
    testWidgets('★ 正常路径（没试过/没挂上）⇒ 开关禁用 + 文案仍是改动前那句', (tester) async {
      await _pumpPage(tester, snapshot: _snapshot(available: true));

      final sw = tester.widget<Switch>(find.byKey(_kLoudSwitch));
      expect(sw.onChanged, isNull, reason: '★ 改动前这里是禁用，现在必须还是禁用');
      expect(sw.value, isFalse);
      expect(find.text('这台设备没有提供响度增强接口'), findsOneWidget,
          reason: '★ 正常路径的文案必须逐字不变（观感零变化）');
      expect(find.textContaining('再试一次'), findsNothing);

      await _dropTree(tester);
    });

    testWidgets('★ 挂上了 ⇒ 开关可点、跟着用户设置显示，文案还是原句', (tester) async {
      await _pumpPage(
        tester,
        snapshot: _snapshot(available: true, supported: true, enabled: true),
      );

      final sw = tester.widget<Switch>(find.byKey(_kLoudSwitch));
      expect(sw.onChanged, isNotNull);
      expect(sw.value, isTrue);
      expect(find.textContaining('把整体响度往上提'), findsOneWidget);
      expect(find.textContaining('再试一次'), findsNothing);

      await _dropTree(tester);
    });

    testWidgets('★ 负向有牙：试过但没挂上 ⇒ 开关**可点**、文案换成真话（改动前是禁用+谎报）',
        (tester) async {
      await _pumpPage(
        tester,
        snapshot: _snapshot(
          available: true,
          attempted: true,
          failed: true,
          retryable: true,
        ),
      );

      final sw = tester.widget<Switch>(find.byKey(_kLoudSwitch));
      expect(sw.onChanged, isNotNull, reason: '★ 必须可点：这是用户唯一的自救入口');
      expect(sw.value, isFalse, reason: '还没挂上 ⇒ 不许显示成开（显示成开就是骗人）');
      expect(find.text('这台设备没有提供响度增强接口'), findsNothing,
          reason: '★ 不许谎报硬件没有');
      expect(find.textContaining('再试一次'), findsOneWidget);

      await _dropTree(tester);
    });

    testWidgets('★ 点一下那颗开关 ⇒ 真的过桥一次 setLoudness(playerId, enabled=true)',
        (tester) async {
      // 先让引擎记住身份：这一页自己拿不到播放器，靠 `_lastPlayerId`
      // （= `player_service._retargetEffects` 每轮写进去的那个）
      SharedPreferences.setMockInitialValues({});
      _installFxMock(_snapshot(available: true));
      await ExtraFxEngine.instance.init();
      await ExtraFxEngine.instance.ensure(force: true, playerId: 'uuid-A');

      await _pumpPage(
        tester,
        snapshot: _snapshot(
          available: true,
          attempted: true,
          failed: true,
          retryable: true,
        ),
      );
      _fxCalls = [];

      await tester.tap(find.byKey(_kLoudSwitch));
      await tester.pump();
      await tester.pump();

      expect(_fxCalls, isNotEmpty, reason: '★ 点开关必须过桥（重挂请求就是它）');
      final call = _fxCalls.firstWhere((c) => c['method'] == 'setLoudness');
      expect(call['enabled'], isTrue);
      expect(call['playerId'], 'uuid-A',
          reason: '★ 身份必须过桥：不带它原生会挂到兼容格子那个可能已死的 session 上');
      expect(call['retry'], isTrue,
          reason: '★ 还要带 retry：原生只有看到它才可能重挂（冷却 + 次数上限在原生那侧）');

      await _dropTree(tester);
    });
  });

  // ── 7. ★★ 「连点风暴」：次数用满之后的诚实终态 ─────────────────────────────
  group('★7 重挂次数用满 ⇒ 文案切诚实终态（方案 A：开关**不许**禁用）', () {
    ExtraFxState burned() => _state(
      available: true,
      attempted: true,
      failed: true,
      retryable: true,
      exhausted: true,
    );

    test('★ 用满时：文案不许再劝人「点右边的开关再试一次」（那时点了不会重挂）', () {
      final s = burned();
      expect(s.loudAttachState, AttachState.failed);
      expect(s.loudRetryExhausted, isTrue);
      expect(s.loudCardOverride, isNotNull);
      expect(s.loudCardOverride, isNot(contains('点右边的开关再试一次')),
          reason: '★ 用满之后再说这句就是**空头支票**：原生的重挂预算已经用完，点了不会重建');
      expect(s.loudCardOverride, isNot(contains('没有提供')),
          reason: '⛔ 更不许退回"硬件没有"那个谎报');
      expect(s.loudCardOverride, contains('换一首歌'),
          reason: '要说清**什么会重新给机会**（换歌 = 新 session，原生预算归零）');
    });

    test('★★ 用满时开关**仍然可点**（用户拍板方案 A：保留开关 + 再试一次）', () {
      final s = burned();
      expect(s.loudSwitchOn, isTrue,
          reason: '★ 不许把这一项标成不可用 —— 那是换个方向的谎报，而且用户明确否决了这个方案');
      expect(s.loudSwitchChecked, isFalse, reason: '没挂上就不许显示成开（这条改动前就是这样）');
    });

    test('★ 负向对照：用满与没用满必须**不同**（否则这一格是死的）', () {
      final notBurned = _state(
        available: true,
        attempted: true,
        failed: true,
        retryable: true,
      );
      expect(notBurned.loudRetryExhausted, isFalse);
      expect(notBurned.loudCardOverride, contains('点右边的开关再试一次'));
      expect(notBurned.loudCardOverride, isNot(burned().loudCardOverride),
          reason: '★ 两种状态的文案必须不同，否则"用满"这一格没有任何可见效果');
    });

    test('★ 老原生（不回报 loudRetryExhausted）⇒ 落回改动前的文案', () {
      final s = ExtraFxState.fromMap(<Object?, Object?>{
        'available': true,
        'loudSupported': false,
        'loudEnabled': true,
        'loudAttachAttempted': true,
        'loudAttachFailed': true,
        'loudRetryable': true,
      });
      expect(s.loudRetryExhausted, isFalse);
      expect(s.loudCardOverride, '这次没能挂上响度增强（音效引擎初始化失败）\n点右边的开关再试一次就行');
    });

    testWidgets('★ 线上：用满时卡片说真话，且开关仍可点（改动前这里是禁用 + 谎报）',
        (tester) async {
      await _pumpPage(
        tester,
        snapshot: _snapshot(
          available: true,
          attempted: true,
          failed: true,
          retryable: true,
          exhausted: true,
        ),
      );

      final sw = tester.widget<Switch>(find.byKey(_kLoudSwitch));
      expect(sw.onChanged, isNotNull, reason: '★ 方案 A：开关必须还能点');
      expect(sw.value, isFalse, reason: '没挂上 ⇒ 不许显示成开');
      expect(find.text('这台设备没有提供响度增强接口'), findsNothing,
          reason: '★ 不许谎报硬件没有');
      expect(find.textContaining('换一首歌'), findsOneWidget);

      await _dropTree(tester);
    });
  });
}
