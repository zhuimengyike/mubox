#version 460 core
#include <flutter/runtime_effect.glsl>

// Mu Box 极光：分层 fbm 噪声织出流动帘幕，纵向渐隐成丝缕，双色随主题色。
// uniform 顺序即索引顺序（vec2 占 2 个 float 槽、vec3 占 3 个）：
//   0,1 uSize | 2 uTime | 3 uBass | 4 uMelody | 5-7 uColA | 8-10 uColB | 11 uAlpha
uniform vec2 uSize;
uniform float uTime;
uniform float uBass;
uniform float uMelody;
uniform vec3 uColA;
uniform vec3 uColB;
uniform float uAlpha;

out vec4 fragColor;

float hash(vec2 p) {
  return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  float a = hash(i);
  float b = hash(i + vec2(1.0, 0.0));
  float c = hash(i + vec2(0.0, 1.0));
  float d = hash(i + vec2(1.0, 1.0));
  return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 3 阶 fbm：极光的丝缕感来自多尺度噪声叠加。全屏噪声是实打实的 GPU 开销，
// 所以从 4 阶收敛到 3 阶（末尾乘 1.14 补偿总幅度的损失，亮度观感不变）。
float fbm(vec2 p) {
  float v = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 3; i++) {
    v += amp * noise(p);
    p = p * 2.03 + vec2(11.3, 7.7);
    amp *= 0.5;
  }
  return v * 1.14;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float t = uTime;

  // 两层 fbm 帘幕叠加（原三层，第三层权重仅 0.15、肉眼几乎无差）：慢的垫底、快的织丝
  float curtain = 0.0;
  curtain += fbm(vec2(uv.x * 2.4 + t * 0.045, uv.y * 3.2 - t * 0.085)) * 0.62;
  curtain += fbm(vec2(uv.x * 4.6 - t * 0.030, uv.y * 5.0 - t * 0.150)) * 0.38;

  // 竖直帘幕条带（极光的「rays」）：噪声横向压缩成正弦密条，再乘噪声形成断续
  float bands = sin((uv.x * 7.5 + curtain * 4.0) * 3.14159265) * 0.5 + 0.5;
  bands = pow(bands, 2.6);

  // 弧带包络：真实极光是横跨天空的一条弧带，不是满屏均匀的雾。
  // 弧线随 x 缓慢起伏，竖向高斯衰减 —— 能量集中在弧带附近，上下自然淡出。
  float arcY = 0.30 + 0.09 * sin(uv.x * 3.1 + t * 0.12);
  float arc = exp(-pow((uv.y - arcY) / 0.30, 2.0));

  // 下部拖丝：弧带往下散成一缕缕（越往下越细碎）
  float strands = mix(1.0, bands, smoothstep(0.0, 0.60, uv.y));

  float glow = bands * arc * strands * (0.55 + 0.80 * curtain);
  glow *= 0.72 + 0.62 * uBass;   // 鼓点：整片极光涌亮
  glow *= 0.86 + 0.34 * uMelody; // 旋律段：更通透
  glow *= 2.10;                  // 整体增益：壁纸上也要一眼看得见

  // 颜色：主题双色打底，再掺入极光本色（青绿 → 紫），避免只有一片灰白雾
  vec3 base = mix(uColA, uColB, clamp(curtain * 1.4 - 0.2, 0.0, 1.0));
  vec3 col = mix(base, vec3(0.32, 1.00, 0.62), 0.42); // 极光青绿
  col = mix(col, vec3(0.58, 0.42, 1.00),             // 上缘偏紫（高空极光的紫边）
      clamp(arcY * 2.2 - uv.y * 2.6, 0.0, 0.55));
  col = mix(col, vec3(1.0), clamp(glow - 0.55, 0.0, 0.45)); // 亮芯偏白

  float a = clamp(glow, 0.0, 1.0) * uAlpha;

  // 夜空星点：按屏幕比例建网格，0.5% 的格子有星。
  // 必须乘「格内衰减」——只按格子取值会把整格点亮成方块（踩过：屏幕上出现一片
  // 十几像素的青绿/紫方块），用 exp(-dot(gv,gv)*k) 收成一颗粒子才对。
  vec2 grid = uv * vec2(uSize.x / uSize.y, 1.0) * 88.0;
  vec2 gp = floor(grid);
  vec2 gv = fract(grid) - 0.5;
  float h = hash(gp);
  float star = step(0.995, h) *
      exp(-dot(gv, gv) * 46.0) *
      (0.50 + 0.50 * sin(t * 2.2 + h * 40.0));
  a = clamp(a + star * 0.95, 0.0, 1.0);

  fragColor = vec4(col * a, a); // 预乘 alpha
}
