/// 均衡器页：一条可拖的增益曲线 + 设备预设 + 总开关。
///
/// 曲线底下叠着 37 柱实时频谱（正在播放且用户开着频谱时），调哪一段一眼看得见。
/// 拖动只改本页临时状态，松手才把整条曲线提交给原生 —— 避免拖动过程中每帧过
/// MethodChannel，也避免把半截曲线写进持久化。
///
/// 原生侧见 `android/.../EqualizerEngine.kt`，数据层见 `lib/eq_engine.dart`。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_config.dart';
import '../eq_engine.dart';
import '../eq_presets.dart';
import '../player_service.dart';
import '../spectrum_engine.dart';
import '../widgets/ambient_layer.dart';
import '../widgets/glass_panel.dart';
import '../widgets/input_dialog.dart';
import '../widgets/wallpaper_layer.dart';

// 曲线区几何：手势与绘制共用同一套换算，避免「拖到的位置」和「画出来的位置」对不上
const double _kPadL = 20;
const double _kPadR = 20;
const double _kPadT = 24;
const double _kPadB = 10;

Rect _plotOf(Size size) =>
    Rect.fromLTRB(_kPadL, _kPadT, size.width - _kPadR, size.height - _kPadB);

double _xOf(int i, int bands, Rect plot) =>
    plot.left + plot.width * (i + 0.5) / bands;

double _yOf(int millibel, Rect plot, int minLevel, int maxLevel) {
  final span = (maxLevel - minLevel).abs() < 1 ? 1 : (maxLevel - minLevel);
  return plot.bottom - (millibel - minLevel) / span * plot.height;
}

int _levelOf(double y, Rect plot, int minLevel, int maxLevel) {
  final t = ((plot.bottom - y) / plot.height).clamp(0.0, 1.0);
  return (minLevel + t * (maxLevel - minLevel)).round();
}

/// dB 文本：+3.0 / 0.0 / -2.5
String _dbText(int millibel) {
  final db = millibel / 100.0;
  if (db.abs() < 0.05) return '0.0';
  return db > 0 ? '+${db.toStringAsFixed(1)}' : db.toStringAsFixed(1);
}

/// 频段中心频率文本：60 / 230 / 910 / 3.6k / 14k（入参单位毫赫兹）
String _freqText(int milliHz) {
  final hz = milliHz / 1000.0;
  if (hz >= 1000) {
    final k = hz / 1000.0;
    return '${k.toStringAsFixed(k >= 10 ? 0 : 1)}k';
  }
  return hz.round().toString();
}

/// 设备预设名中文化（各家 ROM 给的都是英文，认不出的原样显示）
const Map<String, String> _presetZh = {
  'normal': '标准',
  'flat': '平坦',
  'classical': '古典',
  'dance': '舞曲',
  'folk': '民谣',
  'heavy metal': '重金属',
  'hip hop': '嘻哈',
  'jazz': '爵士',
  'pop': '流行',
  'rock': '摇滚',
  'bass boost': '低音增强',
  'treble boost': '高音增强',
  'vocal boost': '人声增强',
  'loudness': '响度',
  'custom': '自定义',
};

String _presetName(String raw) =>
    _presetZh[raw.trim().toLowerCase()] ?? raw.trim();

class EqualizerPage extends StatefulWidget {
  const EqualizerPage({super.key});

  @override
  State<EqualizerPage> createState() => _EqualizerPageState();
}

class _EqualizerPageState extends State<EqualizerPage> {
  /// 拖动中的临时曲线（null = 用引擎里的真实值）
  List<int>? _dragLevels;

  /// 正在拖的频段下标（-1 = 没在拖）
  int _activeBand = -1;

  /// 本页是否申请了频谱使用权：离开时只归还自己那一份
  bool _startedSpectrum = false;

  @override
  void initState() {
    super.initState();
    // 进来补一次刷新：可能刚播放过，音频会话已经就绪
    EqEngine.instance.refresh();
    if (AppConfig.instance.spectrumEnabled && (playerService?.isPlaying ?? false)) {
      // ⚠️ 必须走引用计数，**不能**直接 start()/stop()：播放栏的 SpectrumView
      // 同时也在用这份数据，直接 stop 会把播放栏的频谱一起掐停（且它记着
      // 「我已持有」，之后不会再申请 → 那一整首都不跳了）。
      SpectrumEngine.instance.acquire();
      _startedSpectrum = true;
    }
  }

  @override
  void dispose() {
    if (_startedSpectrum) SpectrumEngine.instance.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          const Positioned.fill(child: WallpaperLayer()),
          const Positioned.fill(child: AmbientLayer(isPreview: true)),
          SafeArea(
            child: ValueListenableBuilder<EqState>(
              valueListenable: EqEngine.instance.state,
              builder: (context, s, _) => Column(
                children: [
                  _header(s, primary),
                  Expanded(
                    child: s.hasBands ? _body(s, primary) : _unavailable(s),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 顶栏：返回 + 标题 + 开关
  Widget _header(EqState s, Color primary) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 14, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: '返回',
            onPressed: () => Navigator.pop(context),
          ),
          const Expanded(
            child: Text(
              '均衡器',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          Switch(
            value: s.enabled,
            activeThumbColor: primary,
            onChanged: s.hasBands
                ? (v) => EqEngine.instance.setEnabled(v)
                : null,
          ),
        ],
      ),
    );
  }

  /// 页面主体：**刻意不用 ListView** —— 它的垂直滚动手势会和曲线拖拽抢手势
  /// 竞技场，实测结果是「曲线拖不动、页面自己滚了」。所以曲线卡片固定在
  /// 外层，只有下方预设区单独可滚（预设多时才需要）。
  Widget _body(EqState s, Color primary) {
    final levels = _dragLevels ?? s.levels;
    // 「我的预设」高亮哪一套：**纯函数比曲线**（逐段相等才算），
    // 不用原生 currentPreset —— 手动拖过圆点之后它是 ROM 的「自定义」，靠不住。
    final myPresets = EqEngine.instance.userPresets;
    final selected = presetMatchingLevels(myPresets, levels);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassPanel(
            borderRadius: BorderRadius.circular(16),
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
            // 壁纸亮的时候纯半透明卡片会让曲线和读数糊在一起，垫一层深色
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 2),
              child: Column(
                children: [
                  SizedBox(height: 236, child: _curve(s, levels, primary)),
                  const SizedBox(height: 2),
                  _bandLabels(s, levels),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          const Text(
            '拖动圆点调各频段增益，松手即生效；关掉总开关只是旁路，曲线会留着',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white70,
              shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (s.presets.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _sectionTitle('设备预设'),
                    const SizedBox(height: 10),
                    _presetWrap(s, primary),
                  ],
                  // 「我的预设」紧挨设备预设下方：
                  // 存的是用户自己起的名字 + 当前曲线，落 prefs 的 eq_presets
                  // ⇒ 自动进备份（见 lib/eq_presets.dart 顶部的理由）。
                  const SizedBox(height: 18),
                  _sectionTitle('我的预设'),
                  const SizedBox(height: 10),
                  if (myPresets.isEmpty)
                    const Text(
                      '还没有自己的预设：调好曲线后点下方「保存当前曲线」',
                      style: TextStyle(
                        fontSize: 11,
                        color: Colors.white54,
                        shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
                      ),
                    )
                  else ...[
                    _myPresetWrap(myPresets, selected, primary),
                    const SizedBox(height: 8),
                    const Text(
                      '点一下套用，长按删除',
                      style: TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          _actions(s),
          const SizedBox(height: 8),
          // ⚠️ 单独一行放在 _actions 下方，**不塞进那颗 Row**：
          // 三颗按钮挤在一行会把「拉平 / 关闭均衡器」压窄 = 观感变化。
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
            ),
            icon: const Icon(Icons.bookmark_add_outlined, size: 18),
            label: const Text('保存当前曲线'),
            onPressed: () => _saveCurrentAsPreset(levels),
          ),
        ],
      ),
    );
  }

  /// 把当前曲线存成一套命名预设（重名 = 覆盖那套的曲线，不会攒出一堆同名 chip）。
  Future<void> _saveCurrentAsPreset(List<int> levels) async {
    if (levels.isEmpty) return;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const TextInputDialog(
        title: '保存为我的预设',
        hint: '给这套曲线起个名字',
        confirmLabel: '保存',
      ),
    );
    if (name == null || name.trim().isEmpty) return;
    await EqEngine.instance.saveCurrentAs(name);
    if (!mounted) return;
    setState(() {}); // 列表变了：本页自己重画一次（不动全局 rebuild）
  }

  /// 长按删除一套「我的预设」，删前问一句（点错了曲线就没了）。
  Future<void> _confirmRemovePreset(EqUserPreset p) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这套预设？'),
        content: Text('「${p.name}」会被删掉，当前正在生效的曲线不受影响。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await EqEngine.instance.removeNamed(p.id);
    if (!mounted) return;
    setState(() {});
  }

  /// 曲线交互区：一个画布吃掉按下/拖动，按 x 找最近频段、按 y 反算增益
  Widget _curve(EqState s, List<int> levels, Color primary) {
    return LayoutBuilder(
      builder: (context, c) {
        final size = Size(c.maxWidth, c.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanDown: (d) => _onDrag(d.localPosition, size, s, levels),
          onPanUpdate: (d) => _onDrag(d.localPosition, size, s, levels),
          onPanEnd: (_) => _commit(),
          onPanCancel: _commit,
          child: ValueListenableBuilder<List<double>>(
            valueListenable: SpectrumEngine.instance.bars,
            builder: (context, bars, _) => CustomPaint(
              size: size,
              painter: _EqCurvePainter(
                levels: levels,
                bars: bars,
                minLevel: s.minLevel,
                maxLevel: s.maxLevel,
                primary: primary,
                enabled: s.enabled,
                activeBand: _activeBand,
              ),
            ),
          ),
        );
      },
    );
  }

  void _onDrag(Offset p, Size size, EqState s, List<int> levels) {
    final plot = _plotOf(size);
    if (plot.width <= 0 || plot.height <= 0) return;
    final bands = s.bands;
    if (bands <= 0) return;
    final band =
        ((p.dx - plot.left) / plot.width * bands).floor().clamp(0, bands - 1);
    var level = _levelOf(p.dy, plot, s.minLevel, s.maxLevel);
    // 0 dB 附近吸附：想「调回不增不减」时不用跟手指较劲
    if (level.abs() < 40) level = 0;
    final next = List<int>.of(levels);
    while (next.length < bands) {
      next.add(0);
    }
    if (next[band] == level && _dragLevels != null) return;
    setState(() {
      _dragLevels = next..[band] = level;
      _activeBand = band;
    });
  }

  void _commit() {
    final levels = _dragLevels;
    setState(() {
      _dragLevels = null;
      _activeBand = -1;
    });
    if (levels != null) EqEngine.instance.setBands(levels);
  }

  /// 频段读数：每个频段下方一行「增益 + 中心频率」
  Widget _bandLabels(EqState s, List<int> levels) {
    final bands = s.bands;
    final enabled = s.enabled;
    return Row(
      children: [
        for (var i = 0; i < bands; i++)
          Expanded(
            child: Column(
              children: [
                Text(
                  _dbText(i < levels.length ? levels[i] : 0),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: enabled ? Colors.white70 : Colors.white38,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  _freqText(i < s.centerFreqs.length ? s.centerFreqs[i] : 0),
                  style: const TextStyle(fontSize: 10, color: Colors.white38),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _presetWrap(EqState s, Color primary) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [for (final p in s.presets) _presetChip(p, s, primary)],
    );
  }

  Widget _presetChip(EqPreset p, EqState s, Color primary) {
    final selected = s.currentPreset == p.index;
    return GestureDetector(
      onTap: () => EqEngine.instance.applyPreset(p.index),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          // 底色压深：chips 直接浮在壁纸上，半透明白会和亮壁纸糊成一片看不清
          color: selected
              ? primary.withValues(alpha: 0.32)
              : Colors.black.withValues(alpha: 0.34),
          border: Border.all(color: selected ? primary : Colors.white24),
        ),
        child: Text(
          _presetName(p.name),
          style: TextStyle(
            fontSize: 12,
            color: Colors.white,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  /// 「我的预设」chip 行：样式与设备预设（[_presetChip]）逐项一致，
  /// 只是行为多一条「长按删除」。高亮由传进来的 [selected] 决定（曲线相等那套）。
  Widget _myPresetWrap(
    List<EqUserPreset> items,
    EqUserPreset? selected,
    Color primary,
  ) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final p in items) _myPresetChip(p, p.id == selected?.id, primary),
      ],
    );
  }

  Widget _myPresetChip(EqUserPreset p, bool selected, Color primary) {
    return GestureDetector(
      onTap: () async {
        await EqEngine.instance.applyNamed(p.id);
        if (!mounted) return;
        setState(() {}); // 曲线变了：本页重画一次，高亮跟着走
      },
      onLongPress: () => _confirmRemovePreset(p),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          // 底色压深：chips 直接浮在壁纸上，半透明白会和亮壁纸糊成一片看不清
          color: selected
              ? primary.withValues(alpha: 0.32)
              : Colors.black.withValues(alpha: 0.34),
          border: Border.all(color: selected ? primary : Colors.white24),
        ),
        child: Text(
          p.name,
          style: TextStyle(
            fontSize: 12,
            color: Colors.white,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _actions(EqState s) {
    return Row(
      children: [
        Expanded(
          child: OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: const BorderSide(color: Colors.white24),
            ),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('拉平'),
            onPressed: () => EqEngine.instance.reset(),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: FilledButton.icon(
            icon: Icon(
              s.enabled ? Icons.hearing_disabled : Icons.hearing,
              size: 18,
            ),
            label: Text(s.enabled ? '关闭均衡器' : '开启均衡器'),
            onPressed: () => EqEngine.instance.setEnabled(!s.enabled),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text) => Text(
    text,
    style: const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Colors.white,
      shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
    ),
  );

  /// 还没播过歌：音频会话不存在，Equalizer 无从 attach —— 说清原因并给个重试
  Widget _unavailable(EqState s) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.graphic_eq, color: Colors.white38, size: 46),
            const SizedBox(height: 16),
            const Text(
              '均衡器要挂在正在播放的音频会话上',
              style: TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              '先在歌单里放一首歌，再回到这一页。\n调好的曲线会存下来，之后每次播放自动套用。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white54, fontSize: 12, height: 1.7),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('重新检测'),
              onPressed: () => EqEngine.instance.refresh(),
            ),
          ],
        ),
      ),
    );
  }
}

/// 曲线绘制：网格 → 实时频谱柱（垫底）→ 平滑曲线（填充 + 描边）→ 各频段圆点
class _EqCurvePainter extends CustomPainter {
  _EqCurvePainter({
    required this.levels,
    required this.bars,
    required this.minLevel,
    required this.maxLevel,
    required this.primary,
    required this.enabled,
    required this.activeBand,
  });

  final List<int> levels;

  /// SpectrumEngine 的 37 柱幅度（0..1）；空 = 没数据，不画
  final List<double> bars;

  final int minLevel;
  final int maxLevel;
  final Color primary;
  final bool enabled;
  final int activeBand;

  @override
  void paint(Canvas canvas, Size size) {
    final plot = _plotOf(size);
    if (plot.width <= 0 || plot.height <= 0) return;
    _paintGrid(canvas, plot);
    _paintBars(canvas, plot);
    _paintCurve(canvas, plot);
    _paintDots(canvas, plot);
  }

  void _paintGrid(Canvas canvas, Rect plot) {
    final paint = Paint()..strokeWidth = 1;
    for (var db = -12; db <= 12; db += 6) {
      final level = db * 100;
      if (level < minLevel || level > maxLevel) continue;
      final y = _yOf(level, plot, minLevel, maxLevel);
      // 0 dB 是基准线，画亮一点
      paint.color = db == 0 ? Colors.white24 : Colors.white10;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), paint);
    }
  }

  /// 实时频谱垫在曲线后面：随鼓点起伏，能看出「正在调的那段有没有声音」
  void _paintBars(Canvas canvas, Rect plot) {
    if (bars.isEmpty) return;
    final n = bars.length;
    final paint = Paint()
      ..color = primary.withValues(alpha: enabled ? 0.16 : 0.07);
    final bw = plot.width / n;
    for (var i = 0; i < n; i++) {
      final h = plot.height * bars[i].clamp(0.0, 1.0);
      if (h <= 0.5) continue;
      final r = Rect.fromLTWH(
        plot.left + i * bw + bw * 0.2,
        plot.bottom - h,
        bw * 0.6,
        h,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(2)),
        paint,
      );
    }
  }

  void _paintCurve(Canvas canvas, Rect plot) {
    final n = levels.length;
    if (n == 0) return;
    final pts = [
      for (var i = 0; i < n; i++)
        Offset(_xOf(i, n, plot), _yOf(levels[i], plot, minLevel, maxLevel)),
    ];
    final path = _smoothPath(pts);

    final fill = Path.from(path)
      ..lineTo(pts.last.dx, plot.bottom)
      ..lineTo(pts.first.dx, plot.bottom)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            primary.withValues(alpha: enabled ? 0.30 : 0.12),
            primary.withValues(alpha: 0.02),
          ],
        ).createShader(plot),
    );

    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = enabled ? primary : Colors.white38,
    );
  }

  void _paintDots(Canvas canvas, Rect plot) {
    final n = levels.length;
    if (n == 0) return;
    final dot = Paint()..color = enabled ? Colors.white : Colors.white54;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = enabled ? primary : Colors.white30;
    for (var i = 0; i < n; i++) {
      final p = Offset(
        _xOf(i, n, plot),
        _yOf(levels[i], plot, minLevel, maxLevel),
      );
      final active = i == activeBand;
      canvas.drawCircle(p, active ? 8 : 6, ring);
      canvas.drawCircle(p, active ? 5 : 3.4, dot);
      if (active) _paintLevelText(canvas, p, levels[i]);
    }
  }

  void _paintLevelText(Canvas canvas, Offset p, int millibel) {
    final tp = TextPainter(
      text: TextSpan(
        text: _dbText(millibel),
        style: const TextStyle(
          fontSize: 11,
          color: Colors.white,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    // 贴顶时把读数放到点下方，别被裁掉
    final dy = p.dy - 20 < 0 ? p.dy + 12 : p.dy - 20;
    tp.paint(canvas, Offset(p.dx - tp.width / 2, dy));
  }

  /// Catmull-Rom 转三次贝塞尔：让折线变成顺滑的曲线，端点做钳制避免过冲
  Path _smoothPath(List<Offset> pts) {
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (var i = 0; i < pts.length - 1; i++) {
      final p0 = i == 0 ? pts[i] : pts[i - 1];
      final p1 = pts[i];
      final p2 = pts[i + 1];
      final p3 = i + 2 < pts.length ? pts[i + 2] : p2;
      final c1 = Offset(
        p1.dx + (p2.dx - p0.dx) / 6,
        p1.dy + (p2.dy - p0.dy) / 6,
      );
      final c2 = Offset(
        p2.dx - (p3.dx - p1.dx) / 6,
        p2.dy - (p3.dy - p1.dy) / 6,
      );
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    return path;
  }

  @override
  bool shouldRepaint(_EqCurvePainter old) =>
      old.enabled != enabled ||
      old.activeBand != activeBand ||
      old.primary != primary ||
      old.minLevel != minLevel ||
      old.maxLevel != maxLevel ||
      !listEquals(old.levels, levels) ||
      !listEquals(old.bars, bars);
}
