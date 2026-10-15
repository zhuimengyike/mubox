/// 自定义特效页「麦克风权限查询」为什么**故意保留宽兜底**的断言。
///
/// 背景：设置页那两处权限调用刚被**收紧**（`on PlatformException` +
/// `on MissingPluginException`，见 `test/settings_page_battery_test.dart`）。
/// `custom_page.dart` 的 `_checkMic` / `_askMic` 是同一族的**另外两处**，
/// 但它们**刻意不收**，理由写在 `custom_page.dart` 那两处的文档注释里。
///
/// 本文件把那套理由变成可执行的东西，四条：
/// 1. ★ **宽窄只在一个地方有区别**：平台异常（`PlatformException` /
///    `MissingPluginException`）下，**宽兜底**与**窄兜底**结果**完全一样** ——
///    两条路都不会让异常漏出去；
/// 2. ★ **唯一的区别在 `Error`**：插件解码层抛 `TypeError` 时，
///    宽兜底吞掉（漏出 0 个），窄兜底让它漏出去（漏出 1 个）；
/// 3. ★ **`_micOk` 是这一页唯一的观感开关**：`custom_page.dart:78` 的
///    `if (g.id == 'r' && !_micOk) _micHint()` —— 三种通道结果下，
///    取到的 `CustomPage` widget **逐字段相等** ⇒ 渲染路径没变；
/// 4. ★ **防回退**：钉住生产代码这两处**仍然是宽兜底**，
///    免得以后有人「顺手修好」，把一条提示的显示问题换成用户可见的崩溃。
///
/// ⚠️ 第 4 条**不是**同义反复：它必须与第 2 条**一起**才成立 ——
/// 单看第 4 条只是「源码里写着 catch (_)」；配上第 2 条（宽兜底吞 `Error`、
/// 窄兜底不吞）才证明「这个 `catch (_)` 确实是那个决定了行为的 `catch (_)`」。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/pages/custom_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// `permission_handler` 的原生通道名。
const MethodChannel _kPermChannel =
    MethodChannel('flutter.baseflow.com/permissions/methods');

/// 哑播放器：自定义特效页不直接用氛围层，但这一族的页面会读全局
/// `playerService`，先放一副哑牌免得 `Null check operator` 把用例淹掉。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void _setPermHandler(Future<Object?> Function(MethodCall call) handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kPermChannel, handler);
}

void _clearPermChannel() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_kPermChannel, null);
}

/// 在**独立 zone** 里跑 [body]，返回「漏出来的未捕获异步异常」列表。
///
/// ⚠️ **不许拿它套 `tester.pumpWidget`**：`runZonedGuarded` 会把
/// `TestAsyncUtils` 的 guard 拧住，`pumpWidget` 直接不进、**实测挂死**。
/// 所以这里只用它量**纯平台调用**（第 1、2 条），不量渲染。
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

/// ★ **照 `custom_page.dart` `_checkMic` 的兜底结构写**（宽），原因见本文件头。
Future<void> broadAsProduction(Future<void> Function() call) async {
  try {
    await call();
  } catch (_) {
    // 生产代码就是这个
  }
}

/// ★ **假想的收紧版**（对照物，**不是**生产代码）：只吞两副平台异常。
Future<void> narrowHypothetical(Future<void> Function() call) async {
  try {
    await call();
  } on PlatformException {
    //
  } on MissingPluginException {
    //
  }
}

/// 让插件**解码层**抛一个真 `Error`（`TypeError`）。
///
/// `checkPermissionStatus` 回一个形状不对的值（`String` 而不是 `int`），
/// 插件自己的 `decodePermissionStatus(int value)` 就抛 `TypeError`。
///
/// ⚠️ 为什么不用「往 channel 里抛 `Error`」：channel 边界会把**任何**对象包成
/// `PlatformException`，于是「`Error` 会不会被吞」在那条路上根本问不出来。
void _malformedReply() => _setPermHandler((call) async => '不是个 int');

/// 捕获 `debugDumpApp()` 的文本 —— 整棵 widget 树的**确定性**序列化。
///
/// ⚠️ **目前没有用例在用它**，但留着有一条明确理由：它是「观感零变化」在
/// 无法出图（本仓**没有 `tool_shot.py`**，那是桌面 PyQt 仓的工具）时的
/// 下一手证据。第 3 条现在量的是「提示可见性」这个更精确的可观测量
/// （`_micOk` 是这一页唯一的观感开关）；要更严就把这里的 dump 接回第 3 条。
///
/// ⚠️ 但**别直接用 `debugDumpApp()` 做断言**：实测它的输出**会被测试 reporter
/// 截断**（只看到头一行 + 一堆 `│` 缩进行），`equals` 失败时**看不出差在哪**。
/// 真要接回去，得自己 `debugPrint` 覆盖 + 落文件再 diff。
// ignore: unused_element
Future<String> dumpTree(WidgetTester tester) async {
  final buf = StringBuffer();
  final prev = debugPrint;
  debugPrint = (String? message, {int? wrapWidth}) {
    if (message != null) buf.writeln(message);
  };
  try {
    debugDumpApp();
    // debugDumpApp 是同步的，但让它先把已入队的输出吐完
    await tester.pump();
  } finally {
    debugPrint = prev;
  }
  return buf.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    playerService = PlayerService(player: _StubPlayer());
    // 律动区那个二级页自带 `AmbientLayer` 预览 ⇒ 它会去 listen 省电模式的
    // EventChannel（测试里没有原生实现）。给个哑 handler，否则 MissingPluginException
    // 会把这条**原本与渲染无关**的用例判红。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.mubox.mu_box_phone/power_save'),
      (call) async => null,
    );
  });

  tearDown(() {
    _clearPermChannel();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.mubox.mu_box_phone/power_save'), null);
    playerService = null;
  });

  // ─────────── 1. 宽窄在平台异常下**没有区别** ───────────

  test('★1 平台异常下宽窄等价：PlatformException 两副兜底都吞得住', () async {
    _setPermHandler((call) async {
      throw PlatformException(code: 'BOOM', message: '打桩：${call.method} 挂了');
    });

    final broad = await leakUncaught(() async {
      await broadAsProduction(() => Permission.microphone.status);
    });
    final narrow = await leakUncaught(() async {
      await narrowHypothetical(() => Permission.microphone.status);
    });

    expect(broad, isEmpty, reason: '宽兜底必须吞住平台异常');
    expect(narrow, isEmpty, reason: '窄兜底也必须吞住平台异常');
    // ignore: avoid_print
    print('MuBox 判据·麦克风1：PlatformException 下 宽=${broad.length} 窄=${narrow.length}');
  });

  test('★1b 平台异常下宽窄等价：MissingPluginException 两副都吞得住', () async {
    _clearPermChannel(); // 不打桩 ⇒ MissingPluginException

    final broad = await leakUncaught(() async {
      await broadAsProduction(() => Permission.microphone.status);
    });
    final narrow = await leakUncaught(() async {
      await narrowHypothetical(() => Permission.microphone.status);
    });

    expect(broad, isEmpty);
    expect(narrow, isEmpty);
    // ignore: avoid_print
    print('MuBox 判据·麦克风1b：MissingPluginException 下 宽=${broad.length} 窄=${narrow.length}');
  });

  // ─────────── 2. ★ 唯一的区别：Error ───────────

  test('★2 宽窄唯一的区别：插件解码抛 TypeError ⇒ 宽吞掉、窄漏出', () async {
    _malformedReply();

    final broad = await leakUncaught(() async {
      await broadAsProduction(() => Permission.microphone.status);
    });
    final narrow = await leakUncaught(() async {
      await narrowHypothetical(() => Permission.microphone.status);
    });

    expect(broad, isEmpty,
        reason: '★ 宽兜底把 `Error` 也吞了 —— 这就是"代价"，本页**接受**它');
    expect(narrow, isNotEmpty,
        reason: '★ 窄兜底不吞 `Error`。这两条一起才证明「宽窄确实有区别、'
            '而且区别只落在 Error 上」—— 第 4 条据此才不是同义反复');
    expect(narrow.first is Error, isTrue,
        reason: '漏出来的必须是 `Error`（不是 `Exception`）：'
            '实际 ${narrow.first.runtimeType}');
    // ignore: avoid_print
    print('MuBox 判据·麦克风2：TypeError 下 宽=${broad.length}（吞） 窄=${narrow.length}（漏）'
        ' —— ${narrow.first.runtimeType}');
  });

  // ─────────── 3. ★ _micOk 是唯一的观感开关 ───────────

  testWidgets('★3 三种通道结果下提示的可见性一致（观感零变化）', (tester) async {
    // 平台异常被吞掉之后仍会经由 FlutterError.reportError 走一遭 ——
    // 挂个哑 handler，免得框架把它算成用例失败（也顺便量一下它到底有没有被吞）。
    final reports = <Object>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (details) => reports.add(details.exception);

    /// 这一页的提示（`_micHint()`）—— 文字是 `custom_page.dart` 里的原文。
    Finder hint() => find.textContaining('律动需要');

    Future<bool> hintVisibleWith(
        Future<Object?> Function(MethodCall call) handler) async {
      reports.clear();
      _setPermHandler(handler);
      // ⚠️ 从「四个区折叠」起：目录页（`CustomPage()`）只剩四张区入口卡，
      // 律动那条提示搬进了**律动区的专属页** ⇒ 这里必须点名 `group: 'r'`。
      // 项数与判的东西一个字没减，只换了被测的那个页面。
      await tester.pumpWidget(const MaterialApp(
        home: CustomPage(group: 'r'),
      ));
      // ★ 必须等 `initState` 里那次 fire-and-forget 的 `_checkMic()` 跑完
      // （它 await 了权限通道，要过 microtask 链才 setState）。
      await tester.pump(const Duration(milliseconds: 100));
      // ★ 再滚到"律动"区：这一页是 `ListView`，**屏幕外的条目根本不会被构建**
      // ——不滚过去的话，提示即使该显示也不在树里，量出来永远是 `false`
      // （实测：600 高的测试视口里只有"视觉"区）。
      //
      // ⚠️ 别用 `tester.scrollUntilVisible`：目标**压根不存在**时它会抛
      // `Bad state: No element`，而"不存在"恰恰是这里要量的结果之一
      // （实测踩过）。用不会抛的拖拽，滚到底再看。
      for (var i = 0; i < 30 && hint().evaluate().isEmpty; i++) {
        await tester.drag(find.byType(Scrollable).first,
            const Offset(0, -400), warnIfMissed: false);
        await tester.pump();
      }
      final visible = hint().evaluate().isNotEmpty;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      return visible;
    }

    try {
      // ① 授权成功 ⇒ `_micOk = true` ⇒ **不显示**提示（这是既有观感）
      final granted = await hintVisibleWith((call) async => 1);
      // ② **被拒绝**（`PermissionStatus.denied` = 0）⇒ `_micOk = false`
      //    ⇒ 提示**必须出现**。这一条是"Finder 真的测得出来"的证明：
      //    少了它，上面三条全是 `false` 也能绿（假绿）。
      final denied = await hintVisibleWith((call) async => 0);
      // ③ 平台异常 ⇒ 宽兜底吞掉（`_micOk` 停缺省 true）⇒ 同样不显示
      final platformErr = await hintVisibleWith((call) async {
        throw PlatformException(code: 'BOOM', message: '挂了');
      });
      // ④ 通道没实现 ⇒ 同上
      final missingPlugin = await hintVisibleWith((call) async {
        throw MissingPluginException('没有实现');
      });

      expect(denied, isTrue,
          reason: '★ 被拒绝时提示**必须**显示 —— 先证明这个 Finder 真能测到东西。'
              '若这里是 false，说明 Finder 是坏的，下面几条相等全是假绿。');
      expect(granted, isFalse, reason: '授权成功时不该显示「未授权」提示');
      expect(platformErr, isFalse,
          reason: '平台异常下：兜底吞掉 ⇒ `_micOk` 停缺省 true ⇒ 与"授权成功"同观感');
      expect(missingPlugin, isFalse, reason: '通道缺失下同上');
      expect(platformErr, equals(granted),
          reason: '平台异常与授权成功的提示可见性必须**一致** —— '
              '`_micOk` 是这一页唯一的观感开关（`custom_page.dart:78`）'
              '⇒ 渲染路径没变 ⇒ 像素不变');
      expect(missingPlugin, equals(granted), reason: '通道缺失与授权成功必须一致');
      expect(reports, isEmpty,
          reason: '平台异常必须被兜底吞干净，不许冒到 FlutterError（这是"吞住了"的证明）');
      // ignore: avoid_print
      print('MuBox 判据·麦克风3：提示可见性 授权=$granted 拒绝=$denied '
          '平台异常=$platformErr 通道缺失=$missingPlugin，冒到 FlutterError=${reports.length} 个 ✅');
    } finally {
      FlutterError.onError = prevOnError;
    }
  });

  // ─────────── 4. ★ 防回退：这两处**故意**是宽兜底 ───────────

  test('★4 防回退：custom_page.dart 的 _checkMic / _askMic 仍是宽兜底', () {
    final src = File('lib/pages/custom_page.dart').readAsStringSync();

    // 两处权限调用各自的兜底块，按调用点往后取到最近的 catch 参数表结尾。
    final perm = RegExp(
      r'Permission\s*\.\s*microphone\s*(?:\.\s*status|\.\s*request\s*\()',
      multiLine: true,
    );
    final guards = <String>[];
    for (final m in perm.allMatches(src)) {
      final after = src.substring(m.start);
      final catchAt = after.indexOf('catch');
      expect(catchAt, greaterThanOrEqualTo(0),
          reason: '这两处都必须有兜底块（裸奔才是真 bug）');
      final absCatch = m.start + catchAt;
      final close = src.indexOf(')', src.indexOf('(', absCatch));
      // ⚠️ ★ 块要**从本行开头**取，不能从 `catch` 取：收紧版写的是
      // `} on PlatformException catch (_) {`，从 `catch` 起取只会拿到
      // `catch (_` —— 那里面永远不含 `on PlatformException`，
      // 于是「防收紧」那条断言**恒真**（假绿）。实测这个坑踩过。
      final lineStart = src.lastIndexOf('\n', absCatch) + 1;
      guards.add(src.substring(
          lineStart, close < 0 ? absCatch : close).trim());
    }

    expect(guards, hasLength(2),
        reason: '这一页应该有 2 处麦克风权限调用（_checkMic 的 status + '
            '_askMic 的 request），实际取到 ${guards.length} 处');
    for (final g in guards) {
      expect(g.contains('catch ('), isTrue,
          reason: '★ 必须是**裸 catch**（宽兜底）—— 这一页刻意不收，'
              '理由见 custom_page.dart 的文档注释与本文第 2 条。实际：$g');
      expect(g.contains('on PlatformException'), isFalse,
          reason: '★ 不许被"顺手收紧"成 on PlatformException：'
              '这一页是「观感别改」那条线，收紧会把提示的显示问题'
              '换成用户可见的崩溃。实际：$g');
    }
    // ignore: avoid_print
    print('MuBox 判据·麦克风4：两处兜底仍是裸 catch ✅ $guards');
  });
}
