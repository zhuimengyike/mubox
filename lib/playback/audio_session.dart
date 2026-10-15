/// 原生**音频会话归属**的可执行规格（零 Flutter / 零插件依赖）。
///
/// ⚠️ 这个文件**不是产品代码**，而是原生那一侧语义的**可执行规格**：把 fork 里那
/// 几个 Kotlin 文件的会话归属语义在原地复刻出来，好让「谁把 effect 挂到谁身上」
/// 这件事**能跑、能红**，而不是只写在文档里等人忘掉。
///
/// # 按播放器身份取 session（本文件的模型描述的就是这一面）
///
/// **旧的全局格子**（下面这条故障链的每一环都是事实）：
/// 1. `AudioSessionProvider.kt` 是**全进程一个格子**：
///    ```kotlin
///    object AudioSessionProvider { @Volatile var sessionId: Int = -1 }
///    ```
/// 2. `MediaPlayerWrapper.kt` 的 `setSource()` 与 `setOnPreparedListener` **两处**
///    都写这个格子（`AudioSessionProvider.sessionId = mediaPlayer.audioSessionId`）；
/// 3. 三个引擎**构造时绑定 session、没有改绑 API**：
///    `SpectrumEngine` 读 `AudioSessionProvider.sessionId` 后 `Visualizer(sessionId)`（且
///    「已 running 就直接 return」）、`EqualizerEngine` 的 `Equalizer(0, session)`
///    （唯一的重挂判断是 `attachedSession == session`）、`ExtraEffectsEngine` 的
///    `BassBoost(0, session)` / `LoudnessEnhancer(session)`；
/// 4. 于是**第二个 `AudioPlayer` 一旦 `setSource`，全局格子就被抢走**
///    ⇒ 频谱停摆 + EQ/低音/响度静默失效。预取的定义就是给另一个播放器 `setSource`，
///    所以「只做预取」踩的是同一个雷。
///
/// **现在**（本文件的模型描述这一面）：
/// - `AudioSessionProvider` 变成**按播放器身份查**的登记表
///   （`put(playerId, session)` / `sessionOf(playerId)` / `forget(playerId)`）；
///   身份 = Dart 侧 `AudioPlayer.playerId`，由 `AudioplayersPlugin` 传给
///   `WrappedPlayer.playerId`，再传给 `MediaPlayerWrapper`；
/// - 旧的 `sessionId` 格子**留着但 private set**：它仍然"谁最后写谁占"
///   —— [AudioSessionRegistry.legacySlot] / [legacyStolenBy] 就是拿来钉住这条旧事实的，
///   它同时是「引擎**绝不能再读它**」的理由；
/// - 三个引擎都改成**按身份挂 + 能重挂**（[NativeEffectLike.rebind]）；
///   频谱的 `Visualizer` 没有改绑 API，所以它的"重挂"= 换身份时**先停再重建**
///   （[SpectrumLike.start] 里那句 `running && 同身份 ⇒ return`，其余情况重建）。
///
/// # 谁还在盯这个文件
///
/// `test/audio_session_test.dart`：正向证明「双播放器下按身份查，谁也抢不走谁的」，
/// 负向证明「兼容格子**仍然**会被抢」（所以引擎读它就一定会挂错人）。
library;

/// 一个播放器在**原生侧**的样子。
///
/// 对应 `MediaPlayerWrapper`：`setSource` 会 `reset()` 再设数据源，并把
/// 自己的 `audioSessionId` **按身份**登记进 [AudioSessionRegistry]。
class NativePlayerHandle {
  NativePlayerHandle(this.tag, {required this.playerId, required this.sessionId});

  /// 给人看的标识（"A"/"B"/"prefetch"…），只用于断言消息。
  final String tag;

  /// Dart 侧 `AudioPlayer.playerId`（`AudioPlayer({String? playerId})` 里
  /// `?? _uuid.v4()`，全进程唯一）。
  ///
  /// ⚠️ 这是**双播放器方案能成立的关键**：它是"播放器实例"的稳定身份，
  /// 而 `audioSessionId` 会随 MediaPlayer 的建立/release 变化。
  final String playerId;

  /// 这个播放器**当前**的 `MediaPlayer.getAudioSessionId()`。
  ///
  /// ⚠️ 对**单个** MediaPlayer 而言它是稳定的：会话 id 只在 MediaPlayer 被
  /// `release()` 时才可能变；`stop()` / `pause()` 都**不 release**
  /// （`WrappedPlayer.stop()` 只在 `ReleaseMode.RELEASE` 下才 release，
  /// 而本 App 在 `player_service.dart` 明确设了 `ReleaseMode.stop`）。
  /// 但 `WrappedPlayer.getOrCreatePlayer()` 在 release 之后会**重建 MediaPlayer**
  /// ⇒ 同一个 playerId 的 session **可能换值** ⇒ 引擎判断要不要重挂时必须
  /// **同时**看身份和 session（见 [NativeEffectLike.attach]）。
  int sessionId;

  /// MediaPlayer 被真正 `release()`（原生会 [AudioSessionRegistry.forget]）。
  bool released = false;

  @override
  String toString() => '$tag(playerId=$playerId, session=$sessionId)';
}

/// 对应**改造后**的 `AudioSessionProvider.kt`。
class AudioSessionRegistry {
  final Map<String, int> _byPlayer = {};

  int _legacySlot = -1;
  String? _lastWriter;

  /// 兼容格子：**最后一次写入的值**（谁最后 `setSource` 谁占）。
  ///
  /// 产品代码里三个引擎**一律不再读它**（只有 `sessionOf(null)` 才回落），
  /// 它现在的用途是"老调用点兜底"。
  int get legacySlot => _legacySlot;

  /// 最后写格子的播放器身份（日志里靠它看出"是谁抢的"）。
  String? get lastWriter => _lastWriter;

  /// 兼容格子是不是被 [playing] 之外的播放器抢走了（只要有第二个播放器 `setSource` 就成立）。
  bool legacyStolenBy(NativePlayerHandle playing) =>
      _lastWriter != null && _lastWriter != playing.playerId;

  /// 对应 `AudioSessionProvider.put(playerId, session)`：
  /// 按身份登记（有效值才进表），同时把兼容格子写成"最后一次的值"。
  int put(NativePlayerHandle p) {
    _lastWriter = p.playerId;
    _legacySlot = p.sessionId;
    if (p.sessionId >= 0) _byPlayer[p.playerId] = p.sessionId;
    return p.sessionId;
  }

  /// 对应 `AudioSessionProvider.sessionOf(playerId)`：
  /// **按播放器身份问它自己的 session**；没登记过返回 -1。
  /// `null` ⇒ 回落兼容格子（老调用点，行为与改造前逐项一致）。
  int sessionOf(String? playerId) =>
      playerId == null ? _legacySlot : (_byPlayer[playerId] ?? -1);

  /// 对应 `MediaPlayerWrapper.release()` 里的 `forget(playerId)`：
  /// MediaPlayer 没了，按身份的登记撤掉。
  ///
  /// ⚠️ **刻意不碰兼容格子**（与原生一致）：它仍指着那个死掉的 session ——
  /// 这是改造前就有的真实缺陷，[legacySlot] 那条负向用例靠它。
  void forget(NativePlayerHandle p) {
    p.released = true;
    _byPlayer.remove(p.playerId);
  }
}

/// 三个 effect 的**共同形状**（SpectrumEngine / EqualizerEngine / ExtraEffectsEngine）。
///
/// 它们的共同点是：**按身份取 session + 判断里带身份 + 支持重挂**。
/// 各不相同的那点（Visualizer / Equalizer / BassBoost+LoudnessEnhancer）与这套模型无关，
/// 所以模型只留这一个抽象 —— 多写两遍不会多证明任何事。
abstract class NativeEffectLike {
  NativeEffectLike(this.name);

  final String name;

  /// 已经挂到**哪个播放器**上（null = 还没挂 / 老调用点）。
  String? attachedPlayerId;

  /// 已经挂上的 session；-1 = 还没挂。
  int attachedSession = -1;

  /// 挂上 / 重挂过多少次。
  /// 对频谱就是「`Visualizer` 被重建了几次」（它没有改绑 API）；对 EQ/音效是重挂次数。
  int rebuilds = 0;

  /// ⚠️ **三个引擎都有改绑能力**（都靠"带新身份重新订阅 / 重新 `open`"实现）。
  bool get supportsRebind => true;

  /// attach / rebind 的**共同实现**（三种情形，对应原生 `open(playerId)` / `start(playerId)`）：
  ///
  /// ① 同身份 + 同 session ⇒ 已经挂着，**什么都不做**（返回 false，不重建）；
  /// ② 同身份 + session 变了（MediaPlayer 被重建）⇒ 重挂；
  /// ③ **换了身份**（交叉淡变换场 / 预取占了另一个播放器）⇒ 重挂。
  ///
  /// 返回 true = 真的挂了/重挂了一次。
  bool attach(AudioSessionRegistry reg, {String? playerId}) {
    final s = reg.sessionOf(playerId);
    if (s < 0) return false; // session 未就绪：原生侧 available=false，下次再试
    if (attachedSession == s && attachedPlayerId == playerId) return false;
    detach();
    attachedPlayerId = playerId;
    attachedSession = s;
    rebuilds++;
    return true;
  }

  /// 改绑到 [playerId]（= 调一次 [attach]，语义上就是"切到新 session"）。
  bool rebind(AudioSessionRegistry reg, {required String? playerId}) =>
      attach(reg, playerId: playerId);

  /// 放掉当前的 effect（原生的 `release()`）。子类可在这里补广播。
  void detach() {
    attachedPlayerId = null;
    attachedSession = -1;
  }

  /// 这个引擎现在挂着的 session 是不是**正在播的那个播放器**的。
  bool matchesActive(NativePlayerHandle active) =>
      attachedSession >= 0 && attachedSession == active.sessionId;

  @override
  String toString() => '$name(playerId=$attachedPlayerId, session=$attachedSession)';
}

/// 均衡器：多一条「OPEN/CLOSE 广播必须配对」的语义。
///
/// 原生按官方约定在 attach 成功后发 `ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION`、
/// 在放掉旧的之前发 `ACTION_CLOSE_AUDIO_EFFECT_CONTROL_SESSION`，**两者用的是
/// 各自的 session**（CLOSE 用旧的那个）。换场时必须成对出现，否则系统的音效框架
/// 会以为旧 session 还归我们管（或新 session 没人管）。
class EqualizerLike extends NativeEffectLike {
  EqualizerLike() : super('EqualizerEngine');

  /// 发出去的广播（按顺序）。
  final List<String> broadcasts = [];

  @override
  bool attach(AudioSessionRegistry reg, {String? playerId}) {
    final changed = super.attach(reg, playerId: playerId);
    if (changed) broadcasts.add('OPEN:$attachedSession');
    return changed;
  }

  @override
  void detach() {
    if (attachedSession >= 0) broadcasts.add('CLOSE:$attachedSession');
    super.detach();
  }
}

/// 音效增强（低音 + 响度）：**刻意不发** OPEN/CLOSE 广播（统一由均衡器发，
/// 两边都发会让系统收到重复的 open/close）—— 所以它只继承共同形状。
class ExtraEffectsLike extends NativeEffectLike {
  ExtraEffectsLike() : super('ExtraEffectsEngine');
}

/// 频谱：多一条「已启动就不会自己重挂」的语义 —— 改造后它变成**按播放器**的。
class SpectrumLike extends NativeEffectLike {
  SpectrumLike() : super('SpectrumEngine');

  bool running = false;

  /// 原生 `SpectrumEngine.start(playerId)`：
  ///
  /// - **已经在挂同一个播放器** ⇒ 直接返回（不重建、不闪断）——
  ///   这就是改造前那句 `if (running) return` 的"每播放器"版本；
  /// - **换了播放器** ⇒ 先 [stop] 再重建（`Visualizer` 没有改绑 API）。
  bool start(AudioSessionRegistry reg, {String? playerId}) {
    if (running && attachedPlayerId == playerId) return true; // ★ 同播放器：什么都不做
    if (running) stop(); // 换了播放器：先停再重建
    if (!attach(reg, playerId: playerId)) return false;
    running = true;
    return true;
  }

  /// 原生 `SpectrumEngine.stop()`：释放 Visualizer。
  /// 只有 `EventChannel.onCancel`（= Dart 侧引用计数减到 0 / 换场重订阅）会走这儿。
  void stop() {
    running = false;
    detach();
  }

  /// 频谱的"改绑"就是 [start]（换身份 ⇒ 先停再重建）。
  @override
  bool rebind(AudioSessionRegistry reg, {required String? playerId}) =>
      start(reg, playerId: playerId);

  /// 原生退避重试上限（`SpectrumEngine` 的 `MAX_RETRY`）。
  static const int maxRetry = 8;

  /// 模拟"session 一直没就绪 → 退避重试 8 次 → 放弃并报 SPECTRUM_UNAVAILABLE"。
  /// 返回用掉的尝试次数（= [maxRetry] + 1 表示真的放弃了）。
  int startWithRetry(AudioSessionRegistry reg, {String? playerId}) {
    var tries = 0;
    while (tries <= maxRetry) {
      tries++;
      if (start(reg, playerId: playerId)) return tries;
    }
    return tries; // = maxRetry + 1
  }
}
