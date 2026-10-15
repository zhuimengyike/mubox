/// 队列**预取**的纯决策（零 Flutter / 零插件依赖，可纯 Dart 单测）。
///
/// **调用点：`lib/player_service.dart`（唯一）** —— `_tickDual()` 里调 [PrefetchPolicy.decide]，
/// 真的 `setSource` 在 `_prefetch()`（给**空闲那一副**播放器，只加载不播）。
///
/// 它原先接不上，原因与 `crossfade.dart` 同一个：预取的定义就是「给另一个还没播的
/// 播放器 `setSource`」，而 `MediaPlayerWrapper` 会在 `setSource()` 里把**全进程唯一的**
/// `AudioSessionProvider.sessionId` 抢走 ⇒ 预取**和双播放器踩的是同一个雷**
/// （「只做预取风险小一个量级」这个说法是错的：它踩的是同一个坑）。
/// 换成 per-player 登记表之后就都不抢了。**缺省仍然关闭**
/// （`AppConfig.crossfadeEnabled`，默认 false）。
///
/// 这里只交**判定**：什么时候该预取、预取谁、预取失败了下一拍怎么办。
/// 这些都是纯算术 + 一个计数器，真机上没法试（要卡 500ms、要拔网线、要听有没有空档）。
///
/// 三条硬性质（都有单测逐条钉死）：
///
/// 1. **预取的最早时刻 = 现在正在播的那首「切歌那一刻」的前一拍**
///    —— 早于它就是在白占第二个解码器；晚于它，`setSource` 还没 prepare 完就要切了，
///    等于空档没消掉（因为 prepare 是异步的，见 `PrefetchDecision.lead`）。
/// 2. **该预取的目标必须与「真到曲末时 `next` 会选中的那首」逐项相同** ——
///    否则预取的是 A、真放的是 B，那不只是白干，还会把 B 的 session 抢走之后再抢一次。
/// 3. **失败要退避、且不许一直重试到曲末** —— 文件损坏的歌重试到死会拖垮切歌。
library;

import 'dart:math';

import 'crossfade.dart';

/// 一次预取判定的结果。**纯数据**，不持有任何播放器引用。
class PrefetchDecision {
  const PrefetchDecision({
    required this.shouldPrefetch,
    required this.slotIndex,
    required this.retryAfterTick,
  });

  /// 不预取（默认态）：槽位 -1、不重试。
  static const PrefetchDecision idle =
      PrefetchDecision(shouldPrefetch: false, slotIndex: -1, retryAfterTick: 0);

  /// 这一拍要不要动手预取。
  final bool shouldPrefetch;

  /// 预取到哪个槽位（引用 `queue.dart` 的 `QueueState.refs` 下标）；
  /// 不预取时为 **-1**。
  final int slotIndex;

  /// 这一拍**不许**预取：最近失败过，要等到第 [retryAfterTick] 拍之后才准再试。
  /// 0 = 没有退避限制。
  final int retryAfterTick;

  @override
  bool operator ==(Object other) =>
      other is PrefetchDecision &&
      other.shouldPrefetch == shouldPrefetch &&
      other.slotIndex == slotIndex &&
      other.retryAfterTick == retryAfterTick;

  @override
  int get hashCode => Object.hash(shouldPrefetch, slotIndex, retryAfterTick);

  @override
  String toString() => shouldPrefetch
      ? 'PrefetchDecision(预取 refs[$slotIndex])'
      : 'PrefetchDecision(不预取, 退避到第 $retryAfterTick 拍)';
}

/// 预取失败的退避上限（拍数）：连续失败到这个数就不再重试，等下一次切歌重置。
/// 5 拍 ≈ 2.5 秒（位置 tick 是 500ms），够覆盖「文件正在被写」这种瞬时故障。
const int kPrefetchMaxRetryTicks = 5;

/// 预取的纯决策器。
///
/// 刻意**不持有**任何状态机之外的东西：它不知道播放器、不知道 session、不落盘。
/// 真正把它变成 `setSource` 的那一步在 `player_service.dart`。
abstract final class PrefetchPolicy {
  /// 预取的目标下标。
  ///
  /// [nextIndex] 由调用方传入 —— **必须与「真到曲末时 `next()` 会选中的那首」同一个
  /// 函数算出来**（顺序模式是 `player_service.dart` 的 `_nextIndex`，随机模式是
  /// `queue.dart` 的 `ShuffleOrder.step`）。本函数刻意**不自己算**：
  /// 算两遍就迟早会算出两个答案（预取 A、真放 B），那是这一块最贵的 bug。
  static int targetIndex(int nextIndex, int queueLength) {
    if (queueLength <= 0) return -1;
    if (nextIndex < 0 || nextIndex >= queueLength) return -1;
    return nextIndex;
  }

  /// 这一拍该不该预取。
  ///
  /// - [tick]：位置 tick 的序号（从 0 起）。退避按它算，**不用墙钟**（单测里没法等真实时间）。
  /// - [pos] / [total] / [nextDuration]：与 [CrossfadePlan.shouldStart] 同一套口径
  ///   （tick 粒度、会提前、未知即 `<= 0`）。
  /// - [alreadyLoaded]：槽位里已经装的就是这一首（切歌后没换过）⇒ 不必再 `setSource`，
  ///   重复 `setSource` 会白走一次解码器初始化，还会**再抢一次全局 session**。
  /// - [failures] / [lastFailTick]：上一次预取失败的次数与拍号。
  static PrefetchDecision decide({
    required int tick,
    required Duration pos,
    required Duration total,
    required Duration nextDuration,
    required int nextIndex,
    required int queueLength,
    bool alreadyLoaded = false,
    int failures = 0,
    int lastFailTick = -1,
  }) {
    if (tick < 0) return PrefetchDecision.idle;
    // 退避窗口内：什么都不做（但把还差几拍说出去，便于日志与单测断言）
    if (failures >= kPrefetchMaxRetryTicks) {
      return PrefetchDecision.idle;
    }
    if (failures > 0 && lastFailTick >= 0) {
      final until = lastFailTick + _backoffTicks(failures);
      if (tick < until) {
        return PrefetchDecision(
          shouldPrefetch: false,
          slotIndex: -1,
          retryAfterTick: until,
        );
      }
    }
    if (alreadyLoaded) return PrefetchDecision.idle;
    final info = window(pos: pos, total: total, nextDuration: nextDuration);
    if (!info.inWindow) return PrefetchDecision.idle;
    final i = targetIndex(nextIndex, queueLength);
    if (i < 0) return PrefetchDecision.idle;
    return PrefetchDecision(
      shouldPrefetch: true,
      slotIndex: i,
      retryAfterTick: 0,
    );
  }

  /// 预取窗口：与交叉淡变**同一个窗口**（现在就用的那道 `lead`）。
  ///
  /// 为什么不另立一个更早的窗口（比如播到 80% 就预取）：
  /// 提前 20% 预取意味着第二个解码器要**多占**那么久（1 小时的歌 = 12 分钟），
  /// 而收益只是"更早 prepare 完"—— 300ms 的 `setSource` 早就够了。
  /// 窗口一致还顺带保证一件事：**预取与淡变同时开始，淡变开始时 source 一定就绪**。
  static ({bool inWindow, Duration lead}) window({
    required Duration pos,
    required Duration total,
    required Duration nextDuration,
    CrossfadePlan plan = CrossfadePlan.standard,
  }) {
    final lead = plan.lead;
    if (!plan.enabled) return (inWindow: false, lead: lead);
    if (total <= Duration.zero || nextDuration <= Duration.zero) {
      _logCrossfadeSkip('unknownDuration', total: total, pos: pos);
      return (inWindow: false, lead: lead);
    }
    if (nextDuration <= plan.effectiveDuration) {
      return (inWindow: false, lead: lead);
    }
    if (pos < Duration.zero) return (inWindow: false, lead: lead);
    final left = total - pos;
    if (left <= Duration.zero) {
      _logCrossfadeSkip('pastEnd', total: total, pos: pos);
      return (inWindow: false, lead: lead);
    }
    return (inWindow: left <= lead, lead: lead);
  }

  /// 指数退避的拍数：1、2、4、8……封顶 [kPrefetchMaxRetryTicks]。
  /// 线性退避（1、2、3…）在「文件正在被下载器写完」这种场景下会白试太多次。
  static int _backoffTicks(int failures) =>
      min(1 << (failures.clamp(1, 30) - 1), kPrefetchMaxRetryTicks);
}

// ══════════════════════════════════════════════════════════════════════════════
// 诊断：交叉淡变**本该开始、却永远开不了窗**时说一句（**判定一个字不改**）
//
// 为什么要它：`window()` 上面那两处守卫一旦成立就**再也不会翻回来** ——
//   · `total <= 0`：当前歌的时长 app 不知道（有些文件读出来就是 0，UI 显示 `0:00/0:00`）；
//   · `left <= 0`：位置已经越过**已知**时长（快进过了头）。
// 两种情况下曲末都只能硬切，而**没有任何一行日志说为什么** —— 现象是
// 「我明明开了交叉淡变，怎么没效果」，很容易被当成 bug。
//
// ⛔ 这一节**只 print，不参与任何控制流**：守卫的条件、返回值、调用顺序全都没动。
// ⛔ 不动 `CrossfadePlan.shouldStart`（那边有同一组守卫，改一处就够看）。
// ══════════════════════════════════════════════════════════════════════════════

/// 上一行诊断的去重签名（本文件**唯一**的可变状态）。
///
/// 为什么必须去重：位置 tick 是 500ms 一拍，而且**同一拍会被问两遍**
/// （`_tickDual` 直接问一次 `window()`，`decide()` 内部再问一次）⇒ 不去重就是
/// 每秒 4 行、一首歌几百行，把 logcat 冲掉。`pos ~/ 30` 的分桶让
/// **同一首歌 + 同一个原因最多半分钟一条**：真要排查时，日志里一定有新鲜的。
String? _lastSkipSign;

/// 打一行 `Crossfade: skipped reason=… total=… pos=…`。
///
/// ASCII 前缀 `Crossfade:` 照本项目约定（中文关键词在 logcat 里可能被转义过滤不到，
/// 同 `MuBox` / `FxShaders:` 那两条教训）。**两个数值的单位 = 毫秒**
/// （就是 `Duration.inMilliseconds`，不另做换算）。
void _logCrossfadeSkip(
  String reason, {
  required Duration total,
  required Duration pos,
}) {
  final sign = '$reason|${total.inMilliseconds}|${pos.inSeconds ~/ 30}';
  if (sign == _lastSkipSign) return;
  _lastSkipSign = sign;
  // 刻意 `print` 而不是 `debugPrint`：本模块的设计性质是**零 Flutter 依赖**
  // （见文件头），`debugPrint` 会把 `package:flutter/foundation.dart` 拉进来。
  // Android 上 Dart 的 stdout 由引擎转发进 logcat（tag = `flutter`），release 一样看得到
  // —— 与 `library_data.dart` 里那两条常驻日志同一条通道。下面的 ignore 是本仓
  // `analysis_options.yaml` 自己写明的口子（`// ignore: name_of_lint`）。
  // ignore: avoid_print
  print('Crossfade: skipped reason=$reason '
      'total=${total.inMilliseconds} pos=${pos.inMilliseconds}');
}

