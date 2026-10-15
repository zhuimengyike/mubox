/// 特效注册表：每个特效的名称 / 图标 / 一句话说明 / 专属参数，全部写在这一处。
///
/// 参数键 = `<区前缀><索引>.<参数名>`（v 视觉 / r 律动 / a 氛围 / e 边框），
/// 值与「用户是否改过」一起存 `AppConfig.fxParams`（SharedPreferences 一份 JSON）。
/// **默认值只在本文件声明一次**：绘制端（ambient_painter / spectrum.dart）、
/// 粒子生成（ambient_layer）与设置页三处都从 `Fx.def()` 取缺省，
/// 不会出现「UI 显示 1.0、实际画 0.8」这种两套默认值打架的情况。
///
/// 新增一个特效参数 = 在这里加一行 + 在绘制端读一次 `fxv('键')`，
/// 设置页 UI 由本文件自动生成，不需要再写页面代码。
library;

import 'package:flutter/material.dart';

import 'theme.dart'; // kFxTintDefault / kFxTintPresets：氛围色调的槽位与默认色

/// 参数显示格式（只影响滑块右侧的数值文案）。
enum FxFormat {
  /// ×1.0 倍率
  times,

  /// 整数（个/根/颗）
  integer,

  /// 百分比
  percent,

  /// **屏幕比例位置（0~1）**：`v*.x` / `v*.y` 这种「把特效挪到屏幕哪个点」的参数。
  ///
  /// ⚠️ 它和 [percent] **不是一回事**，别合并：
  /// - 调节粒度 **0.1%**（[kFxPosStep] = 0.001 ⇒ 滑杆 1000 档）；[percent] 仍是 2% 一档。
  ///   用户原话：「视觉特效的位置调整的精细度还不够，会跳过一些我想要放置的地方」——
  ///   2% 一格在 1080 宽的手机上约 9 个逻辑像素，想放的地方落在档与档之间就永远够不着。
  /// - 读数带**一位小数**（`50.0%`），[percent] 仍是整数（`50%`）。
  /// - 设置页额外配一对 −/+ 微调按钮（`widgets/fx_step_button.dart`），
  ///   手指拖个大概、按钮对准。
  position,

  /// 像素
  px,

  /// 秒
  sec,

  /// 开关（0/1，UI 显示为 Switch 而不是滑块）
  toggle,

  /// 颜色：值是「主题色稳定槽位」，-1 = 跟随主题。
  /// UI 不显示滑块，而是渲染一条色卡（跟随主题 + 内置主题色 + 用户自定义色）。
  color,
}

/// 一个特效参数：范围 / 缺省 / 显示格式 / 是否影响粒子生成。
class FxParam {
  const FxParam(
    this.key,
    this.label,
    this.min,
    this.max,
    this.def,
    this.format, {
    this.particles = false,
    this.shared = false,
  });

  /// 全键（如 `a0.count`）；同一特效开多个图层时，后面的图层会带上 `#槽位` 上标
  /// （如 `a0#2.count`），见 [fxInstanceKey]。
  final String key;

  /// 中文标签
  final String label;

  final double min;
  final double max;
  final double def;
  final FxFormat format;

  /// 改这个参数需重新生成粒子列表（数量 / 大小 / 随机度这类生成端属性）。
  /// 速度、亮度这类只在绘制端读的参数标 false，拖动时零重建、即时生效。
  final bool particles;


  /// 「整组公共」参数：**永远读写不带图层上标的老键**（如 `v0.link`），
  /// 不管在哪个图层的设置页里改，改的都是同一个值。
  /// 只有描述「多个图层之间怎么协作」的参数才该标它（目前只有爱心的牵手联动：
  /// 牵不牵手是整条链的属性，不是某一颗爱心的属性）。
  final bool shared;

  /// 滑块右侧的数值文案。
  String display(double v) => switch (format) {
        FxFormat.times => '×${v.toStringAsFixed(2)}',
        FxFormat.integer => '${v.round()}',
        FxFormat.percent => '${(v * 100).round()}%',
        FxFormat.position => '${(v * 100).toStringAsFixed(1)}%',
        FxFormat.px => '${v.round()} px',
        FxFormat.sec => '${v.toStringAsFixed(1)} s',
        FxFormat.toggle => v > 0.5 ? '开' : '关',
        FxFormat.color => '',
      };

  /// 开关型参数：UI 用 Switch 呈现。
  bool get isToggle => format == FxFormat.toggle;

  /// 颜色型参数：UI 用色卡条呈现。
  bool get isColor => format == FxFormat.color;
}

/// 一个特效：属于哪个区、区内索引（与 AppConfig 的 effect 字段一致）、名称图标与参数表。
class FxEffect {
  const FxEffect({
    required this.group,
    required this.index,
    required this.name,
    required this.icon,
    required this.desc,
    required this.params,
    this.tintable = true,
    this.tintHint,
  });

  /// 区前缀：v 视觉 / r 律动 / a 氛围 / e 边框
  final String group;

  /// 区内索引（与 `AppConfig.visualEffect` 等字段的取值一致，跳号沿用旧索引）
  final int index;

  final String name;
  final IconData icon;

  /// 一句话说明（列表卡片副标题、设置页顶部）
  final String desc;

  final List<FxParam> params;

  /// 是否**没有**自选颜色。
  /// true（默认）= 这个特效的参数表里有「颜色」，用户能从主题色列表里挑一套
  /// （含自己建的自定义色），也可以选回「跟随主题」。
  /// false = 固定本色：火焰橙 / 花瓣粉 / 雨丝白 / 雪白 / 阳光暖黄 / 萤火虫暖绿 /
  /// 烟花彩 —— 设置页不显示颜色选择器，改显示 [tintHint] 一行说明。
  final bool tintable;

  /// 不显示颜色选择器时的说明文案（不填用默认那句）。
  final String? tintHint;

  /// 参数键前缀（如 `a5`）
  String get prefix => '$group$index';
}

/// 区定义：前缀 / 标题 / 图标 / 副标题。
class FxGroupInfo {
  const FxGroupInfo(this.id, this.title, this.icon, this.desc);
  final String id;
  final String title;
  final IconData icon;
  final String desc;
}

const List<FxGroupInfo> kFxGroups = [
  FxGroupInfo('v', '视觉', Icons.favorite, '背景中央的造型动效，占屏面积最大'),
  FxGroupInfo('r', '律动', Icons.graphic_eq, '播放栏顶部随音乐实时跳动的频谱'),
  FxGroupInfo('a', '氛围', Icons.auto_awesome, '铺满整屏的环境粒子与光影'),
  FxGroupInfo('e', '边框', Icons.crop_free, '贴着屏幕四边的一圈光效'),
];

// ── 参数构造小工具（少写一堆重复字段）─────────────────────────────────────

/// 位置类参数的调节步长：**滑杆分档与 −/+ 按钮步长共用这一个数**。
///
/// 0.001 = 屏幕比例的 0.1%（1080 宽 ≈ 1 个逻辑像素，比原来 0.02 的约 9 个像素细 20 倍）。
/// ⛔ 别在两处各写一个 0.001，也别顺手把它接到别的格式上（[FxFormat.percent] 仍是 0.02）。
const double kFxPosStep = 0.001;

FxParam _x(String k, String label, double min, double max, double def,
        {bool particles = false, bool shared = false}) =>
    FxParam(k, label, min, max, def, FxFormat.times,
        particles: particles, shared: shared);
FxParam _p(String k, String label, double min, double max, double def,
        {bool particles = false}) =>
    FxParam(k, label, min, max, def, FxFormat.percent,
        particles: particles);

/// 屏幕比例位置参数（0~1）：**缺省值与旧版逐字相同**，只是把调节粒度从 2% 提到
/// 0.1%（约半个逻辑像素），并在设置页配一对 −/+ 微调按钮（手指拖个大概、按钮对准）。
FxParam _pos(String k, String label, double def) =>
    FxParam(k, label, 0, 1, def, FxFormat.position);
FxParam _px(String k, String label, double min, double max, double def,
        {bool particles = false}) =>
    FxParam(k, label, min, max, def, FxFormat.px,
        particles: particles);
FxParam _i(String k, String label, double min, double max, int def,
        {bool particles = false, bool shared = false}) =>
    FxParam(k, label, min, max, def.toDouble(), FxFormat.integer,
        particles: particles, shared: shared);
FxParam _s(String k, String label, double min, double max, double def,
        {bool particles = false}) =>
    FxParam(k, label, min, max, def, FxFormat.sec,
        particles: particles);
FxParam _t(String k, String label, bool def,
        {bool shared = false}) =>
    FxParam(k, label, 0, 1, def ? 1 : 0, FxFormat.toggle,
        shared: shared);

/// 颜色参数：值 = 颜色槽位（-1 = 跟随主题，0~39 内置主题色，40+ 自定义色，
/// 1000+ 旧的氛围色调 —— 见 theme.dart 的 kFxTintPresets）。
/// 上界给到 1010，是为了让「内置色 / 自定义色 / 氛围色调」三类槽位都塞得下：
/// `AppConfig.setFx` 会按本范围 clamp，上界给小了会把槽位砍成别的颜色。
/// [def] 默认 -1（跟随主题）；氛围区那六个能选色的特效用 [kFxTintDefault]（水蓝），
/// 因为**改动前它们的默认色就是固定的水蓝**，不写回水蓝会让默认观感整体换色。
FxParam _c(String k, String label, {double def = -1}) =>
    FxParam(k, label, -1, 1010, def, FxFormat.color);

// ── 全部特效（顺序 = 列表页展示顺序）───────────────────────────────────────
final List<FxEffect> kFxEffects = [
  // ══ 视觉 ══════════════════════════════════════════════════════════════════
  FxEffect(
    group: 'v',
    index: 0,
    name: '爱心',
    icon: Icons.favorite,
    desc: '几圈抖动线条围成的心，中间吊着歌名，两侧拉线到屏幕边缘',
    params: [
      _pos('v0.x', '水平位置', 0.5),
      _pos('v0.y', '垂直位置', 0.47),
      _c('v0.tint', '颜色'),
      // ── 牵手联动：爱心开了两颗以上才有意义，所以这三项是「整组公共」参数 ──
      _t('v0.link', '牵手联动', false,
          shared: true),
      _i('v0.hands', '每只手线条', 1, 8, 5,
          shared: true),
      _x('v0.knot', '牵手结大小', 0, 2, 1,
          shared: true),
      _x('v0.size', '整体大小', 0.6, 1.5, 1.0),
      _x('v0.beat', '心跳频率', 0.5, 2.0, 1.0),
      _x('v0.title', '歌名字号', 0.6, 1.8, 1.0),
      _x('v0.line', '线条粗细', 0.5, 2.0, 1.0),
      _x('v0.jitter', '手绘抖动', 0, 2.0, 1.0),
      _x('v0.tassel', '流苏长度', 0, 1.8, 1.0),
      _i('v0.tasselN', '流苏根数', 0, 12, 8),
      _i('v0.sparks', '心尖火花', 0, 10, 5),
    ],
  ),
  FxEffect(
    group: 'v',
    index: 1,
    name: '旋转方块',
    icon: Icons.view_in_ar,
    desc: '两个立方体线框同中心反向翻滚，带透视近大远小',
    params: [
      _pos('v1.x', '水平位置', 0.5),
      _pos('v1.y', '垂直位置', 0.47),
      _c('v1.tint', '颜色'),
      _x('v1.size', '整体大小', 0.6, 1.5, 1.0),
      _x('v1.spin', '旋转速度', 0.2, 3.0, 1.0),
      _i('v1.count', '方块对数', 1, 3, 1),
      _x('v1.depth', '立体深度', 0.5, 3.0, 1.0),
      _x('v1.line', '线条粗细', 0.6, 2.0, 1.0),
    ],
  ),
  FxEffect(
    group: 'v',
    index: 2,
    name: '粒子漩涡',
    icon: Icons.blur_on,
    desc: '中心星核 + 螺旋旋臂，粒子沿螺旋被吸进去，吸入口会闪白',
    params: [
      _pos('v2.x', '水平位置', 0.5),
      _pos('v2.y', '垂直位置', 0.47),
      _c('v2.tint', '颜色'),
      _x('v2.size', '漩涡大小', 0.6, 1.5, 1.0),
      _x('v2.spin', '旋转速度', 0.2, 3.0, 1.0),
      _i('v2.arms', '旋臂数量', 2, 8, 5),
      _i('v2.count', '粒子数量', 60, 400, 220, particles: true),
      _x('v2.core', '星核大小', 0.1, 0.4, 0.22),
      _x('v2.spiral', '螺旋卷曲', 1, 6, 3.0),
      _x('v2.tail', '粒子拖尾', 0, 16, 8),
    ],
  ),
  FxEffect(
    group: 'v',
    index: 3,
    name: '能量光球',
    icon: Icons.brightness_7,
    desc: '湍流能量球 + 一圈圈收缩扩张的能量环，环上有流光在跑',
    params: [
      _pos('v3.x', '水平位置', 0.5),
      _pos('v3.y', '垂直位置', 0.47),
      _c('v3.tint', '颜色'),
      _x('v3.size', '光球大小', 0.6, 1.5, 1.0),
      _x('v3.glow', '光球亮度', 0.5, 1.6, 1.0),
      _x('v3.speed', '环脉动速度', 0.3, 2.5, 1.0),
      _x('v3.beat', '脉动频率', 0.5, 2.0, 1.0),
      _i('v3.rings', '能量环数', 2, 8, 5),
      _i('v3.dots', '环上流光', 0, 6, 3),
      _i('v3.veins', '能量脉络', 0, 14, 7),
      _x('v3.pulse', '节拍响应', 0, 1.5, 1.0),
    ],
  ),
  FxEffect(
    group: 'v',
    index: 4,
    name: '粒子聚散',
    icon: Icons.blur_circular,
    desc: '粒子聚成心形再散开，散开时拉出拖尾，聚拢顶点整体白闪',
    params: [
      _pos('v4.x', '水平位置', 0.5),
      _pos('v4.y', '垂直位置', 0.47),
      _c('v4.tint', '颜色'),
      _x('v4.size', '心形大小', 0.6, 1.5, 1.0),
      _x('v4.speed', '聚散频率', 0.3, 2.5, 1.0),
      _i('v4.count', '粒子数量', 60, 400, 180, particles: true),
      _x('v4.scatter', '散开半径', 0.3, 1.0, 0.55),
      _x('v4.tail', '散开拖尾', 0, 12, 4.2),
    ],
  ),
  FxEffect(
    group: 'v',
    index: 5,
    name: '万花筒',
    icon: Icons.auto_awesome_motion,
    desc: '多条波形臂绕中心多重旋转对称，整体随节奏收缩扩张',
    params: [
      _pos('v5.x', '水平位置', 0.5),
      _pos('v5.y', '垂直位置', 0.47),
      _c('v5.tint', '颜色'),
      _x('v5.size', '整体大小', 0.6, 1.5, 1.0),
      _i('v5.arms', '对称臂数', 4, 16, 8),
      _x('v5.spin', '旋转速度', 0.2, 3.0, 1.0),
      _x('v5.wiggle', '波形摆动', 0, 0.5, 0.20),
      _i('v5.dots', '臂上流光', 0, 4, 2),
      _t('v5.poly', '外圈轮廓', true),
    ],
  ),
  FxEffect(
    group: 'v',
    index: 6,
    name: '3D 深度球',
    icon: Icons.public,
    desc: '球面粒子绕倾斜轴旋转，近大远小有视差，外带经纬线框',
    params: [
      _pos('v6.x', '水平位置', 0.5),
      _pos('v6.y', '垂直位置', 0.47),
      _c('v6.tint', '颜色'),
      _x('v6.size', '球体大小', 0.6, 1.5, 1.0),
      _x('v6.spin', '旋转速度', 0.2, 3.0, 1.0),
      _x('v6.tilt', '倾斜角度', 0, 1, 0.5),
      _x('v6.depth', '立体深度', 0.5, 3.0, 1.0),
      _i('v6.count', '表面粒子', 60, 400, 150, particles: true),
      _t('v6.grid', '经纬线框', true),
    ],
  ),
  FxEffect(
    group: 'v',
    index: 7,
    name: '歌词逐字',
    icon: Icons.subtitles,
    desc: '当前歌词行在中央随进度逐字点亮，下方挂译文',
    params: [
      _pos('v7.x', '水平位置', 0.5),
      _pos('v7.y', '垂直位置', 0.47),
      _c('v7.tint', '颜色'),
      _x('v7.size', '整体大小', 0.6, 1.5, 1.0),
      _x('v7.font', '字号', 0.6, 1.8, 1.0),
      _x('v7.wrap', '行宽', 0.4, 1.1, 0.66),
      _x('v7.dim', '未唱部分', 0.1, 0.7, 0.32),
      _x('v7.sub', '译文比例', 0.4, 1.2, 0.6),
    ],
  ),

  // ══ 律动 ══════════════════════════════════════════════════════════════════
  FxEffect(
    group: 'r',
    index: 0,
    name: '频谱',
    icon: Icons.bar_chart,
    desc: '最经典的柱状频谱，低频到高频由主题色渐到浅色',
    params: [
      _px('r0.gap', '柱间距', 0, 8, 3),
      _px('r0.radius', '柱圆角', 0, 8, 3),
      _px('r0.minH', '静止柱高', 2, 20, 4),
      _x('r0.glow', '柱顶光晕', 0, 1.5, 1.0),
      _t('r0.peak', '峰值残响', true),
    ],
  ),
  FxEffect(
    group: 'r',
    index: 1,
    name: '波形',
    icon: Icons.show_chart,
    desc: '把频段连成一条中心线上下对称的平滑曲线，示波器观感',
    params: [
      _x('r1.amp', '振幅', 0.15, 0.5, 0.44),
      _px('r1.line', '曲线粗细', 1, 5, 2.2),
      _p('r1.fill', '填充浓度', 0, 0.6, 0.30),
      _t('r1.round', '圆滑曲线', true),
    ],
  ),
  FxEffect(
    group: 'r',
    index: 2,
    name: '环形',
    icon: Icons.donut_large,
    desc: '各频段沿圆周径向铺开，中心留一圈随能量呼吸的空腔',
    params: [
      _x('r2.inner', '中心空腔', 0.1, 0.6, 0.30),
      _px('r2.line', '环线粗细', 1, 5, 2.2),
      _x('r2.glow', '空腔辉光', 0, 2.0, 1.0),
      _t('r2.peak', '峰值亮点', true),
    ],
  ),
  FxEffect(
    group: 'r',
    index: 3,
    name: '圆点',
    icon: Icons.circle,
    desc: '一排圆点按频段原地上下跳，带光晕和白热高光核',
    params: [
      _x('r3.r', '圆点大小', 0.15, 0.6, 0.32),
      _px('r3.gap', '点间距', 0, 10, 4),
      _x('r3.amp', '跳动幅度', 0.15, 0.5, 0.34),
      _x('r3.glow', '光晕', 0, 1.5, 1.0),
      _t('r3.peak', '峰值亮点', true),
    ],
  ),
  FxEffect(
    group: 'r',
    index: 5,
    name: '镜像',
    icon: Icons.flip,
    desc: '柱子以中心基线上下对称，下半截半透明，层次翻倍',
    params: [
      _px('r5.gap', '柱间距', 0, 8, 3),
      _px('r5.radius', '柱圆角', 0, 6, 2.5),
      _x('r5.down', '下柱浓度', 0.2, 1.0, 0.55),
      _t('r5.peak', '峰值亮点', true),
    ],
  ),
  FxEffect(
    group: 'r',
    index: 6,
    name: '3D 频谱',
    icon: Icons.view_in_ar,
    desc: '每根柱顶加一块向右后倾的斜顶面，挤出立体感',
    params: [
      _px('r6.skew', '顶面后倾', 0, 8, 2.6),
      _px('r6.thick', '顶面厚度', 0, 8, 2.4),
      _px('r6.gapW', '柱间缝', 0, 6, 2),
      _x('r6.alpha', '柱体浓度', 0.3, 1.0, 0.80),
    ],
  ),

  // ══ 氛围 ══════════════════════════════════════════════════════════════════
  FxEffect(
    group: 'a',
    index: 0,
    name: '雨滴',
    tintable: false, // 雨丝本色是白的水光，不该被色调染
    icon: Icons.water_drop,
    desc: '三层景深的斜雨丝，带重力加速与落地水花',
    params: [
      _i('a0.count', '雨丝数量', 10, 160, 32, particles: true),
      _x('a0.speed', '下落速度', 0.3, 3.0, 1.0),
      _x('a0.len', '雨丝长度', 0.5, 2.0, 1.0, particles: true),
      _x('a0.width', '雨丝粗细', 0.5, 2.0, 1.0, particles: true),
      _x('a0.wind', '风斜强度', 0, 2.0, 1.0, particles: true),
      _x('a0.random', '随机度', 0.3, 2.0, 1.0, particles: true),
      _t('a0.splash', '落地水花', true),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 1,
    name: '星空',
    icon: Icons.star,
    desc: '三档星点 + 十字大星 + 极淡星云底，星星会换位置',
    params: [
      _c('a1.tint', '颜色', def: kFxTintDefault),
      _i('a1.count', '星星数量', 20, 300, 48, particles: true),
      _x('a1.size', '星点大小', 0.5, 2.0, 1.0, particles: true),
      _x('a1.twinkle', '闪烁速度', 0, 2.5, 1.0, particles: true),
      _p('a1.big', '大星比例', 0, 0.5, 0.20, particles: true),
      _x('a1.life', '换位周期', 0.3, 3.0, 1.0, particles: true),
      _x('a1.nebula', '星云浓度', 0, 3.0, 1.0),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 2,
    name: '阳光',
    tintable: false, // 阳光本色就是暖黄，不跟色调
    icon: Icons.wb_sunny,
    desc: '树荫下透光的斑驳光影：叶影 + 暖光团 + 刺眼亮核 + 空气浮尘',
    params: [
      _i('a2.count', '光斑数量', 10, 120, 38, particles: true),
      _x('a2.size', '光斑大小', 0.5, 2.0, 1.0, particles: true),
      _x('a2.breathe', '明暗呼吸', 0.3, 2.5, 1.0, particles: true),
      _p('a2.warm', '暖度', 0, 1, 0),
      _i('a2.dust', '空气浮尘', 0, 40, 14),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 3,
    name: '彩星',
    icon: Icons.auto_awesome,
    desc: '和星空同源，但每颗星按种子取鲜艳色相，星云也带彩',
    params: [
      _c('a3.tint', '颜色', def: kFxTintDefault),
      _i('a3.count', '星星数量', 20, 300, 48, particles: true),
      _x('a3.size', '星点大小', 0.5, 2.0, 1.0, particles: true),
      _x('a3.twinkle', '闪烁速度', 0, 2.5, 1.0, particles: true),
      _p('a3.big', '大星比例', 0, 0.5, 0.20, particles: true),
      _x('a3.life', '换位周期', 0.3, 3.0, 1.0, particles: true),
      _x('a3.nebula', '星云浓度', 0, 3.0, 1.0),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 4,
    name: '萤火虫',
    tintable: false, // 萤火虫是暖黄/暖绿，不跟色调
    icon: Icons.lightbulb_outline,
    desc: '暖黄/暖绿小光点在原地利萨如游走，忽明忽暗',
    params: [
      _i('a4.count', '萤火虫数量', 6, 120, 26, particles: true),
      _x('a4.size', '光点大小', 0.5, 2.0, 1.0, particles: true),
      _x('a4.glow', '光晕大小', 0.5, 2.0, 1.0),
      _x('a4.blink', '明灭速度', 0.3, 2.5, 1.0, particles: true),
      _x('a4.drift', '游走速度', 0.3, 2.5, 1.0, particles: true),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 5,
    name: '极光',
    icon: Icons.waves,
    desc: '顶部成片、向下散成丝缕的噪声帘幕（GPU 着色器绘制）',
    params: [
      _c('a5.tint', '颜色', def: kFxTintDefault),
      _x('a5.speed', '流动速度', 0.3, 2.5, 1.0),
      _x('a5.alpha', '光带亮度', 0.3, 1.6, 1.0),
      _p('a5.mix', '主色↔浅色', 0, 1, 0),
      _x('a5.beat', '节拍响应', 0, 2.0, 1.0),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 6,
    name: '飘雪',
    tintable: false, // 雪是白的，不跟色调
    icon: Icons.ac_unit,
    desc: '六角结晶与小雪粒混下，缓慢自转、摆动飘落',
    params: [
      _i('a6.count', '雪片数量', 10, 110, 18, particles: true),
      _x('a6.size', '雪片大小', 0.5, 2.0, 1.0, particles: true),
      _x('a6.speed', '下落速度', 0.3, 3.0, 1.0),
      _x('a6.sway', '横向摆动', 0, 2.0, 1.0, particles: true),
      _x('a6.random', '随机度', 0.3, 2.0, 1.0, particles: true),
      _t('a6.crystal', '六角结晶', true),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 7,
    name: '气泡',
    icon: Icons.bubble_chart,
    desc: '从底部升起的水泡，带薄膜虹彩、上升中微微放大',
    params: [
      _c('a7.tint', '颜色', def: kFxTintDefault),
      _i('a7.count', '气泡数量', 8, 100, 19, particles: true),
      _x('a7.size', '气泡大小', 0.5, 2.0, 1.0, particles: true),
      _x('a7.speed', '上升速度', 0.3, 3.0, 1.0),
      _x('a7.random', '随机度', 0.3, 2.0, 1.0, particles: true),
      _x('a7.grow', '上升放大', 0, 1.0, 0.4),
      _x('a7.film', '薄膜亮度', 0.3, 2.0, 1.0),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 8,
    name: '烟花',
    tintable: false, // 烟花自带随机彩色，不跟色调
    icon: Icons.celebration,
    desc: '阻尼弹道的炸裂烟花，白热爆闪 + 光丝拖尾 + 双色混喷',
    params: [
      _i('a8.bursts', '同屏烟花数', 1, 12, 7, particles: true),
      _x('a8.density', '火花密度', 0.3, 1.5, 1.0, particles: true),
      _x('a8.scale', '爆炸规模', 0.5, 2.0, 1.0),
      _s('a8.interval', '绽放间隔', 2, 16, 6.0),
      _x('a8.gravity', '下坠重力', 0.3, 3.0, 1.0),
      _x('a8.trail', '光丝拖尾', 0, 2.0, 1.0),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 10,
    name: '火焰',
    tintable: false, // 火焰本色是橙黄，不跟色调
    icon: Icons.local_fire_department,
    desc: '扎根底部的通透火苗，三层泪滴路径 + 上升火星余烬',
    params: [
      _i('a10.count', '火苗簇数', 4, 60, 16, particles: true),
      _x('a10.size', '火苗宽度', 0.5, 2.0, 1.0, particles: true),
      _x('a10.height', '火舌高度', 0.4, 2.0, 1.0),
      _x('a10.flicker', '闪烁速度', 0.3, 2.5, 1.0, particles: true),
      _x('a10.glow', '地面火光', 0, 2.0, 1.0),
      _i('a10.embers', '火星数量', 0, 4, 2),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 11,
    name: '水面',
    icon: Icons.water,
    desc: '整片水域的焦散光网与横向波光带（GPU 着色器绘制）',
    params: [
      _c('a11.tint', '颜色', def: kFxTintDefault),
      _x('a11.speed', '水流速度', 0.3, 2.5, 1.0),
      _x('a11.alpha', '水面亮度', 0.3, 1.6, 1.0),
      _p('a11.mix', '主色↔浅色', 0, 1, 0),
      _x('a11.beat', '节拍响应', 0, 2.0, 1.0),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 12,
    name: '花瓣',
    tintable: false, // 花瓣是粉/白/暖杏固定三色，不跟色调
    icon: Icons.local_florist,
    desc: '粉白黄三色花瓣，飘落 + 摆动 + 自转 + 绕长轴翻面',
    params: [
      _i('a12.count', '花瓣数量', 6, 80, 19, particles: true),
      _x('a12.size', '花瓣大小', 0.5, 2.0, 1.0, particles: true),
      _x('a12.speed', '飘落速度', 0.3, 3.0, 1.0),
      _x('a12.spin', '自转速度', 0, 2.0, 1.0, particles: true),
      _x('a12.drift', '横向漂移', 0, 2.0, 1.0, particles: true),
      _x('a12.random', '随机度', 0.3, 2.0, 1.0, particles: true),
    ],
  ),
  FxEffect(
    group: 'a',
    index: 13,
    name: '波纹',
    icon: Icons.blur_on,
    desc: '水面上的涟漪圈：错相多层同心圆 + 迎光高光弧',
    params: [
      _c('a13.tint', '颜色', def: kFxTintDefault),
      _i('a13.count', '落点数量', 4, 60, 10, particles: true),
      _x('a13.speed', '扩散速度', 0.3, 3.0, 1.0, particles: true),
      _x('a13.maxR', '最大半径', 0.5, 2.0, 1.0, particles: true),
      _x('a13.random', '随机度', 0.3, 2.0, 1.0, particles: true),
      _i('a13.rings', '每点圈数', 1, 4, 3),
      _t('a13.highlight', '迎光高光', true),
    ],
  ),

  // ══ 边框 ══════════════════════════════════════════════════════════════════
  FxEffect(
    group: 'e',
    index: 0,
    name: '呼吸边框',
    icon: Icons.crop_din,
    desc: '三层描边模拟柔边光晕，贴着四边缓慢明暗呼吸',
    params: [
      _x('e0.speed', '呼吸速度', 0.3, 2.5, 1.0),
      _px('e0.inset', '内缩距离', 0, 24, 7),
      _px('e0.radius', '圆角大小', 0, 60, 30),
      _x('e0.line', '线宽', 0.5, 2.0, 1.0),
      _x('e0.corner', '四角光斑', 0, 2.0, 1.0),
      _x('e0.glow', '整体亮度', 0.5, 1.8, 1.0),
    ],
  ),
  FxEffect(
    group: 'e',
    index: 1,
    name: '流光边框',
    icon: Icons.bolt,
    desc: '高亮光带沿四条边循环跑动，头亮尾隐的彗星观感',
    params: [
      _x('e1.speed', '行进速度', 0.3, 3.0, 1.0),
      _x('e1.tail', '彗尾长度', 0.05, 0.4, 0.16),
      _i('e1.lanes', '光带条数', 1, 3, 2),
      _px('e1.line', '光带粗细', 1, 6, 3.0),
      _x('e1.corner', '四角积淀', 0, 2.0, 1.0),
    ],
  ),
  FxEffect(
    group: 'e',
    index: 4,
    name: '歌词跑马灯',
    icon: Icons.subtitles,
    desc: '当前歌词行沿底边循环滚动（无词时滚歌名），首尾无缝',
    params: [
      _x('e4.speed', '滚动速度', 0.3, 3.0, 1.0),
      _x('e4.font', '字号', 0.7, 2.0, 1.0),
      _px('e4.bottom', '离底距离', 60, 260, 138),
      _x('e4.glow', '外发光', 0, 2.0, 1.0),
      _px('e4.spacing', '字间距', 0, 6, 1.5),
    ],
  ),
  FxEffect(
    group: 'e',
    index: 5,
    name: '频谱灯带',
    icon: Icons.graphic_eq,
    desc: '底边一排灯珠随真实频谱亮起，冲得高的会向上拖光尾',
    params: [
      _i('e5.lamps', '灯珠数量', 12, 72, 36),
      _px('e5.h', '灯珠高度', 3, 20, 7),
      _x('e5.glow', '灯顶光晕', 0, 2.0, 1.0),
      _px('e5.bottom', '离底距离', 0, 60, 9),
      _t('e5.tail', '能量拖尾', true),
    ],
  ),
];

/// 注册表门面：按键查参数、取缺省值。
class Fx {
  Fx._();

  /// 全部参数按键索引（启动时构建一次）。
  static final Map<String, FxParam> all = {
    for (final e in kFxEffects)
      for (final p in e.params) p.key: p,
  };

  /// 全部「区前缀 + 索引」标识（判断某个索引是不是还在架上）。
  static final Set<String> _ids = {
    for (final e in kFxEffects) '${e.group}${e.index}',
  };

  /// 该区这个索引是否还存在（老存值可能落在已下架的索引上）。
  /// 注意**别拿某一个具体参数键去判断存在性** —— 极光/水面/频谱灯带这类
  /// 特效并没有 `count` 或 `speed` 参数，会被误判成下架而回落到本区第一项。
  static bool has(String group, int index) => _ids.contains('$group$index');

  /// 参数缺省值；键不存在返回 0（绘制端拿到 0 也不会崩）。
  /// 传「带图层上标的键」（`v0#2.size`）也对：先解析回基键再查。
  static double def(String key) => param(key)?.def ?? 0;

  /// 按键查参数，**自动剥掉图层上标**（`v0#2.size` → `v0.size`）。
  /// 所有「按 catalog 声明的范围 clamp / 查存在性」的地方都必须走它。
  static FxParam? param(String key) => all[fxBaseKey(key)];

  /// 按区取特效列表（列表页用）。
  static List<FxEffect> of(String group) =>
      [for (final e in kFxEffects) if (e.group == group) e];

  /// 按区 + 索引取特效；找不到返回 null。
  static FxEffect? find(String group, int index) {
    for (final e in kFxEffects) {
      if (e.group == group && e.index == index) return e;
    }
    return null;
  }

  /// 某区全部参数的键（恢复默认 / 备份用）。
  static List<String> keysOf(String group) =>
      [for (final e in of(group)) for (final p in e.params) p.key];
}

/// 绘制端读参数的统一入口：缺省回落到注册表默认值。
/// 传 null（理论上不会）时也安全。
double fxv(Map<String, double>? fx, String key) => fx?[key] ?? Fx.def(key);

/// 开关类参数的读取。
bool fxo(Map<String, double>? fx, String key) => fxv(fx, key) > 0.5;

/// 颜色类参数的读取：**没设过时回落到 catalog 声明的缺省**（氛围那 6 个能选色的
/// 特效缺省是「水蓝」槽位 `kFxTintDefault`，不是 -1）；只有**键根本没声明**
/// （例如固定本色的雨滴/火焰）才给 -1。
/// 不能直接用 [fxv] —— 它对未声明的键返回 `Fx.def` = 0，而 0 是「经典蓝」槽位，
/// 会把从没选过颜色的特效误染成蓝色。
int fxc(Map<String, double>? fx, String key) {
  final v = fx?[key];
  if (v != null) return v.round();
  return Fx.param(key) != null ? Fx.def(key).round() : -1;
}

// ── 图层（同一特效能同时开多个，每个一套自己的参数）─────────────────────────
//
// 参数键 = 基键 + 可选的图层上标：`v0.size`（槽位 0，= 改动前的老键）
// / `v0#2.size`（槽位 2）。槽位 0 不带后缀，是为了让**老用户的存值一个都不动**：
// 单个图层的画面、备份、视觉方案恢复全部与改动前逐帧一致。

/// 图层上标分隔符。基键里不会出现 `#`，所以解析无歧义。
const String _kSlotMark = '#';

/// 图层参数键 → 注册表基键：`v0#2.size` → `v0.size`；本来就是基键则原样返回。
String fxBaseKey(String key) {
  final i = key.indexOf(_kSlotMark);
  if (i < 0) return key;
  final d = key.indexOf('.', i);
  return d < 0 ? key.substring(0, i) : key.substring(0, i) + key.substring(d);
}

/// 图层上标后缀：槽位 ≤ 0（老键）或 [shared] 参数（整组公共项）时**空串**。
String _slotMark(int slot, bool shared) =>
    (shared || slot <= 0) ? '' : '$_kSlotMark$slot';

/// 键**前缀**（不含 `.参数名`）+ 图层槽位 → 带槽位的前缀：`v2` @1 → `v2#1`。
///
/// ⚠️ 绘制端是按「前缀 + `.参数名`」拼键的，所以它**必须走这里**，
/// ⛔ **别把 [fxInstanceKey] 当「前缀工具」用**：那位的入参是**带点的完整基键**
/// （`v2.x`），传给它一个不带点的前缀（`v2`）时它找不到那个点 ⇒ **静默原样返回**
/// ⇒ 上标被吃掉、整层参数全读成裸键。症状：「第 2 层之后的滑杆怎么拖都没反应，
/// 反而第 1 层的滑杆会同时挪动好几层」（`ambient_painter.dart` 的 `_vPrefix`
/// 就是这么踩的）。
String fxInstancePrefix(String base, int slot, {bool shared = false}) =>
    '$base${_slotMark(slot, shared)}';

/// 基键 + 图层槽位 → 实际存储键。槽位 ≤ 0 用老键；[shared] 参数永远用老键。
/// 传进来的本来就是**不带点的前缀**（`v2`）时按前缀处理（`v2#1`），与
/// [fxInstancePrefix] 一致 —— 两种入参都不会再静默丢掉槽位。
String fxInstanceKey(String base, int slot, {bool shared = false}) {
  final d = base.indexOf('.');
  final mark = _slotMark(slot, shared);
  if (d < 0) return '$base$mark';
  return '${base.substring(0, d)}$mark${base.substring(d)}';
}

/// 视觉区的一个图层：同一个特效能同时开多个（例：三颗爱心各调各的）。
/// [slot] 是该图层的参数槽位（0 = 老键；> 0 = `v0#2.` 前缀），**删图层不会挪别人的槽位**，
/// 所以增删图层不会串参数。
class VisualLayer {
  const VisualLayer({required this.effect, required this.slot, this.enabled = true});

  /// 视觉特效索引（v 区，见 [FxEffect.index]）
  final int effect;

  /// 参数槽位
  final int slot;

  /// 该图层是否显示（目录页的眼睛开关）
  final bool enabled;

  VisualLayer copyWith({int? effect, bool? enabled}) => VisualLayer(
        effect: effect ?? this.effect,
        slot: slot,
        enabled: enabled ?? this.enabled,
      );

  Map<String, dynamic> toJson() =>
      {'effect': effect, 'slot': slot, 'enabled': enabled};

  /// 反序列化；数据不合法（老格式 / 手改坏了）返回 null，由调用方跳过。
  static VisualLayer? fromJson(Object? o) {
    if (o is! Map) return null;
    final e = o['effect'];
    final s = o['slot'];
    if (e is! int || s is! int || s < 0) return null;
    return VisualLayer(effect: e, slot: s, enabled: o['enabled'] != false);
  }

  @override
  bool operator ==(Object other) =>
      other is VisualLayer &&
      other.effect == effect &&
      other.slot == slot &&
      other.enabled == enabled;

  @override
  int get hashCode => Object.hash(effect, slot, enabled);
}

/// 视觉区图层数上限（多了既挤屏也拖帧率；每层都是一整套路径绘制）。
const int kMaxVisualLayers = 6;

/// 牵手链：n 颗爱心并排（含彼此相牵的手）刚好占用屏幕宽度的这个比例。
const double kHeartChainSpan = 0.9;

/// 基础心宽占屏宽的比例（与 painter 里的 `min(w*0.66, h*0.52)` 一致）。
const double _kHeartWidthFrac = 0.66;

/// 相邻两颗之间那段「手」的长度 ≈ 心宽的这个比例。
const double _kHeartHandFrac = 0.35;

/// 牵手时每颗爱心的缩放倍数：让 n 颗爱心 + (n-1) 段手正好铺满 [kHeartChainSpan]。
/// 单颗返回 1.0（不缩放）—— 所以只开一颗爱心时画面与改动前逐帧一致。
double heartChainFit(int n) {
  if (n < 2) return 1.0;
  final w = kHeartChainSpan / ((1 + _kHeartHandFrac) * n - _kHeartHandFrac);
  return (w / _kHeartWidthFrac).clamp(0.0, 1.0);
}

/// 牵手时相邻两颗爱心的中心间距（屏幕宽度比例）= 心宽 + 一段手长。
/// 与 [heartChainFit] 同一套假设，改一个必须改另一个。
double heartChainGap(int n) =>
    heartChainFit(n) * _kHeartWidthFrac * (1 + _kHeartHandFrac);

/// 这个颜色**是不是用户显式选过**（存过键）。
/// 「围着选色转 / 只在自选色时染色」这类判断必须用它，不能拿解析后的值去比 ——
/// 氛围那 6 个特效的缺省本身就是一个具体颜色，解析出来永远 ≥ 0。
bool fxcSet(Map<String, double>? fx, String key) =>
    fx != null && fx.containsKey(key);
