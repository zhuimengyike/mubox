#version 460 core
#include <flutter/runtime_effect.glsl>

// Mu Box 水面：两层流动噪声取「等值线脊」做焦散亮纹（真实水面光斑就是这种网状亮线），
// 再叠三条横向波光带 —— 把原本「一圈圈同心圆」变成有水面质感的场景。
//
// uniform 顺序即索引顺序：
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

float fbm(vec2 p) {
  float v = 0.0;
  float amp = 0.5;
  for (int i = 0; i < 3; i++) {
    v += amp * noise(p);
    p = p * 2.03 + vec2(5.3, 17.1);
    amp *= 0.5;
  }
  return v * 1.14;
}

void main() {
  vec2 uv = FlutterFragCoord().xy / uSize;
  float t = uTime;

  // 水面域：按屏幕宽高比取样，避免噪声在竖向被拉伸。
  // focus 做透视：上方（远处）纹路更细密、下方（近处）更舒展，水面有了纵深。
  float focus = mix(1.26, 0.90, smoothstep(0.0, 1.0, uv.y));
  vec2 p = vec2(uv.x * uSize.x / uSize.y, uv.y) * 3.2 * focus;

  // 两层流动噪声（错速反向）：第一层给大结构、第二层被它扰动 → 水面在缓慢流淌
  float w1 = fbm(p + vec2(t * 0.10, -t * 0.07));
  float w2 = fbm(p * 1.9 + vec2(-t * 0.07, t * 0.13) + w1 * 0.70);

  // 焦散主纹：噪声等值线的脊（离 0.5 越近越亮），pow 收窄成细亮网
  float ridge = 1.0 - abs(w2 - 0.5) * 2.0;
  float caustic = pow(clamp(ridge, 0.0, 1.0), 7.0);

  // 第二层更细的焦散（更快、更密）→ 网状光斑有了层次
  float ridge2 =
      1.0 - abs(fbm(p * 3.1 + vec2(t * 0.16, -t * 0.11) + w2 * 0.5) - 0.5) * 2.0;
  caustic += pow(clamp(ridge2, 0.0, 1.0), 9.0) * 0.70;

  // 纵深：上方淡（远处水面）、下方浓（近处水面）。
  // 原实现 smoothstep(0.02, 0.85, uv.y) 到上方 1/4 只剩 0~19%，叠加 pow 收窄的
  // 焦散后上半屏几乎全黑；现在给 0.62 保底 —— 顶部也有清楚的焦散光网，
  // 越往下越浓，远近层次仍在，但不再留白。
  float depth = mix(0.62, 1.0, smoothstep(-0.10, 0.82, uv.y));

  // 横向波光：三条缓慢起伏的细亮带（水面本身的「粼粼」，非涟漪），
  // 纵向铺开到上/中/下三段，顶部同样有波光。
  float band = 0.0;
  for (int i = 0; i < 3; i++) {
    float fi = float(i);
    float yy = 0.18 + fi * 0.24 + 0.03 * sin(uv.x * 6.0 + t * 0.5 + fi * 2.1);
    band += exp(-pow((uv.y - yy) / 0.022, 2.0)) *
        (0.5 + 0.5 * sin(uv.x * 9.0 - t * 0.9 + fi * 1.7));
  }

  float glow = (caustic * (0.55 + 0.50 * w1) + band * 0.32) * depth;
  glow *= 0.75 + 0.45 * uBass;   // 鼓点：水面整体亮一下
  glow *= 0.88 + 0.28 * uMelody; // 旋律段：更通透
  glow *= 1.15;

  vec3 col = mix(uColA, uColB, clamp(w2 * 1.3 - 0.15, 0.0, 1.0));
  col = mix(col, vec3(1.0), clamp(caustic - 0.35, 0.0, 0.55)); // 焦散亮斑偏白

  float a = clamp(glow, 0.0, 1.0) * uAlpha * 0.85;
  fragColor = vec4(col * a, a); // 预乘 alpha
}
