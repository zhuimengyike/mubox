/// 交叉淡变的**纯计算**部分（零 Flutter / 零插件依赖，可纯 Dart 单测）。
///
/// **调用点：`lib/player_service.dart`（唯一）** —— `_tickDual()` 用它判断"这一拍该不该
/// 换场"、`_crossfadeTo()` 用它取两条音量曲线。
///
/// 它原先接不上，卡在一条硬阻塞（完整故障链见 `lib/playback/audio_session.dart` 文件头）：
///
/// > `AudioSessionProvider` 原本是**全进程一个格子**的 sessionId；
/// > `MediaPlayerWrapper` 在**每次 `setSource()`** 里把它写成本播放器的 session；
/// > 而 `SpectrumEngine` / `EqualizerEngine` / `ExtraEffectsEngine`
/// > 三个引擎**全部在构造时绑定 session、没有改绑 API**。
/// > ⇒ **只要出现第二个 `AudioPlayer` 并给它 `setSource`（= 预取的定义），
/// > 正在播的那个播放器就会被抢走全局格子 ⇒ 频谱停摆、EQ/低音/响度静默失效。**
///
/// 把那个格子换成**按播放器身份查**的登记表（`put` / `sessionOf` / `forget`）
/// 并给三个引擎补上"换场重挂"之后，阻塞才解除。**但缺省仍然关闭**：
/// `AppConfig.crossfadeEnabled`（默认 false）—— 它会改观感（两首重叠 ~300ms、
/// 通知栏提前跳下一首）且双份解码资源，得先在真机上确认听感才敢默认开。
///
/// 抽到这儿来的理由与 `playback/queue.dart` 同一套：曲线端点、时序窗口、会不会削波
/// 这三件事**在真机上极难试**（要听、要卡 500ms、要量响度），但全是纯算术。
///
/// 三条硬性质（都有单测逐条钉死）：
///
/// 1. **端子精确**：A 的序列末项**精确等于 0.0**、B 的序列末项**精确等于 1.0**
///    —— 与 `volume_fade.dart` 那条「每次淡变结束音量必须回到 1.0」的硬不变量同源。
/// 2. **线性 ⇒ 零削波（可用数学证明，不是"大概不会爆"）**：
///    A、B 走的是**互补的线性**曲线 ⇒ 任意时刻 `a + b == 1.0`。
///    两个各自 ≤1.0 的信号叠在一起，只要 `a + b ≤ 1` 就**不可能**越过满刻度；
///    换成等功率（equal-power / sin-cos）曲线的话中点 `a + b ≈ 1.414`，
///    **有意想不到的削波风险**——这就是本文件坚持线性曲线的唯一理由。
/// 3. **提前量容错**：位置 tick 是 500ms 一拍（`player_service.dart` 的
///    `TimerPositionUpdater`），所以触发判定必须**接受最多一拍（500ms）的提前**
///    —— 否则「按 `pos + 淡变时长 == 总时长` 卡点」会永远差半秒，A 播完了还没开始淡出。
library;

import '../volume_fade.dart';

/// 交叉淡变的默认时长。
///
/// 为什么是 300ms：
/// - **下界**：要盖住现在那个 100~300ms 的空档（目标是「切歌间隙 < 50ms」），
///   比空档还短的淡变等于没做；
/// - **上界**：A、B 同时出声的时间就是 300ms，再长人耳能明显听出"两首歌叠在一起"
///   （尤其副歌接前奏的两首），而且通知栏曲目信息会提前这么久跳走。
/// ⚠️ 这个值**不是观感承诺**：它只是缺省值，开这个功能之前要先在真机上听过再定。
const Duration kCrossfadeTime = Duration(milliseconds: 300);

/// 交叉淡变的步进间隔（毫秒）。**复用** `volume_fade.dart` 的 `kFadeStepMs`（16ms
/// ≈ 一帧），不另立一套 —— 两套不同步进的淡变叠在一起，音量曲线的台阶会对不齐。
const int kCrossfadeStepMs = kFadeStepMs;

/// 位置 tick 的周期（毫秒）：`player_service.dart` 的 `TimerPositionUpdater`
/// 是 500ms 一拍。所有"提前量"判定都要按它留容差，见 [CrossfadePlan.shouldStart]。
const int kPositionTickMs = 500;

/// 一次交叉淡变的计划：**只管时长与触发窗口，不管谁在播**。
/// 纯数据 + 纯判定，不持有任何播放器引用（真正 `setSource` 的那一步在 `player_service.dart`）。
class CrossfadePlan {
  const CrossfadePlan(this.duration);

  /// 淡变时长。`Duration.zero` / 负数 = **关闭淡变**（[enabled] 为 false）。
  final Duration duration;

  /// 关闭态：不做交叉淡变，切歌仍走现在的「硬停 + 淡入」路径。
  static const CrossfadePlan off = CrossfadePlan(Duration.zero);

  /// 默认计划（[kCrossfadeTime] 的淡变）。
  static const CrossfadePlan standard = CrossfadePlan(kCrossfadeTime);

  /// 是否真的要做淡变。
  bool get enabled => duration > Duration.zero;

  /// 淡变要走多少步（与 `fadeSequence` 同一套步数公式，绝不另算一套）。
  int get steps => fadeSteps(duration);

  /// 淡变的实际总时长（步数 × 步进）。步数是取整过的，所以它与 [duration] 可能
  /// 差不到一步 —— 触发窗口按**实际**总时长算，别按 [duration] 算。
  Duration get effectiveDuration =>
      Duration(milliseconds: fadeSteps(duration) * kCrossfadeStepMs);

  /// 离曲末还有多久时该开始淡出。**把一拍 tick 的提前量算进去**，这样
  /// 「A 正好在曲末那一刻静音、B 正好满音量」是常态而不是碰运气。
  Duration get lead => effectiveDuration + const Duration(milliseconds: kPositionTickMs);

  /// 「这一拍该不该开始交叉淡变」。
  ///
  /// - [pos] / [total] / [nextDuration] 全部是**位置 tick**（≤1Hz，且会提前）；
  /// - [total] 或 [nextDuration] 未知（`<= 0`，手动扫进来的歌一开始就没有时长）
  ///   ⇒ **不淡变**：总时长未知时算不出曲末，硬要淡变会把歌从中间切掉；
  /// - [nextDuration] 太短（比一拍还短）⇒ 不淡变：下一首还没等淡完就自己结束了，
  ///   那就是「两首歌同时在响 + 下一首提前结束」，比硬切更糟；
  /// - [atEnd] = **曲末是否由播放器自己到达**。用户手点「下一首」时为 false
  ///   —— 手动切歌要**立刻响**，不该先等 300ms 淡出（那是手感变迟钝，属于改观感）。
  bool shouldStart({
    required Duration pos,
    required Duration total,
    required Duration nextDuration,
    required bool atEnd,
  }) {
    if (!enabled || !atEnd) return false;
    if (total <= Duration.zero || nextDuration <= Duration.zero) return false;
    if (nextDuration <= effectiveDuration) return false;
    if (pos < Duration.zero) return false;
    final left = total - pos;
    if (left <= Duration.zero) return false; // 已经过点了：别再起一轮淡变
    return left <= lead;
  }

  /// 这一拍离该不该开始淡变还有多久（负数 = 已经该开始了 / 已经过点）。
  /// 只给判定与日志用，不参与控制流。
  Duration timeUntilStart({
    required Duration pos,
    required Duration total,
  }) => (total - pos) - lead;

  /// 淡变结束那一刻，「当前曲」在界面上应该已经换成下一首了。
  @override
  String toString() => 'CrossfadePlan(${duration.inMilliseconds}ms, '
      '$steps步/实际${effectiveDuration.inMilliseconds}ms)';}

/// 交叉淡变的**音量序列**（两个播放器各一条）。
///
/// [outLeft] = 即将退场那个播放器的音量、[inRight] = 即将上场那个。
/// 两条序列**等长**，第 i 项要**同一拍写入**（先写 A 再写 B 都行，但不能隔一拍）。
class CrossfadeCurves {
  const CrossfadeCurves({required this.outLeft, required this.inRight});

  final List<double> outLeft;
  final List<double> inRight;

  int get length => outLeft.length;

  /// 两路叠加后的最大瞬时幅度。线性互补曲线下恒为 1.0 —— 用它来钉「不会削波」。
  double get peakSum {
    var m = 0.0;
    for (var i = 0; i < outLeft.length; i++) {
      final s = outLeft[i] + inRight[i];
      if (s > m) m = s;
    }
    return m;
  }

  @override
  String toString() =>
      'CrossfadeCurves(${outLeft.length}步, 峰值和=$peakSum)';
}

/// 算这一次交叉淡变的两条音量曲线。
///
/// - [fromLeft]：A 现在**实际**的音量（可能不是 1.0：刚起播时 A 还在淡入途中，
///   或者上一轮淡变被打断过）。传进来才不会出现「音量从 1.0 跳一下再往下走」的爆点。
/// - [toRight]：B 要淡到的终点。除调试外都传 1.0 —— 它必须精确等于 1.0，
///   否则破坏 `volume_fade.dart` 那条「每次淡变结束音量必须回到 1.0」的硬不变量。
///
/// ⚠️ **刻意不给 A 单独的终点参数**：A 的终点**恒为 0.0**，是这条曲线的一部分，
/// 不是可调项。给成参数就等于允许"淡到一半就交接"，那会在交接点留一个音量台阶。
CrossfadeCurves crossfadeCurves({
  required double fromLeft,
  required Duration duration,
  double toRight = 1.0,
}) {
  // steps 为 0 或 1 时不淡变：直接到端点（与 fadeSequence 的"至少一步"同语义）
  final steps = fadeSteps(duration);
  final a = fadeSequence(from: fromLeft.clamp(0.0, 1.0), to: 0.0, d: duration);
  final b = fadeSequence(from: 0.0, to: toRight.clamp(0.0, 1.0), d: duration);
  // 两条序列等长（同一个 steps），这里只是把"等长"这件事变成结构性的
  return CrossfadeCurves(
    outLeft: List<double>.unmodifiable(a.take(steps + 1)),
    inRight: List<double>.unmodifiable(b.take(steps + 1)),
  );
}
