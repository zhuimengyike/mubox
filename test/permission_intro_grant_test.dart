/// 首启引导页（`permission_intro_page.dart`）`_grant()` 三处权限调用的**兜底断言**。
///
/// 症状（修前）：`_grant()` 里三句权限调用**都没有兜底**：
/// ```dart
/// setState(() { _busy = true; _attempted = true; });
/// final media  = await OnAudioQuery().permissionsRequest();   // ← 抛了就断在这
/// final notif  = await Permission.notification.request();     // ← 或这
/// final record = await Permission.microphone.request();       // ← 或这
/// if (!mounted) return;
/// setState(() { _busy = false; … });                          // ← 永远到不了
/// ```
/// 三句都在 `_busy = true` **之后**、`setState(_busy = false)` **之前**
/// ⇒ 任何一句抛了：按钮**永久停在「授权中…」且 `onPressed: null`**，
/// 用户点不动、也进不了主界面（`setOnboarded(true)` 在最后）。
/// ★ 这是**首启引导页** —— 卡住 = 第一眼就进不去 App。
///
/// 断言（四条）：
/// 1. ★ **正常路径逐项等价**：三个通道都不抛时，引导页**状态机与点击后走哪条路**
///    逐项钉住 —— 按钮可点 → 忙碌 → 三项授权态 → 进入主界面（`onboarded` 落盘）；
/// 2. ★ **异常路径**：三处**各自单独**抛 `PlatformException` ⇒ 不炸、**按钮恢复可点**、
///    且**另外两处照样被请求**（各自兜底，一处挂不拖死别处）；
/// 3. ★ **负向对照有牙**：把兜底收起来（= 修前写法）⇒ 必须复现「按钮卡在授权中…」；
/// 4. ★ **`Error` 不被吞**：`PlatformException` 之外的真 `Error`（`TypeError`）
///    必须**漏出来**（宽兜底会吞掉它 —— 由 4b 对照证明）。
///
/// ⚠️ 这里**不能用**「可执行代码逐行全等」那种做法：本页是**真改代码**。
/// 所以第 1 条换成「**正常路径的行为断言**」——把流程的每一步都断言出来。
///
/// ⚠️ 已踩过的坑（别改回去）：
/// - **`runZonedGuarded` 不许套 `tester.pumpWidget`**（会把 `TestAsyncUtils` 的
///   guard 拧住、`pumpWidget` 直接不进，实测挂死）。要量渲染路径上的异步错误
///   走 `FlutterError.onError`。
/// - **别用「平台实现抛 `Error`」+ 真页面 `pumpWidget`**：那个 `Error` 会进
///   `flutter_test` 自己的错误处理闭包，触发
///   `binding.dart:1911` 的 `_pendingExceptionDetails != null` 断言。
///   ⇒ 第 4 条改用**纯 Dart**（不装页面）。
/// - **`on_audio_query` 的通道回的是 `bool`**：回个非 bool 就能让**插件解码层**
///   抛真 `TypeError`（是 `Error`，不是 `Exception`）—— 第 4 条要的就是它。
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/pages/permission_intro_page.dart';
import 'package:on_audio_query/on_audio_query.dart';
// `permission_handler` 的 `PlatformException` / `PermissionStatus` 在本文件里
// 只由上面那条 import 间接带进来；这条**显式**留着是为了表明
// 「本文件测的就是 permission_handler 这条链路」，不是漏删的。
// ignore: unused_import
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `permission_handler` 的原生通道（notification / microphone 都走它）。
const MethodChannel _kPermChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');

/// `on_audio_query` 插件通道（音乐库权限走它）。
const MethodChannel _kAudioQueryChannel =
    MethodChannel('com.lucasjosino.on_audio_query');

/// `permission_handler` 的 `openAppSettings` 也走这条通道的另一个方法，
/// 但同一通道就够了；`power_monitor` 那条单独挂哑 handler 免得异步冒异常。
const MethodChannel _kPowerSaveChannel =
    MethodChannel('com.mubox.mu_box_phone/power_save');

/// 记录每个通道被调了几次 / 被调了哪些方法。
class Calls {
  final List<String> audioQuery = <String>[];
  final List<String> perm = <String>[];
  void clear() {
    audioQuery.clear();
    perm.clear();
  }
}

/// 三个通道的行为配置。
class _Chan {
  /// `permissionsRequest` 回什么。★ 回非 bool ⇒ 插件解码层抛真 `TypeError`。
  Object? audioQueryReply = true;

  /// ★ `requestPermissions` 回的是 **`Map<int,int>`**（权限值 → 状态值），
  /// 不是单个 int —— 回单个 int 会让插件解码层抛 `TypeError`（实测）。
  /// 缺省「全都 granted」。
  ///
  /// ⚠️ 键是 `Permission` 的**数字 value**，不是枚举序号：
  /// `Permission.microphone = 7`、`Permission.notification = 17`
  /// （见 `permission_handler_platform_interface` 的 `permissions.dart`）。
  /// 我第一次随手写成 `0/1` ⇒ 两项都解不出 granted ⇒ 对勾只亮 1 个（实测）。
  Map<int, int> permRequestReply = <int, int>{
    7: 1, // Permission.microphone → granted
    17: 1, // Permission.notification → granted
  };

  /// 让哪条通道抛什么异常（null = 不抛）。键：'audioQuery' / 'permRequest' /
  /// 'appSettings'
  ///
  /// ⚠️ **刻意没有 `checkPermissionStatus`**：本页**从来不调它** ——
  /// `permission_handler.dart:107` 的 `Permission.request()` 只调
  /// `requestPermissions`，`status` 那个 getter 没人碰。我第一版给它写了个
  /// 场景，结果那一场**根本没抛**（调用记录里一次都没有）⇒ 那种"假场景"
  /// 必须踢掉：它会让断言看起来覆盖了三处，其实只覆盖了两处。
  final Map<String, Object> throwOn = <String, Object>{};
}

// 类型故意是公开的（`Calls` 而不是 `_Calls`）：私有类型做全局变量会触发
// `library_private_types_in_public_api`。测试文件里公开一个记录器无所谓。
late Calls calls;

void _install(_Chan c) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kAudioQueryChannel, (call) async {
    calls.audioQuery.add(call.method);
    final e = c.throwOn['audioQuery'];
    if (e != null) throw e;
    if (call.method == 'permissionsRequest') return c.audioQueryReply;
    return null;
  });
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kPermChannel, (call) async {
    calls.perm.add(call.method);
    switch (call.method) {
      case 'requestPermissions':
        final e = c.throwOn['permRequest'];
        if (e != null) throw e;
        return c.permRequestReply;
      case 'openAppSettings':
        final e = c.throwOn['appSettings'];
        if (e != null) throw e;
        return true;
      default:
        return null;
    }
  });
}

void _clearChannels() {
  for (final ch in [_kAudioQueryChannel, _kPermChannel]) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(ch, null);
  }
}

/// 页面上那颗按钮（`_busy` 时会变成「授权中…」且被禁用）。
Finder get _grantButton => find.byType(FilledButton);

bool _buttonEnabled(WidgetTester tester) =>
    tester.widget<FilledButton>(_grantButton).onPressed != null;

String _buttonLabel(WidgetTester tester) {
  final t = find.descendant(of: _grantButton, matching: find.byType(Text));
  return tester.widgetList<Text>(t).map((w) => w.data ?? '').join();
}

/// 点一下按钮并把异步链推完。
Future<void> _tapGrant(WidgetTester tester) async {
  await tester.tap(_grantButton);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
  await tester.pump();
}

Future<void> _pumpPage(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(home: PermissionIntroPage()));
  await tester.pump();
}

// ───────────────────────── 第 3 条的「修前写法」对照 ─────────────────────────

/// ★ **照修前的 `_grant()` 写**：三句权限调用**都没有兜底** —— 第 3 条用它
/// 复现「按钮卡在授权中…」。它**不是**生产代码，是拿来做负向对照的。
Future<void> unguardedGrantLikeBefore(
  Future<bool> Function() media,
  Future<bool> Function() notif,
  Future<bool> Function() record,
  void Function() setBusyFalse,
) async {
  final m = await media(); // ← 抛了就断在这，下面全不执行
  final n = await notif();
  final r = await record();
  setBusyFalse();
  // ignore: unused_local_variable
  final _ = (m, n, r);
}

/// 在**独立 zone** 里跑 [body]，返回「漏出来的未捕获异步异常」列表。
///
/// ⚠️ **不许拿它套 `tester.pumpWidget`**（会把 `TestAsyncUtils` 的 guard 拧住、
/// `pumpWidget` 直接不进，实测挂死）。只能量纯 Dart 的那几条。
Future<List<Object>> runZonedGuardedHelper(Future<void> Function() body) async {
  final errs = <Object>[];
  final done = Completer<void>();
  runZonedGuarded(
    () async {
      await body();
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!done.isCompleted) done.complete();
    },
    (e, _) {
      errs.add(e);
      if (!done.isCompleted) done.complete();
    },
  );
  await done.future.timeout(const Duration(seconds: 5), onTimeout: () {});
  return errs;
}

/// 包一层，让第 4 条能在**不改生产代码**的前提下走**真**插件调用路径。
class OnAudioQueryWrapper {
  static Future<bool> request() => OnAudioQuery().permissionsRequest();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppConfig.instance.onboarded = false;
    calls = Calls();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSaveChannel, (call) async => null);
  });

  tearDown(() {
    _clearChannels();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSaveChannel, null);
  });

  // ───────────────── 1. 正常路径逐项等价 ─────────────────

  testWidgets('★1 正常路径：三个通道都不抛 ⇒ 流程逐项与改动前一致', (tester) async {
    _install(_Chan());
    AppConfig.instance.onboarded = false;

    await _pumpPage(tester);

    // ① 初态：可点、且**三个通道一个都还没被调**（没人在 build 里偷跑权限）
    expect(_buttonEnabled(tester), isTrue, reason: '初态按钮必须可点');
    expect(calls.audioQuery, isEmpty, reason: '进页面不该自己请求音乐库权限');
    expect(calls.perm, isEmpty, reason: '进页面不该自己请求权限');

    await _tapGrant(tester);

    // ② 三个通道**各被请求一次**，顺序与改动前一致：音乐库 → 通知 → 麦克风
    expect(calls.audioQuery, contains('permissionsRequest'),
        reason: '音乐库权限必须被请求');
    expect(calls.perm.where((m) => m == 'requestPermissions').length, 2,
        reason: '通知 + 麦克风 = 2 次 requestPermissions');
    // ③ 授权态：三个都 granted ⇒ 页面上三个对勾
    expect(find.byIcon(Icons.check_circle), findsNWidgets(3),
        reason: '三项都授权 ⇒ 三个对勾（这是"状态机走完了"的可见证据）');
    // ④ 按钮恢复可点、文字回到「开启权限」
    expect(_buttonEnabled(tester), isTrue, reason: '忙完必须恢复可点');
    expect(_buttonLabel(tester), contains('开启权限'),
        reason: '忙完文字必须回到「开启权限」，实际=${_buttonLabel(tester)}');
    // ⑤ 音乐库拿到 ⇒ 进入主界面（onboarded 落盘）
    expect(AppConfig.instance.onboarded, isTrue,
        reason: '音乐库授权成功必须 setOnboarded(true)（home 切主界面）');
    final sp = await SharedPreferences.getInstance();
    expect(sp.getBool('onboarded'), isTrue, reason: 'onboarded 必须落盘');
    // ignore: avoid_print
    print('MuBox 判据·首启1：正常路径 按钮=${_buttonLabel(tester)} '
        '对勾=${find.byIcon(Icons.check_circle).evaluate().length} '
        'audioQuery=${calls.audioQuery} perm=${calls.perm} onboarded=true ✅');
  });

  // ───────────────── 2. 异常路径：三处各自单独抛 ─────────────────

  /// ★ 三处**真的会被走到**的失败点（不是猜的，是按调用链核过的）：
  /// 1. `audioQuery` —— `OnAudioQuery().permissionsRequest()`（音乐库）；
  /// 2. `permRequest` —— `Permission.request()` → `requestPermissions`
  ///    （通知 + 麦克风各一次）；
  /// 3. `openAppSettings` —— `_askMic` 里授权没给成时那条「去系统设置」的退路。
  ///
  /// ⚠️ **`checkPermissionStatus` 不在这张表里**：本页**从来不调它** ——
  /// `permission_handler` 的 `Permission.request()`（`permission_handler.dart:107`）
  /// 只调 `requestPermissions`，`status` 那个 getter 没人碰。
  /// 我第一版把它当失败点写了个场景，结果那一场**根本没抛**（实测：调用记录里
  /// 一个 `checkPermissionStatus` 都没有）⇒ 那种"假场景"必须踢掉，
  /// ★ 它会让断言看起来覆盖了三处，其实只覆盖了两处。
  for (final site in ['audioQuery', 'permRequest']) {
    testWidgets('★2 异常路径：$site 抛 PlatformException ⇒ 不炸且按钮恢复可点',
        (tester) async {
      final c = _Chan();
      c.throwOn[site] =
          PlatformException(code: 'BOOM', message: '打桩：$site 通道挂了');
      _install(c);
      AppConfig.instance.onboarded = false;

      final reports = <Object>[];
      final prevOnError = FlutterError.onError;
      FlutterError.onError = (d) => reports.add(d.exception);
      try {
        await _pumpPage(tester);
        await _tapGrant(tester);

        // ★ 先证明这个场景**真的抛了**（不然就是"假场景"）
        expect(calls.audioQuery, contains('permissionsRequest'),
            reason: '音乐库那次必须真的被调用过');
        expect(calls.perm, contains('requestPermissions'),
            reason: '权限那次必须真的被调用过');

        expect(reports, isEmpty,
            reason: '平台异常必须被兜住，不许冒到 FlutterError');
        expect(_buttonEnabled(tester), isTrue,
            reason: '★ 核心：抛了以后按钮**必须恢复可点** —— '
                '修前这里会永久卡在「授权中…」+禁用。'
                '实际 label=${_buttonLabel(tester)} enabled=${_buttonEnabled(tester)}');
        expect(_buttonLabel(tester), contains('开启权限'),
            reason: '按钮文字必须回到「开启权限」');
        if (site == 'audioQuery') {
          // 音乐库没拿到 ⇒ 必须给出提示 + 「去系统设置」退路
          expect(find.text('音乐权限未开启时无法扫描歌曲，请先授权'), findsOneWidget,
              reason: '试过了且音乐库没拿到 ⇒ 必须给出「未开启」提示');
          expect(find.text('去系统设置手动开启'), findsOneWidget,
              reason: '必须留有绕过去的手动路径');
          expect(AppConfig.instance.onboarded, isFalse,
              reason: '音乐库没拿到就不该进主界面（与改动前一致）');
        }
        // ignore: avoid_print
        print('MuBox 判据·首启2[$site]：按钮=${_buttonLabel(tester)} '
            'enabled=${_buttonEnabled(tester)} '
            '冒到 FlutterError=${reports.length} 个 ✅');
      } finally {
        FlutterError.onError = prevOnError;
      }
    });
  }

  testWidgets('★2c 第三处：授权没给成时点「去系统设置」，openAppSettings 抛也吞得住',
      (tester) async {
    final c = _Chan()
      // ★ 音乐库这次**回 false**：那条横幅与「去系统设置」只在
      // `_attempted && !_mediaGranted` 时才出现 —— 音乐库要是 true，
      // 横幅压根不渲染（第一版就是这么空跑一场的，实测）。
      ..audioQueryReply = false
      // 两个权限都拒（0 = PermissionStatus.denied）
      ..permRequestReply = <int, int>{7: 0, 17: 0};
    c.throwOn['appSettings'] =
        PlatformException(code: 'BOOM', message: '设置页跳不过去');
    _install(c);
    AppConfig.instance.onboarded = false;

    await _pumpPage(tester);
    await _tapGrant(tester);

    // ★ 先证明前置条件真的成立了（否则后面是空跑）
    expect(calls.audioQuery, contains('permissionsRequest'));
    expect(find.text('音乐权限未开启时无法扫描歌曲，请先授权'), findsOneWidget,
        reason: '音乐库没拿到 ⇒ 必须先出现「未开启」横幅，'
            '否则「去系统设置」根本不会渲染，这一场就是空跑');
    final manual = find.text('去系统设置手动开启');
    expect(manual, findsOneWidget, reason: '拒了权限就该出现手动入口');

    final reports = <Object>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) => reports.add(d.exception);
    try {
      await tester.tap(manual);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(calls.perm, contains('openAppSettings'),
          reason: '★ 先证明这一路**真的走到**了 openAppSettings');
      expect(reports, isEmpty,
          reason: '★ 这一处（`_askMic` 里的 `openAppSettings()`）也必须兜住 —— '
              '它是"去系统设置"唯一的退路，抛出去就没人接');
      // ignore: avoid_print
      print('MuBox 判据·首启2c：openAppSettings 抛了但被兜住 '
          '（冒到 FlutterError=${reports.length} 个）✅');
    } finally {
      FlutterError.onError = prevOnError;
    }
  });

  testWidgets('★2b 一处挂不拖死别处：音乐库通道挂了，通知/麦克风照样被请求',
      (tester) async {
    final c = _Chan();
    c.throwOn['audioQuery'] =
        PlatformException(code: 'BOOM', message: '音乐库通道挂了');
    _install(c);

    await _pumpPage(tester);
    await _tapGrant(tester);

    expect(calls.audioQuery, contains('permissionsRequest'),
        reason: '音乐库那次确实被调了（然后挂了）');
    expect(calls.perm.where((m) => m == 'requestPermissions').length, 2,
        reason: '★ 各自兜底：音乐库挂了，通知与麦克风**仍然各被请求一次** —— '
            '这就是"一处挂不拖死别处"的证明');
    expect(_buttonEnabled(tester), isTrue, reason: '按钮仍恢复可点');
    // ignore: avoid_print
    print('MuBox 判据·首启2b：音乐库挂了以后 perm 调用=${calls.perm}（应为 2 次 request）✅');
  });

  // ───────────────── 3. 负向对照有牙 ─────────────────

  testWidgets('★3 有牙（负向对照）：兜底收起来 ⇒ 按钮永久卡在「授权中…」',
      (tester) async {
    // 用**修前的形状**（三句都不兜底）跑同一套打桩：音乐库通道抛。
    var finished = false;

    final leaked = await runZonedGuardedHelper(() async {
      await unguardedGrantLikeBefore(
        () async => throw PlatformException(code: 'BOOM', message: '音乐库挂了'),
        () async => true,
        () async => true,
        () => finished = true,
      );
    });

    expect(leaked, hasLength(1),
        reason: '★ 修前写法必须把异常漏出去（这就是"牙"）');
    expect(finished, isFalse,
        reason: '★ 修前写法**永远走不到** `setState(_busy = false)` ⇒ '
            '`_busy` 停在 true ⇒ 按钮永久「授权中…」+禁用。'
            '这就是要修的病症。');
    // ignore: avoid_print
    print('MuBox 判据·首启3有牙：修前写法 漏出=${leaked.length} 个 '
        '走到收尾=$finished（false = 卡死）✅');
  });

  // ───────────────── 4. Error 不被吞（纯 Dart） ─────────────────

  test('★4 Error 不被吞：插件解码层抛 TypeError ⇒ 窄兜底漏出、宽兜底吞掉',
      () async {
    // 让 on_audio_query 的 `permissionsRequest` 回一个**非 bool**
    // ⇒ 插件 `final bool resultRequest = await …` 抛真 `TypeError`。
    final c = _Chan()..audioQueryReply = '不是个 bool';
    _install(c);

    Future<bool> call() => OnAudioQueryWrapper.request();

    // ① 照生产代码的兜底（两个 on…catch）
    final guarded = await runZonedGuardedHelper(() async {
      try {
        await call();
      } on PlatformException {
        //
      } on MissingPluginException {
        //
      }
    });
    // ② 宽兜底（对照物）
    final broad = await runZonedGuardedHelper(() async {
      try {
        await call();
      } catch (_) {
        //
      }
    });

    expect(guarded, hasLength(1),
        reason: '★ 真 `Error` 必须漏出来 —— 窄兜底抓不到它（这正是"没被吞"）');
    expect(guarded.first is Error, isTrue,
        reason: '漏出来的必须是 Error，实际 ${guarded.first.runtimeType}');
    expect(broad, isEmpty,
        reason: '★ 有牙：同一个 Error 换成宽兜底就被吞干净 —— '
            '证明第 4 条量的确实是兜底的宽窄');
    // ignore: avoid_print
    print('MuBox 判据·首启4：TypeError 窄兜底漏出=${guarded.length}（${guarded.first.runtimeType}）'
        ' 宽兜底漏出=${broad.length}（0=吞掉）✅');
  });
}
