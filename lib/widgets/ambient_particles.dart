part of 'ambient_layer.dart';

/// 一圈爱心的线条配置：圈放大 / 采样点数 / 每段点数 / 段间缺口 / 抖动幅度px / 线宽 / 透明度 / 是否用浅色
class _RingConfig {
  final double scale;
  final int samples;
  final int segLen;
  final int gap;
  final double jitterAmp;
  final double strokeWidth;
  final double alpha;
  final bool useLight;
  const _RingConfig(this.scale, this.samples, this.segLen, this.gap,
      this.jitterAmp, this.strokeWidth, this.alpha, this.useLight);
}

/// 三圈爱心线条：外圈大而疏（浅色）、中圈主轮廓（主色）、内圈小而密（浅色），
/// 圈间交替深浅增强"几圈线条"的层次感。
const List<_RingConfig> _rings = [
  _RingConfig(1.06, 150, 12, 2, 1.4, 1.8, 0.50, true),
  _RingConfig(1.00, 120, 10, 3, 2.0, 2.4, 0.72, false),
  _RingConfig(0.94, 90, 9, 3, 2.4, 1.8, 0.58, true),
];

/// 一颗雨滴：固定种子生成、运行期只读。
class _Drop {
  final double x; // 0..1 屏宽比例
  final double y0; // 0..1 初始纵向比例（错相）
  final double speed; // 每秒下落屏高倍数
  final double len; // 水滴长度（屏高比例）
  final double alpha; // 透明度
  final double swayAmp; // 摆动幅度（屏宽比例）
  final double swayPhase; // 摆动相位
  final double tilt; // 倾斜（横向偏移 = tilt * 纵向位移）
  final double width; // 线宽（按景深层定粗细）
  const _Drop({
    required this.x,
    required this.y0,
    required this.speed,
    required this.len,
    required this.alpha,
    required this.swayAmp,
    required this.swayPhase,
    required this.tilt,
    required this.width,
  });
}

/// 一颗星星：随机生成、运行期只读。光点闪烁，部分大星带十字光芒。
/// 位置不固定——每颗星有独立生命周期，周期结束淡出换到随机新位置。
class _Star {
  final double r; // 星点半径 px
  final double baseAlpha; // 基础透明度
  final double twinkleSpeed; // 闪烁速度（每秒相位圈数）
  final double phase; // 闪烁相位
  final bool cross; // 是否带十字光芒（大星）
  final double life; // 生命周期（秒）：在该位置停留多久后换随机新位置
  final int seed; // 种子基：与周期一起决定每个位置（确定性伪随机）
  const _Star({
    required this.r,
    required this.baseAlpha,
    required this.twinkleSpeed,
    required this.phase,
    required this.cross,
    required this.life,
    required this.seed,
  });
}

/// 阳光暖黄基色：固定暖黄，不随主题/氛围色调（阳光本色就是暖黄）。
const Color _sunWarm = Color(0xFFFFCE66);

/// 树影斑驳的叶影基色：偏暗的绿褐，模拟树荫下的阴影层次。
const Color _leafShadow = Color(0xFF14241C);

/// 一只萤火虫：暖黄/暖绿小光点，在基位置附近缓慢游走（利萨如漂移），忽明忽暗。
class _Firefly {
  final double baseAlpha; // 基础透明度
  final double glowSpeed; // 忽明忽暗速度（每秒相位圈数）
  final double phase; // 闪烁相位
  final double life; // 换位周期（秒）
  final int seed; // 种子基：与周期一起决定基位置
  final double driftSpeed; // 游走速度
  final double amp; // 游走幅度（屏宽比例）
  final bool green; // 是否暖绿（否则暖黄）
  final double r; // 光点半径 px
  const _Firefly({
    required this.baseAlpha,
    required this.glowSpeed,
    required this.phase,
    required this.life,
    required this.seed,
    required this.driftSpeed,
    required this.amp,
    required this.green,
    required this.r,
  });
}

/// 一片雪花：大者为六角结晶（六主臂 + 侧枝，绘制端成形），小者为柔光圆点；
/// 缓慢下落 + 自转 + 横向摆动 + 缓慢横漂。
class _Snow {
  final double x; // 0..1 屏宽比例
  final double y0; // 0..1 初始纵向比例（错相）
  final double speed; // 每秒下落屏高倍数（慢）
  final double swayAmp; // 横向摆动幅度（屏宽比例）
  final double swayPhase; // 摆动相位
  final double drift; // 缓慢横向漂移（屏宽比例/秒）
  final double size; // 雪花半径 px
  final double alpha; // 透明度
  const _Snow({
    required this.x,
    required this.y0,
    required this.speed,
    required this.swayAmp,
    required this.swayPhase,
    required this.drift,
    required this.size,
    required this.alpha,
  });
}

/// 一个气泡：从底部升起、轻微横移、上升中微放大、到顶淡出。
class _Bubble {
  final double x; // 0..1 屏宽比例
  final double y0; // 初始相位（错开）
  final double speed; // 上升速度（屏高倍数/秒）
  final double size; // 基础半径 px
  final double swayAmp; // 横向摆动幅度（屏宽比例）
  final double swayPhase; // 摆动相位
  final double alpha; // 透明度
  const _Bubble({
    required this.x,
    required this.y0,
    required this.speed,
    required this.size,
    required this.swayAmp,
    required this.swayPhase,
    required this.alpha,
  });
}

/// 树影斑驳：一个光斑 / 叶影。软椭圆斑，rx/ry 控制形状，rot 控制朝向。
/// 每个斑有独立生命周期：淡入 → 呼吸 → 淡出 → 换到随机新位置再淡入（位置由 seed 确定性生成）。
/// kind：0=叶影（暗斑垫底）、1=强光（亮核+大光晕）、2=暖光团（纯弥散暖光，无核）。
class _Dapple {
  final double rx; // 横向半轴（屏宽比例）
  final double ry; // 纵向半轴（屏高比例）
  final double baseAlpha; // 基础透明度（生命周期内峰值）
  final double breatheSpeed; // 明暗呼吸速度（每秒相位圈数）
  final double phase; // 呼吸相位
  final double driftSpeed; // 周期内缓慢游走速度
  final double amp; // 游走幅度（屏宽比例）
  final double rot; // 椭圆旋转角
  final int kind; // 0=叶影 1=强光 2=暖光团
  final double life; // 生命周期（秒）：多久淡出并换一个随机位置
  final int seed; // 种子：与周期一起决定每个周期的随机位置
  const _Dapple({
    required this.rx,
    required this.ry,
    required this.baseAlpha,
    required this.breatheSpeed,
    required this.phase,
    required this.driftSpeed,
    required this.amp,
    required this.rot,
    required this.kind,
    required this.life,
    required this.seed,
  });
}

/// 漩涡粒子：绕中心螺旋旋转，轨道半径/角速度/相位/大小固定，位置由 elapsed 实时计算。
class _GalaxyParticle {
  final double orbit; // 轨道半径（相对视觉区比例 0.08~0.58）
  final double angSpeed; // 角速度（rad/s，内圈快外圈慢）
  final double phase; // 初始相位角
  final double size; // 粒子半径 px
  final double alpha; // 透明度
  final bool useLight; // 用浅色还是主色
  const _GalaxyParticle({
    required this.orbit,
    required this.angSpeed,
    required this.phase,
    required this.size,
    required this.alpha,
    required this.useLight,
  });
}

/// 聚散粒子：固定一颗心形目标点（heartUnit 采样）与一个散开位置，运行时在两者间插值。
class _HeartParticle {
  final double ht; // 心形参数 t（0~2π），决定聚拢时的心形目标
  final double sx; // 散开位置 x（相对视觉区比例）
  final double sy; // 散开位置 y（相对视觉区比例）
  final double size; // 粒子半径 px
  final double alpha; // 透明度
  final bool useLight; // 用浅色还是主色
  const _HeartParticle({
    required this.ht,
    required this.sx,
    required this.sy,
    required this.size,
    required this.alpha,
    required this.useLight,
  });
}


/// 一个烟花火花：属于某次爆发，沿固定方向飞出、受重力下坠、寿命内淡出。
/// 同一爆发的火花共用爆发中心与周期时刻，一起绽放形成一朵烟花。
class _Spark {
  final double ox; // 爆发中心 x（屏宽比例）
  final double oy; // 爆发中心 y（屏高比例）
  final double phase; // 周期内爆发时刻（0..1，错开各次爆发）
  final double ang; // 飞出方向（rad）
  final double speed; // 初速（屏高/秒）
  final double gravity; // 重力（屏高/秒²）
  final double life; // 寿命（秒）
  final double size; // 火花半径 px
  final double alpha;
  final Color color;
  final bool leader; // 本发火花的「首颗」标记：绘制时用它画一次中心白热爆闪
  final double delay; // 错峰出生延迟（秒）：同一发火花在延迟窗口内陆续出现，
                      // 摊平「爆炸瞬间全部火花+爆闪同帧出现」的绘制峰值（卡顿根源）
  const _Spark({
    required this.ox,
    required this.oy,
    required this.phase,
    required this.ang,
    required this.speed,
    required this.gravity,
    required this.life,
    required this.size,
    required this.alpha,
    required this.color,
    required this.leader,
    required this.delay,
  });
}

/// 一缕火焰：扎根底部的一簇火舌（绘制端画三层泪滴路径），明灭闪烁、高低起伏。
class _Flame {
  final double x; // 屏宽比例
  final double phase; // 错相（余烬上升周期用）
  final double size; // 基准半径 px
  final double flicker; // 闪烁速度（每秒相位圈数）
  final double tall; // 本簇火焰高度上限（0.3~1.0，越高升得越高）
  const _Flame({
    required this.x,
    required this.phase,
    required this.size,
    required this.flicker,
    required this.tall,
  });
}

/// 一圈水面波纹：从水面某点向外扩散的同心圆环，越扩越淡。
class _Ripple {
  final double x; // 屏宽比例
  final double y; // 屏高比例（下半屏水面）
  final double phase; // 错相
  final double speed; // 扩散速度（周期/秒）
  final double maxR; // 最大半径（屏宽比例）
  final double alpha;
  const _Ripple({
    required this.x,
    required this.y,
    required this.phase,
    required this.speed,
    required this.maxR,
    required this.alpha,
  });
}

/// 一片花瓣：飘落 + 横向摆动 + 缓慢横漂 + 自转。
class _Petal {
  final double x; // 屏宽比例
  final double y0; // 初始纵（屏高比例，错相）
  final double speed; // 下落速度（屏高/秒）
  final double swayAmp; // 横向摆动幅度（屏宽比例）
  final double swayPhase; // 摆动相位
  final double drift; // 缓慢横漂（屏宽比例/秒）
  final double rotSpeed; // 自转角速度（rad/s）
  final double size; // 花瓣长轴 px
  final double alpha;
  final int color; // 0 粉 1 白 2 暖黄
  const _Petal({
    required this.x,
    required this.y0,
    required this.speed,
    required this.swayAmp,
    required this.swayPhase,
    required this.drift,
    required this.rotSpeed,
    required this.size,
    required this.alpha,
    required this.color,
  });
}

/// 一个 3D 深度球的表面点：单位球面坐标，运行时绕倾斜轴旋转投影。
class _OrbPoint {
  final double x;
  final double y;
  final double z;
  const _OrbPoint(this.x, this.y, this.z);
}

/// 固定种子生成雨滴（细长雨丝风）：每次启动雨型一致、确定性强。
/// randomness 控制样式随机度（0.3 统一 ~ 2.0 随机）。按景深分远/中/近三层：
/// 远层最多（细淡短慢），近层最少（粗亮长快），营造近大远小的雨幕层次；
/// 风感以垂直为主：tilt 为三角分布（两次均匀随机相加居中于 0），大多数雨丝
/// 近乎垂直、少量带各种左右偏斜，不再统一右斜；gravity 加速在绘制端做。
///
/// [lenScale]/[widthScale]/[windScale] 是雨滴特效页里的「雨丝长度 / 粗细 / 风斜强度」，
/// 都是生成端属性，拖动时由氛围层去抖后整体重建。
List<_Drop> _generateDrops(int seed, int count, double randomness,
    {double lenScale = 1.0, double widthScale = 1.0, double windScale = 1.0}) {
  final rng = Random(seed);
  return List.generate(max(0, count), (_) {
    // 景深三档抽签：远 45% / 中 35% / 近 20%（远处雨幕密、近处雨丝疏）
    final roll = rng.nextDouble();
    final int layer;
    if (roll < 0.45) {
      layer = 0; // 远：细丝淡影
    } else if (roll < 0.80) {
      layer = 1; // 中：主雨幕
    } else {
      layer = 2; // 近：粗亮长丝
    }
    // 各层基准：线宽 px / 雨丝长度（屏高比例）/ 基础亮度 / 每秒穿屏速度
    final double w, len, aBase, spd;
    if (layer == 2) {
      w = 1.7 + rng.nextDouble() * 0.8; // 1.7~2.5（近处粗）
      len = 0.050 + rng.nextDouble() * 0.045; // 5%~9.5% 屏高（近处长）
      aBase = 0.26 + rng.nextDouble() * 0.16; // 0.26~0.42（近处亮）
      spd = 0.30 + rng.nextDouble() * 0.22; // 近处快
    } else if (layer == 1) {
      w = 1.0 + rng.nextDouble() * 0.5; // 1.0~1.5
      len = 0.030 + rng.nextDouble() * 0.028; // 3%~5.8% 屏高
      aBase = 0.16 + rng.nextDouble() * 0.12; // 0.16~0.28
      spd = 0.20 + rng.nextDouble() * 0.16;
    } else {
      w = 0.55 + rng.nextDouble() * 0.35; // 0.55~0.9（远处细）
      len = 0.018 + rng.nextDouble() * 0.018; // 1.8%~3.6% 屏高（远处短）
      aBase = 0.10 + rng.nextDouble() * 0.10; // 0.10~0.20（远处淡）
      spd = 0.12 + rng.nextDouble() * 0.12; // 远处慢（视差景深）
    }
    // 随机度 k：**只调个体差异的跨度，不改整体快慢 / 长短 / 明暗**。
    // 旧写法把 k 直接乘在 speed/len/alpha 上 —— 拉大随机度会让整场雨同时变快、变长、变亮，
    // 跟「下落速度 / 雨丝长度」两个滑杆打架（用户反馈：随机度看着像第二个大小）。
    // k = 1 时 diff 恒为 1，画出来的雨与旧版完全一致。
    final k = randomness;
    final diff = 1 + (rng.nextDouble() - 0.5) * (k - 1); // 速度/长度的个体差异
    final diffA = 1 + (rng.nextDouble() - 0.5) * (k - 1); // 亮度的个体差异
    return _Drop(
      x: rng.nextDouble(),
      y0: rng.nextDouble(),
      speed: spd * 1.2 * diff,
      len: len * 1.2 * diff * lenScale,
      alpha: (aBase * 1.15 * diffA).clamp(0.0, 0.5),
      // 微摆：围绕中值 0.0045 拉开/收拢（k=1 时等于旧式 0.002 + rng*0.005）
      swayAmp: 0.0045 + (rng.nextDouble() - 0.5) * 0.005 * k, // 微摆，别抢风感
      swayPhase: rng.nextDouble() * 2 * pi,
      tilt: (rng.nextDouble() + rng.nextDouble() - 1.0) * 0.16 * k * windScale,
      width: w * widthScale,
    );
  });
}

/// 生成星空：三档（小碎星 / 普通星 / 大星带十字），大小亮度跨度大、层次丰富。
/// 每颗星带独立生命周期，位置随周期变化（见 _paintStars）。
/// [sizeScale] 星点大小 / [twinkleScale] 闪烁快慢 / [bigPct] 带十字大星占比 /
/// [lifeScale] 换位周期倍率 —— 都是星空·彩星特效页里的设置项。
List<_Star> _generateStars(int count,
    {double sizeScale = 1.0,
    double twinkleScale = 1.0,
    double bigPct = 0.20,
    double lifeScale = 1.0}) {
  final rng = Random();
  // 大星阈值：bigPct=0.20 时与原实现（0.80）完全一致
  final bigAt = 1.0 - bigPct.clamp(0.0, 0.6);
  return List.generate(max(0, count), (_) {
    final roll = rng.nextDouble();
    final double r, baseAlpha;
    final bool big;
    if (roll < bigAt * 0.65) {
      r = 0.4 + rng.nextDouble() * 0.6; // 小碎星（最多，暗而细碎）
      baseAlpha = 0.55 + rng.nextDouble() * 0.45;
      big = false;
    } else if (roll < bigAt) {
      r = 0.8 + rng.nextDouble() * 0.8; // 普通星（较亮）
      baseAlpha = 0.65 + rng.nextDouble() * 0.35;
      big = false;
    } else {
      r = 1.7 + rng.nextDouble() * 1.3; // 大星（带十字光芒，更大更亮）
      baseAlpha = 0.88 + rng.nextDouble() * 0.12;
      big = true;
    }
    return _Star(
      r: r * sizeScale,
      baseAlpha: baseAlpha,
      twinkleSpeed: (0.3 + rng.nextDouble() * 1.8) * twinkleScale, // 闪烁快慢差异大
      phase: rng.nextDouble() * 2 * pi,
      cross: big,
      life: (4.0 + rng.nextDouble() * 8.0) * lifeScale, // 4~12 秒随机换位
      seed: rng.nextInt(1 << 30),
    );
  });
}

/// 生成萤火虫：暖黄/暖绿小光点，数量中等、游走幅度小、忽明忽暗节奏错开。
/// [sizeScale] 光点大小 / [blinkScale] 明灭快慢 / [driftScale] 游走速度。
List<_Firefly> _generateFireflies(int count,
    {double sizeScale = 1.0, double blinkScale = 1.0, double driftScale = 1.0}) {
  final rng = Random();
  return List.generate(max(0, count), (_) {
    return _Firefly(
      baseAlpha: 0.45 + rng.nextDouble() * 0.45,
      glowSpeed: (0.3 + rng.nextDouble() * 1.2) * blinkScale, // 忽明忽暗快慢差异
      phase: rng.nextDouble() * 2 * pi,
      life: 5.0 + rng.nextDouble() * 8.0, // 5~13 秒换位
      seed: rng.nextInt(1 << 30),
      driftSpeed: (0.15 + rng.nextDouble() * 0.35) * driftScale, // 缓慢游走
      amp: (0.012 + rng.nextDouble() * 0.07) * driftScale, // 游走幅度（屏宽比例）
      green: rng.nextBool(),
      r: (1.5 + rng.nextDouble() * 1.6) * sizeScale, // 光点半径 1.5~3.1px
    );
  });
}

/// 生成飘雪：白色絮状，慢速下落、大小跨度大、带横向摆动与缓慢横漂。
/// count 由飘雪特效页的「雪片数量」决定；仍保留 110 硬上限兜底：
/// 六角结晶每片多条线段，片数过多 GPU 吃不住（性能红线）。
///
/// [randomness] = 随机度：**只改个体差异**（围绕各自中值拉开/收拢），
/// 不像旧写法那样把 k 直接乘上去（那会让整场雪同时变快变大，看着像第二个「雪片大小」）。
/// k = 1 时与旧式逐项等价。
List<_Snow> _generateSnow(int count, double randomness,
    {double sizeScale = 1.0, double swayScale = 1.0}) {
  final rng = Random();
  final n = count.clamp(0, 110);
  final k = randomness;
  return List.generate(n, (_) {
    return _Snow(
      x: rng.nextDouble(),
      y0: rng.nextDouble(),
      // 中值：速度 0.04（约 25 秒穿屏）/ 摆动 0.0205 / 大小 2.7px
      speed: (0.04 + (rng.nextDouble() - 0.5) * 0.05 * k).clamp(0.004, 0.4),
      swayAmp:
          ((0.0205 + (rng.nextDouble() - 0.5) * 0.025 * k).clamp(0.0, 0.09)) *
              swayScale,
      swayPhase: rng.nextDouble() * 2 * pi,
      drift: (rng.nextDouble() - 0.5) * 0.01, // 缓慢横漂（可左可右）
      size: ((2.7 + (rng.nextDouble() - 0.5) * 3.0 * k).clamp(0.5, 8.0)) *
          sizeScale,
      alpha: 0.35 + rng.nextDouble() * 0.40, // 亮度：结晶清晰可辨
    );
  });
}

/// 生成气泡：数量少、上升慢、大小跨度大、错相升起。
///
/// [randomness] = **随机度**，只放大/收窄「个体差异」，**不改整体大小与速度**：
/// randomness = 1 时与原实现逐粒相同（默认值）；调小 → 一堆气泡大小速度都差不多；
/// 调大 → 大的更大、小的更小。原先它直接乘在 size/speed 上，拉大随机度会让气泡
/// **整体**变大变快，看着就像第二个「大小」滑杆（用户反馈）。
List<_Bubble> _generateBubbles(int count, double randomness,
    {double sizeScale = 1.0}) {
  final rng = Random();
  final k = randomness; // 差异倍率：1 = 原分布
  return List.generate(max(0, count), (_) {
    // 基准分布：size 3~17px（中值 10）、speed 0.04~0.16（中值 0.10）
    final sizeRaw = 3.0 + rng.nextDouble() * 14.0;
    final speedRaw = 0.04 + rng.nextDouble() * 0.12;
    return _Bubble(
      x: rng.nextDouble(),
      y0: rng.nextDouble(),
      // 围绕中值拉开/收拢，平均值不随随机度漂移
      speed: (0.10 + (speedRaw - 0.10) * k).clamp(0.02, 0.30),
      size: (10.0 + (sizeRaw - 10.0) * k).clamp(2.0, 26.0) * sizeScale,
      swayAmp: 0.008 + rng.nextDouble() * 0.02,
      swayPhase: rng.nextDouble() * 2 * pi,
      alpha: 0.40 + rng.nextDouble() * 0.50,
    );
  });
}

/// 生成树影斑驳：三类叠加——
/// ① 叶影（暗斑）：约一半，大而淡，垫出树荫底色，换位慢（树荫相对稳定）；
/// ② 强光：固定「几点」，大光晕 + 小亮核，其中部分「极大增强」到接近饱和；
/// ③ 暖光团：纯弥散暖光（无核），像被树叶漫射的柔和暖光。
/// 每个斑带独立生命周期，随机换位、淡入淡出。强光/暖光稀疏克制，避免糊成一整片黄。
List<_Dapple> _generateDapple(int count,
    {double breatheScale = 1.0, double sizeScale = 1.0}) {
  final rng = Random();
  final list = <_Dapple>[];

  // ① 叶影垫底：数量约一半，大而淡，20~36 秒才换位（树荫稳定）
  final shadowCount = (count * 0.5).round();
  for (var i = 0; i < shadowCount; i++) {
    list.add(_Dapple(
      rx: (0.10 + rng.nextDouble() * 0.16) * sizeScale,
      ry: (0.10 + rng.nextDouble() * 0.16) * sizeScale,
      baseAlpha: 0.07 + rng.nextDouble() * 0.07,
      breatheSpeed: (0.03 + rng.nextDouble() * 0.08) * breatheScale,
      phase: rng.nextDouble() * 2 * pi,
      driftSpeed: 0.02 + rng.nextDouble() * 0.06,
      amp: 0.01 + rng.nextDouble() * 0.04,
      rot: rng.nextDouble() * pi,
      kind: 0,
      life: 20 + rng.nextDouble() * 16,
      seed: rng.nextInt(1 << 30),
    ));
  }

  // ② 强光：固定几点，光晕较大、基本静止（慢漂），中心带亮核；约 2/5 是「极大增强」的刺眼级
  const spotCount = 5;
  for (var i = 0; i < spotCount; i++) {
    final superBright = rng.nextDouble() < 0.4; // 随机挑几个极亮
    list.add(_Dapple(
      rx: (superBright
              ? 0.09 + rng.nextDouble() * 0.10
              : 0.06 + rng.nextDouble() * 0.08) *
          sizeScale,
      ry: (superBright
              ? 0.09 + rng.nextDouble() * 0.10
              : 0.06 + rng.nextDouble() * 0.08) *
          sizeScale,
      baseAlpha: superBright
          ? 0.85 + rng.nextDouble() * 0.15 // 0.85~1.0 接近饱和
          : 0.45 + rng.nextDouble() * 0.20, // 0.45~0.65 常规
      breatheSpeed: (0.02 + rng.nextDouble() * 0.06) * breatheScale,
      phase: rng.nextDouble() * 2 * pi,
      driftSpeed: 0.01 + rng.nextDouble() * 0.03,
      amp: 0.005 + rng.nextDouble() * 0.02,
      rot: rng.nextDouble() * pi,
      kind: 1,
      life: 8 + rng.nextDouble() * 7, // 8~15 秒淡入淡出换位
      seed: rng.nextInt(1 << 30),
    ));
  }

  // ③ 暖光团：纯弥散暖光，无核，中等数量、柔和，10~20 秒换位
  final glowCount = max(4, min(12, (count * 0.3).round()));
  for (var i = 0; i < glowCount; i++) {
    list.add(_Dapple(
      rx: (0.04 + rng.nextDouble() * 0.06) * sizeScale,
      ry: (0.04 + rng.nextDouble() * 0.06) * sizeScale,
      baseAlpha: 0.20 + rng.nextDouble() * 0.15,
      breatheSpeed: (0.03 + rng.nextDouble() * 0.10) * breatheScale,
      phase: rng.nextDouble() * 2 * pi,
      driftSpeed: 0.02 + rng.nextDouble() * 0.06,
      amp: 0.01 + rng.nextDouble() * 0.04,
      rot: rng.nextDouble() * pi,
      kind: 2,
      life: 10 + rng.nextDouble() * 10,
      seed: rng.nextInt(1 << 30),
    ));
  }

  return list;
}

/// 生成漩涡粒子：内圈密外圈疏（sqrt 分布），内圈快外圈慢（开普勒感），营造星系旋涡。
List<_GalaxyParticle> _generateGalaxy(int count) {
  final rng = Random();
  return List.generate(count, (_) {
    final orbit = 0.08 + pow(rng.nextDouble(), 0.55) * 0.5; // 内圈密、外圈疏
    return _GalaxyParticle(
      orbit: orbit,
      angSpeed: 0.6 + 1.7 / (orbit + 0.15), // 内圈转得快、外圈慢
      phase: rng.nextDouble() * 2 * pi,
      size: 1.0 + rng.nextDouble() * 1.6,
      alpha: 0.35 + rng.nextDouble() * 0.65,
      useLight: rng.nextBool(),
    );
  });
}

/// 生成聚散粒子：心形目标点随机采样、散开位置均匀散布在矩形内。
List<_HeartParticle> _generateHeartParts(int count) {
  final rng = Random();
  return List.generate(count, (_) {
    return _HeartParticle(
      ht: rng.nextDouble() * 2 * pi,
      sx: (rng.nextDouble() - 0.5) * 2.2,
      sy: (rng.nextDouble() - 0.5) * 2.2,
      size: 1.2 + rng.nextDouble() * 1.8,
      alpha: 0.45 + rng.nextDouble() * 0.55,
      useLight: rng.nextBool(),
    );
  });
}

/// 生成烟花：大幅增强的炸裂版——
/// ① 单发更大：火花数 70~160、初速大幅提高（配合绘制端的阻尼弹道，炸开半径可达
///    半屏以上）、寿命更长（余晖拖得更久）；
/// ② 双色：每发主色 + 色相偏移的点缀色混喷，同屏多色更绚丽；
/// ③ 层次：约 1/3 是「巨无霸」双层环爆发（外环快、内环慢，两圈套叠更立体），
///    其余为单环球壳（均匀方向 + 微抖，避免死板圆环）；
/// 爆发中心散布屏幕上半部、周期时刻错开；每发第一颗火花标记 leader，
/// 绘制时用它画一次中心白热爆闪。
/// [density] 是烟花特效页的「火花密度」：单发火花数按倍率缩放（钳在 10~400，
/// 上限是绘制端的性能红线 —— 同屏火花过多时爆炸瞬间会掉帧）。
List<_Spark> _generateFireworks(int burstCount, {double density = 1.0}) {
  final rng = Random();
  final list = <_Spark>[];
  final bursts = burstCount.clamp(1, 12);
  for (var b = 0; b < bursts; b++) {
    final ox = 0.10 + rng.nextDouble() * 0.80; // 爆发中心（屏宽比例）
    final oy = 0.08 + rng.nextDouble() * 0.52; // 上半部（屏高比例）
    final phase = rng.nextDouble(); // 各次爆发在周期内错开
    final mega = b % 3 == 0; // 约每三发一发「巨无霸」
    final hue = rng.nextDouble() * 360;
    final col = HSVColor.fromAHSV(1.0, hue, 0.62, 1.0).toColor();
    // 点缀色：色相偏移 90°~210°，同发双色混喷
    final acc = HSVColor.fromAHSV(
        1.0, (hue + 90 + rng.nextDouble() * 120) % 360, 0.55, 1.0).toColor();
    final sparkCount = ((mega ? 110 + rng.nextInt(51) : 70 + rng.nextInt(31)) *
            density)
        .round()
        .clamp(10, 400);
    final half = sparkCount ~/ 2;
    for (var i = 0; i < sparkCount; i++) {
      // 巨无霸：后半颗走内环（慢速小圈套在快速大圈内，层次立体）
      final inner = mega && i >= half;
      final double ang;
      final double speed;
      if (mega) {
        final j = inner ? i - half : i;
        final n = half.toDouble();
        ang = 2 * pi * (j / n) + (rng.nextDouble() - 0.5) * 0.10 +
            (inner ? pi / n : 0.0); // 内环相位错开半格，两圈不重叠
        speed = inner ? 0.24 + rng.nextDouble() * 0.12 : 0.42 + rng.nextDouble() * 0.28;
      } else {
        ang = 2 * pi * (i / sparkCount) + (rng.nextDouble() - 0.5) * 0.12;
        speed = 0.30 + rng.nextDouble() * 0.25;
      }
      list.add(_Spark(
        ox: ox,
        oy: oy,
        phase: phase,
        ang: ang,
        speed: speed,
        gravity: 0.10 + rng.nextDouble() * 0.05,
        life: 1.4 + rng.nextDouble() * 0.7 + (mega ? 0.3 : 0.0), // 余晖更长
        size: 1.6 + rng.nextDouble() * 1.4,
        alpha: 0.65 + rng.nextDouble() * 0.35,
        color: rng.nextDouble() < 0.70 ? col : acc, // 主色为主、点缀色穿插
        leader: i == 0,
        delay: i == 0 ? 0.0 : rng.nextDouble() * 0.30, // 错峰出生（0~0.3s 随机摊开）
      ));
    }
  }
  return list;
}


/// 生成火焰：簇数由火焰特效页的「火苗簇数」直接决定（上限 60，防止铺满卡顿）、
/// 扎根底部（原地燃烧）、大小/闪烁差异，暖橙主导；高度各异，错落成片。
List<_Flame> _generateFlames(int count,
    {double sizeScale = 1.0, double flickerScale = 1.0}) {
  final rng = Random();
  final n = count.clamp(1, 60);
  return List.generate(n, (_) => _Flame(
        x: rng.nextDouble(),
        phase: rng.nextDouble(),
        size: (5 + rng.nextDouble() * 9) * sizeScale,
        flicker: (0.5 + rng.nextDouble() * 1.6) * flickerScale,
        tall: 0.3 + rng.nextDouble() * 0.7, // 高度各异，错落成片
      ));
}

/// 生成水面波纹：落点数量由波纹特效页决定，散布全屏（不只是下半屏），错相扩散。
/// [speedScale] = 扩散速度倍率（默认 1.0 = 旧观感）。
/// [randomness] = 随机度：只改个体差异（围绕中值），不改整体的扩散快慢与圈的大小。
List<_Ripple> _generateRipples(int count, double randomness,
    {double maxRScale = 1.0, double speedScale = 1.0}) {
  final rng = Random();
  final n = count.clamp(1, 60);
  final k = randomness;
  return List.generate(n, (_) => _Ripple(
        x: rng.nextDouble(),
        y: 0.06 + rng.nextDouble() * 0.88, // 全屏散布，避免只在下半屏
        phase: rng.nextDouble(),
        // 中值：扩散速度 0.16 / 最大半径 0.07 屏宽
        speed: ((0.16 + (rng.nextDouble() - 0.5) * 0.12 * k).clamp(0.02, 0.6)) *
            speedScale,
        maxR: ((0.07 + (rng.nextDouble() - 0.5) * 0.06 * k).clamp(0.015, 0.25)) *
            maxRScale,
        alpha: 0.30 + rng.nextDouble() * 0.30,
      ));
}

/// 生成花瓣：数量由花瓣特效页直接决定（上限 80）、大小/摆动/横漂/自转差异大
/// （近大亮、远小淡成层次），粉白黄三色，尺寸放大到花瓣形态可辨。
/// [randomness] = 随机度：只改个体差异（围绕中值），不改整体的飘落快慢与花瓣大小。
List<_Petal> _generatePetals(int count, double randomness,
    {double sizeScale = 1.0, double spinScale = 1.0, double driftScale = 1.0}) {
  final rng = Random();
  final n = count.clamp(1, 80);
  final k = randomness;
  return List.generate(n, (_) => _Petal(
        x: rng.nextDouble(),
        y0: rng.nextDouble(),
        // 中值：飘落 0.065 / 摆动 0.03 / 大小 12px
        speed: (0.065 + (rng.nextDouble() - 0.5) * 0.07 * k).clamp(0.005, 0.3),
        swayAmp: (0.03 + (rng.nextDouble() - 0.5) * 0.04 * k).clamp(0.0, 0.2),
        swayPhase: rng.nextDouble() * 2 * pi,
        drift: (rng.nextDouble() - 0.5) * 0.02 * driftScale,
        rotSpeed: (rng.nextDouble() - 0.5) * 2.2 * spinScale,
        size: ((12 + (rng.nextDouble() - 0.5) * 8 * k).clamp(2.0, 40.0)) *
            sizeScale,
        alpha: 0.40 + rng.nextDouble() * 0.45, // 深浅错开，远近层次
        color: rng.nextInt(3),
      ));
}

/// 生成 3D 深度球表面点：单位球面上均匀采样（面积元均匀），数量适中。
List<_OrbPoint> _generateOrb(int count) {
  final rng = Random();
  return List.generate(count, (_) {
    final z = rng.nextDouble() * 2 - 1;
    final a = rng.nextDouble() * 2 * pi;
    final r = sqrt(1 - z * z);
    return _OrbPoint(r * cos(a), r * sin(a), z);
  });
}

/// 确定性伪随机（sin 哈希）：任意整数 → 0..1 稳定值。
/// 用于星空「按周期换位」——同一周期位置稳定，不同周期位置随机。
double _starRand(int seed) {
  final v = sin(seed * 12.9898 + 78.233) * 43758.5453;
  return v - v.floor();
}

/// 每颗星固定的鲜艳彩色（由 seed 决定色相，换位后颜色不变）。
/// [baseHue] 非空时（用户给彩星选过颜色）把色相限制在基色 ±45° 内 ——
/// 保持「彩」的观感，但整体朝用户选的那个颜色偏。
Color _starColor(int seed, {double? baseHue}) {
  final r = _starRand(seed + 0x9E3779B9);
  final hue = baseHue == null ? r * 360.0 : (baseHue + (r - 0.5) * 90.0) % 360.0;
  return HSVColor.fromAHSV(1.0, hue, 0.55, 1.0).toColor();
}

/// 解析当前氛围特效的配色：读它自己的「颜色」参数（`a*.tint`，-1 = 跟随主题）。
///
/// 每个能选颜色的氛围特效（星空/彩星/极光/气泡/水面/波纹）各存各的槽位，
/// 槽位指向**主题色列表**里的某一套（含用户自建的自定义色，见 theme.dart fxTintColors）。
/// 固定本色的特效（雨滴/阳光/萤火虫/飘雪/烟花/火焰/花瓣）没有这个键 → 一律主题色，
/// 而且它们本身也不读这两个色。
(Color, Color) _resolveAmbientColors(Color primary, Color light) {
  final cfg = AppConfig.instance;
  final effect = Fx.find('a', cfg.ambientEffect);
  if (effect == null) return (primary, light);
  final tint = fxc(cfg.fxParams, '${effect.prefix}.tint');
  if (tint < 0) return (primary, light);
  return fxTintColors(tint, primary, light);
}

