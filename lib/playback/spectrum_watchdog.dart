/// 频谱「断流」看门狗：判断原生 Visualizer 是不是**已经不再送帧**了。
///
/// **调用点：`lib/spectrum_engine.dart`（唯一）** —— 每收到一帧就 [markFrame]，
/// 换订/停止时 [reset]；`lib/widgets/spectrum.dart` 只读一个 `stalled` 布尔
/// （⛔ 时钟绝不进 `spectrum.dart`，见下）。
///
/// # 为什么要有它
///
/// 症状：「App 认为还在播放音乐，其实**频谱没在跳舞**，也没声音」。成因：
/// FFT 数据是**原生回调**推上来的（`SpectrumEngine.kt` 的
/// `setDataCaptureListener(onFftDataCapture)`），而 Dart 侧**没有任何"多久没收到帧"
/// 的判断** ⇒ 只要那条回调链一停（Visualizer 被孤儿化 / 轨道被挪走 / 系统把这一路
/// 静音），`bars` 就停在最后一帧不动，而 `SpectrumView._onTick` 里那句
/// `if (SpectrumEngine.instance.active) return;` 会**一直当它活着**：
/// 界面把最后一帧当成"还在跳"，不报错、不自愈、一个字都不说 ——
/// 这一条是**纯 App 侧缺陷**（它与"没声音"那一半的成因无关）。
///
/// # 为什么时钟放在这个文件里，而不是 `spectrum.dart`
///
/// 有一条**硬线**（源码级断言钉着）：`lib/widgets/spectrum.dart` 里不许出现
/// `DateTime.now` / `Stopwatch` / `elapsed`
/// —— 峰值衰减 `_peakDecay = 0.93` 是**帧基**的，加时间基节流就是改观感。
/// 所以：**时间判断在这里，观感（帧基衰减）还在原处**。
/// `spectrum.dart` 只是把"引擎还活着"换成"引擎还活着**而且还在送帧**"，
/// 衰减用的仍是同一个帧基因子，一帧的节奏都没变。
///
/// # 硬性质（都有单测逐条钉死）
///
/// 1. **新订阅有宽限期**：`reset()` 之后按"订阅开始的时刻"起算，
///    不是立刻判死 —— 原生重建 `Visualizer` 后要几百毫秒才有第一帧，
///    一订阅就判死会让每次切歌都白发一次重建（`markHeal` 的节流会把它变成
///    "每次换订白重建一次"）。所以起算点 = `最近一帧 ?? 本次订阅时刻`；
/// 2. **边界是 `>` 而不是 `>=`**：恰好等于 [staleAfter] 的那一刻**还不算**断流
///    —— 那一帧可能正在路上；
/// 3. **收到一帧立刻回活**（不用等下一条 tick）：断流是"帧停了"，
///    帧回来了就是没断流，中间不留滞后窗口；
/// 4. **自愈必须节流**：断流期间每一帧都会问 [shouldHeal]，不节流就成了
///    「每秒 60 次 cancel+re-listen」，比断流本身更耗电、还可能把刚建好的
///    Visualizer 反复掐掉（`spectrum_engine.dart` 里那句 `await old.cancel()`
///    的注释说的就是这个坑）；
/// 5. **自愈有上限**（[kSpectrumMaxHeals]）：持续性断流下节流会变成
///    「一直播就一直每 17 秒重建一次」—— 收到任何一帧才把次数清零。
///
/// ⚠️ **"静音的一拍"不算断流**：安静的间奏里原生照样按 20Hz 送**全 0** 的帧，
/// 帧到了就是到了 —— 只看"帧来没来"，不看帧里的能量。
library;

/// 多久没收到帧就算「断流」。
///
/// 为什么是 2 秒：原生捕获率是 `Visualizer.getMaxCaptureRate()`（≈20Hz，即 50ms 一帧），
/// 2 秒 = **40 帧没来**。正常播放时不可能；而暂停/换场那一下（Dart 侧 release，
/// 或换身份重建 Visualizer 的几百毫秒）又远够不到 —— 两边都留了余量。
const Duration kSpectrumStaleAfter = Duration(seconds: 2);

/// 两次自愈之间的最小间隔。
///
/// 15 秒：自愈 = 原生 `Visualizer` 重建（`enabled=false` + `release()` + 新 `Visualizer`），
/// 一次就要几百毫秒才重新有帧；重建太勤会把"刚挂上还没出帧"的窗口算成又一次断流，
/// 自己把自己拖进重建循环。
const Duration kSpectrumHealMinInterval = Duration(seconds: 15);

/// **连续**多少次自愈都换不来一帧就收手。
///
/// 为什么必须有上限：断流若是持续性的（不是打嗝），15 秒一次的节流会变成
/// 「用户一听歌，后台就每 17 秒重建一次 Visualizer，直到天荒地老」——
/// 那是白耗电 + 白扰音频服务。3 次（≈ 一分钟内）换不来帧就认定"这条路暂时不通"，
/// 界面停在**静止基座**（诚实），日志留一句，等用户自己拨开关/重启播放再试。
/// 收到任何**一帧**就把计数清零 —— 打嗝型断流照旧能被第一次自愈救回来。
const int kSpectrumMaxHeals = 3;

/// 断流判断 + 自愈节流。**零 Flutter / 零插件依赖**（可纯 Dart 单测）。
class SpectrumWatchdog {
  SpectrumWatchdog({
    this.staleAfter = kSpectrumStaleAfter,
    this.healMinInterval = kSpectrumHealMinInterval,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    _since = _clock();
  }

  /// 多久没收到帧算断流。
  final Duration staleAfter;

  /// 两次自愈之间的最小间隔。
  final Duration healMinInterval;

  /// 取当前时刻的口子（**只给单测**；产品代码一律走缺省的 `DateTime.now`）。
  final DateTime Function() _clock;

  /// 最近一帧的时刻；null = 本次订阅**还没收到过任何一帧**。
  DateTime? _lastFrameAt;

  /// 起算点：最近一帧的时刻，或（还没收到帧时）本次订阅开始的时刻。
  late DateTime _since;

  /// 上一次自愈的时刻；null = 还没自愈过。
  DateTime? _lastHealAt;

  /// 最近一帧之后已经自愈了多少次（收到帧就清零）。
  int _healsSinceFrame = 0;

  /// 最近一帧的时刻（日志/单测断言用）；从没收到过帧时为 null。
  DateTime? get lastFrameAt => _lastFrameAt;

  /// 距起算点过了多久（= 距最近一帧，或距本次订阅开始）。日志/单测用。
  Duration get sinceJudged => _clock().difference(_since);

  /// 收到一帧。
  void markFrame() {
    _lastFrameAt = _clock();
    _since = _lastFrameAt!;
    _healsSinceFrame = 0; // 帧回来了：自愈次数重新起算（打嗝型断流不受上限影响）
  }

  /// 换订阅 / 停止 / 重新开始采集：起算点回到"现在"（给新订阅一个宽限期）。
  ///
  /// ⚠️ **只清帧，不清自愈的两本账**（`_lastHealAt` 与 `_healsSinceFrame`）：
  /// `reset()` 多半就是自愈自己触发的重建，顺手把节流账抹掉 = 下一帧又要自愈一次
  /// = 节流失效；把次数账抹掉 = 重建循环可以永远来（上限形同虚设）。
  void reset() {
    _lastFrameAt = null;
    _since = _clock();
  }

  /// 现在是不是断流了。
  ///
  /// 起点 = `最近一帧 ?? 本次订阅时刻`：新订阅在 [staleAfter] 之内**不算**断流
  /// （宽限期），过了还一帧没来才算 —— 那正是「频谱一动不动」最纯粹的样子。
  bool get stalled => sinceJudged > staleAfter;

  /// 连续自愈已用尽（[kSpectrumMaxHeals] 次都没换来一帧）⇒ 不再无脑重建。
  bool get healExhausted => _healsSinceFrame >= kSpectrumMaxHeals;

  /// 最近一帧之后已经自愈了几次（单测/日志用）。
  int get healsSinceFrame => _healsSinceFrame;

  /// 现在该不该动手自愈（断流 + 距上次自愈够久 + 还没用尽次数）。
  bool get shouldHeal {
    if (!stalled) return false;
    if (healExhausted) return false;
    final lastHeal = _lastHealAt;
    if (lastHeal == null) return true;
    return _clock().difference(lastHeal) >= healMinInterval;
  }

  /// 记一次自愈（真正的重建由调用方做，这里只管节流账与次数账）。
  void markHeal() {
    _lastHealAt = _clock();
    _healsSinceFrame++;
  }

  /// 下一次自愈还要等多久（负数 = 现在就该自愈）；只给日志/单测看，不参与控制流。
  Duration untilHeal() {
    final lastHeal = _lastHealAt;
    if (lastHeal == null) return Duration.zero;
    return healMinInterval - _clock().difference(lastHeal);
  }
}
