/// 设置页「后台播放（忽略电池优化）」两处权限调用的**异常兜底断言**。
///
/// 症状（修前）：`permission_handler` 的 `status` / `request` 都要走原生通道，
/// 通道不可用时**抛异常**。而这两处**都没包 try/catch**：
///   - `_checkBattery()` 是 `initState` 里 fire-and-forget 调的（没人 await）；
///   - 按钮的 `onPressed` 里那次 `request()` 也是。
/// ⇒ 抛出去就是**未捕获异步异常**：用户点「允许后台播放」，屏幕上什么都不发生，
/// 控制台一条红字，连个失败提示都没有。实测原始输出（修前副本跑出来的）：
/// ```
/// PlatformException(BOOM, 打桩：checkPermissionStatus 通道挂了, null, null)
/// ```
///
/// 处置：**静默、不弹任何 UI**；日志前缀用 ASCII `MuBox`。
///
/// ⚠️ **兜底刻意只吞平台异常，不是 `catch (e)`** —— 见第 5、6、7 条：
/// 要吞的是【平台通道挂了】（`PlatformException` / `MissingPluginException`，
/// **外部环境**问题）；`Error` 子类（`StateError` / `TypeError` /
/// `NoSuchMethodError`…）是【我们自己的编程错误】，吞掉等于**把证据藏起来**。
/// 写法照 `lib/eq_engine.dart` 的 `_call`。
///
/// ─────────────────────────────────────────────────────────────────────
/// ★★ **五个已经踩过的坑，别改回去**（每一条都花了一轮才查出来）：
///
/// 1. **`runZonedGuarded` 不许套 `tester.pumpWidget`** —— 它会把
///    `TestAsyncUtils` 的 guard 拧住，`pumpWidget` 直接不进，**实测挂死**。
///    要量「渲染管线里的异步错误」走 [leaksDuring] 的 `FlutterError.onError`。
/// 2. **别用 `(state as dynamic)._checkBattery()` 调私有成员** —— Dart 会给私有名
///    做名字改编（mangling），dynamic 永远解析不到；它抛的 `NoSuchMethodError`
///    还会**被宽 catch / zone 收走**，于是断言**伪装成「0 漏出」的假绿**。
///    —— ★ 第 6 条测的就是这个形状本身。
/// 3. **别指望「往 method channel 里抛 `Error`」**：channel 边界会把任何对象
///    包成 `PlatformException(code: 'error', message: <toString()>)`
///    —— 实测 `StateError('…')` 到了 Dart 侧变成
///    `PlatformException(error, Bad state: …, null, null)`，
///    于是「`Error` 会不会被吞」这个问题**在 channel 上根本问不出来**。
///    要问它必须换掉**平台实现**（见 [_ThrowingPlatform]）。
/// 4. （探针期踩的）把「修前副本」import 进测试时**只能用相对路径**：
///    `package:mu_box_phone/...` 会解析到仓库里那份（已修好的），测了个寂寞。
/// 5. ★ **别拿「平台实现抛 `Error`」+ 真页面 `pumpWidget` 去量第 5 条**：
///    那个 `Error` 会走进 flutter_test 自己的错误处理闭包，触发
///    `binding.dart:1911` 的 `_pendingExceptionDetails != null` 断言
///    （「A test overrode FlutterError.onError but either failed to return it…」）
///    —— 实测踩了两次（一次带 `takeException()`、一次不带），怎么摆都报。
///    ⇒ 第 5、6 条改用**纯 Dart 夹具** [guardedAsProduction] / [broadCatch]，
///    用 `leakUncaught` 量；夹具与生产代码的对齐由第 7 条从源码上钉住。
/// ─────────────────────────────────────────────────────────────────────
///
/// 条目：
/// 1. ★ 负向（有牙）：照修前那样**不包** ⇒ zone 必须收到 1 个漏出的异常；
/// 2. ★ 正向：装出真页面（`initState`→`_checkBattery`→`status`）⇒ 0 个漏出；
/// 3. ★ 正向：`request()` 那半的兜底形状（`PlatformException` + `MissingPluginException`）⇒ 0 个漏出；
/// 4. ★ 接线：两处权限调用**各自都有兜底块**；
/// 5. ★★ 收紧不变量：平台实现抛 **`StateError`** ⇒ `on PlatformException` **不吞 `Error`**，必须漏出去；
/// 6. ★★ 有牙：同一个 `StateError` 换成 `catch (e)` ⇒ **必被吞掉**，
///    证明第 5 条量的确实是「兜底的宽窄」，不是别的；
/// 7. ★ 接线：两处兜底都是 platform-only（两个 `on … catch`，且无裸 `catch (`）。
library;

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/pages/settings_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `permission_handler` 的原生通道名（与插件里那个字面量一致）。
const MethodChannel _kPermChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');

/// `lib/power_monitor.dart` 在这个通道上 `receiveBroadcastStream()` ——
/// 测试环境没人实现它，会异步冒 `MissingPluginException`，落哪一拍不确定。
/// 给个哑 handler 把不确定性掐掉（同 `sound_effects_page_test.dart`）。
const MethodChannel _kPowerSaveChannel =
    MethodChannel('com.mubox.mu_box_phone/power_save');

/// 哑播放器：设置页里有几张卡会读全局 `playerService`。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// ★ 让插件的**解码层**抛一个**真正的 `Error`**（`TypeError`）。
///
/// 第 5、6 条要问的是「**`Error` 会不会被兜底吞掉**」。这个 `Error` 必须出现在
/// **Dart 侧**（兜底块所在的层），不能是通道那头抛过来的 —— 见文件头坑 3：
/// 通道边界会把任何对象包成 `PlatformException`，`Error` 在通道上问不出来。
///
/// 做法：让 `checkPermissionStatus` 回一个**形状不对的值**（`String` 而不是 `int`），
/// 插件自己的 `decodePermissionStatus(int value)` 就会因实参类型不符抛
/// `TypeError` —— 那是 `Error`，不是 `Exception`。
///
/// ⚠️ 为什么不用 `PermissionHandlerPlatform.instance = <会抛的假实现>`（本来那写法）：
/// 那要 import `permission_handler_platform_interface`，而它只是**传递依赖**，
/// 直接 import 会触发 `depend_on_referenced_packages`（实测），
/// 要消掉就得动 `pubspec.yaml` —— 不值得。这条同样能拿到真 `Error`。
void _installPermChannelWithMalformedReply() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kPermChannel, (call) async => '不是个 int');
}

/// 让**权限通道**每次都抛 [error]。
void _installPermChannelThrowing(Object error) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kPermChannel, (call) async => throw error);
}

PlatformException _boom(String method) =>
    PlatformException(code: 'BOOM', message: '打桩：$method 通道挂了');

void _clearPermChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kPermChannel, null);
}

/// 在**独立 zone** 里跑 [body]，返回「漏出来的未捕获异步异常」列表。
///
/// 这是纯 Dart 侧唯一能看见「未捕获异步异常」的窗口：`runZonedGuarded` 的
/// `onError` 收的正是没人 catch 的那些（已 await 且被 catch 的不会进来）。
/// 末尾多等 200ms 是给 fire-and-forget 的那次调用留出发射时间。
///
/// ⚠️ **不许拿它套 `tester.pumpWidget`**（会挂死，见文件头坑 1）。
Future<List<Object>> leakUncaught(Future<void> Function() body) async {
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

/// 装一个**真** widget 树时，量「有没有异常从异步里漏出来」。
///
/// 走 `FlutterError.onError` 而不是 zone：这是 `WidgetsFlutterBinding` 暴露的
/// **真通道** —— 框架接住的异步异常最终都经 `FlutterError.reportError`。
/// （凡是被 `try/catch` 兜住的、或根本没抛的，这里**一条都收不到**。）
///
/// ⚠️ 别改成 zone 套 `pumpWidget`：会挂死（见文件头坑 1）。
Future<List<Object>> leaksDuring(
  WidgetTester tester,
  Future<void> Function() body,
) async {
  final errs = <Object>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    errs.add(details.exception);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prev;
  }
  return errs;
}

/// ★ **故意照修前的 `catch (e)`（catch-all）写** —— 第 6 条的负向对照。
/// 它 != 生产代码，是「把范围放宽会怎样」的对照物。
Future<void> broadCatch(Future<void> Function() body) async {
  try {
    await body();
  } catch (e) {
    debugPrint('MuBox 判据·宽兜底吞掉了 ${e.runtimeType}');
  }
}

/// ★ **照生产代码 `_checkBattery()` 的兜底结构写**，只把被测的那一句换成回调。
///
/// 为什么要这个夹具（而不是第 5 条也去 `pumpWidget` 真页面）：见文件头坑 5 ——
/// 让真页面在「平台实现抛 `Error`」的状态下 build，那个 `Error` 会**走进
/// flutter_test 自己的错误处理闭包**，触发
/// `_pendingExceptionDetails != null` 断言（实测踩过两次），
/// 于是「它到底有没有被吞」就量不准了。
///
/// ⚠️ 夹具必须与生产代码**逐条对齐**：两个 `on … catch` 的**种类和顺序**
/// 都要一样（`PlatformException` 在前、`MissingPluginException` 在后）。
/// 生产代码那边由第 7 条从源码上钉住，防止夹具与实际写法漂移。
Future<void> guardedAsProduction(Future<void> Function() call) async {
  try {
    await call();
  } on PlatformException catch (e) {
    debugPrint('夹具：吞掉平台异常 $e');
  } on MissingPluginException catch (e) {
    debugPrint('夹具：吞掉插件未就绪 $e');
  }
}

/// 从 [src] 里挑出**权限通道**的调用点：`Permission.ignoreBatteryOptimizations`
/// 后面接 `.status` 或 `.request(…)`。
final RegExp _kPermCall = RegExp(
  r'Permission\s*\.\s*ignoreBatteryOptimizations\s*(?:\.\s*status|\.\s*request\s*\()',
  multiLine: true,
);

/// 某个权限调用点的**兜底块**：从最近的 `try` 起，到调用点**之后第 2 个**
/// `catch (` 的参数表结尾止。
///
/// 为什么是「第 2 个」：生产代码的兜底是**两副** `on … catch`，要判「收紧」
/// 就必须把**两副都包进块里**。而块尾又只能取到**参数表结尾** —— 再往后就会
/// 把兜底子句体（`catch (e) { … }`）连同它体内别的 `catch (` 一起吸进来。
///
/// ⚠️ ★ 三个已经踩过的界，别改回去（每个都实打实红过一轮）：
///   - **往前找** `catch`：`try/catch` 里 `catch` 在 `try` 之后，往前找只会拿到
///     **上一个** `try` 的兜底 ⇒ 块整个是错的（实测 `[false, false]` 假红）；
///   - 只截到**第 1 个** `catch (`：`on MissingPluginException` 落在块外
///     （实测 `platform=true / missing=false`）；
///   - 拿「后面最后一个 `catch`」或「下一个 `on `」推进：前者吃到几万字符外
///     别的函数（实测 `guardLen=39128`），后者因为兜底子句体夹在两个 `on `
///     之间而**根本不推进**。
///
/// 找不到兜底返回 `null`。
String? _guardBlock(String src, int callIndex) {
  final after = src.substring(callIndex);
  final catchAt = after.indexOf('catch');
  if (catchAt < 0) return null;
  final absCatch = callIndex + catchAt;
  final tryAt = src.substring(0, absCatch).lastIndexOf('try');
  if (tryAt < 0) return null;

  // 第 2 个 catch ( 的参数表结尾。
  final second = src.indexOf('catch', absCatch + 1);
  if (second < 0) return src.substring(tryAt, absCatch);
  final open = src.indexOf('(', second);
  if (open < 0) return src.substring(tryAt, second);
  final close = src.indexOf(')', open);
  return src.substring(tryAt, close < 0 ? second : close);
}

/// 每个权限调用点**各自是否真有兜底块**。
List<bool> guardedCallSites(String src) => <bool>[
      for (final m in _kPermCall.allMatches(src)) _guardBlock(src, m.start) != null,
    ];

/// 某个权限调用点的兜底块里有没有**裸 `catch`**（= 没有 `on <类型>` 的宽兜底）。
///
/// ⚠️ ★ 不能直接拿 `catch\s*\(` 去搜：`on PlatformException catch (e)` 里的
/// `catch (` **也**会被搜到 —— 那会把收紧后的**正确**写法判成「有裸 catch」，
/// 于是第 7 条**永远是红的**（实测 `bare=true`）。
/// 这条断言读的是「`catch` 前面那截（去掉尾部空白）是不是 `on <类型>`」。
bool _hasBareCatch(String guard) {
  for (final m in RegExp(r'catch\s*\(').allMatches(guard)) {
    final head = guard.substring(0, m.start).trimRight();
    if (!RegExp(r'\bon\s+[A-Za-z_][A-Za-z0-9_]*$').hasMatch(head)) {
      return true;
    }
  }
  return false;
}

/// 每个权限调用点的兜底块是不是**只吞平台异常**。
///
/// 「收紧」的断言口径：兜底块里**必须同时出现** `on PlatformException` 与
/// `on MissingPluginException`；并且**不许**出现裸的 `catch`（`catch (e)` /
/// `catch (_)`）—— 那种会把 `Error` 一起吞掉（见第 5~7 条）。
List<bool> platformOnlyCallSites(String src) => <bool>[
      for (final m in _kPermCall.allMatches(src))
        () {
          final g = _guardBlock(src, m.start);
          if (g == null) return false;
          return g.contains('on PlatformException') &&
              g.contains('on MissingPluginException') &&
              !_hasBareCatch(g);
        }(),
    ];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // 这一页读**全局** `playerService`；App 里它在 `main()` 一定存在，
    // `flutter test` 里没人建 ⇒ 先放一副哑牌。**不调 `init()`** ⇒ 不碰插件、不落盘。
    playerService = PlayerService(player: _StubPlayer());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSaveChannel, (call) async => null);
  });

  tearDown(() {
    _clearPermChannel();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSaveChannel, null);
    playerService = null;
  });

  // ───────────────────────── 1. 负向：先证明「牙」 ─────────────────────────

  test('★1 负向（判据有牙）：不包 try/catch 直接查状态 ⇒ 独立 zone 必收到 1 个漏出的异常',
      () async {
    _installPermChannelThrowing(_boom('checkPermissionStatus'));

    // 这就是**修前** `_checkBattery()` 的第一行：fire-and-forget 的 `status`。
    final leaked = await leakUncaught(() async {
      unawaited(Permission.ignoreBatteryOptimizations.status);
    });

    expect(
      leaked,
      hasLength(1),
      reason: '这个打桩场景必须真的抛，否则本文其余几条测的是空气。'
          '实测漏出来的是：${leaked.isEmpty ? '（什么都没漏）' : leaked.first}',
    );
    expect(leaked.first, isA<PlatformException>(),
        reason: '漏出来的应该是权限通道抛的 PlatformException');
    // ignore: avoid_print
    print('MuBox 判据·1负向：漏出 ${leaked.length} 个 —— ${leaked.first}');
  });

  // ───────────────────────── 2. 正向：status 那半 ─────────────────────────

  testWidgets('★2 正向：装出真页面（initState→_checkBattery→status）一个异常都不漏',
      (tester) async {
    _installPermChannelThrowing(_boom('checkPermissionStatus'));

    // 真页面走一遍：`initState` 里那次 fire-and-forget 的 `_checkBattery()`
    // 就在这一拍发生。兜住了 ⇒ 一条都收不到。
    final leaked = await leaksDuring(tester, () async {
      // ⚠️ 必须套 `Scaffold`：这一页里有 `InkWell`，没有 `Material` 祖先会抛
      // 「No Material widget found」—— 那是**壳的问题**，会把真断言淹掉。
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: SettingsPage()),
      ));
      await tester.pump();
    });

    expect(
      leaked,
      isEmpty,
      reason: '兜住了就一个都不许漏；漏了说明兜底没生效。'
          '漏出来的是：${leaked.isEmpty ? '' : leaked.first}',
    );
    // ignore: avoid_print
    print('MuBox 判据·2正向：装真页面漏出 ${leaked.length} 个');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // ──────────────────── 3. 正向：request 那半的兜底形状 ────────────────────

  test('★3 正向：两副平台异常包进 on…catch ⇒ zone 收到 0 个（按钮那半的形状）',
      () async {
    // ① 插件的 PlatformException
    _installPermChannelThrowing(_boom('requestPermissions'));
    var leaked = await leakUncaught(() async {
      try {
        await Permission.ignoreBatteryOptimizations.request();
      } on PlatformException {
        // 生产代码里这里是一行 debugPrint，静默
      } on MissingPluginException {
        //
      }
    });
    expect(leaked, isEmpty, reason: 'PlatformException 那半不许漏');
    // ignore: avoid_print
    print('MuBox 判据·3正向：PlatformException 兜底后漏出 ${leaked.length} 个');

    // ② 通道根本没实现（不打桩）⇒ MissingPluginException，同样不许漏
    _clearPermChannel();
    leaked = await leakUncaught(() async {
      try {
        await Permission.ignoreBatteryOptimizations.request();
      } on PlatformException {
        //
      } on MissingPluginException {
        //
      }
    });
    expect(leaked, isEmpty, reason: 'MissingPluginException 那半不许漏');
    // ignore: avoid_print
    print('MuBox 判据·3正向：MissingPluginException 兜底后漏出 ${leaked.length} 个');
  });

  // ───────────────────────── 4. 接线：生产代码真有兜底 ─────────────────────────

  test('★4 接线：settings_page.dart 里两处权限调用各自都有兜底块', () {
    // ⚠️ `flutter test` 的 cwd = 包根，所以这个相对路径是稳的。
    final src = File('lib/pages/settings_page.dart').readAsStringSync();
    final flags = guardedCallSites(src);

    expect(
      flags,
      hasLength(2),
      reason: '这一页应该有 2 处权限通道调用（_checkBattery 的 status + '
          '按钮的 request）；数量变了说明有人加了/删了调用点，回来核一遍',
    );
    expect(
      flags,
      everyElement(isTrue),
      reason: '每一处**各自**都必须有兜底块（不是"文件里有个 catch 就算"）：$flags',
    );
    // ignore: avoid_print
    print('MuBox 判据·4接线：权限调用点 $flags（每处都有兜底块）');
  });

  // ─────────────── 5. ★★ 收紧不变量：Error 不许被吞 ───────────────

  test('★5 收紧：插件解码抛 TypeError（是 Error）⇒ on PlatformException 不吞，必须漏出去',
      () async {
    // ★ 这个 TypeError 出在 **Dart 侧**（插件解码层），不是通道那头包过来的。
    _installPermChannelWithMalformedReply();

    final leaked = await leakUncaught(() async {
      await guardedAsProduction(
          () => Permission.ignoreBatteryOptimizations.status);
    });

    expect(
      leaked,
      isNotEmpty,
      reason: '★ 收紧的证明：TypeError 是 `Error`（不是 `Exception`），必须**不被吞**、'
          '能到达 zone 的 onError。若这里是空的 ⇒ 兜底退回了 `catch (e)`，'
          '编程错误又被藏起来了。',
    );
    expect(leaked.first, isA<TypeError>(),
        reason: '漏出来的应该是插件解码层那个 TypeError；'
            '实际是 ${leaked.first.runtimeType}：${leaked.first}');
    expect(leaked.first is Exception, isFalse,
        reason: '★ 关键：它必须是 `Error` 而**不是** `Exception` —— '
            '否则「只吞平台异常」这条根本测不出来');
    // ignore: avoid_print
    print('MuBox 判据·5收紧：${leaked.first.runtimeType} 漏出 ${leaked.length} 个 —— ${leaked.first}');
  });

  // ─────────────── 6. ★★ 有牙：换成 catch-all 就吞了 ───────────────

  test('★6 有牙（负向对照）：同一个 Error 换成 catch (e) ⇒ 必被吞掉', () async {
    // 与第 5 条**同一个 Error 来源**，只把兜底的宽窄换掉。
    _installPermChannelWithMalformedReply();

    // ★ 这里**故意用宽兜底**（= 修前的写法），而不是 [guardedAsProduction]。
    final leaked = await leakUncaught(() async {
      await broadCatch(() => Permission.ignoreBatteryOptimizations.status);
    });

    expect(
      leaked,
      isEmpty,
      reason: '宽兜底必须把这个 Error 吞干净 —— 这就是第 5 条为什么必须有：'
          '换了宽兜底，编程错误就再也冒不出来（本项目的假绿形状）。',
    );
    // ignore: avoid_print
    print('MuBox 判据·6有牙：宽兜底把 Error 吞了，漏出 ${leaked.length} 个（0 = 吞掉）');
  });

  // ─────────────── 7. 接线：生产代码确实收紧了 ───────────────

  test('★7 接线：两处兜底都是 platform-only（两个 on…catch，且无裸 catch）', () {
    expect(Platform.isWindows || Platform.isLinux || Platform.isMacOS, isTrue,
        reason: '这条判据读源码，只能在桌面测试机上跑');
    final src = File('lib/pages/settings_page.dart').readAsStringSync();
    final flags = platformOnlyCallSites(src);

    expect(flags, hasLength(2), reason: '调用点数应该还是 2 处：$flags');
    expect(
      flags,
      everyElement(isTrue),
      reason: '每处都必须同时有 `on PlatformException` + `on MissingPluginException`，'
          '且没有裸 `catch (`：$flags',
    );
    // ignore: avoid_print
    print('MuBox 判据·7接线：platform-only $flags');
  });
}
