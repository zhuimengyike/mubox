part of 'ambient_layer.dart';

/// 白色径向渐变光斑（单位圆）shader，懒建一次复用。
/// 配合 ColorFilter.mode(color, BlendMode.modulate) 给任意颜色的柔光斑上色：结果色=color、
/// alpha 中心亮→边缘渐隐。与直接构建带 alpha 的 RadialGradient 完全等价，但整个重绘循环
/// 只建一次 shader，不再每个斑每帧 new Gradient + createShader（全屏重绘下的主要分配来源）。
RadialGradient? _unitGlowGradient;
Shader? _unitGlowShader;
Shader _unitGlowShaderOf() =>
    _unitGlowShader ??=
        (_unitGlowGradient ??= const RadialGradient(
          colors: [
            Color(0xFFFFFFFF),
            Color(0x99FFFFFF),
            Color(0x2EFFFFFF),
            Color(0x00FFFFFF),
          ],
          stops: [0.0, 0.35, 0.7, 1.0],
        )).createShader(Rect.fromCircle(center: Offset.zero, radius: 1.0));

/// 构建三档圆形柔光晕（单位圆）shader：中心 alpha=a0 → 半径一半 a1 → 边缘归零。
Shader _buildHaloShader(double a0, double a1) => RadialGradient(
      colors: [
        const Color(0xFFFFFFFF).withValues(alpha: a0),
        const Color(0xFFFFFFFF).withValues(alpha: a1),
        const Color(0xFFFFFFFF).withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1.0));

/// 各动效光晕 shader 懒建一次复用（同 _unitGlowShaderOf 思路）：配合
/// ColorFilter.mode(color, BlendMode.modulate) 上色，结果色 = color、
/// alpha 按各档比例缩放，与「每个粒子每帧按自身 alpha new Gradient +
/// createShader」渲染完全等价，但零分配——烟花（活跃期数百火花）/飘雪/
/// 萤火虫/星空大星的光晕是全屏重绘循环的主要分配来源。
Shader? _haloStar, _haloFirefly, _haloSnow, _haloSpark;
Shader _haloStarOf() => _haloStar ??= _buildHaloShader(0.45, 0.15);
Shader _haloFireflyOf() => _haloFirefly ??= _buildHaloShader(0.6, 0.2);
Shader _haloSnowOf() => _haloSnow ??= _buildHaloShader(1.0, 0.3);
Shader _haloSparkOf() => _haloSpark ??= _buildHaloShader(0.6, 0.18);

/// 漩涡星核双色径向渐变（单位圆）shader：懒建一次、按主题色对缓存复用
/// （同 _unitGlowShaderOf 思路）。绘制时 canvas 缩放到 coreR，鼓点呼吸只改
/// 缩放不改 shader；仅主题/氛围色调变化时才重建一次，整帧零分配。
Shader? _galaxyCoreShaderCache;
Color? _galaxyCoreLight;
Color? _galaxyCorePrimary;
Shader _galaxyCoreShaderOf(Color light, Color primary) {
  if (_galaxyCoreLight != light || _galaxyCorePrimary != primary) {
    _galaxyCoreLight = light;
    _galaxyCorePrimary = primary;
    _galaxyCoreShaderCache = RadialGradient(
      colors: [
        light.withValues(alpha: 0.75),
        primary.withValues(alpha: 0.45),
        primary.withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.38, 1.0],
    ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1.0));
  }
  return _galaxyCoreShaderCache!;
}

/// 星芒十字线（单位长度）shader：两端透明、中点 alpha 0.55，横向线性渐变；
/// 绘制时等比缩放对齐长度、旋转对齐竖向，配合 modulate 上色。
Shader? _crossShader;
Shader _crossShaderOf() => _crossShader ??= LinearGradient(
      colors: [
        const Color(0xFFFFFFFF).withValues(alpha: 0.0),
        const Color(0xFFFFFFFF).withValues(alpha: 0.55),
        const Color(0xFFFFFFFF).withValues(alpha: 0.0),
      ],
      stops: const [0.0, 0.5, 1.0],
    ).createShader(
        Rect.fromPoints(const Offset(-1.0, 0.0), const Offset(1.0, 0.0)));

/// 气泡薄膜虹彩：单位圆上的六色彩虹环（首尾同色无缝），只在半径 1 的单位圆里
/// 建一次复用；绘制时按气泡半径缩放 + modulate 上色 → 每个气泡零 shader 分配。
Shader? _bubbleFilmShader;
Shader _bubbleFilmOf() => _bubbleFilmShader ??= const SweepGradient(
      colors: [
        Color(0xFF7FD8FF),
        Color(0xFFB79CFF),
        Color(0xFFFFB3D9),
        Color(0xFFFFF0A8),
        Color(0xFF9EFFD0),
        Color(0xFF7FD8FF),
      ],
    ).createShader(Rect.fromCircle(center: Offset.zero, radius: 1.0));

/// 花瓣单位路径：桃/樱花瓣形态——椭圆轮廓、尖端带小 V 形缺口（樱花瓣标志）、
/// 底部圆润。定义在单位坐标（长轴 1：尖端 -0.5 / 底部 +0.5，宽约 0.6），
/// 绘制时缩放对齐各花瓣尺寸，全程只建一次复用。
Path? _petalUnitPathCache;
Path _petalUnitPath() =>
    _petalUnitPathCache ??= Path()
      ..moveTo(0, 0.5) // 底部圆端
      ..quadraticBezierTo(0.30, 0.32, 0.27, -0.10) // 右缘鼓肚向上
      ..quadraticBezierTo(0.25, -0.46, 0.0, -0.32) // 升到尖端后折进中央缺口
      ..quadraticBezierTo(-0.25, -0.46, -0.27, -0.10) // 缺口另一侧（V 形小缺口）
      ..quadraticBezierTo(-0.30, 0.32, 0, 0.5) // 左缘鼓肚回底部
      ..close();

/// 三种花瓣的纵向渐变（尖端近白迎光、根部加深成影，造出薄透花瓣的深浅
/// 层次），单位坐标空间内懒建一次复用；每瓣上色走 ColorFilter.modulate 注入
/// alpha（同 _drawUnitHalo 思路），渐变本体零每帧分配。
final List<Shader?> _petalShaderCache = List.filled(3, null);
Shader _petalShaderOf(int kind) {
  final (base, deep) = switch (kind) {
    0 => (const Color(0xFFFFB3CC), const Color(0xFFE888AE)), // 樱粉
    1 => (const Color(0xFFFDF1F4), const Color(0xFFEFCFDA)), // 白粉
    _ => (const Color(0xFFFFDCA8), const Color(0xFFF2BC85)), // 暖杏黄
  };
  return _petalShaderCache[kind] ??= LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [
      Color.lerp(base, Colors.white, 0.72)!, // 尖端近白（花瓣薄透光的迎光面）
      base,
      deep, // 根部加深（背光阴影层次）
    ],
    stops: const [0.0, 0.42, 1.0],
  ).createShader(const Rect.fromLTWH(-0.5, -0.5, 1.0, 1.0));
}

/// 画一个圆形柔光晕：复用单位圆 shader + modulate 上色（同 _drawSoftBlob 思路），
/// 颜色与 alpha 全由 color 注入，与「按粒子 alpha 构建径向渐变」渲染完全等价，
/// 但不再每个粒子每帧分配一个渐变 shader；用完清空 shader/colorFilter。
void _drawUnitHalo(
    Canvas canvas, Paint fill, Offset p, double radius, Color color, Shader shader) {
  canvas.save();
  canvas.translate(p.dx, p.dy);
  canvas.scale(radius, radius);
  fill
    ..shader = shader
    ..colorFilter = ColorFilter.mode(color, BlendMode.modulate);
  canvas.drawCircle(Offset.zero, 1.0, fill);
  fill
    ..shader = null
    ..colorFilter = null;
  canvas.restore();
}

/// 只打印一次的诊断标记：确认 GPU 极光分支真的被执行到。
bool _gpuAuroraLogged = false;

/// 一个视觉图层这一帧的几何与配色快照。
/// 牵手链要同时用到相邻两层的中心/呼吸半径，所以先整帧算齐再逐层画。
class _VInst {
  _VInst({
    required this.effect,
    required this.slot,
    required this.cx,
    required this.cy,
    required this.heartW,
    required this.s,
    required this.pulse,
    required this.breath,
    required this.jitterGain,
    required this.lineK,
    required this.primary,
    required this.light,
  });

  final int effect; // 特效索引
  final int slot; // 参数槽位
  final double cx, cy; // 绘制中心
  final double heartW; // 布局尺寸（爱心宽 / 各特效的基准尺度）
  final double s; // 心形单位坐标 → 像素
  final double pulse; // 本帧心跳量（0..1 左右）
  final double breath; // 心跳呼吸缩放
  final double jitterGain; // 手绘抖动增益
  final double lineK; // 线条粗细倍率（本层自己的 v*.line）
  final Color primary, light; // 本层配色（自选色已解析）
}

class _AmbientPainter extends CustomPainter {
  final double t; // 0~1 循环相位
  final double elapsed; // 累计秒数（雨滴/打湿）
  /// 本帧实际使用的主题色。视觉特效若自选了颜色（`v*.tint`），paint 里会临时把
  /// 它换成那套配色，画完视觉块再恢复 —— 所以这两个不能是 final。
  Color primary;
  Color light;
  final String title;
  final String marqueeText; // 底部跑马灯文本：当前高亮歌词行（无词则回退歌名）
  final String lyricText; // 当前歌词行文本（逐字浮现用；无词为空）
  final String subLyric; // 当前歌词行的子歌词（译文）；无则空串
  final double lyricProgress; // 当前歌词行内进度（0..1）
  final bool hasSong;
  final bool playing;
  final TextScaler textScaler;
  final List<_Drop> drops;
  final List<_Star> stars;
  final List<_Firefly> fireflies;
  final List<_Snow> snows;
  final List<_Bubble> bubbles;
  final List<_Dapple> dapples;
  /// 粒子类视觉特效的粒子表：**按图层槽位**取（同一特效开两层时数量各是各的）。
  final Map<int, List<_GalaxyParticle>> galaxyBySlot;
  final Map<int, List<_HeartParticle>> heartPartsBySlot;
  final Map<int, List<_OrbPoint>> orbBySlot;
  /// 下面三个是「当前正在绘制的那一层」的粒子表，绘制前按槽位换一次。
  /// 画粒子特效的函数体里读的就是它们，所以那几个函数一行都没动（同 primary/light 的招数）。
  List<_GalaxyParticle> galaxy = const [];
  List<_HeartParticle> heartParts = const [];
  List<_OrbPoint> orbPoints = const [];
  final List<_Spark> sparks;
  final List<_Flame> flames;
  final List<_Ripple> ripples;
  final List<_Petal> petals;
  final List<double> spectrum; // 播放栏 37 柱归一化频谱（0..1），边框灯带用
  final Color ambientPrimary; // 氛围主色（雨滴/极光主带/阳光基色）
  final Color ambientLight; // 氛围浅色（星空/气泡描边）
  final bool showHeart; // 视觉区域开关（爱心/旋转方块）
  final bool showAmbient; // 氛围区域开关（雨滴/星空）
  final int ambientEffect; // 氛围动效类型：0 雨滴 / 1 星空 / 2 阳光 / 3 彩星 / 4 萤火虫 / 5 极光 / 6 飘雪 / 7 气泡
  /// 视觉区图层表（只含显示的层，顺序 = 绘制顺序）：同一个特效能同时开多个，
  /// 每个图层一套自己的参数（键带 `#槽位` 上标，见 effect_catalog.fxInstanceKey）。
  final List<VisualLayer> visualLayers;
  /// 每个特效的专属参数（键与含义见 effect_catalog.dart）。
  /// 这里只放用户实际改过的键，缺省由 [fxv] 回落到注册表默认值 —— 绘制端不再维护第二套默认值。
  final Map<String, double> fx;
  final double bass; // 低频能量（0..1），节拍联动
  final double melody; // 旋律能量（0..1，中高频），随旋律起伏变色/变亮
  final bool showEdge; // 边框区域开关
  final int edgeEffect; // 边框动效类型：0 呼吸边框 / 1 流光边框 / 4 歌词跑马灯 / 5 频谱灯带（2 VU、3 聚光已下架）
  final ui.FragmentShader? auroraShader; // 极光 GPU 着色器（null = 退回路径实现）
  final ui.FragmentShader? orbShader; // 能量球 GPU 着色器（null = 退回路径实现）
  final ui.FragmentShader? waterShader; // 水面焦散 GPU 着色器（null = 退回路径实现）

  _AmbientPainter({
    required this.t,
    required this.elapsed,
    required this.primary,
    required this.light,
    required this.title,
    required this.marqueeText,
    required this.lyricText,
    required this.subLyric,
    required this.lyricProgress,
    required this.hasSong,
    required this.playing,
    required this.textScaler,
    required this.drops,
    required this.stars,
    required this.fireflies,
    required this.snows,
    required this.bubbles,
    required this.dapples,
    required this.galaxyBySlot,
    required this.heartPartsBySlot,
    required this.sparks,
    required this.flames,
    required this.ripples,
    required this.petals,
    required this.orbBySlot,
    required this.spectrum,
    required this.ambientPrimary,
    required this.ambientLight,
    required this.showHeart,
    required this.showAmbient,
    required this.ambientEffect,
    required this.visualLayers,
    required this.fx,
    required this.bass,
    required this.melody,
    required this.showEdge,
    required this.edgeEffect,
    required this.auroraShader,
    required this.orbShader,
    required this.waterShader,
  });

  // 预建 Paint 实例复用，避免每帧 new
  final Paint _stroke = Paint()..style = PaintingStyle.stroke;
  final Paint _fill = Paint()..style = PaintingStyle.fill;

  /// 心形参数方程：x=16sin³t, y=13cost−5cos2t−2cos3t−cos4t
  /// 单位坐标 x∈[-16,16]、y∈[-17,5]；屏幕映射加 +6 再取反使心尖在下。
  static Offset heartUnit(double t) {
    final c = cos(t), s = sin(t);
    return Offset(
      16 * s * s * s,
      13 * c - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t),
    );
  }

  /// 每点固定伪随机相位（黄金角分散），不同索引永不重合，避免每帧 new Random。
  static double _phase(int i, double mul) => i * 2.399963 * mul;

  /// 取正模：`(a % b + b) % b`，保证跨循环负值时仍落在 [0,b)。
  static double _wrap(double a, double b) => (a % b + b) % b;

  // ── 特效参数读取 ──────────────────────────────────────────────────────────
  // 前缀按「当前正在绘制的图层」拼：基键 = 该图层的特效（已下架的索引回落到本区第一项），
  // 再带上图层槽位上标（槽位 0 不带，用的就是那套老键）。
  // 存在性判断走 Fx.has，**不能拿某个具体参数键去试**
  // （极光/水面/灯带没有 count、灯带没有 speed，会被误判成下架）。
  int _vIndex = 0; // 当前图层特效索引
  int _vSlot = 0; // 当前图层参数槽位（0 = 老键）
  String get _vBase => Fx.has('v', _vIndex) ? 'v$_vIndex' : 'v0';
  // ⚠️ 这里拼的是**键前缀**（后面 `_v(n)` 会接 `.参数名`），所以必须用
  // `fxInstancePrefix`（`v2` @1 → `v2#1`）。⛔ 别改用 `fxInstanceKey`：
  // 那位的入参是带点的完整基键，给它一个不带点的前缀会**静默原样返回**
  // ⇒ 整层参数都读裸键 ⇒ 「槽位 >0 的图层拖滑杆没反应、反而跟着第 1 层动」。
  String get _vPrefix => fxInstancePrefix(_vBase, _vSlot);
  String get _aPrefix => Fx.has('a', ambientEffect) ? 'a$ambientEffect' : 'a0';
  String get _ePrefix => Fx.has('e', edgeEffect) ? 'e$edgeEffect' : 'e0';

  /// 视觉特效参数（缺省回注册表默认值）
  double _v(String n) => fxv(fx, '$_vPrefix.$n');

  /// 氛围特效参数
  double _a(String n) => fxv(fx, '$_aPrefix.$n');

  /// 边框特效参数
  double _e(String n) => fxv(fx, '$_ePrefix.$n');

  /// 算一个图层这一帧的几何与配色。
  /// [fit] 是牵手链的整排缩放（1.0 = 不缩放，即单颗爱心和改动前逐帧一致）。
  _VInst _layoutVisual(Size size, double fit) {
    // 布局常量：爱心偏大（约 0.6~0.7 屏宽），中心略偏下给上方天条线留空间
    final heartW = min(size.width * 0.66, size.height * 0.52) *
        _v('size') *
        (_vIndex == 0 ? fit : 1.0);
    final s = heartW / 32.0; // 心形参数单位 → 像素
    // 中心位置可调（每个图层各自独立）：x/y 是屏幕宽/高的比例，
    // 默认 0.5 / 0.47 就是旧版的「水平居中、略偏下」。
    final cx = size.width * _v('x');
    final cy = size.height * _v('y');

    // 心跳：lub-dub 双搏动。相位用非线性时间扭曲制造呼吸性心律不齐——
    // 吸气时搏动更密、呼气更疏，节奏自然不再机械；扭曲函数端点对齐，
    // 循环回绕处相位连续，上一拍尾音走完才接下一轮，不再突兀重置。
    // 搏动数取整（随心跳频率参数），保证回绕处相位差恰为整数圈，调速也不跳变。
    // ⚠️ 只有用到 pulse 的特效（爱心 v0、能量光球 v3）才声明 `beat`；没声明的特效
    // 读不到会回落到 0，把搏动数压到下限 3 —— 那会让能量光球的脉动比改动前慢一截。
    // 所以「没有这个参数」时显式按 1.0（旧版 visualSpeed 的默认值）算。
    final beatK = Fx.param('$_vPrefix.beat') == null ? 1.0 : _v('beat');
    final beats = (5 * beatK).round().clamp(3, 12);
    final warp = t + 0.18 * sin(2 * pi * t) / (2 * pi); // 0..1 单调，端点 0/1 对齐
    final u = (beats * warp) % 1.0;
    final pulse = exp(-pow((u - 0.5) / 0.13, 2)) +
        0.55 * exp(-pow((u - 0.5 + 0.22) / 0.09, 2));
    // 未播放更安静；播放时心跳缩放更明显；低频鼓点（bass）叠加额外脉动
    final kick = playing ? bass : 0.0;
    final breath = 1 + (playing ? 0.16 : 0.08) * pulse + 0.08 * kick;
    final jitterGain =
        playing ? (0.7 + 0.9 * pulse + 0.5 * kick) : (0.6 + 0.5 * pulse);

    // 本图层自选颜色：v*.tint ≥ 0 时这一层改用那套配色（含用户自定义色）。
    // 按层解析、按层恢复，所以「一层红心 + 一层蓝万花筒」互不串色。
    var lp = primary;
    var ll = light;
    final vTint = fxc(fx, '$_vPrefix.tint');
    if (vTint >= 0) {
      final c = fxTintColors(vTint, lp, ll);
      lp = c.$1;
      ll = c.$2;
    }
    return _VInst(
      effect: _vIndex,
      slot: _vSlot,
      cx: cx,
      cy: cy,
      heartW: heartW,
      s: s,
      pulse: pulse,
      breath: breath,
      jitterGain: jitterGain,
      lineK: _v('line'),
      primary: lp,
      light: ll,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final savedPrimary = primary;
    final savedLight = light;

    // 爱心开关关掉时，轮廓/边缘线/三圈/流苏/中心歌名一起不画；雨滴独立开关
    if (showHeart) {
      // ── 视觉区：**逐图层**绘制（同一特效能同时开多个，如三颗爱心各调各的）──
      // 牵手链：两颗以上爱心 + 爱心开了「牵手联动」时，整排爱心共用一个缩放，
      // 免得每颗都按 0.66 屏宽画出来彼此压成一团。
      final heartLayers =
          [for (final l in visualLayers) if (l.effect == 0) l];
      final link = heartLayers.length > 1 && fxv(fx, 'v0.link') > 0.5;
      final fit = link ? heartChainFit(heartLayers.length) : 1.0;

      // 每层几何/配色先全部算齐 —— 牵手要拿相邻两颗的精确位置，才能让两只手
      // **正好在中间交汇**，而不是各画各的、在中间错开一截。
      final insts = <_VInst>[];
      for (final l in visualLayers) {
        _vIndex = l.effect;
        _vSlot = l.slot;
        primary = savedPrimary;
        light = savedLight;
        insts.add(_layoutVisual(size, fit));
      }
      final chain = [for (final it in insts) if (it.effect == 0) it];
      if (link) chain.sort((a, b) => a.cx.compareTo(b.cx));

      // 旋律辉光层（光效/辉光层）：柔和的主色柔光随旋律起伏变亮、偏白，
      // 给整屏一层「高级感」暖光；作为最底层，垫在所有动效之下。
      // 多层时只画这一层（用第一层的配色与中心）：画 N 遍只是把底色叠得更亮。
      if (insts.isNotEmpty) {
        final first = insts.first;
        final melodyColor = Color.lerp(first.primary, Colors.white, 0.35 * melody)!;
        final glowR = size.shortestSide * (0.62 + 0.10 * melody);
        _fill.shader = RadialGradient(
          colors: [
            melodyColor.withValues(alpha: 0.05 + 0.16 * melody),
            melodyColor.withValues(alpha: 0.0),
          ],
        ).createShader(
            Rect.fromCircle(center: Offset(first.cx, first.cy), radius: glowR));
        canvas.drawCircle(Offset(first.cx, first.cy), glowR, _fill);
        _fill.shader = null;
      }

      // 手先画、心后画：手是从心最宽点长出来的，被心压住一点才像「从心里伸出来」
      if (link) _paintHeartChain(canvas, size, chain);

      for (final it in insts) {
        // ⚠️ 必须重设「当前图层」：绘制函数内部的 `_v('...')`（线条粗细/抖动/数量…）
        // 全按它取键。不设的话整轮都会读到最后那一层的参数（各层参数就串了）。
        _vIndex = it.effect;
        _vSlot = it.slot;
        primary = it.primary;
        light = it.light;
        galaxy = galaxyBySlot[it.slot] ?? const [];
        heartParts = heartPartsBySlot[it.slot] ?? const [];
        orbPoints = orbBySlot[it.slot] ?? const [];
        switch (it.effect) {
          case 1:
            // 旋转方块：若干对立方体同中心反向旋转（不显示歌名）
            _paintSpinner(canvas, it.cx, it.cy, it.heartW);
            break;
          case 2:
            // 粒子漩涡：大量粒子绕中心螺旋旋转（不显示歌名）
            _paintGalaxy(canvas, it.cx, it.cy, it.heartW);
            break;
          case 3:
            // 能量光球：GPU 湍流球（未就绪时退回路径版柔光球）+ 悬浮歌名
            _paintOrb(canvas, size, it.cx, it.cy, it.heartW, it.pulse);
            break;
          case 4:
            // 粒子聚散：粒子聚成心形再散开（不显示歌名）
            _paintHeartParticles(canvas, it.cx, it.cy, it.s, it.heartW);
            break;
          case 5:
            // 万花筒：多重旋转对称几何线条（不显示歌名）
            _paintKaleidoscope(canvas, it.cx, it.cy, it.heartW);
            break;
          case 6:
            // 3D 深度球：单位球面粒子绕倾斜轴旋转，近大远小有视差
            _paint3DOrb(canvas, it.cx, it.cy, it.heartW);
            break;
          case 7:
            // 歌词逐字浮现：当前歌词行逐字点亮（中区显示）
            _paintLyricReveal(canvas, it.cx, it.cy, it.heartW);
            break;
          default:
            // 爱心（默认）：绘制顺序（z 序自下而上）
            // ① 主轮廓（含心跳冲击波 + 轮廓流光）→ ② 左右边缘线 → ③ 爱心三圈
            // → ④ 心尖火花 → ⑤ 垂落流苏 → ⑥ 中心歌曲名
            // 牵手链里的手由 _paintHeartChain 统一画（两端拉屏幕边缘、中间两两相牵），
            // 所以这里跳过各自的两侧拉线。
            _paintHeartOutline(canvas, it.cx, it.cy, it.s, it.breath, it.pulse);
            if (!link) {
              _paintEdgeLines(
                  canvas, size, it.cx, it.cy, it.s, it.breath, t, it.lineK);
            }
            _paintHeartRings(
                canvas, it.cx, it.cy, it.s, it.breath, it.jitterGain, t, it.pulse);
            _paintHeartSparks(canvas, it.cx, it.cy, it.s, it.pulse);
            _paintTassels(canvas, size, it.cx, it.cy, it.s, it.heartW, it.breath, t);
            _paintTitle(canvas, it.cx, it.cy, it.s, it.heartW, it.breath, it.pulse);
            break;
        }
      }
    }
    // 视觉块画完：恢复主题色，后面的氛围/边框各用各的配色
    primary = savedPrimary;
    light = savedLight;
    if (showAmbient) {
      switch (ambientEffect) {
        case 1:
          _paintStars(canvas, size);
          break;
        case 2:
          _paintDapple(canvas, size);
          break;
        case 3:
          _paintStars(canvas, size, colorful: true);
          break;
        case 4:
          _paintFireflies(canvas, size);
          break;
        case 5:
          _paintAurora(canvas, size);
          break;
        case 6:
          _paintSnow(canvas, size);
          break;
        case 7:
          _paintBubbles(canvas, size);
          break;
        case 8:
          _paintFireworks(canvas, size);
          break;
        // 9 流星已移除（跳号占位，其它索引不漂移）；旧存值落 default 雨滴
        case 10:
          _paintFlames(canvas, size);
          break;
        case 11:
          // 水面：整片水域的焦散光网 / 波光带（不含涟漪圈）
          _paintWaterSurface(canvas, size);
          break;
        case 12:
          _paintPetals(canvas, size);
          break;
        case 13:
          // 波纹：水面上的涟漪圈，全屏散布
          _paintRipples(canvas, size);
          break;
        default:
          _paintRain(canvas, size);
      }
    }
    if (showEdge) {
      switch (edgeEffect) {
        case 1:
          _paintEdgeFlow(canvas, size);
          break;
        // 2 节拍VU环绕已移除（跳号占位，其它索引不漂移）；旧存值落默认呼吸边框
        case 4:
          _paintEdgeMarquee(canvas, size);
          break;
        case 5:
          _paintEdgeSpectrumStrip(canvas, size);
          break;
        default:
          _paintEdgeBreath(canvas, size);
      }
    }
  }

  /// 光滑主轮廓：heartUnit 采样闭合曲线，微抖保留手绘感但不散，
  /// 让爱心形状一眼能认出；内部的抖动折线作为线条纹理。
  void _paintHeartOutline(
      Canvas canvas, double cx, double cy, double s, double breath, double pulse) {
    const samples = 112;
    final path = Path();
    for (var i = 0; i < samples; i++) {
      final theta = 2 * pi * i / samples;
      final hp = heartUnit(theta);
      // 微抖：整数频率 + 黄金角相位，循环首尾无缝
      final jx = sin(theta * 5 + t * 2 * pi * 3) * 1.2;
      final jy = cos(theta * 7 + t * 2 * pi * 4) * 1.2;
      final p = Offset(
        cx + hp.dx * s * 1.08 * breath + jx,
        cy - (hp.dy + 6) * s * 1.08 * breath + jy,
      );
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    // 宽笔柔光衬底 + 细亮主线双层描边：轮廓外围一圈微光、主线更实更亮，
    // 心形从背景里「浮」起来（宽淡层画在主线下方，复用同一路径，构造成本可忽略）
    _stroke
      ..color = primary.withValues(alpha: 0.16)
      ..strokeWidth = 7.5 * _v('line')
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, _stroke);

    // 心跳冲击波：每次搏动把主轮廓整体外推并淡出，心跳才「看得见」。
    // 复用同一条已构造好的 path（仅 canvas 缩放），零额外路径/shader 分配。
    if (pulse > 0.02) {
      final w = pulse.clamp(0.0, 1.0);
      canvas.save();
      canvas.translate(cx, cy);
      canvas.scale(1.0 + 0.26 * w);
      canvas.translate(-cx, -cy);
      _stroke
        ..color = light.withValues(alpha: 0.30 * (1.0 - w))
        ..strokeWidth = (1.4 + 6.0 * w) * _v('line')
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(path, _stroke);
      canvas.restore();
    }

    _drawGlow(canvas, path, primary.withValues(alpha: 0.9), 2.4 * _v('line'));

    // 轮廓流光：一段高光沿主轮廓游走（速度带轻微起伏），让静态线条有电流感。
    // PathMetric 取段 → 每帧一个短 Path，成本可忽略。
    final metrics = path.computeMetrics().toList();
    if (metrics.isNotEmpty && metrics.first.length > 0) {
      final m = metrics.first;
      final total = m.length;
      final head = (t + 0.10 * sin(2 * pi * t)) % 1.0; // 走速有快慢
      const litFrac = 0.12; // 高光段占整圈比例
      final s0 = head * total;
      final s1 = s0 + total * litFrac;
      final lit = Path();
      if (s1 <= total) {
        lit.addPath(m.extractPath(s0, s1), Offset.zero);
      } else {
        lit.addPath(m.extractPath(s0, total), Offset.zero);
        lit.addPath(m.extractPath(0, s1 - total), Offset.zero);
      }
      _stroke
        ..color = Color.lerp(light, Colors.white, 0.5)!.withValues(alpha: 0.60)
        ..strokeWidth = 3.2 * _v('line')
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(lit, _stroke);
    }
  }

  /// 心尖火花：每次心跳从心尖迸出几颗小光点，向外飞散并随搏动淡出。
  /// 光晕走缓存好的单位圆 shader（_drawUnitHalo），每颗只一次 drawCircle。
  void _paintHeartSparks(Canvas canvas, double cx, double cy, double s, double pulse) {
    if (pulse < 0.08) return;
    final w = ((pulse - 0.08) / 0.92).clamp(0.0, 1.0); // 0..1 迸发进度
    final tip = Offset(cx, cy + 11 * s); // 心尖
    final n = _v('sparks').round().clamp(0, 10);
    for (var i = 0; i < n; i++) {
      final ph = i * 2.399963; // 黄金角散开，方向不重复
      final far = 0.6 + 0.4 * ((i % 3) / 2.0); // 远近错落
      final d = w * s * (3.0 + 3.4 * far);
      final p = Offset(
        tip.dx + sin(ph) * d * 0.75,
        tip.dy + d * (0.55 + 0.45 * cos(ph).abs()), // 整体偏向下（心尖方向）
      );
      final r = s * (0.55 + 0.35 * far) * (1.0 - 0.45 * w); // 飞散中变小
      final a = (0.80 * (1.0 - w)).clamp(0.0, 1.0);
      _drawUnitHalo(
          canvas, _fill, p, r, light.withValues(alpha: a), _unitGlowShaderOf());
    }
  }

  /// 爱心三圈抖动折线：每圈由若干段短折线围成，段间留缺口，线条感而非光滑轮廓。
  void _paintHeartRings(Canvas canvas, double cx, double cy, double s, double breath,
      double jitterGain, double t, double pulse) {
    for (var r = 0; r < _rings.length; r++) {
      final cfg = _rings[r];
      // 采样闭合轮廓
      final pts = <Offset>[];
      for (var i = 0; i < cfg.samples; i++) {
        final theta = 2 * pi * i / cfg.samples;
        final hp = heartUnit(theta);
        final j = jitterOf(r, i, t, cfg.jitterAmp * jitterGain * _v('jitter'));
        pts.add(Offset(
          cx + hp.dx * s * cfg.scale * breath + j.dx,
          cy - (hp.dy + 6) * s * cfg.scale * breath + j.dy,
        ));
      }
      // 打断成短折线，段间跳过 cfg.gap 个点，索引取模回绕
      final path = Path();
      for (var start = 0; start < pts.length; start += cfg.segLen + cfg.gap) {
        for (var k = 0; k < cfg.segLen; k++) {
          final p = pts[(start + k) % pts.length];
          if (k == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
      }
      // 亮度随心跳微亮：折线跟着搏动「充能」，不是一条死线
      final a = (cfg.alpha * (0.82 + 0.34 * pulse)).clamp(0.0, 1.0);
      _drawGlow(canvas, path, (cfg.useLight ? light : primary).withValues(alpha: a),
          cfg.strokeWidth * _v('line'));
    }
  }

  /// 抖动位移：整数频率（6/9/7/12）→ t 循环首尾相位一致无缝；黄金角相位分散各点。
  Offset jitterOf(int ringIndex, int i, double t, double amp) {
    final p1 = _phase(i, 1.0);
    final p2 = _phase(i, 2.7) + ringIndex * 1.3;
    return Offset(
      amp * (sin(t * 2 * pi * 6 + p1) + 0.5 * sin(t * 2 * pi * 9 + p2)),
      amp * (cos(t * 2 * pi * 7 + p1 * 0.7) + 0.5 * sin(t * 2 * pi * 12 + p2)),
    );
  }

  /// 画一条主实线。原实现是「宽半透柔光 + 窄实线」双 pass，每帧每个路径画两遍；
  /// 全屏 2K 下栅格化成本高（实测单帧 26ms+，60fps 渲染线程直接饱和）。改成单次绘制，
  /// 保留线条主体、去掉外圈柔光，显著降低每帧 GPU 负载（观感：线条更清晰、柔光减弱）。
  void _drawGlow(Canvas canvas, Path path, Color color, double width) {
    _stroke
      ..color = color
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(path, _stroke);
  }

  /// 垂落流苏：根部全部收在心尖（像拴住），随长度向外撇开，末端摆动最大。
  void _paintTassels(Canvas canvas, Size size, double cx, double cy, double s,
      double heartW, double breath, double t) {
    final tipX = cx;
    final tipY = cy + 11 * s * breath; // 心尖（心形翻转后在下）随心跳呼吸
    final n = _v('tasselN').round().clamp(0, 12);
    if (n == 0) return;
    final lenScale = _v('tassel');
    for (var i = 0; i < n; i++) {
      // 扇形分布：沿用旧版以 (n/2 + 0.5) 为中心的写法，根数 = 8 时与旧版逐根一致
      final half = n / 2 + 0.5;
      final spread = (i - half) / half;
      final len = min(heartW * (0.5 + 0.42 * sin(i * 2.39 + 0.7)) * lenScale,
          size.height * 0.30);
      final drift = spread * 0.12 * heartW; // 整体向外撇
      final swayAmp = heartW * (0.05 + 0.04 * sin(i * 1.7)); // 每根摆幅不同
      final phase = i * 2.399963;
      final path = Path()..moveTo(tipX, tipY);
      Offset last = Offset.zero;
      const kSegs = 9;
      for (var k = 1; k <= kSegs; k++) {
        final v = k / kSegs;
        // 横向偏移从根部 0 渐变到全幅 → 全部从心尖长出，像拴住
        // v² 加权 → 末端摆动最大（像钟摆/藤蔓），整数频率 2/6 循环无缝
        final sway = v * v * swayAmp *
            (sin(t * 2 * pi * 2 + phase) + 0.4 * sin(t * 2 * pi * 6 + phase * 2.7));
        final x = tipX + drift * v + sway;
        final y = tipY + v * len;
        path.lineTo(x, y);
        last = Offset(x, y);
      }
      _drawGlow(canvas, path, light.withValues(alpha: 0.65), 2.0 * _v('line'));
      _fill.color = light.withValues(alpha: 0.7);
      canvas.drawCircle(last, 2.6, _fill); // 末端小珠
    }
  }

  /// 边缘锚线：从心最宽点向屏幕左右边缘各发一束同水平方向、互相纠缠的线，
  /// 终点锚在屏幕边缘（小锚点），像拴在屏幕外的东西上。
  /// [lineK] 由调用方传（牵手链在图层循环外画，不能靠 `_v('line')` 猜是哪一层）。
  void _paintEdgeLines(Canvas canvas, Size size, double cx, double cy, double s,
      double breath, double t, double lineK) {
    final baseY = cy - 10 * s * breath; // 心最宽点，随心跳呼吸移动
    for (var side = -1; side <= 1; side += 2) {
      final startX = cx + side * 16 * s * breath;
      final edgeX = side > 0 ? size.width : 0.0;
      _paintHandBundle(canvas, Offset(startX, baseY), Offset(edgeX, baseY), t,
          lw: 1.8 * lineK);
    }
  }

  /// 一「手」线束：从 [a] 到 [b] 之间若干条同水平方向、互相纠缠的线，
  /// 起止两端由 `sin(pi*u)` 包络锚住（中段才摆），[anchorEnd] 时在终点落一个小锚点。
  /// [lw] 是线条宽度（调用方按该图层的 `v*.line` 算好传进来 ——
  /// 牵手链在图层循环外画，不能靠 `_v('line')` 猜是哪一层）。
  ///
  /// 单颗爱心时它就是改动前那条「屏幕边缘锚线」，逐项一致
  /// （默认 5 条、相位 i*2.399963）；牵手的用法只是把 [b] 换成相邻两颗心的中间点。
  void _paintHandBundle(Canvas canvas, Offset a, Offset b, double t,
      {int seed = 0, bool anchorEnd = true, required double lw, int? lines}) {
    // 手线条数是**整组公共**参数：读不带图层上标的老键，所以三颗爱心共用一个值。
    final n = (lines ?? fxv(fx, 'v0.hands')).clamp(1, 8);
    for (var i = 0; i < n; i++) {
      // 起点/终点都挤在同一水平带（微散布形成一束），整体水平延展
      final off = (i - (n - 1) / 2) * 4.0;
      final startY = a.dy + off;
      final endY = b.dy + off * 1.2;
      final phase = seed + i * 2.399963;
      final amp = 6.0 + (i % 3) * 4.0; // 上下摆动幅度小些，别太胖
      final path = Path()..moveTo(a.dx, startY);
      const kSteps = 22;
      for (var k = 1; k <= kSteps; k++) {
        final u = k / kSteps;
        final x = a.dx + (b.dx - a.dx) * u;
        // sin(pi*u) 包络两端锚定；4 个波折 + 随时间抖动（整数频率无缝），
        // 相位错开 → 线条在中段互相纠缠
        final wave = sin(pi * u) *
            amp *
            (sin(u * 2 * pi * 4 + phase + t * 2 * pi * 2) +
                0.5 * sin(u * 2 * pi * 7 + phase * 2.1 + t * 2 * pi * 3));
        final y = startY + (endY - startY) * u + wave;
        path.lineTo(x, y);
      }
      _drawGlow(canvas, path, light.withValues(alpha: 0.6), lw);
      if (anchorEnd) {
        _fill.color = light.withValues(alpha: 0.9);
        canvas.drawCircle(Offset(b.dx, endY), 2.6, _fill); // 终点小锚点
      }
    }
  }

  /// 牵手链：一排骨碌爱心手拉手。
  /// ① 每颗心最宽点各伸出一只手；② 最左/最右那只拉向屏幕左/右边缘（各留一个小锚点）；
  /// ③ 相邻两颗的手在**中间交汇**，交汇处打一个小结（[v0.knot]，0 = 不打结只交汇）。
  /// 链条按 x 从左到右排序，所以拖动某一颗的水平位置，牵手关系会自己跟着换。
  void _paintHeartChain(Canvas canvas, Size size, List<_VInst> chain) {
    for (var i = 0; i < chain.length; i++) {
      final it = chain[i];
      // 每颗心用自己的浅色画自己的那两只手（两手交汇处就是两种颜色相扣，更好看）。
      // 链条在图层循环外画，所以这里也得自己换色，不能靠上一轮的残留值。
      light = it.light;
      final baseY = it.cy - 10 * it.s * it.breath;
      final left = Offset(it.cx - 16 * it.s * it.breath, baseY);
      final right = Offset(it.cx + 16 * it.s * it.breath, baseY);

      // 左手：最左那颗拉屏幕左边缘，其余与左边那颗在中间交汇
      if (i == 0) {
        _paintHandBundle(canvas, left, Offset(0, baseY), t, lw: 1.8 * it.lineK);
      } else {
        final prev = chain[i - 1];
        final prevBaseY = prev.cy - 10 * prev.s * prev.breath;
        final mid = Offset(
          (prev.cx + 16 * prev.s * prev.breath + left.dx) / 2,
          (prevBaseY + baseY) / 2,
        );
        _paintHandBundle(canvas, left, mid, t,
            seed: i * 7, anchorEnd: false, lw: 1.8 * it.lineK);
      }

      // 右手：最右那颗拉屏幕右边缘，其余与右边那颗在中间交汇并打结
      if (i == chain.length - 1) {
        _paintHandBundle(canvas, right, Offset(size.width, baseY), t,
            lw: 1.8 * it.lineK);
      } else {
        final next = chain[i + 1];
        final nextBaseY = next.cy - 10 * next.s * next.breath;
        final mid = Offset(
          (right.dx + next.cx - 16 * next.s * next.breath) / 2,
          (baseY + nextBaseY) / 2,
        );
        _paintHandBundle(canvas, right, mid, t,
            seed: i * 7 + 3, anchorEnd: false, lw: 1.8 * it.lineK);
        _paintClasp(canvas, mid,
            radius: 0.9 * min(it.s, next.s) * fxv(fx, 'v0.knot'),
            pulse: (it.pulse + next.pulse) * 0.5);
      }
    }
  }

  /// 牵手结：两手心相扣处的一颗小心，随心跳轻轻鼓一下。
  /// [radius] 由 v0.knot 给（0 = 不画，只剩两只手交汇）。
  void _paintClasp(Canvas canvas, Offset c, {required double radius, required double pulse}) {
    if (radius <= 0.5) return;
    final r = radius * (1 + 0.18 * pulse);
    final path = Path();
    const samples = 40;
    for (var i = 0; i < samples; i++) {
      final theta = 2 * pi * i / samples;
      final hp = heartUnit(theta);
      // 心形单位坐标 x∈[-16,16]、y∈[-17,5]：统一缩放到半径 r、心尖朝下
      final p = Offset(c.dx + hp.dx * r / 16.0, c.dy - (hp.dy + 6) * r / 16.0);
      if (i == 0) {
        path.moveTo(p.dx, p.dy);
      } else {
        path.lineTo(p.dx, p.dy);
      }
    }
    path.close();
    _fill.color = light.withValues(alpha: (0.55 + 0.35 * pulse).clamp(0.0, 1.0));
    canvas.drawPath(path, _fill);
    _drawGlow(canvas, path, light.withValues(alpha: 0.9), 1.4 + 0.8 * pulse);
  }

  /// 爱心中间歌曲名：吊在顶部凹陷尖端，用定长线拴着，随心跳在隐形边框内随机摆动；
  /// 文本始终水平（不翻转/不横过来），只做平面平移，2 行内省略号。
  void _paintTitle(Canvas canvas, double cx, double cy, double s, double heartW,
      double breath, double pulse) {
    // 先按原公式算并 clamp，再乘用户倍率 —— 保证「倍率 = 1」时与旧版字号逐像素一致
    final fontSize = ((heartW * 0.075).clamp(14.0, 32.0) * _v('title')).toDouble();
    final style = TextStyle(
      color: hasSong
          ? light.withValues(alpha: 0.92)
          : Colors.white.withValues(alpha: 0.55),
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.5,
    );
    final tp = _layoutTitleCached(title, style, heartW * 0.58, textScaler);

    // 悬挂点：顶部凹陷尖端（两个凸起之间向下垂的尖），随心跳呼吸上下浮动
    final anchor = Offset(cx, cy - 11 * s * breath);

    // 定长拴绳：从尖端垂到心腔中心（比原来抬高，处于爱心视觉中心），长度不随心跳/摆动改变
    final lineLen = 7.0 * s;

    // 隐形边框：歌名中心被约束在其中（不可见，仅作摆动边界）
    final boxHalfW = heartW * 0.22;
    final boxHalfH = heartW * 0.09;
    final boxCenter = Offset(cx, cy - 4 * s);

    // 钟摆角：垂直向下为 0，左右摆动；多路非整数频率叠加 → 看似随机，
    // 幅度受心跳 pulse 调制（跳得越强甩得越开）
    final swingAmp = (playing ? 0.38 : 0.24) * (0.5 + 0.5 * pulse);
    final ang = swingAmp *
        (0.6 * sin(elapsed * 1.9) +
            0.5 * sin(elapsed * 2.7 + 1.8) +
            0.35 * sin(elapsed * 4.3 + 3.3)) /
        1.45;

    // 歌名中心（钟摆末端，线长恒定），再约束进隐形边框
    var songC = Offset(
      anchor.dx + sin(ang) * lineLen,
      anchor.dy + cos(ang) * lineLen,
    );
    songC = Offset(
      songC.dx.clamp(boxCenter.dx - boxHalfW, boxCenter.dx + boxHalfW).toDouble(),
      songC.dy.clamp(boxCenter.dy - boxHalfH, boxCenter.dy + boxHalfH).toDouble(),
    );

    // 拴绳：从悬挂点连到歌名顶部中点
    final top = Offset(songC.dx, songC.dy - tp.height / 2);
    _stroke
      ..color = light.withValues(alpha: 0.35)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(anchor, top, _stroke);

    // 歌名文本：始终保持水平（不旋转），只随摆动平移
    tp.paint(canvas, Offset(songC.dx - tp.width / 2, top.dy));
  }

  /// 视觉动效：若干对立方体（3D 线框）同中心、各绕一条体对角线反向旋转，
  /// 透视投影增强三维感；不显示歌名。
  /// 参数：方块对数 / 旋转速度 / 立体深度（透视强度）/ 线条粗细，见 v1.*。
  ///
  /// 第 1 对就是**原来那两个立方体**：一颗绕 (1,1,1) 轴 +0.25 圈/秒（主色 0.85），
  /// 另一颗绕 (1,-1,1) 轴 −0.18 圈/秒（浅色 0.80）—— 两根**不同**体对角线交叉翻滚。
  /// 所以 catalog 里「方块对数」默认必须是 1；第 2、3 对是加分项，轴/转速另配。
  void _paintSpinner(Canvas canvas, double cx, double cy, double heartW) {
    final speed = _v('spin');
    final pairs = _v('count').round().clamp(1, 3);
    final k = 1 / sqrt(3.0);
    final h = heartW * 0.22; // 每对都一样大（旧版观感）
    // (正向那颗的轴, 角速度, 反向那颗的轴, 角速度)，角速度单位 圈/秒
    const cfg = [
      ([1.0, 1.0, 1.0], 0.25, [1.0, -1.0, 1.0], -0.18), // 旧版原样
      ([1.0, -1.0, 1.0], 0.18, [1.0, 1.0, 1.0], -0.13),
      ([-1.0, 1.0, 1.0], 0.13, [-1.0, -1.0, 1.0], -0.09),
    ];
    for (var i = 0; i < pairs; i++) {
      final (a1, s1, a2, s2) = cfg[i];
      _paintCube(canvas, cx, cy, h, a1[0] * k, a1[1] * k, a1[2] * k,
          elapsed * 2 * pi * s1 * speed, primary.withValues(alpha: 0.85));
      _paintCube(canvas, cx, cy, h, a2[0] * k, a2[1] * k, a2[2] * k,
          elapsed * 2 * pi * s2 * speed, light.withValues(alpha: 0.80));
    }
  }

  /// 画一个绕体对角线轴旋转的立方体线框（8 顶点 + 12 棱），透视投影。
  /// 轴 (ax,ay,az) 需为单位向量。
  /// 面填充版（假光照 + 顶点节点）已按用户反馈回滚 —— 实心块不如线框清爽。
  void _paintCube(Canvas canvas, double cx, double cy, double h, double ax, double ay,
      double az, double ang, Color color) {
    // 8 顶点（±h, ±h, ±h）
    final verts = <List<double>>[
      for (final x in [-h, h])
        for (final y in [-h, h])
          for (final z in [-h, h]) [x, y, z],
    ];
    // 旋转 + 透视投影（相机距离 = 5h / 立体深度，深度越大近处越"顶出来"）
    final d = h * 5 / _v('depth');
    final proj = <Offset>[];
    for (final v in verts) {
      final r = _rotAxis(v[0], v[1], v[2], ax, ay, az, ang);
      final persp = d / (d - r[2]);
      proj.add(Offset(cx + r[0] * persp, cy + r[1] * persp));
    }
    // 12 条棱：两个 x 面各 4 边 + 4 条连接棱
    const edges = [
      [0, 1], [1, 3], [3, 2], [2, 0], // x=-h 面
      [4, 5], [5, 7], [7, 6], [6, 4], // x=+h 面
      [0, 4], [1, 5], [2, 6], [3, 7], // 连接棱
    ];
    final path = Path();
    for (final e in edges) {
      path.moveTo(proj[e[0]].dx, proj[e[0]].dy);
      path.lineTo(proj[e[1]].dx, proj[e[1]].dy);
    }
    _drawGlow(canvas, path, color, 1.8 * _v('line'));
  }

  /// Rodrigues 旋转：绕单位轴 (ax,ay,az) 旋转 ang，返回旋转后的 (x,y,z)。
  List<double> _rotAxis(double x, double y, double z, double ax, double ay, double az,
      double ang) {
    final c = cos(ang), s = sin(ang);
    final dot = x * ax + y * ay + z * az;
    final crossX = ay * z - az * y;
    final crossY = az * x - ax * z;
    final crossZ = ax * y - ay * x;
    return [
      x * c + crossX * s + ax * dot * (1 - c),
      y * c + crossY * s + ay * dot * (1 - c),
      z * c + crossZ * s + az * dot * (1 - c),
    ];
  }

  /// 小雨滴（细长雨丝风）：Wallpaper Engine 式雨丝——沿下落方向画带长度的
  /// 线段（前段亮、尾段淡两段纯色，零 shader 开销），无水滴头圆点；雨丝以
  /// 垂直为主、每根角度随机（左右各种偏斜，生成端三角分布）+ 微摆，按景深
  /// 远/中/近三层（粗细亮度长短速度在生成端分层，近处粗亮长快、远处细淡短慢）；
  /// 周期内重力加速（前慢后快），落到底溅起水花（涟漪摊开 + 两颗小水珠弹起）；
  /// 雨丝偏白地混入主题色（半透明白亮丝）；低频鼓点（bass）时雨速微增。
  /// 性能：每滴每帧仅 2 条线段（主体+尾段，纯色无 shader），rainCount=100
  /// 时最坏 200 条线段，远低于飘雪六角结晶的量级。
  void _paintRain(Canvas canvas, Size size) {
    // bass 加速削弱并柔和：避免鼓点跳变让雨速忽快忽慢显得一卡一卡
    final speedBoost = 1.0 * (1.0 + 0.18 * bass) * _a('speed');
    final splash = fxo(fx, '$_aPrefix.splash'); // 落地水花开关
    final h = size.height;
    // 雨丝本色：**纯白水光，不跟氛围色调走**（色调只染氛围色，不染水）。
    // 副歌段整片雨幕更「亮」靠提亮 alpha 实现，而不是给雨丝染色。
    const streak = Color(0xFFFFFFFF);
    final bright = 1.0 + 0.25 * melody;
    for (final d in drops) {
      final p0 = (d.y0 + elapsed * d.speed * speedBoost) % 1.0;
      // 重力加速：周期内 p0^1.5 缓入（前慢后快），落到底部溅起水花后重置
      final progress = p0 * sqrt(p0);
      final dropLen = d.len * h; // 雨丝长度（长短在生成端按景深层已定）
      // 顶端（拖尾）y：从屏幕上方外进入，落到底部
      final topY = progress * (h + dropLen) - dropLen;
      final sway = sin(elapsed * 2 * pi * 0.3 + d.swayPhase) * d.swayAmp * size.width;
      final topX = d.x * size.width + d.tilt * topY + sway;
      // 底端（下落前端）：沿下落方向斜出（各丝偏斜方向随生成端 tilt，可左可右）
      final tipX = topX + d.tilt * dropLen;
      final tipY = topY + dropLen;
      // 亮度：进场淡入
      final aBase =
          (d.alpha * (progress / 0.05).clamp(0.0, 1.0) * bright).clamp(0.0, 1.0);
      if (aBase <= 0.01) continue;
      // 主体雨丝分两段：前段亮、后段淡，拖出「头重尾轻」的渐隐雨丝
      // （纯色两段模拟线性渐隐，复用单例 _stroke，零 shader 分配）
      final midX = topX + d.tilt * dropLen * 0.5;
      final midY = topY + dropLen * 0.5;
      _stroke
        ..shader = null
        ..color = streak.withValues(alpha: aBase)
        ..strokeWidth = d.width
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(midX, midY), Offset(tipX, tipY), _stroke);
      _stroke.color = streak.withValues(alpha: aBase * 0.4);
      canvas.drawLine(Offset(topX, topY), Offset(midX, midY), _stroke);
      // 落地溅落：周期末段触底——涟漪扁椭圆摊开 + 左右各弹起一颗小水珠
      // （只有约 3.5% 周期的雨丝同时处于触底段，额外绘制量可忽略）
      if (splash && progress > 0.965) {
        final q = (progress - 0.965) / 0.035; // 0..1 溅落进度
        final sa = aBase * (1.0 - q);
        _stroke
          ..color = streak.withValues(alpha: sa * 0.55)
          ..strokeWidth = 1.0;
        canvas.drawOval(
            Rect.fromCenter(
                center: Offset(tipX, h - 1.5),
                width: 4.0 + q * 16.0,
                height: 1.6 + q * 3.0),
            _stroke);
        _fill.color = streak.withValues(alpha: sa * 0.8);
        final hop = sin(q * pi) * h * 0.010; // 抛物线起落
        canvas.drawCircle(Offset(tipX - q * 7.0, h - 2.0 - hop), 1.1, _fill);
        canvas.drawCircle(Offset(tipX + q * 7.0, h - 2.0 - hop * 0.8), 1.0, _fill);
      }
    }
  }

  /// 星空：三档光点（碎星/普通星/带十字的大星），纯白高亮、中心带刺眼核心。
  /// 每颗星在随机位置停留一段生命期后淡出，再换到随机新位置淡入，随时间流动。
  void _paintStars(Canvas canvas, Size size, {bool colorful = false}) {
    // 彩星**用户自己选过颜色**时：星点色相围着它转（±45°），不再全随机 ——
    // 否则颜色选择对彩星完全看不出效果。没选过（缺省水蓝）保持全随机的彩，默认观感不变。
    // ⚠️ 要用「选过没」（fxcSet）判断，不能用解析后的槽位值：缺省本身也是个颜色。
    final baseHue = (colorful && fxcSet(fx, '$_aPrefix.tint'))
        ? HSVColor.fromColor(ambientPrimary).hue
        : null;
    // 星云底 + 偶发流星：先铺一层极淡的彩色雾光（银河感），星星画完再叠流星
    _paintNebula(canvas, size, colorful, baseHue);
    final glow = 1.1 + 0.6 * bass; // 基线更高，整体更通透
    for (final d in stars) {
      // 生命周期：位置随周期变化，周期边界淡入/淡出柔和切换
      final cycle = (elapsed / d.life).floor();
      final t = elapsed - cycle * d.life; // 周期内时间
      final fadeIn = (t / 0.8).clamp(0.0, 1.0);
      final fadeOut = ((d.life - t) / 0.8).clamp(0.0, 1.0);
      final fade = fadeIn < fadeOut ? fadeIn : fadeOut;
      if (fade <= 0.01) continue;
      final x = _starRand(d.seed + cycle * 7919); // 该周期随机位置
      final y = _starRand(d.seed + cycle * 7919 + 104729);
      final tw = 0.5 + 0.5 * sin(elapsed * d.twinkleSpeed * 2 * pi + d.phase);
      final a = (d.baseAlpha * (0.7 + 0.3 * tw) * glow * fade).clamp(0.0, 1.0);
      if (a <= 0.02) continue;
      final p = Offset(x * size.width, y * size.height);
      final c = colorful ? _starColor(d.seed, baseHue: baseHue) : ambientLight; // 彩星 / 星空浅色（随色调）
      // 大星：柔光晕（径向渐变，无硬边圆盘）+ 十字光芒（两端渐隐，柔和星芒）
      // 光晕与十字全部复用单位 shader + modulate 上色：与按 a 逐星构建渐变
      // 渲染完全等价，但每颗大星每帧不再分配 3 个渐变 shader
      if (d.cross) {
        final l = d.r * 5.0; // 十字光芒更长更舒展
        _drawUnitHalo(canvas, _fill, p, l, c.withValues(alpha: a), _haloStarOf());
        // 十字线：等比缩放到长度 l 后画单位线段，线宽除回 l 保持 1.1px 不变；
        // 竖线在缩放前旋转 90° 对齐方向（等比变换下圆头笔帽粗细不变）
        final cross = _crossShaderOf();
        final tint = ColorFilter.mode(c.withValues(alpha: a), BlendMode.modulate);
        _stroke
          ..strokeWidth = 1.1 / l
          ..strokeCap = StrokeCap.round;
        for (var vertical = 0; vertical < 2; vertical++) {
          canvas.save();
          canvas.translate(p.dx, p.dy);
          if (vertical == 1) canvas.rotate(pi / 2);
          canvas.scale(l, l);
          _stroke
            ..shader = cross
            ..colorFilter = tint;
          canvas.drawLine(const Offset(-1.0, 0.0), const Offset(1.0, 0.0), _stroke);
          canvas.restore();
        }
        _stroke
          ..shader = null
          ..colorFilter = null;
      }
      // 星点本体 + 中心高光核：更大更亮，偏白刺眼
      _fill.color = c.withValues(alpha: a);
      canvas.drawCircle(p, d.r, _fill);
      final core = Color.lerp(c, Colors.white, 0.72)!;
      _fill.color = core.withValues(alpha: (a * 1.3).clamp(0.0, 1.0));
      canvas.drawCircle(p, d.r * 0.65, _fill);
    }
  }

  /// 星云底：几团缓慢漂移的大而极淡的彩色雾光，叠出「银河」底色。
  /// 复用缓存的单位柔光 shader（_drawSoftBlob），每团一次绘制、零渐变分配。
  void _paintNebula(Canvas canvas, Size size, bool colorful, [double? baseHue]) {
    final neb = _a('nebula'); // 星云浓度：0 = 不要雾底
    if (neb <= 0) return;
    const blobs = 5;
    for (var i = 0; i < blobs; i++) {
      final ph = i * 2.399963;
      final sx = 0.5 + 0.42 * sin(elapsed * 0.035 + ph);
      final sy = 0.42 + 0.34 * cos(elapsed * 0.028 + ph * 1.7);
      final rx = size.width * (0.30 + 0.10 * sin(ph * 2.1));
      final ry = rx * (0.45 + 0.15 * cos(ph));
      final c = colorful
          ? Color.lerp(ambientPrimary, _starColor(i * 977, baseHue: baseHue), 0.6)!
          : Color.lerp(ambientPrimary, ambientLight, 0.35)!;
      // 极低 alpha + 旋律时略亮：是「雾」不是「块」，不能抢星星
      _drawSoftBlob(canvas, Offset(sx * size.width, sy * size.height), rx, ry, ph,
          c.withValues(alpha: (0.045 + 0.030 * melody) * neb));
    }
  }

  // 偶发流星已移除：星空/彩星里偶尔划过的那道光是升级时加的，用户反馈多余。

  /// 阳光（斑驳光影）：躺在树底下、阳光透过树叶洒下的斑驳光影。
  /// 三层叠加——① 深色叶影（阴）垫底 ② 纯弥散暖光团浮中层 ③ 几点强光（亮核+光晕）最上层。
  /// 强光周围大而模糊、中心亮核，暖光团柔和无核，稀疏克制避免糊成一片黄。颜色固定暖黄/深绿，不随主题色。
  void _paintDapple(Canvas canvas, Size size) {
    // 暖度：把固定暖黄往白里混（0 = 纯暖黄原色，1 = 明显偏白亮）
    final sunWarm = Color.lerp(_sunWarm, Colors.white, _a('warm') * 0.45)!;
    // ① 叶影（暗斑）垫底，铺出「树荫下」的底色层次
    for (final d in dapples) {
      if (d.kind != 0) continue;
      final a = _dappleAlpha(d);
      if (a <= 0.01) continue;
      final p = _dapplePos(d, size);
      _drawSoftBlob(canvas, p, d.rx * size.width, d.ry * size.height, d.rot,
          _leafShadow.withValues(alpha: a));
    }
    // ② 暖光团：纯弥散暖光（无核），柔和浮中层
    for (final d in dapples) {
      if (d.kind != 2) continue;
      final a = _dappleAlpha(d);
      if (a <= 0.02) continue;
      final p = _dapplePos(d, size);
      _drawSoftBlob(canvas, p, d.rx * size.width, d.ry * size.height, d.rot,
          sunWarm.withValues(alpha: a));
    }
    // ③ 强光：大而弥散的光晕（周围模糊）+ 中心偏白小亮核，模拟太阳透过树缝
    for (final d in dapples) {
      if (d.kind != 1) continue;
      final a = _dappleAlpha(d);
      if (a <= 0.02) continue;
      final p = _dapplePos(d, size);
      final rx = d.rx * size.width;
      final ry = d.ry * size.height;
      // 光晕：放大一圈的暖黄弥散，周围模糊渐隐
      _drawSoftBlob(canvas, p, rx * 2.4, ry * 2.4, d.rot,
          sunWarm.withValues(alpha: a * 0.55));
      // 亮核：偏白的小软斑（同样柔和无硬边），最亮处
      _drawSoftBlob(canvas, p, rx * 0.5, ry * 0.5, d.rot,
          Color.lerp(sunWarm, Colors.white, 0.55)!
              .withValues(alpha: (a * 1.2).clamp(0.0, 1.0)));
    }
    // 太阳光束（斜向平行四边形光柱）已移除：那是硬边几何条，看着像几条斜色块
    // 「怪怪的」（用户反馈），斑驳光影本身已经能表达「树荫下透光」。
    // 保留下面的空气浮尘 —— 微小亮点漂浮本身很自然，不需要依附光柱。
    final dust = _a('dust').round().clamp(0, 40);
    for (var i = 0; i < dust; i++) {
      final ph = i * 2.399963;
      final fy = (elapsed * (0.012 + 0.006 * (i % 3)) + ph * 0.13) % 1.0;
      final fx0 = 0.15 + 0.70 * ((ph * 0.159) % 1.0) + sin(elapsed * 0.25 + ph) * 0.02;
      final fade = (1.0 - (fy - 0.5).abs() * 1.2).clamp(0.0, 1.0); // 上下淡出
      final a = ((0.10 + 0.10 * sin(elapsed * 0.7 + ph * 2.0)).clamp(0.0, 0.22)) * fade;
      if (a <= 0.01) continue;
      _fill.color = Color.lerp(sunWarm, Colors.white, 0.6)!.withValues(alpha: a);
      canvas.drawCircle(Offset(fx0 * size.width, fy * size.height), 1.3, _fill);
    }
  }

  /// 光斑/叶影的透明度：生命周期首尾淡入淡出 + 不对称呼吸（枝叶间透光忽明忽暗）。
  double _dappleAlpha(_Dapple d) {
    final cycle = (elapsed / d.life).floor();
    final t = elapsed - cycle * d.life; // 周期内时间
    final fadeIn = (t / 0.8).clamp(0.0, 1.0);
    final fadeOut = ((d.life - t) / 0.8).clamp(0.0, 1.0);
    final fade = fadeIn < fadeOut ? fadeIn : fadeOut;
    final breathe = 0.5 + 0.5 * sin(elapsed * d.breatheSpeed * 2 * pi + d.phase);
    return (d.baseAlpha * (0.45 + 0.55 * breathe) * fade).clamp(0.0, 1.0);
  }

  /// 光斑/叶影的位置：每个生命周期换一个随机基位置（seed 确定性生成），周期内缓慢游走。
  Offset _dapplePos(_Dapple d, Size size) {
    final cycle = (elapsed / d.life).floor();
    final bx = _starRand(d.seed + cycle * 7919); // 该周期随机位置
    final by = _starRand(d.seed + cycle * 7919 + 104729);
    final wx = sin(elapsed * d.driftSpeed + d.phase) * d.amp;
    final wy = cos(elapsed * d.driftSpeed * 0.7 + d.phase * 1.3) * d.amp;
    return Offset((bx + wx) * size.width, (by + wy) * size.height);
  }

  /// 画一个柔和椭圆软斑：用 canvas 缩放把单位圆渐变压成与光斑同形状的椭圆渐变，
  /// 渐变与光斑完全同形，边缘（长/短轴端点）都平滑归零，杜绝可见的椭圆弧线硬边。
  /// 非线性 stops 模拟高斯光晕：中心亮、快速柔和消散，像真实光斑没有边界。
  void _drawSoftBlob(Canvas canvas, Offset p, double rx, double ry, double rot, Color color) {
    canvas.save();
    canvas.translate(p.dx, p.dy);
    canvas.rotate(rot);
    canvas.scale(rx, ry);
    // 复用 _fill 画笔 + 渐变 shader，用完清空，避免每帧每个斑块 new Paint
    // 复用白色单位渐变 shader + modulate 上色：颜色与 alpha 全由 color 注入
    //（alpha = color.a × 渐变），与原「渲染改 alpha 的 RadialGradient」完全等价，
    // 但整个重绘循环只 createShader 一次，不再每个斑每帧分配一个渐变。
    _fill
      ..shader = _unitGlowShaderOf()
      ..colorFilter = ColorFilter.mode(color, BlendMode.modulate);
    canvas.drawOval(Rect.fromCircle(center: Offset.zero, radius: 1.0), _fill);
    _fill
      ..shader = null
      ..colorFilter = null;
    canvas.restore();
  }

  /// 萤火虫：暖黄/暖绿小光点，在基位置附近缓慢游走（利萨如漂移）+ 忽明忽暗，
  /// 带柔和光晕，营造「会飞」的氛围。生命周期换位同星空。
  void _paintFireflies(Canvas canvas, Size size) {
    for (final d in fireflies) {
      final cycle = (elapsed / d.life).floor();
      final t = elapsed - cycle * d.life;
      final fadeIn = (t / 1.2).clamp(0.0, 1.0);
      final fadeOut = ((d.life - t) / 1.2).clamp(0.0, 1.0);
      final fade = fadeIn < fadeOut ? fadeIn : fadeOut;
      if (fade <= 0.01) continue;
      // 基位置（该周期随机）+ 利萨如游走
      final bx = _starRand(d.seed + cycle * 7919);
      final by = _starRand(d.seed + cycle * 7919 + 104729);
      final wx = sin(elapsed * d.driftSpeed + d.phase) * d.amp;
      final wy = cos(elapsed * d.driftSpeed * 0.7 + d.phase * 1.3) * d.amp;
      final p = Offset((bx + wx) * size.width, (by + wy) * size.height);
      // 忽明忽暗：不对称呼吸（亮多暗少，更像萤火虫明灭）
      final tw = 0.5 + 0.5 * sin(elapsed * d.glowSpeed * 2 * pi + d.phase);
      final a = (d.baseAlpha * (0.35 + 0.65 * tw) * fade).clamp(0.0, 1.0);
      if (a <= 0.02) continue;
      final c = d.green ? const Color(0xFFB8FF9E) : const Color(0xFFEFFF8A);
      // 柔光晕（复用单位 shader，零分配，更大更通透）+ 中心亮点 + 白热小核
      _drawUnitHalo(canvas, _fill, p, d.r * 5.2 * _a('glow'), c.withValues(alpha: a),
          _haloFireflyOf());
      _fill.color = c.withValues(alpha: a);
      canvas.drawCircle(p, d.r, _fill);
      _fill.color = Color.lerp(c, Colors.white, 0.55)!
          .withValues(alpha: (a * 0.9).clamp(0.0, 1.0));
      canvas.drawCircle(p, d.r * 0.5, _fill);
    }
  }

  /// 极光：顶部几条流动的彩色光带，正弦扰动 + 竖向线性渐变（上亮下透明），
  /// blur 柔化避免硬边，缓慢横向流动。色相随氛围色调。
  void _paintAurora(Canvas canvas, Size size) {
    // 优先走 GPU 噪声帘幕（真·极光）；着色器未就绪/不可用时退回下面的路径实现
    final sh = auroraShader;
    if (sh != null) {
      if (!_gpuAuroraLogged) {
        _gpuAuroraLogged = true;
        debugPrint('FxShaders: aurora GPU path ACTIVE');
      }
      _paintAuroraGpu(canvas, sh, size);
      return;
    }
    const bands = 4; // 四条光带（多一条高位淡带，层次更满）
    final w = size.width;
    final h = size.height;
    final speed = _a('speed'); // 流动速度
    final amp0 = _a('alpha'); // 光带亮度
    final beat = _a('beat'); // 节拍响应
    final (ca, cb) = _auroraColors();
    final blur = Paint()
      ..style = PaintingStyle.fill
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18); // 更柔的光雾
    for (var b = 0; b < bands; b++) {
      final baseY = h * (0.08 + b * 0.11); // 光带中心 y
      final amp =
          h * (0.05 + b * 0.018) * (1.0 + 0.25 * bass * beat); // 鼓点让光带荡得更开
      final thickness = h * (0.11 - b * 0.018); // 光带厚度
      // 双色渐变：每条带从主色到浅色按高度混开，上下色彩过渡更绚丽
      final c = Color.lerp(ca, cb, b / (bands - 1) * 0.75)!;
      final phase = b * 2.1;
      // 上/下边界两条波浪线，围成光带
      final topPts = <Offset>[];
      final bottomPts = <Offset>[];
      const steps = 48;
      for (var i = 0; i <= steps; i++) {
        final u = i / steps;
        final x = u * w;
        final wave = sin(u * 2 * pi * 2 + elapsed * 0.5 * speed + phase) * amp +
            sin(u * 2 * pi * 5 - elapsed * 0.8 * speed + phase * 2.7) * amp * 0.5 +
            sin(u * 2 * pi * 8 + elapsed * 0.35 * speed + phase * 1.7) * amp * 0.22;
        topPts.add(Offset(x, baseY + wave - thickness * 0.5));
        bottomPts.add(Offset(x, baseY + wave + thickness * 0.5));
      }
      final band = Path()..moveTo(topPts.first.dx, topPts.first.dy);
      for (final pt in topPts.skip(1)) {
        band.lineTo(pt.dx, pt.dy);
      }
      for (final pt in bottomPts.reversed) {
        band.lineTo(pt.dx, pt.dy);
      }
      band.close();
      final shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          c.withValues(alpha: (0.68 * amp0).clamp(0.0, 1.0)),
          c.withValues(alpha: (0.26 * amp0).clamp(0.0, 1.0)),
          c.withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.55, 1.0],
      ).createShader(Rect.fromLTWH(0, baseY - thickness, w, thickness * 2));
      blur.shader = shader;
      canvas.drawPath(band, blur);
      // 纯柔光带：不做任何描边/亮缘线，靠渐变+blur 自然收边，观感更柔和耐看
    }
  }

  /// 极光双色：主色 ↔ 浅色按「主色↔浅色」参数混开（0 全主色 / 1 全浅色再偏白）。
  (Color, Color) _auroraColors() {
    final mix = _a('mix').clamp(0.0, 1.0);
    return (
      Color.lerp(ambientPrimary, ambientLight, mix * 0.55)!,
      Color.lerp(ambientLight, Colors.white, 0.25 * mix)!,
    );
  }

  /// 极光（GPU 实现）：分层 fbm 噪声帘幕，顶部成片、向下散成丝缕，双色随主题。
  /// 按**全尺寸**绘制：早先想用 `canvas.scale(0.5)` 做「半分辨率省算力」，但那样
  /// 矩形在设备空间只占左上角 1/4（极光只剩一小块，屏幕其余处全透明），而且
  /// Skia 仍按设备像素求值、根本不省算力 —— 真要省得离屏渲染小图再放大。
  void _paintAuroraGpu(Canvas canvas, ui.FragmentShader sh, Size size) {
    final w = size.width;
    final h = size.height;
    // uniform 顺序与 shaders/aurora.frag 的声明一一对应（vec2/vec3 各占 2/3 个槽）
    sh.setFloat(0, w);
    sh.setFloat(1, h);
    sh.setFloat(2, elapsed * _a('speed')); // 流动速度：缩放喂给着色器的时间即可
    sh.setFloat(3, (bass * _a('beat')).clamp(0.0, 1.0)); // 节拍响应
    sh.setFloat(4, melody);
    final (ca, cb) = _auroraColors();
    sh.setFloat(5, ca.r);
    sh.setFloat(6, ca.g);
    sh.setFloat(7, ca.b);
    sh.setFloat(8, cb.r);
    sh.setFloat(9, cb.g);
    sh.setFloat(10, cb.b);
    sh.setFloat(11, _a('alpha')); // uAlpha：光带整体亮度
    _fill
      ..shader = sh
      ..colorFilter = null;
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), _fill);
    _fill.shader = null;
  }

  /// 飘雪：六角结晶 + 柔光圆点，缓慢自转（正反转各半）、摆动飘落 + 缓慢横漂。
  /// 按片数做 LOD 分级控制线段开销（每结晶片 6 主臂 + 单级侧枝，至多 18 线）：
  /// · 片数 ≤ 40：精细六角（6 主臂 + 55% 处 ±60° 双侧枝，18 线/片）；
  /// · 片数 ≤ 80：简化六芒星（仅 6 主臂，6 线/片）；
  /// · 片数 > 80：全部柔光圆点（0 线/片，大者加亮核），最坏情况也流畅。
  /// 最坏线段数：40×18=720 / 80×6=480 / >80 为 0，远低于旧版全精细的 3600+。
  /// 小雪粒始终为柔光圆点垫远层。速度受 rainSpeed 调制。
  void _paintSnow(Canvas canvas, Size size) {
    final n = snows.length;
    // LOD 档位：2=精细六角 1=简化六芒星 0=纯光点（关掉「六角结晶」则强制纯光点档）
    final lod = !fxo(fx, '$_aPrefix.crystal')
        ? 0
        : (n <= 40 ? 2 : (n <= 80 ? 1 : 0));
    final speed = _a('speed');
    for (final d in snows) {
      final progress = (d.y0 + elapsed * d.speed * speed) % 1.0;
      final y = progress * size.height;
      final sway = sin(elapsed * 2 * pi * 0.25 + d.swayPhase) * d.swayAmp * size.width;
      final drift = (elapsed * d.drift * size.width) % size.width;
      final x = (d.x * size.width + sway + drift) % size.width;
      final p = Offset(x, y);
      if (d.size >= 2.0 && lod > 0) {
        // 结晶：六主臂；精细档再加单级侧枝（55% 处 ±60° 伸枝）
        final L = d.size * 2.7; // 主臂长
        final rot = rot6(d, elapsed); // 自转角（每片算一次）
        final a = d.alpha;
        _drawUnitHalo(canvas, _fill, p, L * 0.9,
            Colors.white.withValues(alpha: a * 0.5), _haloSnowOf());
        _stroke
          ..shader = null
          ..color = Colors.white.withValues(alpha: a)
          ..strokeWidth = 1.1
          ..strokeCap = StrokeCap.round;
        for (var k = 0; k < 6; k++) {
          final ang = rot + k * pi / 3;
          final cA = cos(ang), sA = sin(ang);
          canvas.drawLine(p, Offset(p.dx + cA * L, p.dy + sA * L), _stroke);
          if (lod == 2) {
            // 单级侧枝：主臂 55% 处向两侧 ±60° 伸短枝（每臂 2 线，共 12 线）
            final bx = p.dx + cA * L * 0.55;
            final by = p.dy + sA * L * 0.55;
            for (final side in const [-1.0, 1.0]) {
              final bang = ang + side * pi / 3;
              canvas.drawLine(
                  Offset(bx, by),
                  Offset(bx + cos(bang) * L * 0.34, by + sin(bang) * L * 0.34),
                  _stroke);
            }
          }
        }
        // 中心小板芯
        _fill.color = Colors.white.withValues(alpha: (a * 1.2).clamp(0.0, 1.0));
        canvas.drawCircle(p, d.size * 0.45, _fill);
      } else {
        // 小雪粒 / LOD 光点档：柔光圆点（大者加亮核，远看仍是雪片）
        _drawUnitHalo(canvas, _fill, p, d.size * 2.8,
            Colors.white.withValues(alpha: (d.alpha * 0.8)), _haloSnowOf());
        _fill.color = Colors.white.withValues(alpha: (d.alpha * 1.1).clamp(0.0, 1.0));
        canvas.drawCircle(p, d.size, _fill);
        if (lod == 0 && d.size >= 2.4) {
          _fill.color = Colors.white
              .withValues(alpha: (d.alpha * 1.3).clamp(0.0, 1.0));
          canvas.drawCircle(p, d.size * 0.5, _fill);
        }
      }
    }
  }

  /// 雪片自转角：角速度由尺寸/相位确定性导出（免每片存字段），方向正反各半。
  double rot6(_Snow d, double elapsed) {
    return d.swayPhase * 3.0 +
        elapsed *
            (0.22 + 0.55 * (d.size * 3.7 % 1.0)) *
            (d.x < 0.5 ? 1.0 : -1.0);
  }

  /// 气泡：从底部升起、轻微横移、上升中微放大、到顶淡出，
  /// 透明圆环 + 左上高光，描边色随氛围色调（ambientLight）。
  void _paintBubbles(Canvas canvas, Size size) {
    final speedScale = _a('speed');
    final growScale = _a('grow');
    final film = _a('film');
    // 薄膜色调：**只有用户真给气泡选过颜色**时才把彩虹膜往那个色偏；
    // 没选过（默认）乘白 = 只注入 alpha、RGB 不变 —— 与改动前逐帧一致。
    // （乘满浅色会整颗变暗，"乘白完全染不上色"又是另一个极端，所以只在自选色时取 0.85 折中）
    final filmTint = fxcSet(fx, '$_aPrefix.tint')
        ? Color.lerp(Colors.white, ambientLight, 0.85)!
        : Colors.white;
    for (final d in bubbles) {
      final progress = (d.y0 + elapsed * d.speed * speedScale) % 1.0;
      // 顶部淡出（progress 接近 1 时）
      final fadeOut = ((1.0 - progress) / 0.12).clamp(0.0, 1.0);
      final fadeIn = (progress / 0.06).clamp(0.0, 1.0);
      final fade = fadeIn < fadeOut ? fadeIn : fadeOut;
      if (fade <= 0.01) continue;
      final y = (1.0 - progress) * (size.height + d.size) - d.size; // 从底部升到顶部
      final sway = sin(elapsed * 2 * pi * 0.3 + d.swayPhase) * d.swayAmp * size.width;
      final x = d.x * size.width + sway;
      final grow = 1.0 + progress * growScale; // 上升中放大（幅度可调）
      final r = d.size * grow;
      final p = Offset(x, y);
      final a = d.alpha * fade;
      // 圆环描边：肥皂泡的薄膜虹彩（单位圆 sweep 渐变缩放复用；线宽除回缩放量
      // 保持恒定 1.2px），比纯色圆环更像「一层薄薄的膜」
      canvas.save();
      canvas.translate(p.dx, p.dy);
      canvas.scale(r, r);
      _stroke
        ..shader = _bubbleFilmOf()
        // 薄膜染色：彩虹膜乘上氛围浅色 → 整颗气泡偏向当前色调
        // （原来是乘白色 = 只注入 alpha，色调对气泡完全不起作用）
        ..colorFilter = ColorFilter.mode(
            filmTint.withValues(alpha: (a * 0.55 * film).clamp(0.0, 0.9)),
            BlendMode.modulate)
        ..strokeWidth = 1.2 / r
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(Offset.zero, 1.0, _stroke);
      _stroke
        ..shader = null
        ..colorFilter = null;
      canvas.restore();
      // 左上高光小弧
      _stroke
        ..color = Colors.white.withValues(alpha: a * 0.8)
        ..strokeWidth = 1.0;
      canvas.drawArc(
          Rect.fromCircle(center: p, radius: r * 0.6), -pi * 0.75, pi * 0.5, false, _stroke);
      // 内侧实心小高光点：左上再点一粒，气泡「鼓」起来的通透质感
      _fill.color = Colors.white.withValues(alpha: a * 0.5);
      canvas.drawCircle(
          p + Offset(-r * 0.38, -r * 0.38), max(1.0, r * 0.12), _fill);
    }
  }

  /// 氛围动效：烟花——大而炸裂的绽放。每发一朵：
  /// · 错峰出生：同一发的火花在 0~0.3s 延迟窗口内陆续出现（生成端 delay 字段），
  ///   爆炸瞬间不再「爆闪+上百火花同帧全画」，绘制峰值被摊平、消除爆发卡顿；
  /// · 阻尼弹道：爆发瞬间最快、随后减速悬停再缓坠（x=v(1-e^{-kt})/k），炸开半径可达半屏；
  /// · 中心白热爆闪：爆发头 0.3s 一团白热火球急扩渐隐（每发由 leader 火花画一次，
  ///   尺寸/时长略收，给错峰火花让出填充率预算）；
  /// · 光丝拖尾：沿真实弹道回采样 3 段折线——头亮尾淡渐隐、越快拉丝越长、
  ///   随重力自然下弯（像真实烟花炸开的光丝）；纯色线段零 shader 分配；
  /// · 出生头几帧跳过大光晕（爆闪已盖住中心），进一步压低爆发瞬间的绘制量；
  /// · 巨无霸双层环（外快内慢套叠）、主色 + 点缀色双色混喷，同屏多朵错落。
  void _paintFireworks(Canvas canvas, Size size) {
    final cycle = _a('interval'); // 一轮烟花周期（秒）——「绽放间隔」
    const drag = 1.15; // 阻尼系数：越大减速越快
    const flashDur = 0.30; // 中心爆闪时长（秒，略收短摊平峰值）
    final scale = _a('scale'); // 爆炸规模（炸开半径）
    final grav = _a('gravity'); // 下坠重力
    final trailK = _a('trail'); // 光丝拖尾长度
    for (final s in sparks) {
      final since = _wrap(elapsed - s.phase * cycle, cycle) - s.delay;
      // 错峰出生：未出生/已熄灭的火花直接跳过（爆炸瞬间同帧火花数大幅降低）
      if (since <= 0 || since > s.life) continue;
      // 中心白热爆闪：只在每发首颗火花时画一次，避免八十颗重叠饱和
      if (s.leader && since < flashDur) {
        final fq = since / flashDur;
        final fade = (1.0 - fq) * (1.0 - fq);
        final c = Offset(size.width * s.ox, size.height * s.oy);
        // 彩色外辉：随爆闪急扩的大团色光
        _drawUnitHalo(canvas, _fill, c, size.height * (0.04 + 0.13 * fq),
            s.color.withValues(alpha: fade * 0.75), _unitGlowShaderOf());
        // 白热火球核心：先猛亮后速隐（尾段已淡到不可见时省掉这次绘制）
        if (fade > 0.08) {
          _drawUnitHalo(
              canvas,
              _fill,
              c,
              size.height * (0.015 + 0.06 * fq),
              Color.lerp(s.color, Colors.white, 0.7)!.withValues(alpha: fade),
              _unitGlowShaderOf());
        }
      }
      final u = since / s.life;
      // 阻尼弹道位置（先猛冲后缓漂 + 重力下坠）：封装成局部函数供拖尾回采样
      final ca = cos(s.ang), sa = sin(s.ang);
      Offset posAt(double ts) {
        final d = (1.0 - exp(-drag * ts)) / drag;
        return Offset(
          size.width * s.ox + ca * s.speed * d * size.height * scale,
          size.height * s.oy +
              sa * s.speed * d * size.height * scale +
              0.5 * s.gravity * grav * ts * ts * size.height,
        );
      }
      final p = posAt(since);
      // 淡出（平方利落）× 明灭闪烁：火花噼啪明灭，寿命末熄灭
      final alpha = (s.alpha *
              (1.0 - u) *
              (1.0 - u) *
              (0.72 + 0.28 * sin(since * 26.0 + s.ang * 9.0)))
          .clamp(0.0, 1.0);
      if (alpha <= 0.02) continue;
      final r = s.size * (1.0 - 0.35 * u);
      // 大光晕：出生头几帧跳过（爆闪盖住中心），并且只给「够亮」的火花画 ——
      // 爆炸瞬间上百颗光晕互相重叠，是最贵的一笔填充开销，暗的那些画了也看不出来
      if (since > 0.07 && alpha > 0.30) {
        _drawUnitHalo(
            canvas, _fill, p, r * 3.4, s.color.withValues(alpha: alpha * 0.9), _haloSparkOf());
      }
      // 光丝拖尾：沿真实弹道回采样成一条折线（随重力下弯、越快越长）。
      // 三段合成**单个 Path 一次 drawPath** —— 原实现是三次 drawLine（每段都要改
      // Paint 的颜色/线宽），爆炸瞬间几十颗火花同时画，绘制调用数是主要瓶颈。
      // 「头亮尾淡」用中间 alpha 近似，运动感与长度都保留。
      final ek = exp(-drag * since);
      final look = (0.045 + 0.115 * ek) * trailK; // 回看时长：速度越快光丝拉得越长
      if (s.speed * ek * look * size.height > 2.0) {
        // 回看时刻必须钳到 ≥0：火花刚出生时光丝收在爆心，不会甩到中心后方
        final p1 = posAt(max(0.0, since - look * 0.45));
        final p2 = posAt(max(0.0, since - look * 0.75));
        final p3 = posAt(max(0.0, since - look));
        final trail = Path()
          ..moveTo(p.dx, p.dy)
          ..lineTo(p1.dx, p1.dy)
          ..lineTo(p2.dx, p2.dy)
          ..lineTo(p3.dx, p3.dy);
        _stroke
          ..shader = null
          ..strokeCap = StrokeCap.round
          ..color = s.color.withValues(alpha: alpha * 0.55)
          ..strokeWidth = s.size * 0.70;
        canvas.drawPath(trail, _stroke);
      }
      // 亮体 + 白热核：叠在光丝头上，「头亮尾淡」层次分明。
      // 白热核只在够亮时画（爆炸瞬间大量火花重叠，暗的那些画了也看不出）
      _fill.color = s.color.withValues(alpha: alpha);
      canvas.drawCircle(p, r, _fill);
      if (alpha > 0.20) {
        _fill.color = Color.lerp(s.color, Colors.white, 0.55)!
            .withValues(alpha: (alpha * 0.8 * (1.0 - u * 0.5)).clamp(0.0, 1.0));
        canvas.drawCircle(p, r * 0.55, _fill);
      }
    }
  }


  /// 氛围动效：火焰——轻盈通透的窜动火苗。低不透明度让火舌层层透叠（而非
  /// 实心一坨），色调偏暖橙提亮减饱和；整体再虚化压淡（基础 alpha 更低、
  /// 三层系数同降），形态仍可辨但更虚更透；甩动幅度加大、波纹放缓，火苗
  /// 更飘忽；底部暖色地光垫底（更淡），火星余烬升起；鼓点（bass）时火苗
  /// 窜高、地光略亮。
  void _paintFlames(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final baseY = h * 1.02;
    final beat = 1.0 + 0.40 * bass; // 鼓点：火苗窜高
    // ① 底部地光：火光映亮地面（随鼓点更亮，整体压淡保持通透）。
    // 走缓存的单位柔光 shader（原实现每帧 createShader 一个径向渐变，纯浪费）
    final gr = h * 0.36;
    _drawUnitHalo(canvas, _fill, Offset(w * 0.5, baseY), gr,
        const Color(0xFFFF8A3C)
            .withValues(alpha: (0.07 + 0.09 * bass) * _a('glow')),
        _unitGlowShaderOf());
    // ② 三层火舌：外→中→芯，逐层更矮更窄更亮（提亮减饱和，靠透叠出层次）
    const layers = [
      (1.00, 1.00, 0.42, Color(0xFFFC7A3A)), // 外焰：柔橙
      (0.64, 0.58, 0.48, Color(0xFFFFBE6B)), // 中焰：暖橙黄
      (0.36, 0.32, 0.62, Color(0xFFFFF2C4)), // 内芯：淡黄白
    ];
    for (final f in flames) {
      final bx = f.x * w;
      final hZone = f.tall * h * 0.62 * _a('height');
      // 明灭 + 高低起伏：双频不同相，火焰永远在「呼吸」（起伏加大更显轻盈）
      final flick = 0.5 + 0.5 * sin(elapsed * f.flicker * 2 * pi + f.x * 12.0);
      final dance =
          0.66 + 0.38 * sin(elapsed * f.flicker * 1.35 * 2 * pi + f.x * 5.0 + 1.3);
      final a = 0.18 + 0.24 * flick; // 整体再压低不透明度：更虚化、轻盈通透
      for (final (hr, wr, la, col) in layers) {
        final H = hZone * hr * dance * beat;
        final W = f.size * 2.3 * wr;
        // 整簇甩动：幅度加大（0.75）、芯层相位滞后，内焰「追着」外焰飘
        final sway = sin(elapsed * f.flicker * 2 * pi * 0.85 + f.x * 8.0 + hr * 2.4) *
            W *
            0.75;
        _flameTongue(canvas, bx, baseY, H, W, sway, hr * 2.0,
            0.26 + 0.08 * hr, col, a * la);
      }
      // ③ 火芯亮点：最内层尖端一颗小亮核，火苗有了「燃点」而不是三层色块叠加
      final coreH = hZone * 0.34 * dance * beat;
      final coreSway =
          sin(elapsed * f.flicker * 2 * pi * 0.85 + f.x * 8.0 + 0.9) * f.size * 0.55;
      _drawUnitHalo(
          canvas,
          _fill,
          Offset(bx + coreSway, baseY - coreH),
          f.size * (0.85 + 0.25 * flick),
          const Color(0xFFFFF4D2).withValues(alpha: (0.16 + 0.20 * flick).clamp(0.0, 0.4)),
          _unitGlowShaderOf());
      // ④ 火星余烬：从火中升起的小亮点，随高度摆动渐隐（多颗错峰，断续上升更自然）
      final embers = _a('embers').round().clamp(0, 4);
      for (var k = 0; k < embers; k++) {
        final ec = (elapsed * (0.20 + f.flicker * 0.08) + f.phase * 3.1 + k * 0.47) % 1.0;
        if (ec <= 0.04 || ec >= 0.96) continue;
        final ey = baseY - ec * hZone * 1.1 * beat;
        final ex = bx +
            sin(elapsed * 3.0 + f.x * 20.0 + k * 1.9) * (9.0 + k * 4.0) * ec;
        _fill.color = const Color(0xFFFFDFA0)
            .withValues(alpha: (1.0 - ec) * (k == 0 ? 0.45 : 0.28));
        canvas.drawCircle(Offset(ex, ey), k == 0 ? 1.3 : 1.0, _fill);
      }
    }
  }

  /// 画一条火舌：竖向泪滴状闭合路径——宽度沿高度收细成尖，边缘叠加向上滚动的
  /// 正弦波纹（相位随时间上移 → 火苗向上舔、边缘闪烁），尖端随 sway 甩动。
  /// 单次 path 填充，无 shader 分配。
  void _flameTongue(Canvas canvas, double bx, double by, double H, double W,
      double sway, double ripPhase, double ripAmp, Color color, double alpha) {
    if (H < 2 || W < 1) return;
    const segs = 12;
    final path = Path();
    for (var side = 0; side < 2; side++) {
      final sgn = side == 0 ? -1.0 : 1.0;
      for (var i = 0; i <= segs; i++) {
        final v = side == 0 ? i / segs : 1.0 - i / segs; // 左侧自底向上、右侧自顶向下
        final wv = W * (1.0 - v) * (1.0 - 0.30 * v); // 泪滴收细轮廓
        // 波纹：越靠尖端越明显、随时间向上滚动（火苗向上窜的舔动感）
        final rip = 1.0 +
            ripAmp *
                sin(v * 2 * pi * 2.4 - elapsed * 2 * pi * 1.7 + ripPhase) *
                (0.25 + 0.75 * v);
        final x = bx + sway * v * v + sgn * wv * rip;
        final y = by - H * v;
        if (side == 0 && i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
    }
    path.close();
    _fill
      ..shader = null
      ..color = color.withValues(alpha: alpha.clamp(0.0, 1.0));
    canvas.drawPath(path, _fill);
  }

  /// 氛围动效：波纹——水面上的涟漪圈（多层圈 + 迎光高光弧 + 源点柔光反光）。
  /// 与「水面」(11) 拆成两个效果：这里只管圈，水域质感交给水面效果的焦散光网。
  /// · **铺满整屏**：原实现把源点纵坐标压进下方 3/4（region=0.75），上方 1/4
  ///   一个圈都没有、边界是硬切；涟漪只是同心圆环，不会像雨丝那样糊住顶部，
  ///   所以直接按全屏映射（源点 y 生成时本就散布在 0.06~0.94）；
  /// · **每个源点同时画 3 个错相圈**（间隔 1/3 周期）：原实现每个源点只有一个相位，
  ///   多个源点偶尔同时进入淡出末期，屏幕上就出现「阶段性熄灭又亮起」；错相后
  ///   任意时刻都有圈在扩散，整体亮度平稳。
  /// 全部复用 _stroke/_fill 与单例 shader，零新增分配。
  void _paintRipples(Canvas canvas, Size size) {
    final rings = _a('rings').round().clamp(1, 4); // 每个落点同时几圈
    final highlight = fxo(fx, '$_aPrefix.highlight'); // 迎光高光弧
    for (final r in ripples) {
      final p = Offset(r.x * size.width, r.y * size.height);
      for (var k = 0; k < rings; k++) {
        final c = ((r.phase + elapsed * r.speed) + k / rings) % 1.0; // 周期内 0..1
        final rad = c * r.maxR * size.width;
        // 淡入快速、淡出二次缓降：比线性消隐更柔和、更贴近真实涟漪能量耗散
        final a = r.alpha * (1.0 - c) * (1.0 - c) * (c * 8.0).clamp(0.0, 1.0);
        if (a <= 0.02) continue;
        _stroke.strokeCap = StrokeCap.round;
      // ① 外圈柔化晕：宽而极淡的一圈垫在主环外，涟漪边缘不再生硬
      _stroke
        ..color = ambientLight.withValues(alpha: a * 0.22)
        ..strokeWidth = 3.2;
      canvas.drawCircle(p, rad * 1.10, _stroke);
      // ② 主环 + 内环：双圈层次（内圈更淡更细，像紧随的第二道余波）
      _stroke
        ..color = ambientLight.withValues(alpha: a)
        ..strokeWidth = 1.5;
      canvas.drawCircle(p, rad, _stroke);
      _stroke
        ..color = ambientLight.withValues(alpha: a * 0.5)
        ..strokeWidth = 1.1;
      canvas.drawCircle(p, rad * 0.68, _stroke);
      // ③ 迎光高光弧：主环上固定一侧的一段亮弧（水面反光的「镜面闪」）
      if (highlight) {
        _stroke
          ..color = Color.lerp(ambientLight, Colors.white, 0.65)!
              .withValues(alpha: a * 0.85)
          ..strokeWidth = 1.9;
        canvas.drawArc(
            Rect.fromCircle(center: p, radius: rad), -2.2, 0.9, false, _stroke);
      }
        // ④ 源点柔光：波纹中心一点微弱亮斑（水花落点处的反光）
        _drawUnitHalo(canvas, _fill, p, rad * 0.5,
            ambientLight.withValues(alpha: a * 0.30), _unitGlowShaderOf());
      }
    }
  }

  /// 氛围动效：水面——整片水域的质感（GPU 焦散光网 + 波光带），不含涟漪圈。
  void _paintWaterSurface(Canvas canvas, Size size) {
    final ws = waterShader;
    if (ws != null) {
      _paintWaterGpu(canvas, ws, size);
      return;
    }
    // 无着色器兜底：只画粼光带（水面感弱一些，但不会空屏）
    _paintWaterShimmer(canvas, size);
  }

  /// 水面粼光带（路径实现，兼作水面的无着色器兜底）：几条横向细亮线缓慢起伏漂移。
  void _paintWaterShimmer(Canvas canvas, Size size) {
    const shimmer = 9;
    final speed = _a('speed');
    final alphaK = _a('alpha');
    final shimmerCol = Color.lerp(ambientLight, Colors.white, 0.5)!;
    for (var i = 0; i < shimmer; i++) {
      final yy = size.height * (0.08 + i * 0.10) +
          sin(elapsed * 0.6 * speed + i * 1.7) * size.height * 0.012;
      final half = size.width * (0.14 + 0.10 * sin(i * 2.3));
      final cx0 =
          size.width * (0.5 + 0.26 * sin(elapsed * 0.25 * speed + i * 2.1));
      final a = ((0.045 + 0.045 * sin(elapsed * 0.9 * speed + i * 2.6)) * alphaK)
          .clamp(0.0, 0.20);
      _stroke
        ..shader = null
        ..colorFilter = null
        ..color = shimmerCol.withValues(alpha: a)
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(cx0 - half, yy), Offset(cx0 + half, yy), _stroke);
    }
  }

  /// 水面（GPU 实现）：两层流动噪声的等值线脊做焦散亮网 + 三条横向波光带。
  void _paintWaterGpu(Canvas canvas, ui.FragmentShader sh, Size size) {
    sh.setFloat(0, size.width);
    sh.setFloat(1, size.height);
    sh.setFloat(2, elapsed * _a('speed')); // 水流速度
    sh.setFloat(3, (bass * _a('beat')).clamp(0.0, 1.0)); // 节拍响应
    sh.setFloat(4, melody);
    // 主色 ↔ 浅色按「主色↔浅色」参数混开
    final mix = _a('mix').clamp(0.0, 1.0);
    final ca = Color.lerp(ambientPrimary, ambientLight, mix * 0.55)!;
    final cb = Color.lerp(ambientLight, Colors.white, 0.25 * mix)!;
    sh.setFloat(5, ca.r);
    sh.setFloat(6, ca.g);
    sh.setFloat(7, ca.b);
    sh.setFloat(8, cb.r);
    sh.setFloat(9, cb.g);
    sh.setFloat(10, cb.b);
    sh.setFloat(11, _a('alpha')); // uAlpha：水面整体亮度
    _fill
      ..shader = sh
      ..colorFilter = null;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), _fill);
    _fill.shader = null;
  }

  /// 氛围动效：花瓣——桃/樱花瓣形态（尖端 V 形小缺口的椭圆瓣），纵向渐变
  /// 尖白根深有层次；飘落 + 横向摆动 + 缓慢横漂 + 自转 + 绕长轴「翻面」，
  /// 顶底淡入淡出，下落自然轻盈。绘制走单位路径 + 缓存渐变 shader，零分配。
  void _paintPetals(Canvas canvas, Size size) {
    final path = _petalUnitPath();
    final speedK = _a('speed');
    for (final p in petals) {
      final u = (p.y0 + elapsed * p.speed * speedK) % 1.0;
      final y = u * (size.height + 40.0) - 20.0;
      // 顶部淡入、底部淡出：花瓣从屏外飘进来再飘出屏，不生硬消失
      final fade = (u / 0.08).clamp(0.0, 1.0) * ((1.0 - u) / 0.06).clamp(0.0, 1.0);
      final sway = sin(elapsed * 2 * pi * 0.4 + p.swayPhase) * p.swayAmp * size.width;
      final x = (p.x * size.width + sway + elapsed * p.drift * size.width) % size.width;
      final ang = elapsed * p.rotSpeed + p.swayPhase;
      // 翻面：横向按余弦压缩模拟绕长轴翻转，瓣面忽宽忽窄，立体翻飞感
      final flip = 0.38 + 0.62 * cos(elapsed * p.rotSpeed * 0.8 + p.swayPhase * 1.7).abs();
      canvas.save();
      canvas.translate(x, y);
      canvas.rotate(ang);
      canvas.scale(p.size * flip, p.size);
      _fill
        ..shader = _petalShaderOf(p.color)
        ..colorFilter = ColorFilter.mode(
            const Color(0xFFFFFFFF).withValues(alpha: (p.alpha * fade).clamp(0.0, 1.0)),
            BlendMode.modulate);
      canvas.drawPath(path, _fill);
      // 瓣脉：沿长轴一条极淡细线（单位坐标内画，线宽随花瓣缩放自然变化），
      // 花瓣不再是一块纯色片，凑近看有结构
      _stroke
        ..shader = null
        ..colorFilter = null
        ..color = const Color(0xFFFFFFFF)
            .withValues(alpha: (0.20 * fade * p.alpha).clamp(0.0, 0.25))
        ..strokeWidth = 0.035
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(const Offset(0, 0.46), const Offset(0, -0.30), _stroke);
      _fill
        ..shader = null
        ..colorFilter = null;
      canvas.restore();
      // 外柔光：飘落的花瓣带一层极淡白光（世界坐标画，不受上面缩放影响），
      // 深色壁纸背景里花瓣更「浮」得起来
      _drawUnitHalo(
          canvas,
          _fill,
          Offset(x, y),
          p.size * 1.7,
          Colors.white.withValues(alpha: (0.055 * fade * p.alpha).clamp(0.0, 0.06)),
          _unitGlowShaderOf());
    }
  }

  /// 视觉动效：粒子漩涡——中心亮核 + 5 条螺旋旋臂 + 大量粒子沿螺旋向内吸入，
  /// 内圈快外圈慢、鼓点向外扩散；粒子带更长切向拖尾，营造「吸入式」星系旋涡。不显示歌名。
  void _paintGalaxy(Canvas canvas, double cx, double cy, double heartW) {
    final R = heartW * 0.5; // 最大轨道半径
    final spin = elapsed * _v('spin'); // 整体旋转角速度
    final spread = 1.0 + 0.28 * bass; // 鼓点向外扩散
    // 中心亮核：星系核，随 bass 呼吸。shader 单例缓存（同 _unitGlowShaderOf 思路，
    // 按主题色对失效重建）：画在单位圆上、canvas 缩放到 coreR，鼓点呼吸只改缩放，
    // 不再每帧 new Gradient + createShader。
    final coreR = heartW * _v('core') * (1.0 + 0.4 * bass);
    canvas.save();
    canvas.translate(cx, cy);
    canvas.scale(coreR, coreR);
    _fill.shader = _galaxyCoreShaderOf(light, primary);
    canvas.drawCircle(Offset.zero, 1.0, _fill);
    _fill.shader = null;
    canvas.restore();
    // 星核白热亮芯：最中心一小团偏白亮斑，核更像真的「光源」
    _fill.color = Color.lerp(light, Colors.white, 0.6)!
        .withValues(alpha: (0.55 + 0.35 * bass).clamp(0.0, 1.0));
    canvas.drawCircle(Offset(cx, cy), coreR * 0.28, _fill);
    // 中心十字星芒已移除：把 _crossShaderOf 拉成细长条后会变成一根「长方形纸条」，
    // 观感很怪（用户明确反馈）；核的亮度交给上面的白热亮芯 + 光晕。
    // N 条螺旋旋臂：从中心向外卷曲，随旋转流动，鼓点时更亮
    final arms = _v('arms').round().clamp(2, 8);
    final spiral = _v('spiral');
    for (var a = 0; a < arms; a++) {
      final base = spin * 0.5 + a * 2 * pi / arms;
      final path = Path();
      const steps = 40; // 每臂采样点：52→40，降每帧路径构建量（视觉几乎无差）
      for (var i = 0; i <= steps; i++) {
        final v = i / steps;
        final rr = R * v * spread;
        final ang = base + v * spiral; // 更卷曲的对数螺旋
        final x = cx + cos(ang) * rr;
        final y = cy + sin(ang) * rr;
        if (i == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
      }
      // 旋律一起旋臂偏白提亮（和声/人声段整条漩涡「发光」）
      _stroke
        ..color = Color.lerp(a % 2 == 0 ? primary : light, Colors.white, 0.28 * melody)!
            .withValues(alpha: (0.30 + 0.38 * bass).clamp(0.0, 0.68))
        ..strokeWidth = 2.6
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(path, _stroke);
    }
    // 粒子：沿螺旋向内吸入（径向因子循环收缩），带更长切向拖尾，浮在上层
    for (final p in galaxy) {
      final ang = p.phase + spin * p.angSpeed;
      // 螺旋吸入：径向因子从 1（外圈）缓慢收缩到 0.2（内圈）再淡出重置，
      // 配合持续旋转形成「被吸进中心」的螺旋轨迹
      final radialPhase = (elapsed * 0.30 * _v('spin') + p.orbit * 3.0) % 1.0;
      final radial = 1.0 - 0.8 * radialPhase; // 1.0 → 0.2 向内
      final fadeIn = (radialPhase / 0.12).clamp(0.0, 1.0);
      final fadeOut = ((1.0 - radialPhase) / 0.12).clamp(0.0, 1.0);
      final fade = fadeIn < fadeOut ? fadeIn : fadeOut;
      if (fade <= 0.02) continue;
      final r = p.orbit * R * spread * radial;
      final x = cx + cos(ang) * r;
      final y = cy + sin(ang) * r;
      final fadeDist = (1.2 - p.orbit / 0.58).clamp(0.0, 1.0);
      // 吸入口闪白：径向收到最内圈前的一瞬转白加亮，像被星核「吞掉」时的闪光
      final swallow = radialPhase > 0.82 ? (radialPhase - 0.82) / 0.18 : 0.0;
      final c = Color.lerp(p.useLight ? light : primary, Colors.white, 0.75 * swallow)!;
      final a = (p.alpha * fade * fadeDist * (1.0 + 0.65 * swallow)).clamp(0.0, 1.0);
      if (a <= 0.02) continue;
      // 拖尾只给较亮的粒子画：淡粒子拖尾几乎不可见却让 draw call 翻倍
      if (a >= 0.20) {
        final tail = p.size * _v('tail'); // 拖尾越长，吸入感越强
        _stroke
          ..color = c.withValues(alpha: a * 0.6)
          ..strokeWidth = p.size * 0.8
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
            Offset(x, y), Offset(x + sin(ang) * tail, y - cos(ang) * tail), _stroke);
      }
      _fill.color = c.withValues(alpha: a);
      canvas.drawCircle(Offset(x, y), p.size, _fill);
    }
  }

  /// 视觉动效：能量光球——多个边界清晰的同心圆环叠加，各自以不同频率、相位收缩扩大，
  /// 低频鼓点整体膨胀；歌名悬浮在正中央。
  void _paintOrb(
      Canvas canvas, Size size, double cx, double cy, double heartW, double pulse) {
    final baseR = heartW * 0.40; // 最大基准半径
    final glow = _v('glow'); // 光球亮度
    final pulseK = _v('pulse'); // 节拍响应幅度
    final bassBoost = ((playing ? 0.15 : 0.08) * pulse + 0.22 * bass) * pulseK;
    final bodyR = baseR * (1.0 + 0.55 * bassBoost);
    final sh = orbShader;
    if (sh != null) {
      // GPU 湍流球：球内噪声翻滚 + 径向能量脉络 + 边缘辉光 + 白热核心
      _paintOrbGpu(canvas, sh, size, cx, cy, bodyR);
    } else {
      // ① 主体柔光球体（路径回退）：随鼓点呼吸的软光
      _fill.shader = RadialGradient(
        colors: [
          primary.withValues(alpha: ((0.30 + 0.20 * bassBoost) * glow).clamp(0.0, 1.0)),
          primary.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: bodyR));
      canvas.drawCircle(Offset(cx, cy), bodyR, _fill);
      _fill.shader = null;
      // ② 中心高亮亮核：越靠中心越白
      _fill.shader = RadialGradient(
        colors: [
          light.withValues(alpha: (0.9 * glow).clamp(0.0, 1.0)),
          light.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromCircle(
          center: Offset(cx, cy), radius: baseR * 0.5));
      canvas.drawCircle(Offset(cx, cy), baseR * 0.5, _fill);
      _fill.shader = null;
    }
    // ③ 能量环：若干圈细环各自收缩扩大（主色 → 浅色），环上跑流光点、环亮度随
    // 心跳/鼓点「充能」，不再是一条恒定亮度的死线
    final count = _v('rings').round().clamp(2, 8);
    for (var i = 0; i < count; i++) {
      final freq = 0.35 + i * 0.31;
      final phase = i * 2.399963;
      final breathe = 1.0 +
          0.38 * (0.5 + 0.5 * sin(elapsed * freq * _v('speed') + phase)) +
          bassBoost;
      final R = baseR * (1.0 - i * 0.14) * breathe; // 逐层缩小
      final c = Color.lerp(primary, light, i / (count - 1))!;
      _stroke
        ..color = c.withValues(
            alpha: ((0.50 + 0.30 * pulse + 0.22 * bass) * glow).clamp(0.0, 0.95))
        ..strokeWidth = 1.4 + 0.6 * pulse
        ..strokeCap = StrokeCap.round;
      canvas.drawCircle(Offset(cx, cy), R, _stroke);
      // 环上流光点：每圈数颗沿圆周匀速跑（相邻环反向），像电流绕着球体走
      final dots = _v('dots').round().clamp(0, 6);
      final dir = i.isEven ? 1.0 : -1.0;
      for (var d = 0; d < dots; d++) {
        final ang = elapsed * (0.70 + 0.22 * i) * dir + d * 2 * pi / dots + i * 1.7;
        _fill
          ..shader = null
          ..color = Color.lerp(c, Colors.white, 0.45)!
              .withValues(alpha: (0.50 + 0.35 * pulse).clamp(0.0, 0.95));
        canvas.drawCircle(
            Offset(cx + cos(ang) * R, cy + sin(ang) * R), 1.6 + 0.9 * pulse, _fill);
      }
    }
    // ③b 内部能量脉络：从核心向外辐射的几道短线（各自伸长/回缩），球体内部有了
    // 结构，不再只是一个空壳光环
    final veins = _v('veins').round().clamp(0, 14);
    for (var i = 0; i < veins; i++) {
      final ang = i * 2.399963 + elapsed * 0.35 * _v('speed');
      final grow =
          (0.34 + 0.34 * (0.5 + 0.5 * sin(elapsed * 0.9 + i * 1.3)) + 0.30 * pulse)
              .clamp(0.20, 0.95);
      final r0 = baseR * 0.16;
      final r1 = baseR * grow;
      _stroke
        ..color = Color.lerp(primary, light, 0.5)!
            .withValues(alpha: (0.13 + 0.22 * pulse).clamp(0.0, 0.5))
        ..strokeWidth = 1.2
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(
        Offset(cx + cos(ang) * r0, cy + sin(ang) * r0),
        Offset(cx + cos(ang) * r1, cy + sin(ang) * r1),
        _stroke,
      );
    }
    // ③c 球体边缘辉光：最外一道柔光描边，把光球「框」成一颗实体球（rim light）
    _stroke
      ..color = light.withValues(alpha: (0.15 + 0.20 * bass).clamp(0.0, 0.45))
      ..strokeWidth = 3.4
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(Offset(cx, cy), baseR * (0.98 + 0.10 * bassBoost), _stroke);
    // ④ 中心歌名：正中央悬浮，始终水平
    final fontSize = (heartW * 0.07).clamp(14.0, 28.0).toDouble();
    final style = TextStyle(
      color: hasSong
          ? light.withValues(alpha: 0.95)
          : Colors.white.withValues(alpha: 0.6),
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.5,
    );
    final tp = _layoutTitleCached(title, style, heartW * 0.5, textScaler);
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
  }

  /// 能量球（GPU 实现）：把球心/半径作为 uniform 传进去，球外由着色器丢弃。
  /// 全屏 drawRect 即可（early return 让球外像素几乎零成本）。
  void _paintOrbGpu(Canvas canvas, ui.FragmentShader sh, Size size, double cx,
      double cy, double radius) {
    sh.setFloat(0, size.width);
    sh.setFloat(1, size.height);
    sh.setFloat(2, elapsed);
    sh.setFloat(3, bass);
    sh.setFloat(4, melody);
    sh.setFloat(5, cx);
    sh.setFloat(6, cy);
    sh.setFloat(7, radius);
    sh.setFloat(8, primary.r);
    sh.setFloat(9, primary.g);
    sh.setFloat(10, primary.b);
    sh.setFloat(11, light.r);
    sh.setFloat(12, light.g);
    sh.setFloat(13, light.b);
    sh.setFloat(14, _v('glow')); // uAlpha：光球亮度
    _fill
      ..shader = sh
      ..colorFilter = null;
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), _fill);
    _fill.shader = null;
  }

  /// 视觉动效：粒子聚散——粒子聚成心形后随鼓点「爆开」散出、再缓慢收回，
  /// 低频鼓点让散开更猛；散开时带运动拖尾，聚拢度高时浮出心形轮廓。不显示歌名。
  void _paintHeartParticles(
      Canvas canvas, double cx, double cy, double s, double heartW) {
    // 慢速呼吸聚拢（0=散开、1=聚成心形），pow 让「聚拢」更饱满、「散开」更短促；
    // bass 鼓点把粒子猛地向外打散
    final breathe = 0.5 + 0.5 * sin(elapsed * 0.45 * _v('speed'));
    final gather = pow(breathe, 1.6) - 0.55 * bass;
    final k = gather.clamp(0.0, 1.0);
    final scatterR = heartW * _v('scatter');
    // 聚拢顶点白闪：粒子快聚成心形的一瞬整体转白，「能量凝聚完成」有落点
    final flash = k > 0.86 ? (k - 0.86) / 0.14 : 0.0;
    // 聚拢时的柔光衬底：聚得越拢越亮，凸出一颗「光心」
    _fill.shader = RadialGradient(
      colors: [
        primary.withValues(alpha: 0.12 + 0.30 * k + 0.28 * flash),
        primary.withValues(alpha: 0.0),
      ],
    ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: scatterR * 1.15));
    canvas.drawCircle(Offset(cx, cy), scatterR * 1.15, _fill);
    _fill.shader = null;
    // 聚拢度高时画出淡淡心形轮廓，强化「聚成心形」的认知
    if (k > 0.55) {
      final outline = Path();
      const samples = 90;
      for (var i = 0; i < samples; i++) {
        final theta = 2 * pi * i / samples;
        final hp = heartUnit(theta);
        final x = cx + hp.dx * s;
        final y = cy - (hp.dy + 6) * s;
        if (i == 0) {
          outline.moveTo(x, y);
        } else {
          outline.lineTo(x, y);
        }
      }
      outline.close();
      _stroke
        ..color = Color.lerp(light, Colors.white, 0.55 * flash)!
            .withValues(alpha: (0.34 * k + 0.30 * flash).clamp(0.0, 0.85))
        ..strokeWidth = 1.6 + 1.2 * flash
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(outline, _stroke);
    }
    for (final p in heartParts) {
      final hp = heartUnit(p.ht);
      final hx = cx + hp.dx * s;
      final hy = cy - (hp.dy + 6) * s;
      final gx = cx + p.sx * scatterR;
      final gy = cy + p.sy * scatterR;
      final x = gx + (hx - gx) * k;
      final y = gy + (hy - gy) * k;
      // 旋律一起偏白（和声段整团粒子发亮），聚拢顶点再白闪一层
      final c = Color.lerp(p.useLight ? light : primary, Colors.white,
          (0.25 * melody + 0.70 * flash).clamp(0.0, 1.0))!;
      // 散开运动拖尾：沿「心形 → 散开」方向拉出短线，聚拢时消失
      final tail = p.size * _v('tail') * (1.0 - k); // 拖尾越长，爆散越有速度感
      if (tail > 0.5) {
        final dx = gx - hx;
        final dy = gy - hy;
        final dlen = sqrt(dx * dx + dy * dy) + 1e-6;
        _stroke
          ..color = c.withValues(alpha: p.alpha * 0.5 * (1.0 - k))
          ..strokeWidth = p.size * 0.7
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
            Offset(x, y),
            Offset(x - dx / dlen * tail, y - dy / dlen * tail),
            _stroke);
      }
      // 近心聚拢时更大更亮，散开时渐小渐暗
      final size = p.size * (0.9 + 0.3 * k + 0.35 * flash);
      _fill.color = c.withValues(
          alpha: (p.alpha * (0.55 + 0.45 * k + 0.40 * flash)).clamp(0.0, 1.0));
      canvas.drawCircle(Offset(x, y), size, _fill);
    }
  }

  /// 视觉动效：万花筒——8 条波形臂绕中心多重旋转对称，整体随节奏收缩扩张，
  /// 波形臂两端分别紧粘中心与外圈多边形内角顶点（sin(πv) 包络让两端收敛，不散开）。
  /// 不显示歌名。
  void _paintKaleidoscope(Canvas canvas, double cx, double cy, double heartW) {
    final arms = _v('arms').round().clamp(4, 16);
    final spin = _v('spin');
    final wiggleK = _v('wiggle');
    final R = heartW * 0.45;
    final rot = elapsed * 0.35 * spin;
    // 收缩呼吸：整体周期性缩放 + 鼓点额外扩张
    final zoom = 0.92 +
        0.16 * (0.5 + 0.5 * sin(elapsed * 0.8 * spin)) +
        0.15 * bass;
    // N 条波形臂：从中心向外延伸、切向正弦摆动，深浅色交替；
    // wiggle 用 sin(πv) 包络，两端为 0 → 线头紧粘中心与外圈顶点，中间摆动最明显
    for (var a = 0; a < arms; a++) {
      final base = rot + a * 2 * pi / arms;
      final path = Path()..moveTo(cx, cy);
      const segs = 24;
      for (var i = 1; i <= segs; i++) {
        final v = i / segs;
        final rr = R * v * zoom;
        final wiggle = sin(v * 2 * pi * 2 + elapsed * 1.2 * spin) *
            R *
            wiggleK *
            sin(pi * v);
        final ang = base + wiggle / (rr + 1);
        path.lineTo(cx + cos(ang) * rr, cy + sin(ang) * rr);
      }
      _stroke
        ..color = (a % 2 == 0 ? primary : light).withValues(alpha: 0.68)
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(path, _stroke);
      // 臂上流光：每臂数颗亮点由内向外跑，万花筒转起来才「通电」
      final dots = _v('dots').round().clamp(0, 4);
      for (var d = 0; d < dots; d++) {
        final v = (elapsed * 0.55 + a * 0.13 + d * 0.5) % 1.0;
        final rr = R * v * zoom;
        final wiggle = sin(v * 2 * pi * 2 + elapsed * 1.2 * spin) *
            R *
            wiggleK *
            sin(pi * v);
        final ang = base + wiggle / (rr + 1);
        _fill
          ..shader = null
          ..color = Color.lerp(a % 2 == 0 ? primary : light, Colors.white, 0.55)!
              .withValues(
                  alpha: ((0.30 + 0.45 * bass).clamp(0.0, 0.9) * (1.0 - 0.35 * v)));
        canvas.drawCircle(Offset(cx + cos(ang) * rr, cy + sin(ang) * rr),
            1.7 + 0.9 * bass, _fill);
      }
    }
    // 外圈旋转多边形轮廓（同频收缩）——「外圈轮廓」关掉时只剩向外的波形臂
    if (fxo(fx, '$_vPrefix.poly')) {
      final poly = Path();
      for (var a = 0; a < arms; a++) {
        final ang = rot + a * 2 * pi / arms;
        final x = cx + cos(ang) * R * zoom;
        final y = cy + sin(ang) * R * zoom;
        if (a == 0) {
          poly.moveTo(x, y);
        } else {
          poly.lineTo(x, y);
        }
      }
      poly.close();
      _stroke
        ..color = light.withValues(alpha: 0.35)
        ..strokeWidth = 1.2;
      canvas.drawPath(poly, _stroke);
      // 外圈每个转角一颗小亮点：对称结构有了「节点」，更像镜面反射的棱
      for (var a = 0; a < arms; a++) {
        final ang = rot + a * 2 * pi / arms;
        _fill
          ..shader = null
          ..color = light.withValues(alpha: 0.70);
        canvas.drawCircle(
            Offset(cx + cos(ang) * R * zoom, cy + sin(ang) * R * zoom), 1.9, _fill);
      }
    }
    // 中心亮核（随收缩呼吸）：柔光晕 + 亮芯两层，核更有「光源」感
    _drawUnitHalo(canvas, _fill, Offset(cx, cy), heartW * 0.10 * zoom,
        light.withValues(alpha: 0.55), _haloStarOf());
    // 中心十字星芒已移除（同上：拉成细长条像一根纸条，观感怪）
    _fill.color = Colors.white.withValues(alpha: 0.85);
    canvas.drawCircle(Offset(cx, cy), heartW * 0.018 * zoom, _fill);
  }

  /// 视觉动效：3D 深度球——球面粒子绕倾斜轴旋转，近大远小、近亮远暗（视差深度感），
  /// 外带经纬线框定义球体形状、中心柔光；不显示歌名；鼓点时整体膨胀更亮。
  void _paint3DOrb(Canvas canvas, double cx, double cy, double heartW) {
    final R = heartW * 0.40;
    final d = heartW * 10 / _v('depth'); // 相机距离（近大远小；深度越大透视越夸张）
    final ang = elapsed * 0.5 * _v('spin');
    // 倾斜旋转轴：由「倾斜角度」推动（0.5 = 默认那根轴），再归一化成单位向量
    final tilt = _v('tilt') - 0.5;
    final rawX = 0.35 + tilt * 1.0;
    final rawY = 0.55 - tilt * 0.8;
    const rawZ = 0.75;
    final alen = sqrt(rawX * rawX + rawY * rawY + rawZ * rawZ);
    final axisX = rawX / alen, axisY = rawY / alen, axisZ = rawZ / alen;
    final boom = 1.0 + 0.24 * bass; // 鼓点膨胀
    Offset proj(double x, double y, double z) {
      final r = _rotAxis(x, y, z, axisX, axisY, axisZ, ang);
      final persp = d / (d - r[2]);
      return Offset(cx + r[0] * R * persp * boom, cy + r[1] * R * persp * boom);
    }
    // 线框球：赤道 + 上下各两条纬度环 + 绕轴大圆经线（「经纬线框」可整组关掉）
    if (fxo(fx, '$_vPrefix.grid')) {
      for (final lat in [0.0, 0.55, -0.55, 0.85, -0.85]) {
        final rr = sqrt(1.0 - lat * lat);
        final path = Path();
        for (var i = 0; i <= 48; i++) {
          final th = 2 * pi * i / 48;
          final p = proj(rr * cos(th), rr * sin(th), lat);
          if (i == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        _stroke
          ..color = light.withValues(alpha: 0.20)
          ..strokeWidth = 1.0
          ..strokeCap = StrokeCap.round;
        canvas.drawPath(path, _stroke);
      }
      // 经线：绕轴再叠 5 条大圆。只有纬线时球体像「一摞呼啦圈」，补上经线网格才完整
      for (final lon in [0.0, 0.35, 0.70, 1.05, 1.40]) {
        final ca = cos(lon), sa = sin(lon);
        final path = Path();
        for (var i = 0; i <= 48; i++) {
          final th = 2 * pi * i / 48;
          final x = cos(th) * ca;
          final z = cos(th) * sa;
          final y = sin(th);
          final p = proj(x, y, z);
          if (i == 0) {
            path.moveTo(p.dx, p.dy);
          } else {
            path.lineTo(p.dx, p.dy);
          }
        }
        _stroke
          ..color = light.withValues(alpha: 0.13)
          ..strokeWidth = 1.0
          ..strokeCap = StrokeCap.round;
        canvas.drawPath(path, _stroke);
      }
    }
    // 球体边缘辉光：最外一道柔光描边，把球从背景里「托」起来，体积感更实
    _stroke
      ..color = primary.withValues(alpha: (0.13 + 0.16 * bass).clamp(0.0, 0.4))
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(Offset(cx, cy), R * 0.98 * boom, _stroke);
    // 中心柔光球体（随鼓点呼吸）
    final coreR = heartW * (0.20 + 0.06 * bass);
    _fill.shader = RadialGradient(
      colors: [
        light.withValues(alpha: 0.42),
        primary.withValues(alpha: 0.0),
      ],
    ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: coreR * 1.4));
    canvas.drawCircle(Offset(cx, cy), coreR * 1.4, _fill);
    _fill.shader = null;
    // 表面粒子：近大远小、近亮远暗
    for (final p in orbPoints) {
      final r = _rotAxis(p.x, p.y, p.z, axisX, axisY, axisZ, ang);
      final persp = d / (d - r[2]);
      final x = cx + r[0] * R * persp * boom;
      final y = cy + r[1] * R * persp * boom;
      final depth = (r[2] + 1) / 2; // 0..1 深度（1=最前）
      final size = (1.0 + 2.4 * depth) * (1.0 + 0.3 * bass);
      final a = (0.25 + 0.7 * depth).clamp(0.0, 1.0);
      if (a <= 0.03) continue;
      final c3 = depth > 0.62 ? light : primary;
      // 最近一面的粒子叠柔光晕（复用单位 shader 零分配），近处「发光」更立体
      if (depth > 0.72) {
        _drawUnitHalo(canvas, _fill, Offset(x, y), size * 2.4,
            c3.withValues(alpha: a * 0.55), _haloStarOf());
      }
      _fill.color = c3.withValues(alpha: a);
      canvas.drawCircle(Offset(x, y), size, _fill);
    }
  }

  /// 视觉动效：歌词逐字浮现——当前歌词行在中央显示，随行内进度逐个字符点亮（亮→暗）。
  /// 无词时回退显示歌名（静态居中）；不显示爱心。
  void _paintLyricReveal(Canvas canvas, double cx, double cy, double heartW) {
    final text = lyricText.isNotEmpty ? lyricText : title;
    // 同 v0.title：先按原公式 clamp，再乘倍率（默认 1.0 = 旧版观感）
    final fontSize = ((heartW * 0.062).clamp(16.0, 30.0) * _v('font')).toDouble();
    final litStyle = TextStyle(
      color: (hasSong ? light : Colors.white).withValues(alpha: 0.98),
      fontSize: fontSize,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.6,
      // 立体质感：下层深色投影把字「托」起来 + 主色大辉光，已点亮的字浮在画面上
      shadows: [
        Shadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 3,
            offset: const Offset(0, 2)),
        Shadow(color: light.withValues(alpha: 0.6), blurRadius: 14),
      ],
    );
    final restStyle = TextStyle(
      color: Colors.white.withValues(alpha: _v('dim')),
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.6,
    );
    final n = text.length;
    final lit = (n * lyricProgress).round().clamp(0, n);
    final tp = _layoutLyricRevealCached(
        text, lit, litStyle, restStyle, heartW * _v('wrap'), textScaler);
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
    // 行内进度光带已移除（用户觉得「看着怪怪的」）：逐字点亮本身就够表达进度
    // 子歌词（译文）：挂在主歌词正下方，静态显示、不参与逐字点亮
    if (subLyric.isNotEmpty) {
      // 译文字号：**先在旧公式（主字号 ×0.6）上 clamp，再乘用户倍率**（默认 0.6 → ×1.0）。
      // ⚠️ 顺序不能反：先乘倍率再 clamp 会把上下限一起放开，默认值下就比改动前小一档。
      final subSize = (fontSize * 0.6).clamp(10.0, 20.0) * (_v('sub') / 0.6);
      final subStyle = TextStyle(
        color: Colors.white.withValues(alpha: hasSong ? 0.78 : 0.6),
        fontSize: subSize.toDouble(),
        fontWeight: FontWeight.w500,
        letterSpacing: 0.4,
        shadows: [
          Shadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 4,
              offset: const Offset(0, 1)),
        ],
      );
      final subTp =
          _layoutTitleCached(subLyric, subStyle, heartW * 0.74, textScaler);
      subTp.paint(
        canvas,
        Offset(cx - subTp.width / 2, cy + tp.height / 2 + fontSize * 0.22),
      );
    }
  }

  /// ── 边框区域动效（第四区：屏幕四边，视觉/律动/氛围之外的独立地带）──

  /// 边框动效：呼吸边框——一圈柔和的渐变圆角光晕贴着屏幕四边，随时间缓慢
  /// 明暗呼吸（约 5 秒一个周期，受 edgeSpeed 调制）；播放时低频让光晕轻微
  /// 「吸气」提亮。三层描边由宽淡到窄亮模拟柔边渐变（不用 blur，省 GPU），
  /// 四角光斑稍聚一点，观感优雅安静、无生硬几何感。
  void _paintEdgeBreath(Canvas canvas, Size size) {
    final inset = _e('inset');
    final radius = _e('radius');
    final lineK = _e('line');
    final bright = _e('glow'); // 整体亮度
    final cornerK = _e('corner'); // 四角光斑
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(inset, inset, size.width - inset * 2, size.height - inset * 2),
        Radius.circular(radius),
      ));
    // 呼吸相位：elapsed 驱动（跨循环连续），约 5 秒一个明暗周期
    final breath = 0.5 + 0.5 * sin(elapsed * 2 * pi * 0.2 * _e('speed'));
    // 播放时低频轻微提亮（幅度克制，保持优雅不抢戏）
    final beat = playing ? bass * 0.30 : 0.0;
    final glow = ((breath + beat) * bright).clamp(0.0, 1.0);
    final c = Color.lerp(primary, light, 0.30 + 0.30 * glow)!;
    _stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // 三层描边模拟柔边渐变光晕：宽而淡 → 中等 → 窄而亮，「光从边框里透出」
    _stroke
      ..color = c.withValues(alpha: (0.05 + 0.08 * glow).clamp(0.0, 0.6))
      ..strokeWidth = 15.0 * lineK;
    canvas.drawPath(path, _stroke);
    _stroke
      ..color = c.withValues(alpha: (0.10 + 0.13 * glow).clamp(0.0, 0.7))
      ..strokeWidth = 6.5 * lineK;
    canvas.drawPath(path, _stroke);
    _stroke
      ..color = c.withValues(alpha: (0.24 + 0.30 * glow).clamp(0.0, 0.9))
      ..strokeWidth = 1.8 * lineK;
    canvas.drawPath(path, _stroke);
    // 四角柔光斑：圆角处光更聚一点，呼吸时角部光晕随之胀缩
    // 四角光斑：呼吸之外再叠一点鼓点脉动（角部随低频轻微胀缩，边框「活」起来）
    if (cornerK <= 0) return;
    final cr = (30.0 + 12.0 * glow + 7.0 * bass) * cornerK;
    final ca = (0.10 + 0.16 * glow + 0.10 * bass) * cornerK;
    _drawUnitHalo(canvas, _fill, Offset(inset, inset), cr,
        c.withValues(alpha: ca), _unitGlowShaderOf());
    _drawUnitHalo(canvas, _fill, Offset(size.width - inset, inset), cr,
        c.withValues(alpha: ca), _unitGlowShaderOf());
    _drawUnitHalo(canvas, _fill, Offset(inset, size.height - inset), cr,
        c.withValues(alpha: ca), _unitGlowShaderOf());
    _drawUnitHalo(canvas, _fill, Offset(size.width - inset, size.height - inset), cr,
        c.withValues(alpha: ca), _unitGlowShaderOf());
  }

  /// 边框动效：流光边框——一段高亮光带沿四条边循环跑动，头部亮、尾部渐隐（彗星观感），
  /// 暗色底轨常驻；速度受 edgeSpeed 调制，elapsed 驱动跨循环无缝。
  void _paintEdgeFlow(Canvas canvas, Size size) {
    const inset = 6.0;
    final lineK = _e('line');
    final cornerK = _e('corner');
    final W = size.width - inset * 2;
    final H = size.height - inset * 2;
    final P = 2 * (W + H); // 周长
    final track = Path()
      ..addRRect(RRect.fromRectAndRadius(
        Rect.fromLTWH(inset, inset, W, H),
        const Radius.circular(28),
      ));
    _stroke
      ..color = primary.withValues(alpha: (0.11 + 0.16 * bass).clamp(0.0, 0.4))
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(track, _stroke);
    final head = (elapsed * P * 0.22 * _e('speed')) % P; // 彗星头沿周长匀速前进
    final tailFrac = _e('tail'); // 尾长占周长比例
    final tailLen = P * tailFrac;
    const segs = 220;
    final step = P / segs;
    // 两/三条线一起跑：主彗星（浅色）+ 反向偏移半周的第二条（主浅混色）+ 可选第三条
    final lanes = _e('lanes').round().clamp(1, 3);
    for (var ci = 0; ci < lanes; ci++) {
      // ⚠️ 偏移必须按**实际条数**均分：写成 `ci * P * 0.5` 时第三条（ci=2）会落在
      // 正好一整圈上，与第一条逐像素重合（看着像"第三条没出现、第一条被盖暗"）。
      // lanes=2 时 0 / P/2 与旧版一致，默认观感不变。
      final offset = ci * P / lanes;
      // 旋律段整体偏白：光带跟着人声「发亮」
      final baseCol = switch (ci) {
        0 => light,
        1 => Color.lerp(primary, light, 0.45)!,
        _ => Color.lerp(primary, light, 0.80)!,
      };
      final cCol = Color.lerp(baseCol, Colors.white, 0.22 * melody)!;
      final h = (head + offset) % P;
      for (var i = 0; i < segs; i++) {
        final d0 = i * step;
        final d1 = d0 + step;
        final mid = (d0 + d1) / 2;
        final wrap = ((mid - h) % P + P) % P; // 到头的缠绕最短距离
        final dist = min(wrap, P - wrap);
        // pow(x, 2) 换乘法：这里每帧跑 440 次（220 段×2 条），省掉重复的 pow 调用
        // 双层尾：近尾亮而短 + 远尾极淡而长（彗星拖两层尾羽，速度感更足）
        final q = dist / tailLen;
        final q2 = dist / (tailLen * 2.6);
        final a = (exp(-q * q) + 0.30 * exp(-q2 * q2)).clamp(0.0, 1.0);
        if (a < 0.03) continue;
        _stroke
          ..color = cCol.withValues(alpha: a)
          ..strokeWidth = lineK
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
            _edgePoint(W, H, inset, d0), _edgePoint(W, H, inset, d1), _stroke);
      }
      // 彗星头：白热亮核 + 柔光晕，光带跑动更有「拖着光核」的质感
      final hp = _edgePoint(W, H, inset, h);
      _drawUnitHalo(canvas, _fill, hp, 10.0 * lineK / 3.0,
          cCol.withValues(alpha: 0.8), _unitGlowShaderOf());
      _fill.color = Color.lerp(cCol, Colors.white, 0.65)!.withValues(alpha: 0.95);
      canvas.drawCircle(hp, 2.6 * lineK / 3.0, _fill);
    }
    // 四角积淀：光带拐过圆角时在角部留一层淡光，边框四角不再「空」
    if (cornerK <= 0) return;
    final cornerA = ((0.07 + 0.13 * bass) * cornerK).clamp(0.0, 0.28);
    for (final cx0 in [inset, size.width - inset]) {
      for (final cy0 in [inset, size.height - inset]) {
        _drawUnitHalo(canvas, _fill, Offset(cx0, cy0), 22.0 * cornerK,
            light.withValues(alpha: cornerA), _unitGlowShaderOf());
      }
    }
  }


  /// 边框动效：歌词跑马灯——歌名沿底边循环滚动，首尾无缝；无歌时用「Mu Box」。
  void _paintEdgeMarquee(Canvas canvas, Size size) {
    final glowK = _e('glow'); // 外发光强度
    // 先按原公式 clamp，再乘倍率（默认 1.0 = 旧版字号）
    final fontSize =
        ((size.width * 0.045).clamp(14.0, 26.0) * _e('font')).toDouble();
    final style = TextStyle(
      color: light.withValues(alpha: 0.85),
      fontSize: fontSize,
      fontWeight: FontWeight.w600,
      letterSpacing: _e('spacing'),
      // 文字外发光：跑马灯从「一行灰字」变成会发光的字幕（style 是常量，
      // 不影响 _layoutMarqueeCached 的缓存命中）
      shadows: [
        if (glowK > 0.01)
          Shadow(
              color: light.withValues(alpha: (0.65 * glowK).clamp(0.0, 1.0)),
              blurRadius: 12 * glowK),
        Shadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 2),
      ],
    );
    final tp = _layoutMarqueeCached(marqueeText, style, textScaler);
    if (tp.width <= 0) return;
    final loopW = size.width + tp.width + 80; // 滚动循环长度（含两段间隔）
    final x = size.width - _wrap(elapsed * loopW * 0.10 * _e('speed'), loopW);
    // 离底距离可调：默认 138 是「底部播放栏上方」，调小了会被播放栏挡住
    final y = size.height - _e('bottom') - tp.height;
    // 视口剔除：只画与屏幕相交的副本。文本绘制是本效果最贵的操作，
    // 屏幕外的副本画了也看不见（Skia 仍要逐字走一遍光栅管线），
    // 原先无条件画两份、其中右侧一份永远在屏外，剔除后文本绘制开销减半；
    // 滚动轨迹与循环位置分毫未动，观感完全一致。
    // 底边光轨已移除：字幕底下那条横线是多余的（用户点名要去掉），
    // 字幕本身已有外发光，不需要再垫一条线。
    if (x > -tp.width && x < size.width) {
      tp.paint(canvas, Offset(x, y));
    }
    final x2 = x + loopW; // 右侧补齐一段，循环无缝
    if (x2 > -tp.width && x2 < size.width) {
      tp.paint(canvas, Offset(x2, y));
    }
  }

  /// 边框动效：频谱灯带——底边一排小灯随真实频谱亮起，随频率高低起伏。
  void _paintEdgeSpectrumStrip(Canvas canvas, Size size) {
    final n = _e('lamps').round().clamp(12, 72); // 灯珠数量
    final lampW = size.width / n;
    final y = size.height - _e('bottom');
    final h = _e('h');
    final glowK = _e('glow');
    final tailOn = fxo(fx, '$_ePrefix.tail');
    final segW = lampW * 0.68;
    // 连通底光带已移除（用户反馈多余）：灯珠各自的微弱底轨已经能连成一条灯带。
    for (var i = 0; i < n; i++) {
      final vi = (i / n * spectrum.length).floor();
      final v = (vi < spectrum.length && vi >= 0 ? spectrum[vi] : 0.0).clamp(0.0, 1.0);
      final x = i * lampW + (lampW - segW) / 2;
      // 灯珠颜色沿灯带从主色渐到浅色（左低频右高频），不再整排一色
      final lampC = Color.lerp(primary, light, i / (n - 1))!;
      // 灯珠底轨：微弱常亮，未播放也可见一排
      _fill.color = lampC.withValues(alpha: 0.10);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, y - h, segW, h), const Radius.circular(2)),
          _fill);
      // 点亮部分：随频谱高度，未播放几乎不亮
      final glow = 2.0 + v * h;
      _fill.color = lampC.withValues(alpha: 0.12 + 0.88 * v);
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Rect.fromLTWH(x, y - glow, segW, glow), const Radius.circular(2)),
          _fill);
      // 灯顶柔光：点亮的灯珠顶上叠一层柔光晕（复用单位 shader 零分配），像真的在发光
      if (v > 0.08 && glowK > 0.01) {
        _drawUnitHalo(canvas, _fill, Offset(x + segW / 2, y - glow), segW * 1.6,
            lampC.withValues(alpha: (0.40 * v * glowK).clamp(0.0, 1.0)),
            _unitGlowShaderOf());
      }
      // 能量拖尾：冲得高的灯珠向上拖一小段光尾（越高越长），灯带有了「跳动」
      if (tailOn && v > 0.32) {
        final tail = 6.0 * v;
        _fill
          ..shader = null
          ..color = lampC.withValues(alpha: 0.16 * v);
        canvas.drawRRect(
            RRect.fromRectAndRadius(
                Rect.fromLTWH(x + segW * 0.30, y - glow - tail, segW * 0.40, tail),
                const Radius.circular(1.0)),
            _fill);
      }
    }
  }

  /// 边框周长上第 d 像素（0..P）对应的坐标，顺时针：上→右→下→左。
  Offset _edgePoint(double W, double H, double inset, double d) {
    final d2 = d % (2 * (W + H));
    if (d2 < W) return Offset(inset + d2, inset); // 上边，左→右
    if (d2 < W + H) return Offset(inset + W, inset + d2 - W); // 右边，上→下
    if (d2 < 2 * W + H) return Offset(inset + W - (d2 - W - H), inset + H); // 下边，右→左
    return Offset(inset, inset + H - (d2 - 2 * W - H)); // 左边，下→上
  }

  @override
  bool shouldRepaint(covariant _AmbientPainter old) =>
      old.t != t ||
      old.elapsed != elapsed ||
      old.primary != primary ||
      old.light != light ||
      old.title != title ||
      old.marqueeText != marqueeText ||
      old.lyricText != lyricText ||
      old.subLyric != subLyric ||
      old.lyricProgress != lyricProgress ||
      old.hasSong != hasSong ||
      old.playing != playing ||
      old.textScaler != textScaler ||
      old.drops != drops ||
      old.stars != stars ||
      old.fireflies != fireflies ||
      old.snows != snows ||
      old.bubbles != bubbles ||
      old.dapples != dapples ||
      old.galaxy != galaxy ||
      old.heartParts != heartParts ||
      old.sparks != sparks ||
      old.flames != flames ||
      old.ripples != ripples ||
      old.petals != petals ||
      old.orbPoints != orbPoints ||
      old.spectrum != spectrum ||
      old.ambientPrimary != ambientPrimary ||
      old.ambientLight != ambientLight ||
      old.showHeart != showHeart ||
      old.showAmbient != showAmbient ||
      old.ambientEffect != ambientEffect ||
      !listEquals(old.visualLayers, visualLayers) ||
      old.fx != fx || // 氛围层每次 build 都会传一份新的参数快照，改了参数就能立刻重绘
      old.bass != bass ||
      old.melody != melody ||
      old.showEdge != showEdge ||
      old.edgeEffect != edgeEffect;
}

/// 缓存中心歌名的 TextPainter 布局。
///
/// 氛围层每帧全屏重绘，而画布里的歌名文本其实只在「切歌 / 字体 / 缩放 / 主题色」
/// 变化时才需要重新排版。原先 `_paintTitle` 与 `_paintOrb` 每帧都新建一个
/// `TextPainter` 并 `layout()`，文本排版是较贵的 CPU 操作，白白在每帧重复。
/// 这里用「命中即复用、失效才重排」的单槽缓存（同一时刻只有一首歌名在画），
/// 以 `text|fontSize|fontWeight|letterSpacing|color|maxWidth|textScaler` 作键，
/// 任何一项变了才重排，否则直接复用上一次的结果（布局不变，观感完全一致）。
String? _titlePainterKey;
TextPainter? _titlePainter;

TextPainter _layoutTitleCached(
  String text,
  TextStyle style,
  double maxWidth,
  TextScaler scaler,
) {
  final key =
      '$text|${style.fontSize}|${style.fontWeight}|${style.letterSpacing}|'
      '${style.color?.toARGB32() ?? -1}|$maxWidth|${scaler.scale(1.0)}';
  if (_titlePainterKey == key && _titlePainter != null) {
    return _titlePainter!;
  }
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
    maxLines: 2,
    ellipsis: '…',
    textScaler: scaler,
  )..layout(maxWidth: maxWidth);
  _titlePainterKey = key;
  _titlePainter = tp;
  return tp;
}

String? _marqueeKey;
TextPainter? _marqueePainter;

/// 缓存跑马灯文本的 TextPainter 布局：单行、不省略、宽度不限（用于贴边滚动测量）。
/// 键随 text/style/缩放变化才重排，避免每帧 layout。
TextPainter _layoutMarqueeCached(String text, TextStyle style, TextScaler scaler) {
  final key =
      '$text|${style.fontSize}|${style.fontWeight}|${style.letterSpacing}|'
      '${style.color?.toARGB32() ?? -1}|${scaler.scale(1.0)}';
  if (_marqueeKey == key && _marqueePainter != null) {
    return _marqueePainter!;
  }
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
    textScaler: scaler,
  )..layout();
  _marqueeKey = key;
  _marqueePainter = tp;
  return tp;
}

String? _lyricRevealKey;
TextPainter? _lyricRevealPainter;

/// 缓存歌词逐字浮现的 TextPainter 布局（同 _layoutTitleCached 思路）。
/// 「已点亮字数」只在跨过下一个字时才变化（一行歌词通常几十字），而氛围层
/// 每帧重绘——原先每帧新建 TextPainter + layout() 是较贵的 CPU 操作，
/// 一行歌词期间白白重复几十上百次；命中即复用，文本/字数/样式变了才重排。
TextPainter _layoutLyricRevealCached(
  String text,
  int lit,
  TextStyle litStyle,
  TextStyle restStyle,
  double maxWidth,
  TextScaler scaler,
) {
  final key =
      '$text|$lit|${litStyle.fontSize}|${litStyle.color?.toARGB32() ?? -1}|'
      '${restStyle.color?.toARGB32() ?? -1}|$maxWidth|${scaler.scale(1.0)}';
  if (_lyricRevealKey == key && _lyricRevealPainter != null) {
    return _lyricRevealPainter!;
  }
  final n = text.length;
  final tp = TextPainter(
    text: TextSpan(children: [
      if (lit > 0) TextSpan(text: text.substring(0, lit), style: litStyle),
      if (lit < n) TextSpan(text: text.substring(lit), style: restStyle),
    ]),
    textDirection: TextDirection.ltr,
    textAlign: TextAlign.center,
    maxLines: 2,
    ellipsis: '…',
    textScaler: scaler,
  )..layout(maxWidth: maxWidth);
  _lyricRevealKey = key;
  _lyricRevealPainter = tp;
  return tp;
}
