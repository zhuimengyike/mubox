/// 视觉区「多层」—— **图层槽位参数键** 的像素级断言。
///
/// ## 这一层守的是什么（真 bug）
///
/// 病灶在 `ambient_painter.dart` 的 `_vPrefix`：它拼的是**键前缀**（`v2`），
/// 却拿 `fxInstanceKey`（入参是**带点的完整基键** `v2.x`）去加工 ——
/// 那位的实现是 `base.replaceFirst('.', '#槽位.')`，**找不到点就原样返回**
/// ⇒ 槽位上标被**静默吃掉** ⇒ 绘制端永远只读裸键 `v<特效>.<参数>`。
///
/// 后果（症状：滑杆都在，但滑动了没反应 —— 所有特效都一样）：
/// * **槽位 0** 的图层写的就是裸键 ⇒ 那一层**是好的**（所以「预设能实打实地改变位置」）；
/// * **槽位 > 0** 的图层，设置页写的是 `v2#1.x`，**没有任何人读** ⇒ 怎么拖都不动；
///   ★ 而且它会**跟着第 1 层一起动**（因为读的是同一个裸键）——「改到了别层」。
///
/// ## 断言的分工
/// 1. **纯函数**：`fxInstancePrefix` / `fxInstanceKey` 的槽位语义，含**不带点**的入参；
/// 2. **像素**：槽位 1 的图层改 `x` ⇒ 绘制中心必须跟着动；改**裸键** ⇒ 一个像素都不许动；
/// 3. **像素 · 两层各改各的**：改第 1 层 ⇒ 第 2 层那半屏逐像素不变，反之亦然；
/// 4. **像素 · 绘制轮**：`wiggle` 这种**只在绘制轮读**的参数也必须逐层生效
///    —— `paint()` 的两轮循环都要设 `_vIndex/_vSlot`，只设一轮的话绘制轮会读到
///    上一层的参数前缀，于是这一层的参数静默失效；
/// 5. **接线**：真设置页拖滑杆写进去的键 == 画家拼的键。
/// 6. ★★ **端到端**：两个**不同**的视觉特效各一层 ⇒
///    进 A 的真设置页拖「水平位置」⇒ **只写 A 那层的键、B 那层逐字节不变**；
///    再用同一份层表出图 ⇒ **A 的墨迹质心跟着动、B 所在条带逐像素不变**。
///    （症状：开启了第二个特效之后，就无法再调整第一个了）
///
/// ## 量具纪律（这套东西踩过的四个坑，别再踩）
/// * ⛔ **不许 `pumpAndSettle`**：这一页挂着 `AmbientLayer` 的常驻 `repeat()` 动画，
///   settle 不了（实测把用例挂死到超时）。一律用 `pump()` / `pump(Duration)`。
/// * ⛔ **不许 override `FlutterError.onError`**：框架会报
///   `_pendingExceptionDetails != null`。要吞已知噪音用 `tester.takeException()`。
/// * ⛔ **`toImage()` 必须包 `tester.runAsync`**：它在引擎光栅线程上完成，
///   在 fake-async 里第二次调用**永远不返回**。
/// * ⛔ **收尾要把 `AppConfig` 那个 400ms 去抖计时器跑掉**，否则框架判
///   「A Timer is still pending even after the widget tree was disposed」。
/// * ⚠️ 参数一律走 `AppConfig.setFx`（会 `notifyListeners()` ⇒ 重画）。
///   直接往 `fxParams` 的 map 里塞**不会**触发重画（画家读到的是旧快照，实测）。
library;

import 'dart:ui' as ui;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/effect_catalog.dart';
import 'package:mu_box_phone/pages/effect_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:mu_box_phone/widgets/ambient_layer.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 量具画布尺寸：测试视口 = 400×800 逻辑像素，`toImage()` 按 dpr 1 出图。
const int _w = 400;
const int _h = 800;
final GlobalKey _shotKey = GlobalKey();

/// 墨迹阈值：**必须高于「旋律辉光层」的峰值**（α = 0.05 ⇒ 单通道 ≤ 13，
/// 而阈值 40）⇒ 辉光一个像素都不算墨 —— 于是「第 1 层动没动」这个数
/// 只由第 1 层自己的墨决定，不会被跟着中心跑的辉光污染。
const int _kInk = 40;

Future<Uint8List> _grab(WidgetTester tester) async {
  final out = await tester.runAsync(() async {
    final boundary =
        _shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final ui.Image img = await boundary.toImage();
    final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    final px = bd!.buffer.asUint8List();
    img.dispose();
    return px;
  });
  return out!;
}

bool _isInk(Uint8List px, int i) =>
    px[i] >= _kInk || px[i + 1] >= _kInk || px[i + 2] >= _kInk;

({int count, double cx}) _inkBand(Uint8List px, int x0, int x1) {
  var n = 0;
  var sx = 0.0;
  for (var y = 0; y < _h; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * _w + x) * 4;
      if (_isInk(px, i)) {
        n++;
        sx += x;
      }
    }
  }
  return (count: n, cx: n == 0 ? double.nan : sx / n);
}

/// 两张图在某个条带里**真有差别**的像素数：任一通道差 > [tol] 才算。
///
/// ⚠️ **为什么不用「墨迹掩码不同」**：`paint()` 最底下那层**旋律辉光**是围着
/// `insts.first`（= **第 1 层**）画的 —— 第 1 层一动它就跟着动。它的峰值只有
/// α = 0.05（单通道 ≤ 13）。而「墨迹」是硬阈值（≥40）：平滑渐变上恰好跨过 40
/// 的那一圈像素会因为这几点的亮度变化而**翻面**，实测 37~44 个 ——
/// 那是**阈值假象**，不是「第 2 层动了」。tol = 20 高于辉光峰值，
/// 而任何真的位移都会让边缘像素差 100+ ⇒ 这条断言的灵敏度一点没掉。
({int count, int minX, int maxX, int minY, int maxY}) _pixelDiffBox(
    Uint8List a, Uint8List b, int x0, int x1, {int tol = 20}) {
  var n = 0;
  var minX = _w, maxX = -1, minY = _h, maxY = -1;
  for (var y = 0; y < _h; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * _w + x) * 4;
      var d = (a[i] - b[i]).abs();
      final dg = (a[i + 1] - b[i + 1]).abs();
      final db = (a[i + 2] - b[i + 2]).abs();
      if (dg > d) d = dg;
      if (db > d) d = db;
      if (d > tol) {
        n++;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  return (count: n, minX: minX, maxX: maxX, minY: minY, maxY: maxY);
}

/// 同上，按**墨迹掩码**（阈值 40）算：同一条带里墨迹有无翻面的像素数。
int _inkMaskDiff(Uint8List a, Uint8List b, int x0, int x1) {
  var n = 0;
  for (var y = 0; y < _h; y++) {
    for (var x = x0; x < x1; x++) {
      final i = (y * _w + x) * 4;
      if (_isInk(a, i) != _isInk(b, i)) n++;
    }
  }
  return n;
}

int _inkCount(Uint8List px) {
  var n = 0;
  for (var y = 0; y < _h; y++) {
    for (var x = 0; x < _w; x++) {
      if (_isInk(px, (y * _w + x) * 4)) n++;
    }
  }
  return n;
}

/// `base` 里从 [from] 往右**第一列有墨**的 x。
///
/// 用途：把「B 所在的条带」**精确框到 B 自己的墨迹**上（端到端那条，见文件头 6）。
/// ⚠️ 不能拿「分带线右边的整个半平面」当 B 的条带：那条带里有一大段是**空的**，
/// A 往右挪一点就会**合法地**蹭进那段空白，于是「B 逐像素不变」会被这堆
/// 与 B 无关的像素打红（实测：`x[204..240]` 560 个像素，全是 A 自己的墨）。
/// 框到 B 的墨迹起点之后，断言反而更硬：A 真蹭进 B 的墨里照样红。
int _firstInkCol(Uint8List px, int from, int to) {
  for (var x = from; x < to; x++) {
    for (var y = 0; y < _h; y++) {
      if (_isInk(px, (y * _w + x) * 4)) return x;
    }
  }
  return to;
}

double _inkCx(Uint8List px) {
  var n = 0;
  var sx = 0.0;
  for (var y = 0; y < _h; y++) {
    for (var x = 0; x < _w; x++) {
      final i = (y * _w + x) * 4;
      if (_isInk(px, i)) {
        n++;
        sx += x;
      }
    }
  }
  return n == 0 ? double.nan : sx / n;
}

/// ★ **量具自证**：从基准图里找**最宽的一条空白竖缝**，返回它的中点作为分带线。
///
/// 两层墨迹必须被一条真实的空白缝分开，否则「改第 1 层 ⇒ 第 2 层一个像素都不许变」
/// 这条断言根本量不出东西（带线切在某层墨迹里，怎么量都会红）。缝不够宽就直接红，
/// 并且说明是**量具**的问题、不是被测对象。
int _splitOf(Uint8List base, {int minGap = 40}) {
  var bestStart = 0, bestLen = 0;
  var curStart = 0, curLen = 0;
  final gaps = <String>[];
  for (var x = 0; x < _w; x++) {
    var ink = false;
    for (var y = 0; y < _h; y++) {
      if (_isInk(base, (y * _w + x) * 4)) {
        ink = true;
        break;
      }
    }
    if (!ink) {
      if (curLen == 0) curStart = x;
      curLen++;
      if (curLen > bestLen) {
        bestLen = curLen;
        bestStart = curStart;
      }
    } else {
      if (curLen > 0) gaps.add('[$curStart..${curStart + curLen - 1}]');
      curLen = 0;
    }
  }
  if (curLen > 0) gaps.add('[$curStart..${curStart + curLen - 1}]');
  expect(bestLen, greaterThanOrEqualTo(minGap),
      reason: '★ 量具自证失败：两层墨迹之间没有 ≥$minGap 像素的空白竖缝'
          '（最宽只有 $bestLen；全部空白段 $gaps）。'
          '⚠️ 注意「爱心」这一层把两侧拉线**画到屏幕左右边缘** ⇒ 有爱心层时'
          '天然不存在空白竖缝 ⇒ 分带判据必须用两个**局部**特效。'
          '这是量具的问题，不是被测对象。');
  return bestStart + bestLen ~/ 2;
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

Future<void> _mountVisual(WidgetTester tester, List<VisualLayer> layers) async {
  tester.view.physicalSize = const Size(_w * 3, _h * 3);
  tester.view.devicePixelRatio = 3.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final cfg = AppConfig.instance;
  cfg.fxParams.clear();
  cfg.visualLayers
    ..clear()
    ..addAll(layers);
  cfg.visualLayerSel = layers.first.slot;
  cfg.visualEffect = layers.first.effect;
  cfg.heartEnabled = true; // 视觉总开关（关掉整块都不画）
  cfg.rainEnabled = false; // 氛围/边框/律动全关：量具里只留视觉区，别掺别的墨
  cfg.spectrumEnabled = false;
  cfg.edgeEnabled = false;

  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      backgroundColor: Colors.black,
      body: RepaintBoundary(
        key: _shotKey,
        child: const AmbientLayer(isPreview: true),
      ),
    ),
  ));
  await tester.pump();
  await tester.pump();
}

Future<void> _setFx(WidgetTester tester, String k, double v) async {
  await AppConfig.instance.setFx(k, v);
  await tester.pump();
  await tester.pump();
}

/// 收尾：把 `AppConfig._scheduleFxSave` 那个 400ms 去抖计时器**跑掉**。
/// 不跑掉 ⇒ 框架判「A Timer is still pending even after the widget tree was disposed」。
/// ⚠️ 它会推进动画时钟 ⇒ **只能在所有出图都做完之后调**。
Future<void> _flushFxSave(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump();
}

/// 把已知的 debug 噪音取走（`tester.takeException()` 是框架给的正路；
/// ⛔ 别 override `FlutterError.onError`，那会让框架自己报断言）。
/// 返回**非噪音**异常列表 —— 必须为空。
///
/// ⚠️ **这一条的干净度是打折的，原因写在下面**：`SurfaceCard`（带底色的
/// `DecoratedBox`）里装 `SwitchListTile` ⇒ debug 下每次 build 都报一条
/// `ListTile background color or ink splashes may be invisible.`
/// （assert-only，release 一条没有 —— 这是框架层已知的观感告警，应用侧不修）。
/// 而 flutter_test 在 debug 下会把**同一批**异常聚成一条
/// `Multiple exceptions (N) ...` 再交给 `takeException()` —— **单条拿不到**，
/// N 还随重建次数浮动（实测 2 → 3）。
/// 所以这里按**聚合串的形状**过滤，并用「这一页恰好 2 个 SwitchListTile」把来源
/// 钉住。⇒ 真有第三方错误也会被聚进同一条串里：这条的「异常干净度」
/// **只能打折**，但它要判的接线（写哪个键）是硬的。
bool _isKnownNoise(String s) =>
    s.contains('ListTile background color') ||
    (s.startsWith('Multiple exceptions (') &&
        s.endsWith('and at least one was unexpected.'));

List<Object> _drainKnownNoise(WidgetTester tester) {
  final leaked = <Object>[];
  Object? e;
  while ((e = tester.takeException()) != null) {
    if (_isKnownNoise('$e')) continue;
    leaked.add(e!);
  }
  return leaked;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _wirePowerChannel();
    playerService = PlayerService(player: _StubPlayer());
    AppConfig.instance.fxParams.clear();
  });

  tearDown(() {
    playerService = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.mubox.mu_box_phone/power_save'), null);
  });

  // ─────────── 1. 纯函数：槽位前缀的语义 ───────────

  test('1 图层键前缀：不带点的入参也必须带上槽位上标（原 bug 的形状）', () {
    // 绘制端拼的是**前缀**（后面自己接 `.参数名`）
    expect(fxInstancePrefix('v2', 0), 'v2');
    expect(fxInstancePrefix('v2', 1), 'v2#1');
    expect(fxInstancePrefix('v2', 12), 'v2#12');
    // ★ 原 bug 就是这一条：拿完整基键的工具去加工前缀 ⇒ 上标被静默吃掉
    expect(fxInstanceKey('v2', 1), isNot('v2'),
        reason: '画家的 `_vPrefix` 曾走这条（`fxInstanceKey("v2", 1)` 返回 "v2"）'
            '⇒ 整层参数读裸键 ⇒ 槽位 >0 的图层拖滑杆没反应');
    expect(fxInstanceKey('v2', 1), 'v2#1');
    // 带点的完整基键：语义与改动前**逐字符相同**
    expect(fxInstanceKey('v2.x', 0), 'v2.x');
    expect(fxInstanceKey('v2.x', 1), 'v2#1.x');
    expect(fxInstanceKey('v2.count', 13), 'v2#13.count');
    // shared（整组公共项：牵手三项）永远不加后缀
    expect(fxInstancePrefix('v0', 3, shared: true), 'v0');
    expect(fxInstanceKey('v0.link', 3, shared: true), 'v0.link');
    // 前缀 + `.名` 必须能还原回基键（画家的 `_v(n)` 就是这么拼的）
    for (final slot in [0, 1, 7]) {
      expect(fxBaseKey('${fxInstancePrefix('v2', slot)}.count'), 'v2.count',
          reason: 'slot=$slot');
    }
  });

  // ─────────── 2. 像素：槽位 >0 的图层，参数必须看得见 ───────────

  testWidgets('2 漩涡@槽位1：改 x ⇒ 画面必须动；改裸键 ⇒ 一个像素都不许动',
      (tester) async {
    await _mountVisual(tester, [const VisualLayer(effect: 2, slot: 1)]);
    await _setFx(tester, 'v2#1.size', 0.6);

    final a = await _grab(tester);
    expect(_inkCount(a), greaterThan(1000),
        reason: '先证明「画出来了」，否则下面全是假绿');
    expect(_inkCx(a), closeTo(_w * 0.5, 2), reason: '默认 x = 0.5');

    await _setFx(tester, 'v2#1.x', 0.20);
    final b = await _grab(tester);
    expect(_inkCx(b), closeTo(_w * 0.20, 3),
        reason: '★ 槽位 1 的图层写 `v2#1.x` 后，绘制中心必须落到 0.20*宽 —— '
            '这条红了就是「滑动了没反应」');

    await _setFx(tester, 'v2#1.x', 0.80);
    final c = await _grab(tester);
    expect(_inkCx(c), closeTo(_w * 0.80, 3), reason: '反向再验一次，排除巧合');

    // ★ 负向（同一层的免疫性）：裸键 `v2.x` 现在**不该**再被槽位 1 读
    await _setFx(tester, 'v2.x', 0.30);
    final d = await _grab(tester);
    expect(_inkMaskDiff(c, d, 0, _w), 0,
        reason: '槽位 1 的图层不许再被裸键 `v2.x` 牵动 —— 原 bug 下所有层'
            '共用第 1 层的裸键，这才是「改到了别层」');
    expect(_inkCx(d), closeTo(_w * 0.80, 3));

    // ignore: avoid_print
    print('MuBox 判据·槽位渲染2：默认 cx=${_inkCx(a).toStringAsFixed(1)} '
        '#1@0.20 cx=${_inkCx(b).toStringAsFixed(1)} '
        '#1@0.80 cx=${_inkCx(c).toStringAsFixed(1)} '
        '裸键@0.30 之后 cx=${_inkCx(d).toStringAsFixed(1)}（应仍在 0.80 那侧）');
    await _flushFxSave(tester);
  });

  testWidgets('2b 爱心@槽位0 照旧走老键（老用户那条路没被动）', (tester) async {
    await _mountVisual(tester, [const VisualLayer(effect: 0, slot: 0)]);
    await _setFx(tester, 'v0.size', 0.6);
    final a = await _grab(tester);
    await _setFx(tester, 'v0.x', 0.20);
    final b = await _grab(tester);
    expect(_inkCx(b), lessThan(_inkCx(a) - 50),
        reason: '槽位 0 = 老键 `v0.x`，改动前后都必须是好的（既有行为，别改坏）');
    // ignore: avoid_print
    print('MuBox 判据·槽位渲染2b：槽位0 默认 cx=${_inkCx(a).toStringAsFixed(1)} '
        'x=0.20 cx=${_inkCx(b).toStringAsFixed(1)}');
    await _flushFxSave(tester);
  });

  // ─────────── 3. 像素：两层各改各的，互不串台 ───────────

  testWidgets('3 两层：改第 1 层 ⇒ 第 2 层那半屏逐像素不变（反向亦然）',
      (tester) async {
    // ⚠️ 这两层**刻意既不是爱心、也不是漩涡**：
    //   · 爱心会把两侧拉线画到屏幕左右边缘 ⇒ 全宽都有墨 ⇒ 找不到空白竖缝；
    //   · 漩涡的粒子走 `_drawUnitHalo`，实测会给后画的 3D 球留下几十个像素的
    //     跨层残留（`x[306..357]`）⇒「另一带逐像素不变」会被这堆残留打红。
    // 万花筒是纯描边 + 3D球 ⇒ 两层像素互不污染。
    await _mountVisual(tester, [
      const VisualLayer(effect: 5, slot: 0),
      const VisualLayer(effect: 6, slot: 1),
    ]);
    await _setFx(tester, 'v5.size', 0.45);
    await _setFx(tester, 'v5.x', 0.10);
    await _setFx(tester, 'v6#1.size', 0.45);
    await _setFx(tester, 'v6#1.x', 0.90);

    final base = await _grab(tester);
    final split = _splitOf(base);
    final left0 = _inkBand(base, 0, split);
    final right0 = _inkBand(base, split, _w);
    expect(left0.count, greaterThan(200), reason: '缝左边要有万花筒');
    expect(right0.count, greaterThan(200), reason: '缝右边要有 3D 球');

    // ① 只动第 1 层（万花筒@槽位0）的位置
    await _setFx(tester, 'v5.x', 0.30);
    final movedLeft = await _grab(tester);
    expect(_inkBand(movedLeft, 0, split).cx, greaterThan(left0.cx + 10),
        reason: '★ 第 1 层的绘制中心必须跟着 `v5.x` 动');
    final leakA = _pixelDiffBox(base, movedLeft, split, _w);
    expect(leakA.count, 0,
        reason: '★ 改第 1 层，第 2 层那半屏**一个像素都不许变** —— '
            '这条红了就是「改到了别层」。实际变化 ${leakA.count} 个像素，'
            '包围盒 x[${leakA.minX}..${leakA.maxX}] y[${leakA.minY}..${leakA.maxY}]');
    await _setFx(tester, 'v5.x', 0.10);

    // ② 只动第 2 层（3D球@槽位1）的位置
    final before2 = await _grab(tester);
    await _setFx(tester, 'v6#1.x', 0.70);
    final movedRight = await _grab(tester);
    expect(_inkBand(movedRight, split, _w).cx,
        lessThan(_inkBand(before2, split, _w).cx - 10),
        reason: '★ 第 2 层的绘制中心必须跟着 `v6#1.x` 动');
    final leakB = _pixelDiffBox(before2, movedRight, 0, split);
    expect(leakB.count, 0,
        reason: '★ 改第 2 层，第 1 层那半屏**一个像素都不许变**。'
            '实际变化 ${leakB.count} 个像素，'
            '包围盒 x[${leakB.minX}..${leakB.maxX}] y[${leakB.minY}..${leakB.maxY}]');

    // ignore: avoid_print
    print('MuBox 判据·槽位渲染3：缝=$split｜左带 cx '
        '${left0.cx.toStringAsFixed(1)}→'
        '${_inkBand(movedLeft, 0, split).cx.toStringAsFixed(1)}'
        '（右带逐像素不变 ${leakA.count == 0}）｜右带 cx '
        '${_inkBand(before2, split, _w).cx.toStringAsFixed(1)}→'
        '${_inkBand(movedRight, split, _w).cx.toStringAsFixed(1)}'
        '（左带逐像素不变 ${leakB.count == 0}）');
    await _flushFxSave(tester);
  });

  // ─────────── 4. 像素：**绘制轮**也必须逐层设 _vIndex/_vSlot ───────────

  testWidgets('4 绘制轮参数（波形摆动）也必须逐层生效，且不串到另一层',
      (tester) async {
    await _mountVisual(tester, [
      const VisualLayer(effect: 5, slot: 0),
      const VisualLayer(effect: 6, slot: 1),
    ]);
    await _setFx(tester, 'v5.size', 0.45);
    await _setFx(tester, 'v5.x', 0.10);
    await _setFx(tester, 'v6#1.size', 0.45);
    await _setFx(tester, 'v6#1.x', 0.90);

    final base = await _grab(tester);
    final split = _splitOf(base);
    final leftInk0 = _inkBand(base, 0, split).count;
    expect(leftInk0, greaterThan(200));

    // `v5.wiggle`（波形摆动）只在**绘制函数内部**被读（`_paintKaleidoscope`
    // 的 `_v('wiggle')`），布局轮不读它。绘制轮漏设 `_vIndex/_vSlot` ⇒
    // 这一整轮读的都是最后一层（3D球）的前缀，而 `v6` **没有** `wiggle`
    // ⇒ `Fx.def` = 0 ⇒ 波形臂变直、完全不受这个滑杆影响。
    await _setFx(tester, 'v5.wiggle', 0.50);
    final bigger = await _grab(tester);
    final leftInk1 = _inkBand(bigger, 0, split).count;
    expect(leftInk1, isNot(leftInk0),
        reason: '★ 改第 1 层的 `wiggle` 必须改变它自己的墨迹 —— '
            '不变 = 绘制轮读的不是这一层的参数');
    expect(_pixelDiffBox(base, bigger, split, _w).count, 0,
        reason: '★ 第 1 层的波形摆动不许影响第 2 层那半屏');

    // ignore: avoid_print
    print('MuBox 判据·槽位渲染4：缝=$split｜v5.wiggle 0.20→0.50 左带墨迹 '
        '$leftInk0→$leftInk1（右带逐像素不变 '
        '${_pixelDiffBox(base, bigger, split, _w).count == 0}）');
    await _flushFxSave(tester);
  });

  // ─────────── 5. 接线：真滑杆写进去的键 == 画家读的键 ───────────

  testWidgets('5 真设置页：slot=1 拖「水平位置」写 `v2#1.x`（画家读的同一条键）',
      (tester) async {
    final cfg = AppConfig.instance;
    cfg.fxParams.clear();
    cfg.visualLayers
      ..clear()
      ..add(const VisualLayer(effect: 2, slot: 1));
    cfg.visualLayerSel = 1;
    cfg.visualEffect = 2;
    cfg.heartEnabled = true;
    cfg.rainEnabled = false;
    cfg.edgeEnabled = false;

    await tester.pumpWidget(const MaterialApp(
      home: EffectPage(group: 'v', index: 2, slot: 1),
    ));
    await tester.pump();
    final noise1 = _drainKnownNoise(tester);
    expect(noise1, isEmpty, reason: '只允许那条已知 ListTile 噪音，实际漏出：$noise1');

    final sliders = find.byType(Slider);
    expect(sliders, findsWidgets, reason: '「水平位置」等滑杆必须在页面上');
    // 恰好两个开关（「视觉特效」总开关 + 「显示这一层」）⇒ 已知噪音的来源就这两个。
    expect(find.byType(SwitchListTile), findsNWidgets(2));
    // catalog 顺序前两个就是 x / y；从滑杆中心往左拖 60px
    await tester.drag(sliders.first, const Offset(-60, 0));
    await tester.pump();

    expect(cfg.fxParams.containsKey('v2#1.x'), isTrue,
        reason: '★ 设置页必须写**带槽位**的键（slot=1）');
    expect(cfg.fxParams.containsKey('v2.x'), isFalse,
        reason: '★ 槽位 1 的页面**不许**写裸键 —— 写了就是「所有层共用一套参数」');
    // 页面写的键 == 画家拼的键（同一个函数，这里把等价关系钉死）
    final drawn = '${fxInstancePrefix('v2', 1)}.x';
    expect(drawn, 'v2#1.x');
    expect(cfg.fxParams.keys.single, drawn);
    // ignore: avoid_print
    print('MuBox 判据·槽位渲染5：拖滑杆写入 $drawn = ${cfg.fxParams[drawn]}'
        '（画家拼的键 $drawn）');
    await _flushFxSave(tester);
    final noise2 = _drainKnownNoise(tester);
    expect(noise2, isEmpty, reason: '收尾时还有非噪音异常：$noise2');
  });

  testWidgets('5b 反面对照：页面给 slot=0 ⇒ 写裸键（老用户那条路没被动）',
      (tester) async {
    final cfg = AppConfig.instance;
    cfg.fxParams.clear();
    cfg.visualLayers
      ..clear()
      ..add(const VisualLayer(effect: 2, slot: 0));
    cfg.visualLayerSel = 0;
    cfg.visualEffect = 2;
    cfg.heartEnabled = true;
    cfg.rainEnabled = false;
    cfg.edgeEnabled = false;

    await tester.pumpWidget(const MaterialApp(
      home: EffectPage(group: 'v', index: 2, slot: 0),
    ));
    await tester.pump();
    final noise1 = _drainKnownNoise(tester);
    expect(noise1, isEmpty, reason: '只允许那条已知 ListTile 噪音，实际漏出：$noise1');

    await tester.drag(find.byType(Slider).first, const Offset(-60, 0));
    await tester.pump();

    expect(cfg.fxParams.containsKey('v2.x'), isTrue,
        reason: '槽位 0 用的就是老键（老用户存值一个都不动）');
    expect(cfg.fxParams.keys.any((k) => k.contains('#')), isFalse);
    // ignore: avoid_print
    print('MuBox 判据·槽位渲染5b：拖滑杆写入 v2.x = ${cfg.fxParams['v2.x']}');
    await _flushFxSave(tester);
    final noise2 = _drainKnownNoise(tester);
    expect(noise2, isEmpty, reason: '收尾时还有非噪音异常：$noise2');
  });

  // ─────────── 6. ★★ 端到端：进 A 的页拖滑杆 ⇒ 只有 A 那层变（键 + 像素）────

  testWidgets('6 ★★ 两个不同特效各一层：进 A 的页拖「水平位置」⇒ 只写 A 那层的键、'
      'B 那层逐字节不变；像素上 A 的墨迹质心动了、B 所在的条带逐像素不变',
      (tester) async {
    final cfg = AppConfig.instance;
    // 视觉区：A = 万花筒@槽位 0（老键），B = 3D球@槽位 1（`#1` 键）。
    // 两个都是**局部**特效（爱心会把拉线画到屏幕左右边缘 ⇒ 没有空白竖缝可量）。
    cfg.fxParams.clear();
    cfg.visualLayers
      ..clear()
      ..addAll(const [
        VisualLayer(effect: 5, slot: 0),
        VisualLayer(effect: 6, slot: 1),
      ]);
    cfg.visualLayerSel = 1; // ★ 选中的是 B —— 进 A 的页仍必须只调 A 那一层
    cfg.visualEffect = 6;
    cfg.heartEnabled = true;
    cfg.rainEnabled = false;
    cfg.spectrumEnabled = false;
    cfg.edgeEnabled = false;
    await cfg.setFx('v5.size', 0.45); // 收小 ⇒ 中间留出空白竖缝
    await cfg.setFx('v5.x', 0.10);
    await cfg.setFx('v6#1.size', 0.45);
    await cfg.setFx('v6#1.x', 0.90);

    // ── ① 真设置页：进 A（万花筒）的页、A 的那一层 ──
    await tester.pumpWidget(const MaterialApp(
      home: EffectPage(group: 'v', index: 5, slot: 0),
    ));
    await tester.pump();
    final noise = _drainKnownNoise(tester);
    expect(noise, isEmpty, reason: '只允许那条已知 ListTile 噪音，实际漏出：$noise');
    expect(find.textContaining('万花筒 · 第 1 层'), findsOneWidget,
        reason: '前置：进的是万花筒自己的页');

    final bBefore = {
      for (final e in cfg.fxParams.entries)
        if (e.key.startsWith('v6#1.')) e.key: e.value,
    };
    expect(bBefore.length, 2, reason: '前置：B 那层有 size / x 两个键');

    await tester.drag(find.byType(Slider).first, const Offset(-60, 0));
    await tester.pump();

    // ★ A 那层的键被写（`v5.x`，槽位 0 的裸键）
    expect(cfg.fxParams.containsKey('v5.x'), isTrue,
        reason: '★ 拖「水平位置」必须写 A（万花筒）那一层的键');
    final xa = cfg.fxParams['v5.x']!;
    expect(xa, isNot(0.10), reason: '★ 值真的变了（不是「拖了没反应」）');
    // ★ B 那层逐字节不变（键名 + 值 + 键数）
    // ⚠️ 别用 `bAfter == bBefore`：Dart 的 `Map` **没有重载 `==`**（比的是引用）⇒ 恒为 false。
    final bAfter = {
      for (final e in cfg.fxParams.entries)
        if (e.key.startsWith('v6#1.')) e.key: e.value,
    };
    final bSame = bAfter.length == bBefore.length &&
        bAfter.entries.every((e) => bBefore[e.key] == e.value);
    expect(bSame, isTrue,
        reason: '★ 改 A 那一层，B 那层的参数（键名 + 值）一个都不许变：'
            'before=$bBefore after=$bAfter');
    // ★ 整张参数表里除 A 的键之外，谁都不许被这次拖动碰过
    expect(
        cfg.fxParams.keys.where((k) => !k.startsWith('v5.')).toSet(),
        {...bBefore.keys},
        reason: '★ 这次拖动只该动 `v5.*` 的键');
    await _flushFxSave(tester);

    // ── ② 像素：同一份层表，A 的位置 = 拖动前 0.10 vs 拖动后写进去的值 ──
    await _mountVisual(tester, const [
      VisualLayer(effect: 5, slot: 0),
      VisualLayer(effect: 6, slot: 1),
    ]);
    await _setFx(tester, 'v5.size', 0.45);
    await _setFx(tester, 'v5.x', 0.10);
    await _setFx(tester, 'v6#1.size', 0.45);
    await _setFx(tester, 'v6#1.x', 0.90);
    final base = await _grab(tester);
    final split = _splitOf(base); // 量具自证：两层墨迹之间要有空白竖缝
    final left0 = _inkBand(base, 0, split);
    final right0 = _inkBand(base, split, _w);
    expect(left0.count, greaterThan(200), reason: '缝左边要有万花筒的墨');
    expect(right0.count, greaterThan(200), reason: '缝右边要有 3D 球的墨');

    // 把**设置页拖动写进去的那个值**搬到画面上
    await _setFx(tester, 'v5.x', xa);
    final moved = await _grab(tester);
    expect(_inkBand(moved, 0, split).cx, greaterThan(left0.cx + 10),
        reason: '★ A 的墨迹质心必须跟着「设置页拖出来的那个值」动 '
            '（x = 0.10 → $xa）');
    // 「B 所在的条带」= **B 自己的墨迹**那一带（见 [_firstInkCol] 的理由）
    final bMinX = _firstInkCol(base, split, _w);
    expect(bMinX, lessThan(_w), reason: '量具自证：分带线右边必须真有 B 的墨');
    expect(_inkBand(base, bMinX, _w).count, greaterThan(200),
        reason: '量具自证：B 那一带要有足够的墨才量得出差别');
    final leak = _pixelDiffBox(base, moved, bMinX, _w);
    expect(leak.count, 0,
        reason: '★ B 自己的墨迹条带（x[$bMinX..${_w - 1}]）**逐像素不变** —— '
            '这条红了就是「改到了别层」。实际变化 ${leak.count} 个像素，'
            '包围盒 x[${leak.minX}..${leak.maxX}] y[${leak.minY}..${leak.maxY}]');

    // ignore: avoid_print
    print('MuBox 判据·端到端6：设置页拖 A ⇒ 写 v5.x=$xa；B 的键 '
        '${bBefore.keys.join(",")} 逐字节不变=$bSame；'
        '缝=$split｜A 墨迹质心 ${left0.cx.toStringAsFixed(1)}→'
        '${_inkBand(moved, 0, split).cx.toStringAsFixed(1)}｜'
        'B 条带 x[$bMinX..${_w - 1}] 逐像素不变 ${leak.count == 0}');
    await _flushFxSave(tester);
    // ① 那一段是**真设置页** ⇒ 重建过几轮，收尾把已知的 ListTile 噪音取走
    expect(_drainKnownNoise(tester), isEmpty);
  });
}
