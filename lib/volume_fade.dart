/// 音量淡变的**纯计算**部分（零 Flutter 依赖，可纯 Dart 单测）。
///
/// `player_service.dart` 的 `_fade()` 只负责「照计划过桥 + 让位 + 每步延时」，
/// 步数与每步取值全在这儿算 —— 因为这里有两条**硬不变量**，混在异步循环里没法单测：
///
/// 1. **每次淡变结束音量必须精确回到 1.0**（App 内不做音量缩放，恒为 1.0），
///    否则会「越听越小声」；
/// 2. 步进 16ms、步数封顶 80：再细人耳也分辨不出，白费 channel 往返。
///
/// ⚠️ 这两条不变量都有单测钉住：步数表 / 终值恒等于 [fadeStepValue] 的 `to` /
/// 单调 / 边界，另有一条源码级围栏钉住「淡变循环真的在用这两个函数」。
library;

/// 每步之间的间隔（毫秒，约一帧）
const int kFadeStepMs = 16;

/// 步数上限：再细人耳也分辨不出，白费 channel 往返
const int kFadeMaxSteps = 80;

/// 淡变要走多少步。0 / 负时长也至少 1 步（= 直接到位）。
int fadeSteps(Duration d) =>
    (d.inMilliseconds / kFadeStepMs).ceil().clamp(1, kFadeMaxSteps);

/// 第 [step] 步（1..[steps]）该写入的音量。
///
/// ⚠️ **最后一步直接返回 [to]**，不再走 `from + (to - from) * (i / steps)`：
/// 「终值必须**精确**回到 [to]」是硬不变量（[to] = 1.0 时差一个 ulp 就是
/// `_volume != 1.0`，下一次淡出就从那个脏值起步）。写成显式末步后这条不变量是
/// **结构性**的，不依赖浮点乘加恰好精确。
///
/// 实测（本机 Dart，`from` 以 1e-6 步长扫 0..1 共 100 万点）：旧式在 `* 1.0` 下
/// 也确实逐位等于 1.0 ⇒ 显式末步对音量包络**逐项等价、零观感差异**。
double fadeStepValue({
  required double from,
  required double to,
  required int step,
  required int steps,
}) {
  if (steps <= 1 || step >= steps) return to.clamp(0.0, 1.0);
  // clamp 对合法入参（from/to 都在 0..1）是恒等变换，只为「给什么值都不越界」
  return (from + (to - from) * (step / steps)).clamp(0.0, 1.0);
}

/// 一次淡变**实际写入的音量序列**：第一个是起点 [from]，之后是每一步，
/// 最后一个恒等于 [to]。`_fade()` 就是照这个序列过桥的，所以「终值必须回到 1.0」
/// 这条不变量可以直接在这个序列上钉死。
List<double> fadeSequence({
  required double from,
  required double to,
  required Duration d,
}) {
  final steps = fadeSteps(d);
  return [
    from.clamp(0.0, 1.0),
    for (var i = 1; i <= steps; i++)
      fadeStepValue(from: from, to: to, step: i, steps: steps),
  ];
}
