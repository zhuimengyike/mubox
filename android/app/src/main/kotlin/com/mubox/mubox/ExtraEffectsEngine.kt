package com.mubox.mubox

import android.media.audiofx.BassBoost
import android.media.audiofx.LoudnessEnhancer
import android.os.SystemClock
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import xyz.luan.audioplayers.AudioSessionProvider

/// 音效增强引擎：低音增强（BassBoost）+ 响度增强（LoudnessEnhancer）。
///
/// 与均衡器同一套路子（见 EqualizerEngine.kt）：attach 到**自己播放器的 audio session**
/// （不能挂输出混音 0，Android 12+ 禁止），只是 EQ 调的是各频段增益、这里调的是
/// 「低频整体强度」和「整体响度」两个高层参数。
///
/// 与 EqualizerEngine 的关系：
///  · 同一 session 上挂多个 AudioEffect 是 Android 的标准用法，两者互不干扰；
///  · 两个 effect 各自独立 try —— 某个 ROM 不支持其一，不该把另一个一起拖死；
///  · **刻意不发** ACTION_OPEN/CLOSE_AUDIO_EFFECT_CONTROL_SESSION 广播：那是
///    「谁接管这个 session 的效果链」的声明，统一由 EqualizerEngine 发，
///    两边都发会让系统音效框架收到重复的 open/close。
///
/// 事实来源与 EQ 一致：Dart 侧（SharedPreferences）说了算，只推目标值过来；
/// 原生负责「附着 + 落实」，附着前先缓存目标值，session 就绪后立刻生效。
class ExtraEffectsEngine {
    companion object {
        private const val TAG = "ExtraEffects"

        /// 响度增强增益上限（毫贝，100 mB = 1 dB）：再往上基本必削波，卡在 +12 dB
        private const val LOUDNESS_MAX_MB = 1200

        /// 低音强度满值（Android 约定 0~1000）
        private const val BASS_MAX_STRENGTH = 1000
    }

    private var bass: BassBoost? = null
    private var loud: LoudnessEnhancer? = null
    private var attachedSession = -1

    /// 「要不要重挂、重挂哪几个」的**纯判定**（零 Android 依赖、可离线驱动）。
    /// ⛔ 早退条件（那个 `||`）、显式重试的冷却与次数上限、逐个 effect 决定重建 ——
    /// 三条都在它里面，别把判定搬回 [open]（搬回来就没法离线驱动了）。
    private val attachPolicy = EffectAttachPolicy()

    /// 当前两个 effect 挂在**哪个播放器**上（Dart 侧 `AudioPlayer.playerId`）。
    /// 双播放器下只看 session 不够：见 [open] 那条三态判断。
    private var attachedPlayerId: String? = null

    /// `open(playerId)` 的目标：`info()` 据此回报"我现在对着谁"。
    private var targetPlayerId: String? = null

    // ── 「挂载状态」回报给 Dart（只有 info() 多两个键，判定逻辑一个字没动）──────────
    //
    // 由来：`LoudnessEnhancer` 挂到**新建的音频会话**上会**间歇性**失败 ——
    // `Cannot initialize effect engine for type: fe3199be-… Error: -3`
    // （`-3` = `AudioEffect.ERROR_NO_INIT`）。同一台机器、同一个 effect 型号，另一个 session
    // 上却挂成功了（`dumpsys media.audio_flinger`：一条 session 上 `Loudness Enhancer`
    // 注册成功、另一条上那个 `Registered=n`）⇒ **不是"这台设备没有这个接口"**。
    //
    // 而这两件事在 UI 上是**同一个样子**（`loudSupported = (loud != null)`）⇒
    // 开关被禁用、文案写"没有提供接口"、用户还失去自救入口。这两个格子的唯一作用就是
    // 把「这次没挂上」与「压根没试过 / 硬件就没有」分开。
    //
    /// 这一次**真的去挂了一次**（会话就绪、走过了两个 runCatching）。没试过 = false。
    private var attachAttempted = false

    /// 响度这次**挂失败了**。⚠️ 只有 [attachAttempted] 为真时才有意义。
    private var loudAttachFailed = false

    /// 响度失败的原因**是否可能只是临时的**（重挂有机会成功）。
    ///
    /// 分类规则：`IllegalArgumentException` = `AudioEffect.java` 对 `ERROR_BAD_VALUE(-4)` 抛的那个
    /// ⇒ **effect 类型本身不被支持**，重挂一万次也没用 ⇒ 不许给"再试一次"的假希望；
    /// 其余（`RuntimeException` / `ERROR_NO_INIT(-3)` 等）= "这次没初始化起来" ⇒ 可重试。
    private var loudRetryable = false

    /// ★ 响度这次**构造出来了、但对象是死的**（半残）：句柄在、实现体不在。
    ///
    /// 由来（12 声道输出 `layoutMask=185919`）：某些 ROM 自带的
    /// `AHAL_LoudnessEnhancerImpl` 对这条效果链所在的输出拒绝 `createContext`
    /// ⇒ `AHAL_EffectImpl::open` 因 `!mImplContext` **直接返回** ⇒ 模块建了、没有实现体。
    /// 而 AudioFlinger 会把新句柄挂到**已存在的那个坏模块**上 ⇒ 于是**构造成功**：
    /// * 新建且健康：`got effect 0x0` + `Constructor success` + HAL `V2open`
    /// * 复用坏模块（本状态）：`got effect <非0>` + **无** `Constructor success` + HAL `open…!mImplContext`
    ///
    /// ⇒ 「构造成功」**不等于**「能用」：之后每一个参数命令都失败，
    /// 抛的正是 `RuntimeException("AudioEffect: set/get parameter error")`
    /// （`AudioEffect.checkStatus` 的 default 分支）。
    ///
    /// 为什么必须单独有这一格：只看 `loud != null` 会把这种半残对象当成"可用"
    /// ⇒ ① `info()` 谎报可用（UI 从诚实的"没挂上"翻回正常文案）、
    /// ② 重挂请求的条件 `loud == null` 恒为 false ⇒ 开关变成按不动的死按钮。
    /// 两者正是那个谎报换了个形状回来。检查见 [loudEffectDead]。
    ///
    /// ⚠️ **它同时是「重挂风暴」的另一半**：半残出现之后
    /// `loud == null`（构造失败）与 `loudDead`（复用坏模块）**两个失败态会交替出现**，
    /// 于是「这一项没挂上」这个条件**恒为真** ⇒ 每点一次开关就拆一次链。
    /// ⇒ 有界那件事**不能靠这个条件**，必须另有预算（见 [attachPolicy]）。
    private var loudDead = false

    /// ★ 手上这个 `LoudnessEnhancer` **是不是半残对象**（建了但用不了）。
    ///
    /// 检查只用**已有的公开 API**、且**都是读**：拿 `getEnabled()` / `getTargetGain()`
    /// 打一枪 —— 半残对象上它们必抛（实现体不在），健康对象上它们原样返回值。
    ///
    /// ⚠️ 这几条是刻意选的，别顺手改：
    /// * 两者**都不改任何状态**（AOSP 里 `getEnabled` / `getTargetGain` 都是控制命令的读），
    ///   不像 `setEnabled` 那样有副作用；`enabled` 是 boolean、`targetGain` 是毫贝，
    ///   **两者都不可能是 NaN** ⇒ 没有"读起来像失败"的假阳性。
    /// * **不比对数值**（不去问"读回来的增益等不等于我设的"）：参数是**异步**落到
    ///   effect 线程的，写进去的瞬间读回来可能还是旧值 ⇒ 比对数值会误判健康对象为死。
    ///   这里只问"这条命令到底通不通"。
    /// * 这个函数**纯粹是探测**：一个字段都不写、一条日志都不打（记账由调用方做）
    ///   ⇒ 健康链路上它不留任何痕迹（自动路径逐字节不变的根据）。
    private fun loudEffectDead(): Boolean {
        val l = loud ?: return false
        runCatching { l.enabled }.onFailure { return true }
        runCatching { l.targetGain }.onFailure { return true }
        return false
    }

    // 目标状态：Dart 推过来的值，attach / 重 attach 时都会重新落实
    private var wantBassOn = false
    private var wantBassStrength = 0
    private var wantLoudOn = false
    private var wantLoudGain = 0

    val methodHandler = MethodChannel.MethodCallHandler { call, result ->
        try {
            when (call.method) {
                "open" -> result.success(open(call.argument<String>("playerId")))
                "info" -> result.success(info())
                "applyAll" -> {
                    wantBassOn = call.argument<Boolean>("bassEnabled") ?: false
                    wantBassStrength = call.argument<Int>("bassStrength") ?: 0
                    wantLoudOn = call.argument<Boolean>("loudEnabled") ?: false
                    wantLoudGain = call.argument<Int>("loudGain") ?: 0
                    apply()
                    result.success(info())
                }

                "setBass" -> {
                    wantBassOn = call.argument<Boolean>("enabled") ?: false
                    wantBassStrength = call.argument<Int>("strength") ?: wantBassStrength
                    // 打开这一项时顺带**挂载/重试**一次：`apply()` 在未附着时是静默跳过的，
                    // 不补这一步的话「挂失败之后拨开关」就是个死动作、永远修不回来
                    // （用户能触发的重挂入口只有换场，而换场不由他掌控）。
                    // ⚠️ 关闭时**刻意不重挂**：关功能不该反向多构造一次 effect。
                    // ★★ 重挂请求的条件 =「Dart 说这是**拨开关**（`retry=true`）」**且**
                    //   「这一项确实没挂上」。两条缺一不可：
                    //   · 缺后一条 ⇒ 已经挂着也重建，白耗；
                    //   · 缺前一条 ⇒ **拖强度滑杆也会重挂**。实测过这一枪
                    //     （logcat 里那一行的 `playerId=null`）：`setBassStrength` /
                    //     `setLoudnessGain` 是**不带 playerId** 的（见 extra_effects.dart），
                    //     于是 `alreadyAttached` 里那条身份比对当场失效 ⇒ 整条效果链
                    //     （**连健康的那个一起**）在出声中途被拆掉重建。
                    //     现在滑杆路径连 `open()` 都不调了，见下面那条 `retry` 闸。
                    if (wantBassOn && call.argument<Boolean>("retry") == true) {
                        open(call.argument<String>("playerId"), retryBass = bass == null)
                    }
                    apply()
                    result.success(info())
                }

                "setLoudness" -> {
                    wantLoudOn = call.argument<Boolean>("enabled") ?: false
                    wantLoudGain = call.argument<Int>("gain") ?: wantLoudGain
                    // 同上（理由见 setBass 那段注释）。这一条就是音效页那句
                    // 「点右边的开关再试一次就行」真正落地的地方：`bass` 挂上而 `loud` 挂了
                    // （`Error: -3`）时 `loud == null` ⇒ 真的重挂一次；
                    // ★ 半残（[loudDead]）也算「没挂上」—— 那条 12 声道输出会让模块
                    //   「建得出来、用不了」，只认 null 的话这里恒 false ⇒ 开关又变死按钮。
                    //
                    // ⛔ **重挂的「有界」在 [attachPolicy] 里**（冷却 + 次数上限），不在这一行。
                    //   实测（3 秒 7 次点击 ↔ 7 条 `force re-attach`）：半残之后
                    //   `loud == null` 与 `loudDead` **两个失败态交替出现、两边都满足这个条件**
                    //   ⇒ 闸门等于没有 ⇒ 点几次拆几次，且每次都把健康的 bass 一起拆了。
                    //   现在这一行只负责「用户确实要求了」，放不放行由策略说了算，
                    //   用满之后 info() 报 `loudRetryExhausted` ⇒ UI 切成诚实的终态。
                    if (wantLoudOn && call.argument<Boolean>("retry") == true) {
                        open(
                            call.argument<String>("playerId"),
                            retryLoud = loud == null || loudDead,
                        )
                    }
                    apply()
                    result.success(info())
                }

                "release" -> {
                    release()
                    result.success(info())
                }

                else -> result.notImplemented()
            }
        } catch (t: Throwable) {
            Log.w(TAG, "method ${call.method} failed: ${t.message}")
            result.error("FX_FAILED", t.message, null)
        }
    }

    /// 附着到 [playerId] 这个播放器的 session；session 未就绪时 available=false。
    /// 播放开始时 / 每次换场时 Dart 会再调一次，所以这里不需要自己重试轮询。
    ///
    /// **改绑入口就是这个 `open(playerId)`**（MethodChannel `open` 带 `playerId`，
    /// 调用点 = `lib/extra_effects.dart` 的 `ensure(playerId:)`）。
    ///
    /// 三态（少了第三态 ⇒ 换播放器时它以为"已经挂好了"，于是两个 effect
    /// 留在旧 session 上，对新播放器静默失效、开关却还显示"开着"）：
    /// ① 同播放器 + 同 session ⇒ 已挂着，不动；
    /// ② 同播放器 + session 变了 ⇒ 重挂；
    /// ③ 换了播放器 ⇒ 重挂。
    ///
    /// ⚠️ 早退条件里那个 `(bass != null || loud != null)` 的 `||` **一个字都没动**
    /// （现在在 `EffectAttachPolicy.plan` 里，`(bassAttached || loudAttached)`）。
    /// 这里的修法**刻意绕开**它：用 [retryLoud] / [retryBass] 单独处理用户重试
    /// （见下面的「⛔ 别把 `||` 改成 `&&`」）。
    ///
    /// `setBass` / `setLoudness` 那两条路会**按需**调它（用户拨开关 = 一次显式重挂请求，
    /// Dart 侧带 `retry=true` 才作数）。调它**不会**多构造 effect —— 两个都真挂着且同
    /// session 时它在早退那一行就返回了。调增益/强度那两条滑杆路**根本不调它**
    /// （它们不带 `retry`）⇒ 一个 effect 都不碰。
    ///
    /// 顺带把「这次到底试没试、响度挂没挂上、失败是不是临时的」记进三个格子供 [info] 回报。
    /// ★ 半残（构造成功但对象是死的）也算「挂失败」，而且是**可重试**的那种 ——
    /// 检查见 [loudDead] / [loudEffectDead]。
    ///
    /// [retryLoud] / [retryBass] = 「用户主动拨开关，请真的重挂**这一项**」。
    /// ⛔ 它们**只跳过早退**（且要过 [attachPolicy] 的冷却 + 次数上限），不参与任何别的判定；
    /// 缺省 false，调用点只有 [setBass] / [setLoudness] 打开这一项、
    /// **且这一项确实没挂上（响度还包含挂上的是半残）**时。
    ///
    /// 为什么需要它们：`bass` 挂上、`loud` 挂失败（`Error: -3`）时，
    /// 早退条件 `(bass != null || loud != null)` **已经被 bass 满足** ⇒ `LoudnessEnhancer`
    /// **再也不会被构造** ⇒ 音效页那句「点右边的开关再试一次就行」是**空头支票**：
    /// 点那颗开关，`ExtraEffects` **一条新日志都没有**、状态也不动
    /// （根因就是这一行早退）。
    ///
    /// ⛔ **别把那个 `||` 改成 `&&`**（另一个候选做法，这里**明确否决**，别再顺手改回去）：
    /// 只认 BassBoost、不认 LoudnessEnhancer 的老 ROM 上（构造恒抛 `IllegalArgumentException`
    /// = `ERROR_BAD_VALUE`），`loud` **永远是 null** ⇒ 早退条件永远不成立 ⇒
    /// **每次 `open()` 都要重建两个 effect** = 纯白耗，还会在出声中途把音效整条链重建一次。
    /// 而 `open()` 是**自动**路径（播放中每轮 `ensure`、每次换场都会走），代价按秒计；
    /// 要修的只是「用户点了那颗开关」这一条路 ⇒ 把它限到**带 [retryLoud] 的显式动作**上，
    /// 而且**次数有界**（自动路径一个字节都不变）。
    ///
    /// ⛔ **也别把重建退回「整条链 release()」**：实测 `bass=true` 一直健康，
    /// 却每次重挂都被连带拆掉重建 —— 那正是「一卡一卡 + 机械噪声」的直接放大器
    /// （`AudioFlinger: moveEffectChain_ll: effect chain failed …`）。
    /// 现在重建哪个由 [AttachPlan.rebuildBass] / [AttachPlan.rebuildLoud] 逐个决定。
    private fun open(
        playerId: String? = null,
        retryLoud: Boolean = false,
        retryBass: Boolean = false,
    ): Map<String, Any?> {
        targetPlayerId = playerId
        val session = AudioSessionProvider.sessionOf(playerId)
        if (session < 0) return info()
        val plan = attachPolicy.plan(
            EffectAttachPolicy.Input(
                playerId = playerId,
                session = session,
                attachedPlayerId = attachedPlayerId,
                attachedSession = attachedSession,
                bassAttached = bass != null,
                loudAttached = loud != null,
                retryBass = retryBass,
                retryLoud = retryLoud,
                nowMs = SystemClock.elapsedRealtime(),
            ),
        )
        if (plan.earlyReturn) return info()
        // 只有显式重试**真的推翻了这次早退**才打这一条：重挂请求在「本来就要重挂」的场合
        // （换场 / 换了 session / 两个都没挂上）等于没传，连日志都不多一条 ⇒
        // 自动路径的输出与改动前逐字节相同。观察锚点：
        // 点开关后必须能看见它 + 紧跟其后的 "attached, sessionId=" 行。
        if (plan.logForceReAttach) {
            Log.d(TAG, "force re-attach (user retry), sessionId=$session playerId=$playerId")
        }
        // ★ 逐个拆：只拆真的要重建的那个，健康的那个原样留着（见上面那条 ⛔）。
        if (plan.rebuildBass) releaseBass()
        if (plan.rebuildLoud) releaseLoud()
        attachedSession = session
        attachedPlayerId = playerId
        // 两个 effect 各自独立兜错：老 ROM 可能只认其中一个
        if (plan.rebuildBass) {
            bass = runCatching { BassBoost(0, session) }
                .onFailure { Log.w(TAG, "bass attach failed: ${it.message}") }
                .getOrNull()
        }
        if (plan.rebuildLoud) {
            // 「这一轮真的去挂了」从这一刻起为真（会话已就绪、下面那个 runCatching 一定会跑）
            attachAttempted = true
            loudAttachFailed = false
            loudRetryable = false
            loud = runCatching { LoudnessEnhancer(session) }
                .onFailure {
                    Log.w(TAG, "loudness attach failed: ${it.message}")
                    loudAttachFailed = true
                    // IllegalArgumentException = 这个 effect 类型压根不被支持（ERROR_BAD_VALUE）
                    // ⇒ 重挂没意义；其余（含 ERROR_NO_INIT = -3）只当"这次没起来"
                    loudRetryable = it !is IllegalArgumentException
                }
                .getOrNull()
        }
        apply()
        // ★ 半残判定：`loud` 构造成功**不等于**它能用（那条 12 声道输出上，
        //   模块建得出来、实现体不在 ⇒ 每个参数命令都抛 "set/get parameter error"）。
        //   探测完再把三个格子按同一个事实对齐，**三个必须一起报**：
        //     loudSupported=false（它不算"支持"）+ loudAttachFailed=true + loudRetryable=true。
        //   ⛔ 只报 loudSupported=false 会漏掉 loudAttachFailed ⇒ Dart 的 attachStateOf 落回
        //      `unknown` ⇒ 开关被禁用 + 文案变成「这台设备没有提供接口」
        //      = 谎报换个方向 + 连自救入口都丢了（比不改还糟）。
        //   `loudDead` 先记下来：下面 [info] 报 `loudSupported` 要读它。
        //   ⚠️ 只在真的重建了 loud 时重探；只重建 bass 时 `loudDead` 描述的还是原来那个活对象。
        if (plan.rebuildLoud) {
            loudDead = loudEffectDead()
            if (loudDead) {
                loudAttachFailed = true
                // RuntimeException("AudioEffect: set/get parameter error")，不是硬不支持
                // ⇒ 与本文件既有的判断一致：只有 IllegalArgumentException 才算"硬件就没有"
                loudRetryable = true
            }
        }
        // 这次真的能用的那一项 ⇒ 它的重试预算清零（以后同一条 session 上再坏还有额度）
        attachPolicy.noteAttached(
            bassUsable = bass != null,
            loudUsable = loud != null && !loudDead,
        )
        // ⚠️ 日志前缀刻意保持 "attached, sessionId=" 可 grep（观察锚点），playerId 追加在后面。
        // ★ 这一行的**文本一个字都不许再改**：自动路径（播放中每轮 ensure / 每次换场）的输出
        //   必须与改动前逐字节相同，半残标记另起一行（见下）。
        Log.d(TAG, "attached, sessionId=$session playerId=$playerId bass=${bass != null} loud=${loud != null}")
        // ★ 半残才多打这一条（健康链路上**一条都不多**，日志逐字节不变）。观察锚点：
        //   点开关后若看见它，说明「建了但用不了」，UI 那边此时应当显示诚实的"这次没挂上"。
        //   ⚠️ 只在真的重建了 loud 时打：只重建 bass 时 `loudDead` 描述的是原来那个活对象，
        //     再打一遍就成了重复日志（自动路径「逐字节不变」这条约束会被它破坏）。
        if (plan.rebuildLoud && loudDead) {
            Log.w(
                TAG,
                "loudness attached but DEAD: effect handle exists, every parameter command fails"
                    + " (constructor succeeded, implementation body missing), sessionId=$session playerId=$playerId",
            )
        }
        return info()
    }

    /// 把目标状态落到两个 effect 上（未附着时静默跳过，等下一次 open）
    private fun apply() {
        bass?.let { b ->
            runCatching {
                // 设备不支持强度调节时压根别启用，否则开了也没效果、开关状态还骗人
                val usable = b.strengthSupported
                val target = wantBassOn && usable
                if (usable) {
                    val s = wantBassStrength.coerceIn(0, BASS_MAX_STRENGTH).toShort()
                    if (b.roundedStrength != s) b.setStrength(s)
                }
                if (b.enabled != target) b.enabled = target
            }.onFailure { Log.w(TAG, "apply bass failed: ${it.message}") }
        }
        loud?.let { l ->
            runCatching {
                val g = wantLoudGain.coerceIn(0, LOUDNESS_MAX_MB)
                // 注意：getTargetGain() 返回 Float（毫贝），setTargetGain() 收 Int —— 比较前先转
                if (l.targetGain.toInt() != g) l.setTargetGain(g)
                if (l.enabled != wantLoudOn) l.enabled = wantLoudOn
            }.onFailure { Log.w(TAG, "apply loudness failed: ${it.message}") }
        }
    }

    /// 当前能力与状态快照（Dart 据此渲染 UI）
    private fun info(): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>(
            "available" to (bass != null || loud != null),
            // 带了身份就查那个播放器自己那份 session；没带身份回落兼容格子（与老调用点一致）
            "sessionId" to AudioSessionProvider.sessionOf(targetPlayerId),
            "bassSupported" to (bass?.strengthSupported == true),
            "bassEnabled" to wantBassOn,
            "bassStrength" to wantBassStrength,
            // ★ 半残（[loudDead]：构造出来了但用不了）**不算** supported ——
            //   "构造成功 ≠ 能用"。这一格是 UI 唯一的能力来源，报 true 就是谎报可用。
            "loudSupported" to (loud != null && !loudDead),
            "loudEnabled" to wantLoudOn,
            "loudGain" to wantLoudGain,
            "loudMaxGain" to LOUDNESS_MAX_MB,
            // 「这次没挂上」vs「压根没试过 / 硬件就没有」——Dart 侧据此决定文案与开关可点性。
            // 老版本 Dart 不认识这三个键 ⇒ 行为与改动前逐项相同。
            // ★ 半残走的是「这次没挂上」那一支（loudAttachFailed + loudRetryable 都为真，
            //   见 [open] 里的探测）：它**不是**"硬件就没有"，不许说成硬不支持。
            "loudAttachAttempted" to attachAttempted,
            "loudAttachFailed" to loudAttachFailed,
            "loudRetryable" to loudRetryable,
            // ★ 显式重挂次数**已经用满**（同一条 `(playerId, session)` 上）。
            //   这一格**只改文案**，⛔ 不许拿它去禁用开关：用户拍板的方案是
            //   「保留响度开关 + 再试一次」，把这个功能标成不可用就是换个方向的谎报。
            //   用满之后**之后**的重挂请求一律被 [attachPolicy] 拒（0 次重建），
            //   换一首歌（新 session）自动又是满额 ⇒ 文案要把这一点说清楚。
            "loudRetryExhausted" to attachPolicy.loudRetryExhausted(),
        )
        bass?.let { b ->
            runCatching {
                out["bassEnabled"] = b.enabled
                out["bassStrength"] = b.roundedStrength.toInt()
            }.onFailure { Log.w(TAG, "bass info failed: ${it.message}") }
        }
        loud?.let { l ->
            runCatching {
                out["loudEnabled"] = l.enabled
                out["loudGain"] = l.targetGain.toInt()
            }.onFailure { Log.w(TAG, "loudness info failed: ${it.message}") }
        }
        return out
    }

    /// 拆掉低音那一个（**不动响度**）。
    ///
    /// ★ 为什么要有「逐个拆」：一旦 `open()` 一律调 [release]，两个就一起拆 ——
    /// logcat 里 `bass=true` **17 次附着里一次没坏过**，却每次重挂都被连带拆掉重建。
    /// 那正是「一卡一卡 + 机械噪声」的直接放大器（`AudioFlinger: moveEffectChain_ll:
    /// effect chain failed because destination thread … is not compatible`）。
    private fun releaseBass() {
        runCatching {
            bass?.let {
                it.enabled = false
                it.release()
            }
        }
        bass = null
    }

    /// 拆掉响度那一个（**不动低音**）。半残标记跟着对象一起走，交给随后的重探重新判定。
    private fun releaseLoud() {
        runCatching {
            loud?.let {
                it.enabled = false
                it.release()
            }
        }
        loud = null
        // ★ 半残标记跟着对象一起走：没了就是没了（否则下次挂上健康的也会被判成死的）
        loudDead = false
    }

    private fun release() {
        releaseBass()
        releaseLoud()
        attachedSession = -1
        attachedPlayerId = null
        // 这次「试过没有 / 挂没挂上」随附着一起归零 ⇒ 回到 unknown
        // （= 老实说"现在没有可用的接口"，而不是拿上一轮的成败去骗 Dart）
        attachAttempted = false
        loudAttachFailed = false
        loudRetryable = false
        // 整条链都拆了 ⇒ 重试预算也归零（下次附着是新的开始）
        attachPolicy.reset()
    }
}
