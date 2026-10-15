package com.mubox.mubox

/// 一次 `open()` 的附着计划（纯数据）。
///
/// * [earlyReturn] —— 与那条早退等价：什么都不做，直接回报当前状态；
/// * [rebuildBass] / [rebuildLoud] —— **逐个 effect** 决定要不要 `release()` + 重新构造。
///   ⛔ 两个分开是**故意的**：健康的那个不许被连带的 `release()` 拆掉（实测：
///   `bass=true` 一直正常，却每次重挂都被拆一遍 ⇒ 出声中途重建整条效果链）；
/// * [logForceReAttach] —— 只有「显式重试真的推翻了早退」才为真 ⇒ 自动路径的日志
///   与改动前逐字节相同。
internal data class AttachPlan(
    val earlyReturn: Boolean = true,
    val rebuildBass: Boolean = false,
    val rebuildLoud: Boolean = false,
    val logForceReAttach: Boolean = false,
)

/// `ExtraEffectsEngine.open()` 的**纯判定**：要不要重挂、重挂哪几个、这一枪算不算数。
///
/// 为什么单独抽出来（而不是留在 `open()` 里）：它是「重挂风暴」唯一的判定入口，
/// 抽成零 Android 依赖的纯 Kotlin 之后可以被**离线测试直接驱动**
/// （`kotlinc` 编的就是本文件，与进 APK 的是同一份字节）。
/// `open()` 那边只剩「释放 / 构造 / 记账」这些必须碰 Android API 的动作。
///
/// ## 症状（全量 logcat 可复现）
///
/// 半残 LoudnessEnhancer 一旦出现，`force = loud == null || loudDead` 在**两个失败态上
/// 都为真**（构造失败 ⇒ `loud == null`；复用坏模块 ⇒ `loudDead`），于是：
/// ① 早退那道闸整个失效；② 每一次 `setLoudness(enabled=true)` 都 `release()` + 重建
/// **两个** effect；③ 开关因为「没挂上」显示的永远是关 ⇒ 用户反复点 ⇒ 无界循环。
/// 实测 3 秒 7 次（7 次点击 ↔ 7 条 `force re-attach`，与输入事件的 DOWN/UP 一一对应），
/// 每次都在出声中途拆掉整条效果链。
///
/// ## 本类落地的三件事
/// ① ⛔ **早退条件里的 `||` 一个字不动**（[Input.bassAttached] `||` [Input.loudAttached]）；
/// ② **显式重试有界**：只有 `retryXxx` 才可能推翻早退，且受**冷却 + 次数上限**约束
///    ⇒ 同一 `(playerId, session)` 上最多 [MAX_RETRIES] 次；
/// ③ **不许连带拆健康的那个**：计划里逐个 effect 决定。
///
/// 覆盖本类的用例：`test/attach_retry_test.dart`（Dart 半：三态 / 开关可点性 / 过桥参数）。
internal class EffectAttachPolicy(
    private val cooldownMs: Long = RETRY_COOLDOWN_MS,
    private val maxRetries: Int = MAX_RETRIES,
) {
    companion object {
        /// 两次显式重挂之间的最小间隔。实测点击间隔 0.2~0.8 s
        /// ⇒ 这个值足以把「连点风暴」摊平成有节奏的少数几次。
        const val RETRY_COOLDOWN_MS = 1200L

        /// 同一 `(playerId, session)` 上允许的显式重挂次数上限。
        /// 用满之后 `info()` 报 `loudRetryExhausted=true` ⇒ Dart 把开关切成诚实的终态。
        const val MAX_RETRIES = 3
    }

    /// 一个 effect 的重试预算：冷却 + 上限。
    private class Budget {
        var used = 0
        var lastAtMs = Long.MIN_VALUE

        /// 冷却与上限都过了才放行；**放行才记账**（被拒的那一枪不算数，
        /// 否则连点会瞬间把预算烧光、用户反而更早失去重试机会）。
        fun allow(nowMs: Long, cooldownMs: Long, maxRetries: Int): Boolean {
            if (used >= maxRetries) return false
            if (used > 0 && nowMs - lastAtMs < cooldownMs) return false
            used++
            lastAtMs = nowMs
            return true
        }

        fun reset() {
            used = 0
            lastAtMs = Long.MIN_VALUE
        }
    }

    /// 预算挂在**哪个附着目标**上：换了 playerId 或换了 session（换歌/重放/换播放器）
    /// = 新的机会，预算归零。这是「关掉再打开就再也救不回来」的解药：
    /// 用户不用杀进程，换一首歌就又是满额。
    private var ledgerPlayerId: String? = null
    private var ledgerSession = Int.MIN_VALUE
    private val bassBudget = Budget()
    private val loudBudget = Budget()

    /// 判定输入：全是**当前事实**（由 `open()` 从字段里读），本类不重复持有它们。
    internal data class Input(
        val playerId: String?,
        val session: Int,
        val attachedPlayerId: String?,
        val attachedSession: Int,
        val bassAttached: Boolean,
        val loudAttached: Boolean,
        /// 用户显式要求重挂低音（= 拨开关 **且** 这一项确实没挂上）。
        /// 滑杆路径（`setBassStrength` / `setLoudnessGain`）恒为 false ——
        /// 它们连 `open()` 都不再调（见 `ExtraEffectsEngine` 的 `setBass` / `setLoudness`）。
        val retryBass: Boolean,
        val retryLoud: Boolean,
        val nowMs: Long,
    )

    fun plan(i: Input): AttachPlan {
        if (i.playerId != ledgerPlayerId || i.session != ledgerSession) {
            ledgerPlayerId = i.playerId
            ledgerSession = i.session
            bassBudget.reset()
            loudBudget.reset()
        }
        val sameTarget = i.attachedPlayerId == i.playerId && i.attachedSession == i.session
        // ⛔ 这个 `||` 是既有的语义，**一个字都不许改成 `&&`**：
        //    只认 BassBoost、不认 LoudnessEnhancer 的老 ROM 上 `loud` 永远是 null，
        //    `&&` 会让早退永远不成立 ⇒ 每次 `open()`（含播放中每轮 ensure）都重建两个 effect。
        val alreadyAttached = sameTarget && (i.bassAttached || i.loudAttached)
        if (alreadyAttached) {
            val bass = i.retryBass && bassBudget.allow(i.nowMs, cooldownMs, maxRetries)
            val loud = i.retryLoud && loudBudget.allow(i.nowMs, cooldownMs, maxRetries)
            if (!bass && !loud) return AttachPlan(earlyReturn = true)
            // 走到这里 = 显式重试真的推翻了早退 ⇒ 才记这一条（自动路径一条都不多）
            return AttachPlan(
                earlyReturn = false,
                rebuildBass = bass,
                rebuildLoud = loud,
                logForceReAttach = true,
            )
        }
        // 没挂好：要么目标变了（两个都必须重建 —— AudioEffect 绑死在构造时的 session 上，
        // Android 没有改绑 API），要么两个都是 null（没有健康的可保，重建哪个都一样）。
        val targetChanged = !sameTarget
        return AttachPlan(
            earlyReturn = false,
            rebuildBass = targetChanged || !i.bassAttached,
            rebuildLoud = targetChanged || !i.loudAttached,
            logForceReAttach = false,
        )
    }

    /// 显式重挂次数是否已经用满（→ `info()` 报 `loudRetryExhausted`）。
    fun loudRetryExhausted(): Boolean = loudBudget.used >= maxRetries

    /// 附着之后回填：这一项**这次真的能用了** ⇒ 它的重试预算清零。
    /// 不重置的话，一次历史失败会一直吃掉以后的额度（同一条 session 上再坏就只剩很少机会）。
    fun noteAttached(bassUsable: Boolean, loudUsable: Boolean) {
        if (bassUsable) bassBudget.reset()
        if (loudUsable) loudBudget.reset()
    }

    /// 整条链拆掉（显式 `release`）时一起归零。
    fun reset() {
        ledgerPlayerId = null
        ledgerSession = Int.MIN_VALUE
        bassBudget.reset()
        loudBudget.reset()
    }
}
