#version 460 core
#include <flutter/runtime_effect.glsl>

// Mu Box 能量球：球内湍流噪声 + 径向能量脉络 + 边缘辉光 + 白热核心，
// 左上打光做出球体明暗。球外直接丢弃（early return，省掉大半片元计算）。
//
// uniform 顺序即索引顺序（vec2 占 2 槽、vec3 占 3 槽）：
//   0,1 uSize | 2 uTime | 3 uBass | 4 uMelody | 5,6 uCenter | 7 uRadius
//   | 8-10 uColA | 11-13 uColB | 14 uAlpha
uniform vec2 uSize;
uniform float uTime;
uniform float uBass;
uniform float uMelody;
uniform vec2 uCenter; // 球心（画布坐标）
uniform float uRadius; // 球半径（画布坐标，含鼓点呼吸）
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
    p = p * 2.03 + vec2(9.7, 13.1);
    amp *= 0.5;
  }
  return v * 1.14;
}

void main() {
  vec2 frag = FlutterFragCoord().xy;
  vec2 d = (frag - uCenter) / uRadius; // 归一化到以球心为原点的 [-1,1]
  float r = length(d);
  if (r > 1.08) {
    fragColor = vec4(0.0); // 球外全透明
    return;
  }

  float t = uTime;

  // 噪声输入用「单位方向向量」而不是 atan 角度：atan(y,x) 的值域是 (-π, π]，
  // 在 x 轴负方向（九点钟方向）有一条分支割线，角度会从 π 突跳到 -π ——
  // 直接拿它采样噪声，就会在那里留下一条明显的接缝（用户看到的「分割线」）。
  // 用连续的方向向量采样，球面处处连续。
  vec2 dir = d / max(r, 1e-4);
  float turb = fbm(dir * 1.9 + vec2(t * 0.18, -t * 0.42));
  float turb2 = fbm(dir * 3.6 - vec2(t * 0.13, t * 0.55) + turb * 0.6);

  // 能量脉络：沿角向的径向条纹。这里仍用角度，但取**整数倍**（9.0）——
  // sin(角度 × 整数) 在 ±π 两侧取值相同，天然连续，不会带进接缝。
  float ang = atan(d.y, d.x);
  float veins = sin((ang * 9.0 + turb2 * 4.0) * 3.14159265) * 0.5 + 0.5;
  veins = pow(veins, 3.0) * smoothstep(0.15, 0.85, r);

  // 边缘辉光（rim）：贴球缘一圈亮，球体有「边界」
  float rim = exp(-pow((r - 0.90) / 0.13, 2.0));

  // 白热核心
  float core = exp(-pow(r / 0.30, 2.0));

  // 球面明暗：左上前方打光，右下压暗
  float lit = 0.60 + 0.40 * clamp(1.0 - length(d - vec2(-0.35, -0.35)) * 0.95, 0.0, 1.0);

  float glow = (0.28 + 0.55 * turb) * lit +
      veins * (0.35 + 0.45 * turb2) +
      rim * 0.85 +
      core * 1.25;
  glow *= 0.78 + 0.42 * uBass;   // 鼓点：整球涌亮
  glow *= 0.90 + 0.26 * uMelody; // 旋律段：更通透
  glow *= 1.20;

  vec3 col = mix(uColA, uColB, clamp(turb * 1.5 - 0.2, 0.0, 1.0));
  col = mix(col, vec3(1.0),
      clamp(core * 0.85 + max(glow - 0.85, 0.0) * 0.60, 0.0, 0.90));

  // 球缘柔化：避免硬边圆盘
  float edge = 1.0 - smoothstep(0.86, 1.08, r);
  float a = clamp(glow, 0.0, 1.0) * edge * uAlpha;
  fragColor = vec4(col * a, a); // 预乘 alpha
}
