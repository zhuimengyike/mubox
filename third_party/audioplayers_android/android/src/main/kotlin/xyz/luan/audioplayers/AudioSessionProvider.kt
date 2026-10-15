package xyz.luan.audioplayers

import java.util.concurrent.ConcurrentHashMap

/// **按播放器身份查**的 audio session 登记表（audioplayers fork 的一部分）。
///
/// 没有这张表时只能靠**全进程一个格子** `@Volatile var sessionId: Int` ——
/// `MediaPlayerWrapper` 每次 `setSource()` 都把它写成本播放器的 session，
/// 于是「谁最后 setSource 谁占格子」：一旦出现第二个 `AudioPlayer`（交叉淡变 /
/// 预取的定义就是给另一个播放器 setSource），正在播的那个就被抢走，
/// 而 `SpectrumEngine` / `EqualizerEngine` / `ExtraEffectsEngine` 只能看到格子，
/// 挂到错误（甚至还没播）的 session 上 ⇒ 频谱停摆、EQ/低音/响度静默失效。
///
/// 现在每次写入都带上**播放器身份**：Dart 侧 `AudioPlayer.playerId`
/// （`AudioPlayer({String? playerId}) : playerId = playerId ?? _uuid.v4()`，
/// 全进程唯一、随播放器实例存活），由 `AudioplayersPlugin` 一路传到
/// `WrappedPlayer.playerId` → `MediaPlayerWrapper`。三个引擎改成按身份查询，
/// 于是**双播放器下每个播放器都能问到自己那份 session**，谁也不用抢。
///
/// ⚠️ 旧的 `sessionId` 格子**刻意留着**（`private set`，只有 [put] 能写）：
/// ① 它是「上一次写入的值」，供不带身份的调用兜底与日志排查；
/// ② 它仍然会被后一次写入覆盖 —— 这条旧事实本身就是「引擎绝不能再读它」的理由，
/// `test/audio_session_test.dart` 有一条负向用例专门钉住它还在被抢。
object AudioSessionProvider {
    /// playerId → 该播放器当前的 audio session id。
    /// 只在拿到有效 session（>= 0）时登记；MediaPlayer 被 release 时由 [forget] 撤掉。
    private val sessions = ConcurrentHashMap<String, Int>()

    /// 兼容格子：最后一次写入的值（谁最后 `setSource` 谁占）。
    /// **产品代码里的三个引擎一律不再读它** —— 只有 [sessionOf] 收到 `null` 时才回落。
    @Volatile
    var sessionId: Int = -1
        private set

    /// 最后写格子的播放器 id（排查用：logcat 里能看出"是谁抢的"）。
    @Volatile
    var lastPlayerId: String? = null
        private set

    /// 记下某个播放器当前的 session。调用点只有 `MediaPlayerWrapper` 的两处：
    /// `setSource()`（setDataSource 之后，此时 audioSessionId 已生效）与
    /// `setOnPreparedListener`（prepare 完成后再兜底一次）。
    fun put(playerId: String, session: Int) {
        // 兼容格子照旧无条件写：它的语义就是"最后一次写入的值"，不因为是负值就假装没发生
        sessionId = session
        lastPlayerId = playerId
        // 但按身份的登记表只收有效值：-1/0 等于"这个播放器现在没有可用 session"
        if (session >= 0) sessions[playerId] = session
    }

    /// 按播放器身份问它**自己的** session；没登记过（还没建播放器 / 已 release）返回 -1。
    ///
    /// [playerId] 传 `null` = 调用方没有身份（老调用点），回落到兼容格子 ——
    /// 这条回落路径保证「不带身份时行为与老调用点逐项一致」。
    fun sessionOf(playerId: String?): Int {
        if (playerId == null) return sessionId
        return sessions[playerId] ?: -1
    }

    /// `MediaPlayerWrapper.release()`：MediaPlayer 真的被释放了，它那个 session 已经死了，
    /// 按身份的登记必须撤掉（否则引擎会拿到一个死掉的 id 去 attach，静默失败）。
    ///
    /// ⚠️ **刻意不碰兼容格子**：它仍然指着那个死掉的 session —— 这是既有的真实缺陷，
    /// 保留原样，别"顺手修好"（那会让 `test/audio_session_test.dart` 那条负向用例失去意义）。
    fun forget(playerId: String) {
        sessions.remove(playerId)
    }
}
