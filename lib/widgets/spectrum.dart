/// 频谱动画：用原生 Visualizer 的 FFT 数据驱动柱子（lib/spectrum_engine.dart），
/// 柱顶带峰值残响亮点。可开关；锁屏停动画省电。
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../app_config.dart';
import '../effect_catalog.dart';
import '../theme.dart';
import '../spectrum_engine.dart';

class SpectrumPainter extends CustomPainter {
  final List<Color> colors;
  final List<double>? bars; // 真实频谱幅度（0..1）；null 表示暂无数据
  final List<double>? peaks; // 峰值残响高度（0..1），柱顶亮点回落用；null 表示不画
  final Map<String, double> fx; // 该特效的专属参数（r0.*，见 effect_catalog.dart）

  SpectrumPainter(this.colors, {this.bars, this.peaks, this.fx = const {}});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 4) return;
    if (bars == null || bars!.isEmpty) return;
    const n = 37;
    final gap = fxv(fx, 'r0.gap'); // 柱间距
    final radius = fxv(fx, 'r0.radius'); // 柱圆角
    final minH = fxv(fx, 'r0.minH'); // 静止柱高（不放歌时的底衬高度）
    final glowK = fxv(fx, 'r0.glow'); // 柱顶光晕强度
    final showPeak = fxo(fx, 'r0.peak'); // 峰值残响开关
    final w = (size.width - gap * (n - 1)) / n;
    final count = bars!.length;
    final capPaint = Paint()..color = colors.last; // 峰值残响亮点用浅色
    final barPaint = Paint(); // 柱子画笔复用，避免每帧 new 37 个 Paint
    final glowPaint = Paint(); // 柱顶柔光画笔复用
    // 底轨已移除（用户反馈柱子底下那条线多余）：柱子自身有底边与光晕，不需要垫线。
    for (var i = 0; i < n; i++) {
      final v = i < count ? bars![i].clamp(0.0, 1.0) : 0.0;
      final barH = max(minH, minH + v * (size.height - minH * 2));
      final x = i * (w + gap);
      final r = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, size.height - barH, w, barH),
        Radius.circular(radius),
      );
      // 分段色：低频段主题色 → 高频段浅色，让「低音暖、高音亮」的层次看得见。
      // 注意：原实现逐柱 LinearGradient + createShader（37 次/帧，纯属浪费），
      // 柱体的立体感改由柱顶高光条 + 顶光晕负责，观感几乎无差。
      final seg = count > 1 ? i / (count - 1) : 0.0;
      final top = Color.lerp(
          Color.lerp(colors[0], colors.last, seg)!, Colors.white, 0.18)!;
      barPaint
        ..shader = null
        ..colorFilter = null
        ..color = Color.lerp(colors[0], colors.last, seg)!;
      canvas.drawRRect(r, barPaint);
      // 柱顶高光条：一条偏白的短横条，柱子像被灯从上方照亮
      barPaint.color = top.withValues(alpha: 0.85);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + w * 0.12, size.height - barH, w * 0.76, 2.2),
            const Radius.circular(1.1)),
        barPaint,
      );
      // 柱顶柔光：柱顶中心一点低透明光晕，柱子像真的在发光
      if (v > 0.05 && glowK > 0.01) {
        glowPaint.color =
            top.withValues(alpha: (0.16 + 0.14 * v) * glowK);
        canvas.drawCircle(
            Offset(i * (w + gap) + w / 2, size.height - barH), w * 0.9, glowPaint);
      }
      // 峰值残响：柱顶上方一个慢慢回落的高亮点
      if (showPeak && peaks != null && i < peaks!.length) {
        final peakH =
            max(barH, minH + peaks![i].clamp(0.0, 1.0) * (size.height - minH * 2));
        final cap = RRect.fromRectAndRadius(
          Rect.fromLTWH(i * (w + gap), size.height - peakH - 3.0, w, 3.0),
          const Radius.circular(1.5),
        );
        canvas.drawRRect(cap, capPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant SpectrumPainter old) =>
      old.colors != colors ||
      bars != null ||
      old.bars != null ||
      peaks != null ||
      old.peaks != null;
}

/// 波形动效：把频域柱子连成一条中心线上下对称的平滑曲线（示波器观感）。
/// 复用 SpectrumEngine 的 FFT bars；渐变填充 + 描边，无峰值残响。
class WaveformPainter extends CustomPainter {
  final List<Color> colors;
  final List<double>? bars; // 真实频谱幅度（0..1）；null 表示暂无数据
  final Map<String, double> fx; // 该特效的专属参数（r1.*）

  WaveformPainter(this.colors, {this.bars, this.fx = const {}});

  @override
  void paint(Canvas canvas, Size size) {
    if (bars == null || bars!.isEmpty) return;
    if (size.height <= 4) return;
    final n = bars!.length;
    final cy = size.height / 2;
    final half = size.height * fxv(fx, 'r1.amp'); // 波形振幅（留余量）
    final lineW = fxv(fx, 'r1.line');
    final fillK = fxv(fx, 'r1.fill');
    final roundCurve = fxo(fx, 'r1.round');
    final dx = size.width / (n - 1);
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final strokeShader = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: colors,
    ).createShader(rect);

    // 上半边采样点（中心线向上），中点二次贝塞尔平滑成圆滑包络
    final pts = <Offset>[
      for (var i = 0; i < n; i++)
        Offset(i * dx, cy - bars![i].clamp(0.0, 1.0) * half),
    ];
    final path = Path()..moveTo(0, cy);
    path.lineTo(pts[0].dx, pts[0].dy);
    if (roundCurve) {
      for (var i = 1; i < n; i++) {
        final mid = Offset(
            (pts[i - 1].dx + pts[i].dx) / 2, (pts[i - 1].dy + pts[i].dy) / 2);
        path.quadraticBezierTo(pts[i - 1].dx, pts[i - 1].dy, mid.dx, mid.dy);
      }
    } else {
      // 折线模式：直来直去，频段跳变看得更清楚
      for (var i = 1; i < n; i++) {
        path.lineTo(pts[i].dx, pts[i].dy);
      }
    }
    path.lineTo(pts[n - 1].dx, pts[n - 1].dy);
    // 下半边镜像（从右往左），形成上下对称封闭波形
    for (var i = n - 1; i >= 0; i--) {
      path.lineTo(i * dx, cy + (cy - pts[i].dy));
    }
    path.close();

    if (fillK > 0.01) {
      final fillShader = LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: colors.map((c) => c.withValues(alpha: fillK)).toList(),
      ).createShader(rect);
      canvas.drawPath(path, Paint()
        ..shader = fillShader
        ..style = PaintingStyle.fill);
    }
    canvas.drawPath(path, Paint()
      ..shader = strokeShader
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineW
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round);
  }

  @override
  bool shouldRepaint(covariant WaveformPainter old) =>
      old.colors != colors || bars != null || old.bars != null || old.fx != fx;
}

/// 环形/辐射频谱：把各频段幅度沿圆周 360° 径向采样成「辐射多边形」，
/// 再用中点二次贝塞尔连成一条平滑闭合的呼吸环（不再是一根根离散的短线），
/// 填充半透明渐变 + 亮色描边，柱顶带峰值残响亮点，中心留一圈空腔。
/// 自适应宽高比——播放栏顶部窄条里会自然展开成横放的「能量环」，观感柔和不扎眼。
// ── 环形/镜像频谱共用的渐变与 Paint 缓存（跨帧复用）────────────────────────
// SpectrumView 每次 build 都新建 painter，所以缓存必须放在顶层；同时
// SpectrumView 每次都传一个新的 [accent, accentLight] 列表，判断缓存是否失效
// 只能比「颜色值」而不是列表引用。
List<Color>? _rxColors;
double _rxW = -1;
double _rxH = -1;
Shader? _rxFill;
Shader? _rxStroke;
final Paint _rxFillPaint = Paint()..style = PaintingStyle.fill;
final Paint _rxStrokePaint = Paint()
  ..style = PaintingStyle.stroke
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;
final Paint _rxCorePaint = Paint();

bool _sameColors(List<Color> a, List<Color> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 横向渐变（低频主色 → 高频浅色），按颜色 + 尺寸缓存；返回复用的 shader。
({Shader fill, Shader stroke}) _ringGradients(List<Color> colors, Size size) {
  if (_rxFill == null ||
      _rxStroke == null ||
      _rxColors == null ||
      _rxW != size.width ||
      _rxH != size.height ||
      !_sameColors(_rxColors!, colors)) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    _rxFill = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: colors.map((c) => c.withValues(alpha: 0.28)).toList(),
    ).createShader(rect);
    _rxStroke = LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: colors,
    ).createShader(rect);
    _rxColors = List<Color>.of(colors);
    _rxW = size.width;
    _rxH = size.height;
  }
  return (fill: _rxFill!, stroke: _rxStroke!);
}

class RingSpectrumPainter extends CustomPainter {
  final List<Color> colors;
  final List<double>? bars; // 真实频谱幅度（0..1）；null 表示暂无数据
  final List<double>? peaks; // 峰值残响高度（0..1），柱顶亮点用；null 表示不画
  final Map<String, double> fx; // 该特效的专属参数（r2.*）

  RingSpectrumPainter(this.colors,
      {this.bars, this.peaks, this.fx = const {}});

  @override
  void paint(Canvas canvas, Size size) {
    if (bars == null || bars!.isEmpty) return;
    if (size.height <= 4) return;
    final n = bars!.length;
    final cx = size.width / 2;
    final cy = size.height / 2;
    final halfW = size.width / 2;
    final halfH = size.height / 2;
    final glowK = fxv(fx, 'r2.glow'); // 空腔辉光
    final showPeak = fxo(fx, 'r2.peak');
    // 中心空腔半径：取较短边，保证窄条里环还是正圆，横向会自然伸展开
    final r0 = min(halfW, halfH) * fxv(fx, 'r2.inner');
    // 内环微描边，让空腔有实体边界感
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = colors[0].withValues(alpha: 0.25);
    canvas.drawCircle(Offset(cx, cy), r0, ringPaint);

    // 采样径向尖端（幅度 → 半径），椭圆裁剪保证不溢出
    final tips = <Offset>[];
    for (var i = 0; i < n; i++) {
      final ang = -pi / 2 + 2 * pi * i / n; // 从顶部顺时针
      final dir = Offset(cos(ang), sin(ang));
      final c = dir.dx.abs();
      final s = dir.dy.abs();
      final reach = min(
        c < 1e-6 ? double.infinity : halfW / c,
        s < 1e-6 ? double.infinity : halfH / s,
      );
      final v = bars![i].clamp(0.0, 1.0);
      final len = v * (reach - r0 - 2.0); // 留 2px 不顶边
      tips.add(Offset(cx + dir.dx * (r0 + len), cy + dir.dy * (r0 + len)));
    }

    // 平滑闭合曲线：相邻尖端取中点，中点二次贝塞尔顺滑过渡（同 Waveform 的平滑手法）
    final path = Path()..moveTo(tips.first.dx, tips.first.dy);
    for (var i = 1; i < n; i++) {
      final mid = Offset(
        (tips[i - 1].dx + tips[i].dx) / 2,
        (tips[i - 1].dy + tips[i].dy) / 2,
      );
      path.quadraticBezierTo(tips[i - 1].dx, tips[i - 1].dy, mid.dx, mid.dy);
    }
    final midLast = Offset(
      (tips.last.dx + tips.first.dx) / 2,
      (tips.last.dy + tips.first.dy) / 2,
    );
    path.quadraticBezierTo(tips.last.dx, tips.last.dy, midLast.dx, midLast.dy);
    path.close();

    // 填充 + 描边走横向渐变（低频主色 → 高频浅色）；渐变 shader 与 Paint 全部
    // 跨帧复用（原实现每帧 createShader 两次 + new 两个 Paint）
    final gr = _ringGradients(colors, size);
    canvas.drawPath(path, _rxFillPaint..shader = gr.fill);
    canvas.drawPath(path,
        _rxStrokePaint..shader = gr.stroke..strokeWidth = fxv(fx, 'r2.line'));
    // 中心空腔柔光：随整体能量呼吸的内辉光，环形不再只是一个空心圈
    var energySum = 0.0;
    for (final b in bars!) {
      energySum += b;
    }
    final energy = (energySum / n).clamp(0.0, 1.0);
    final coreR = r0 * (1.15 + 0.25 * energy);
    _rxCorePaint.color =
        colors[0].withValues(alpha: (0.045 + 0.10 * energy) * glowK);
    canvas.drawCircle(Offset(cx, cy), coreR * 1.9, _rxCorePaint);
    _rxCorePaint.color =
        colors.last.withValues(alpha: (0.06 + 0.15 * energy) * glowK);
    canvas.drawCircle(Offset(cx, cy), coreR, _rxCorePaint);

    // 峰值残响：柱顶一个浅色小亮点，慢回落
    if (showPeak && peaks != null) {
      final capPaint = Paint()..color = colors.last;
      for (var i = 0; i < n && i < peaks!.length; i++) {
        final pv = peaks![i].clamp(0.0, 1.0);
        if (pv <= 0.01) continue;
        final ang = -pi / 2 + 2 * pi * i / n;
        final dir = Offset(cos(ang), sin(ang));
        final c = dir.dx.abs();
        final s = dir.dy.abs();
        final reach = min(
          c < 1e-6 ? double.infinity : halfW / c,
          s < 1e-6 ? double.infinity : halfH / s,
        );
        final plen = pv * (reach - r0 - 2.0);
        final dot = Offset(cx + dir.dx * (r0 + plen), cy + dir.dy * (r0 + plen));
        // 柔光晕 + 亮核两层，峰值点更像发光的小灯
        capPaint.color = colors.last.withValues(alpha: 0.3);
        canvas.drawCircle(dot, 3.2, capPaint);
        capPaint.color = colors.last;
        canvas.drawCircle(dot, 2.0, capPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant RingSpectrumPainter old) =>
      old.colors != colors ||
      bars != null ||
      old.bars != null ||
      peaks != null ||
      old.peaks != null ||
      old.fx != fx;
}

/// 圆点均衡器：37 个圆点按频段上下跳动（原地跳，不依赖空间），
/// 带光晕 + 高光核 + 峰值亮点，鼓点强时跳得高、颜色越亮。
class DotsPainter extends CustomPainter {
  final List<Color> colors;
  final List<double>? bars; // 真实频谱幅度（0..1）；null 表示暂无数据
  final List<double>? peaks; // 峰值残响高度（0..1），柱顶亮点用；null 表示不画
  final Map<String, double> fx; // 该特效的专属参数（r3.*）

  DotsPainter(this.colors, {this.bars, this.peaks, this.fx = const {}});

  @override
  void paint(Canvas canvas, Size size) {
    if (bars == null || bars!.isEmpty) return;
    if (size.height <= 4) return;
    const n = 37;
    final gap = fxv(fx, 'r3.gap');
    final glowK = fxv(fx, 'r3.glow');
    final showPeak = fxo(fx, 'r3.peak');
    final w = (size.width - gap * (n - 1)) / n;
    final cy = size.height / 2;
    final half = size.height * fxv(fx, 'r3.amp'); // 上下跳动幅度
    final count = bars!.length;
    // 预建 Paint 复用：圆点每帧画上百次，避免每帧 new 上百个 Paint 造成 GC 卡顿
    final glowPaint = Paint();
    final corePaint = Paint();
    final hiPaint = Paint();
    final peakPaint = Paint();
    for (var i = 0; i < n; i++) {
      final v = i < count ? bars![i].clamp(0.0, 1.0) : 0.0;
      final seg = count > 1 ? i / (count - 1) : 0.0;
      final col = Color.lerp(colors[0], colors.last, seg)!;
      final r = max(1.6, w * fxv(fx, 'r3.r')); // 圆点半径
      final x = i * (w + gap) + w / 2;
      final pos = Offset(x, cy - v * half); // 幅度越高跳得越高
      // 光晕 → 核心 → 高光核，圆润发光（光晕更大更柔）
      glowPaint.color = col.withValues(alpha: (0.32 * glowK).clamp(0.0, 1.0));
      canvas.drawCircle(pos, r * 2.6, glowPaint);
      corePaint.color = col;
      canvas.drawCircle(pos, r, corePaint);
      hiPaint.color = Colors.white.withValues(alpha: 0.8);
      canvas.drawCircle(pos, r * 0.5, hiPaint);
      // 峰值残响亮点：圆点上方小点，慢回落
      if (showPeak && peaks != null && i < peaks!.length) {
        final pv = peaks![i].clamp(0.0, 1.0);
        peakPaint.color = colors.last.withValues(alpha: 0.8);
        canvas.drawCircle(
          Offset(x, cy - pv * half - r - 2.0),
          1.5,
          peakPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant DotsPainter old) =>
      old.colors != colors ||
      bars != null ||
      old.bars != null ||
      peaks != null ||
      old.peaks != null ||
      old.fx != fx;
}

/// 镜像频谱：柱子以中心基线上下对称，上柱主色、下柱半透明，中间一条基线。
/// 与单边频谱相比层次翻倍，原地跳动。
class MirrorPainter extends CustomPainter {
  final List<Color> colors;
  final List<double>? bars; // 真实频谱幅度（0..1）；null 表示暂无数据
  final List<double>? peaks; // 峰值残响高度（0..1），柱顶亮点用；null 表示不画
  final Map<String, double> fx; // 该特效的专属参数（r5.*）

  MirrorPainter(this.colors, {this.bars, this.peaks, this.fx = const {}});

  @override
  void paint(Canvas canvas, Size size) {
    if (bars == null || bars!.isEmpty) return;
    if (size.height <= 4) return;
    const n = 37;
    final gap = fxv(fx, 'r5.gap');
    final radius = fxv(fx, 'r5.radius');
    final downK = fxv(fx, 'r5.down'); // 下柱浓度
    final showPeak = fxo(fx, 'r5.peak');
    final w = (size.width - gap * (n - 1)) / n;
    final cy = size.height / 2; // 中心基线
    final half = size.height / 2 - 2; // 单侧最大柱高
    final count = bars!.length;
    final capPaint = Paint()..color = colors.last;
    final topPaint = Paint(); // 上柱
    final bottomPaint = Paint(); // 下柱（镜像半透明）
    final linePaint = Paint()
      ..color = colors[0].withValues(alpha: 0.35)
      ..strokeWidth = 1.0;
    for (var i = 0; i < n; i++) {
      final v = i < count ? bars![i].clamp(0.0, 1.0) : 0.0;
      final barH = max(3.0, v * half);
      final seg = count > 1 ? i / (count - 1) : 0.0;
      final col = Color.lerp(colors[0], colors.last, seg)!;
      final x = i * (w + gap);
      // 上柱（主色） + 下柱（镜像，半透明）
      topPaint.color = col;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, cy - barH, w, barH), Radius.circular(radius)),
        topPaint,
      );
      // 柱内高光条：左侧一条更亮的细柱，柱子不再是纯色板（像镜面里的反光）
      topPaint.color = Color.lerp(col, Colors.white, 0.35)!;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x + w * 0.18, cy - barH, w * 0.24, barH),
            Radius.circular(radius * 0.48)),
        topPaint,
      );
      // 上柱顶亮边：一小条偏白高光，柱顶像被灯照亮
      topPaint.color = Color.lerp(col, Colors.white, 0.45)!.withValues(alpha: 0.75);
      canvas.drawRect(Rect.fromLTWH(x, cy - barH - 1.2, w, 1.2), topPaint);
      bottomPaint.color = col.withValues(alpha: downK);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromLTWH(x, cy, w, barH), Radius.circular(radius)),
        bottomPaint,
      );
      // 峰值残响：上下各一个亮点
      if (showPeak && peaks != null && i < peaks!.length) {
        final pv = peaks![i].clamp(0.0, 1.0);
        final peakH = max(barH, pv * half);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, cy - peakH - 2.5, w, 2.5),
              const Radius.circular(1.2)),
          capPaint,
        );
        bottomPaint.color = colors.last.withValues(alpha: downK);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, cy + peakH, w, 2.5),
              const Radius.circular(1.2)),
          bottomPaint,
        );
      }
    }
    // 中心基线
    canvas.drawLine(
      Offset(0, cy),
      Offset(size.width, cy),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(covariant MirrorPainter old) =>
      old.colors != colors ||
      bars != null ||
      old.bars != null ||
      peaks != null ||
      old.peaks != null ||
      old.fx != fx;
}

/// 3D 伪立体频谱：每根柱顶带一块向右后倾的斜顶面，做出「挤出立体」的观感。
class _ThreeDSpectrumPainter extends CustomPainter {
  final List<Color> colors;
  final List<double>? bars;
  final Map<String, double> fx; // 该特效的专属参数（r6.*）
  const _ThreeDSpectrumPainter(this.colors, {this.bars, this.fx = const {}});

  @override
  void paint(Canvas canvas, Size size) {
    if (size.height <= 4 || bars == null || bars!.isEmpty) return;
    const n = 37;
    final count = bars!.length;
    final w = size.width / n;
    final skew = fxv(fx, 'r6.skew'); // 顶面后倾透视偏移
    final thickness = fxv(fx, 'r6.thick'); // 顶面厚度
    final gapW = fxv(fx, 'r6.gapW'); // 柱间缝
    final faceK = fxv(fx, 'r6.alpha'); // 柱体浓度
    final topPaint = Paint()..color = colors.last.withValues(alpha: 0.9);
    final facePaint = Paint();
    for (var i = 0; i < n; i++) {
      final v = i < count ? bars![i].clamp(0.0, 1.0) : 0.0;
      final h = 4.0 + v * (size.height - 8);
      final x0 = i * w + gapW / 2; // 留缝
      final bw = w - gapW;
      final seg = count > 1 ? i / (count - 1) : 0.0;
      final c = Color.lerp(colors[0], colors.last, seg)!;
      final baseY = size.height;
      final topY = baseY - h;
      // 斜顶面（立体感）
      final top = Path()
        ..moveTo(x0, topY)
        ..lineTo(x0 + skew, topY - thickness)
        ..lineTo(x0 + bw + skew, topY - thickness)
        ..lineTo(x0 + bw, topY)
        ..close();
      canvas.drawPath(top, topPaint);
      // 右侧面（暗面）：向右后方再挤一块侧面，双面立体
      final side = Path()
        ..moveTo(x0 + bw, topY)
        ..lineTo(x0 + bw + skew, topY - thickness)
        ..lineTo(x0 + bw + skew, baseY - thickness)
        ..lineTo(x0 + bw, baseY)
        ..close();
      facePaint.shader = null;
      facePaint.color = c.withValues(alpha: (0.45 * faceK).clamp(0.0, 1.0));
      canvas.drawPath(side, facePaint);
      // 柱身（前立面）：纯色主体 + 顶部亮边。原实现逐柱 createShader 一个竖向渐变
      // （37 次/帧），改由「亮边 + 侧面暗面」表达体积，观感几乎无差。
      facePaint
        ..shader = null
        ..color = c.withValues(alpha: faceK);
      canvas.drawRect(Rect.fromLTWH(x0, topY, bw, h), facePaint);
      facePaint.color = Color.lerp(c, Colors.white, 0.40)!.withValues(alpha: 0.55);
      canvas.drawRect(Rect.fromLTWH(x0, topY, bw, max(1.6, h * 0.14)), facePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ThreeDSpectrumPainter old) =>
      old.colors != colors || bars != null || old.bars != null || old.fx != fx;
}


class SpectrumView extends StatefulWidget {
  final bool active;

  /// 默认取当前主题的主色 + 浅色渐变
  final List<Color>? colors;

  /// 频谱条高度
  final double height;
  const SpectrumView({super.key, required this.active, this.colors, this.height = 14});

  @override
  State<SpectrumView> createState() => _SpectrumViewState();
}

class _SpectrumViewState extends State<SpectrumView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _c;
  bool _screenOn = true; // 前台/锁屏标记：锁屏停动画省电
  List<double> _smoothed = []; // 真实频谱的 EMA 平滑缓存
  List<double> _peaks = []; // 峰值残响缓存：柱顶亮点回落用
  bool _holds = false; // 本视图当前是否持有频谱引擎的使用权（见 SpectrumEngine.acquire）

  /// 未播放时的静止基线：37 根全部为 0，只画出频谱的「底衬」轮廓（静止状态），
  /// 让播放栏顶部在不放歌时也能看到一条频谱（否则 bars 为空直接不画，什么都看不到）。
  static final List<double> _idleBars = List.filled(37, 0.0);

  /// 峰值残响每帧衰减因子：高点落得快、低点落得慢，约 0.5 秒回落大半
  static const double _peakDecay = 0.93;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800));
    _c.addListener(_onTick);
    WidgetsBinding.instance.addObserver(this);
    AppConfig.instance.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant SpectrumView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  /// 是否有仍在衰减的柱子/峰值：播放中由引擎实时驱动；暂停后靠 _onTick 慢慢落回 0。
  /// 全部落完（<0.005）就没有可画的了，此时不必再全速跑 _c 空转。
  bool _hasLive() {
    for (var i = 0; i < _peaks.length; i++) {
      if (_peaks[i] > 0.005) return true;
    }
    for (var i = 0; i < _smoothed.length; i++) {
      if (_smoothed[i] > 0.005) return true;
    }
    return false;
  }

  /// 真实频谱统一调度：
  /// - _c 只要「频谱开 + 前台 + 有东西可画」才跑，驱动峰值残响衰减 + 暂停时柱子回落；
  ///   空闲（未播放且柱子已落完）就停，避免按 vsync 全速空转消耗渲染线程。
  /// - SpectrumEngine 只在「播放中」才采集，暂停即停（省电）。
  void _sync() {
    final config = AppConfig.instance;
    final needAnim =
        _screenOn && config.spectrumEnabled && (widget.active || _hasLive());
    if (needAnim && !_c.isAnimating) {
      _c.repeat();
    } else if (!needAnim && _c.isAnimating) {
      _c.stop();
    }
    // 自愈：本视图记着「我持有」，但引擎其实已经被停掉（原生报错、或别处直接 stop 过）
    // —— 此时 _acquire() 会因 _holds 早退，频谱这一整场都不会再动，所以先放掉再重申请。
    if (_holds && !SpectrumEngine.instance.active) _holds = false;
    if (_screenOn && config.spectrumEnabled && widget.active) {
      _acquire();
    } else {
      _release();
    }
  }

  /// 申请频谱引擎：重复调用不会重复计数（本视图只持有一份）。
  void _acquire() {
    if (_holds) return;
    _holds = true;
    SpectrumEngine.instance.acquire();
  }

  /// 归还频谱引擎：播放栏与设置页预览同时开着时，先走的那个不会把另一个掐停。
  void _release() {
    if (!_holds) return;
    _holds = false;
    SpectrumEngine.instance.release();
  }

  /// 真实频谱平滑：EMA 衰减，柱子不跳得太硬；同时更新峰值残响高点。
  void _handleBars(List<double> src) {
    if (src.isEmpty) return;
    if (_smoothed.length != src.length) {
      _smoothed = List.of(src);
      _peaks = List.of(src);
    } else {
      for (var i = 0; i < src.length; i++) {
        final target = src[i];
        // 每柱独立响应速度：柱子起落不同步，减少「整体一起呼吸」的规律性；
        // 上升快（跟鼓点）、下降较干脆，运动更激烈。
        final up = 0.55 + (i % 6) * 0.06; // 0.55 ~ 0.85
        final down = 0.22 + (i % 5) * 0.04; // 0.22 ~ 0.38
        final factor = target > _smoothed[i] ? up : down;
        _smoothed[i] += (target - _smoothed[i]) * factor;
        if (_smoothed[i] > _peaks[i]) _peaks[i] = _smoothed[i];
      }
    }
  }

  /// 每帧衰减：峰值残响亮点回落；暂停（引擎已停、无新数据）时柱子主体也慢慢下沉。
  ///
  /// ★ **引擎"订阅着"不等于"还有帧在来"**。
  /// FFT 是原生回调推的，回调链一停（Visualizer 被孤儿化 / 轨道被挪走 / 系统把那
  /// 一路静音），`bars` 就停在最后一帧 —— 旧写法 `if (active) return;` 会把这一帧
  /// **永远当活的画下去**，界面于是"看起来在跳其实定格了"，一个字都不说。
  /// 现在多问一句 `stalled`（时间判断都在 `playback/spectrum_watchdog.dart`，
  /// ⛔ 本文件依旧**不许出现任何时间基写法**，有源码级断言钉着）：
  /// 断流 ⇒ 按**同一套帧基因子**落回静止基座，并让引擎试着重挂一次。
  void _onTick() {
    for (var i = 0; i < _peaks.length; i++) {
      final v = _peaks[i] * _peakDecay;
      _peaks[i] = v < 0.005 ? 0.0 : v;
    }
    final engine = SpectrumEngine.instance;
    if (engine.active && !engine.stalled) return; // 播放中且帧真的在来：由 _handleBars 驱动
    if (engine.stalled) {
      // 断流自愈（内部节流，见 kSpectrumHealMinInterval）：重建一次 Visualizer。
      unawaited(engine.healIfStalled());
    }
    for (var i = 0; i < _smoothed.length; i++) {
      final v = _smoothed[i] * _peakDecay;
      _smoothed[i] = v < 0.005 ? 0.0 : v;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _screenOn = state != AppLifecycleState.paused && state != AppLifecycleState.hidden;
    _sync();
  }

  @override
  void dispose() {
    AppConfig.instance.removeListener(_sync);
    WidgetsBinding.instance.removeObserver(this);
    _c.removeListener(_onTick);
    _c.dispose();
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppConfig.instance,
      builder: (context, _) {
        if (!AppConfig.instance.spectrumEnabled) return const SizedBox.shrink();
        final colors = widget.colors ??
            [context.accent, context.accentLight];
        final rhythm = AppConfig.instance.rhythmEffect; // 0 频谱 / 1 波形 / 2 环形 / 3 圆点 / 5 镜像 / 6 3D频谱
        return ListenableBuilder(
          listenable: Listenable.merge([
            SpectrumEngine.instance.bars,
            SpectrumEngine.instance.bass,
            _c,
          ]),
          builder: (context, _) {
            _handleBars(SpectrumEngine.instance.bars.value);
            // 未播放时若频谱已衰减为空，用静止基线（全 0）画一个「静止频谱」轮廓，
            // 让播放栏顶部在不放歌时也有一条可见的频谱（静止状态），点播放键即开始跳动。
            final bars = _smoothed.isEmpty ? (widget.active ? null : _idleBars) : _smoothed;
            final peaks = _peaks.isEmpty ? null : _peaks;
            // 该律动特效的专属参数快照（r0/r1/r2/r3/r5/r6.*，见 effect_catalog.dart）
            final fx = Map.of(AppConfig.instance.fxParams);
            final painter = switch (rhythm) {
              1 => WaveformPainter(colors, bars: bars, fx: fx),
              2 => RingSpectrumPainter(colors, bars: bars, peaks: peaks, fx: fx),
              3 => DotsPainter(colors, bars: bars, peaks: peaks, fx: fx),
              5 => MirrorPainter(colors, bars: bars, peaks: peaks, fx: fx),
              6 => _ThreeDSpectrumPainter(colors, bars: bars, fx: fx),
              _ => SpectrumPainter(colors, bars: bars, peaks: peaks, fx: fx),
            };
            return CustomPaint(
              painter: painter,
              size: Size(double.infinity, widget.height),
            );
          },
        );
      },
    );
  }
}
