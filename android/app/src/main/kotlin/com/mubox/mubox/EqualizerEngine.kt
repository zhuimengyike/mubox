package com.mubox.mubox

import android.content.Context
import android.content.Intent
import android.media.audiofx.AudioEffect
import android.media.audiofx.Equalizer
import android.util.Log
import io.flutter.plugin.common.MethodChannel
import xyz.luan.audioplayers.AudioSessionProvider

/// 均衡器引擎：attach 到自己播放器的 audio session（与频谱同一个 sessionId），
/// 用 android.media.audiofx.Equalizer 做多段增益。
///
/// 为什么不 attach 输出混音(0)：与频谱同理 —— Android 12+ 禁止处理全局输出，
/// 必须挂在自己的播放 session 上（详见 SpectrumEngine 的注释）。
/// 需要 MODIFY_AUDIO_SETTINGS（普通权限，装完即有，无需运行时申请）。
///
/// 另外按官方约定发 ACTION_OPEN/CLOSE_AUDIO_EFFECT_CONTROL_SESSION 广播：
/// 告知系统音频效果框架「这个 session 由本 App 接管」，系统音效面板/厂商音效
/// 才不会在我们播放期间另起一套效果链（参考 equalizer_flutter 的实现）。
///
/// 事实来源分工：
///  · Dart 侧是设置的唯一事实来源（存 SharedPreferences），只把目标值推过来；
///  · 原生只做「附着到当前 session + 把目标值落到 effect」，附着前先缓存目标值，
///    这样「先设好 EQ 再播放」也能在 session 就绪后立刻生效；
///  · 频段数 / 增益范围 / 预设名各家 ROM 不同，统一由 getInfo 回给 Dart 驱动 UI。
class EqualizerEngine(private val context: Context) {
    companion object {
        private const val TAG = "EqualizerEngine"

        /// 兜底增益上限（毫贝）：个别 ROM 报出异常大的范围值，clamp 一下更安全
        private const val LEVEL_GUARD = 2000
    }

    private var eq: Equalizer? = null
    private var attachedSession = -1

    /// 当前 effect 挂在**哪个播放器**上（Dart 侧 `AudioPlayer.playerId`）。
    /// 双播放器（交叉淡变/预取）下，只看 session 是不够的 ——
    /// 见 [open] 里那条三态判断。
    private var attachedPlayerId: String? = null

    /// `open(playerId)` 指定的目标播放器：`info()` 据此回报"我现在对着谁"。
    /// 没带身份的调用为 null ⇒ 回报兼容格子的值，与不带身份的调用点一致。
    private var targetPlayerId: String? = null

    /// 目标状态：附着成功或重新附着时都会重新应用（Dart 推过来的值）
    private var wantEnabled = false
    private val wantLevels = mutableListOf<Int>()
    private var wantPreset = -1

    val methodHandler = MethodChannel.MethodCallHandler { call, result ->
        try {
            when (call.method) {
                "open" -> result.success(open(call.argument<String>("playerId")))
                "info" -> result.success(info())
                "applyAll" -> {
                    wantEnabled = call.argument<Boolean>("enabled") ?: false
                    wantLevels.clear()
                    wantLevels.addAll(intList(call.argument<Any?>("levels")))
                    wantPreset = -1
                    apply()
                    result.success(info())
                }

                "setEnabled" -> {
                    wantEnabled = call.argument<Boolean>("enabled") ?: false
                    apply()
                    result.success(info())
                }

                "setBands" -> {
                    wantLevels.clear()
                    wantLevels.addAll(intList(call.argument<Any?>("levels")))
                    wantPreset = -1 // 手动拖过就不再算「某个预设」
                    apply()
                    result.success(info())
                }

                "setPreset" -> {
                    // 预设会重写各段增益：先清掉自定义值，否则 apply 时又盖回去
                    wantLevels.clear()
                    wantPreset = call.argument<Int>("index") ?: -1
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
            result.error("EQ_FAILED", t.message, null)
        }
    }

    /// Dart 传过来的是 List<dynamic>（元素为 Number），逐个取整，别直接当 List<Int> 用
    private fun intList(raw: Any?): List<Int> =
        (raw as? List<*>)?.map { (it as? Number)?.toInt() ?: 0 } ?: emptyList()

    /// 附着到 [playerId] 这个播放器的 session；session 未就绪（还没建过播放器）时返回
    /// available=false。Dart 在每次开始播放 / 每次换场时都会再调一次，所以这里不需要
    /// 自己重试轮询。
    ///
    /// **改绑入口就是这个 `open(playerId)`**（MethodChannel `open` 带 `playerId` 参数，
    /// 调用点 = `lib/eq_engine.dart` 的 `ensure(playerId:)`）。
    ///
    /// 判断是**三态**的（只判第二态时换播放器会被当成"已经挂好了"）：
    /// ① 同一个播放器 + 同一个 session ⇒ 真的已经挂着，什么都不做；
    /// ② 同一个播放器 + session 变了（MediaPlayer 被重建，比如 ReleaseMode.RELEASE）⇒ 重挂；
    /// ③ **换了播放器**（交叉淡变换场 / 预取占了另一个）⇒ 重挂 ——
    ///    旧的 Equalizer 还挂在旧 session 上，对新播放器**静默失效**，
    ///    而界面上开关还显示"开着"。
    private fun open(playerId: String? = null): Map<String, Any?> {
        targetPlayerId = playerId
        val session = AudioSessionProvider.sessionOf(playerId)
        if (session < 0) return info()
        if (eq != null && attachedPlayerId == playerId && attachedSession == session) return info()
        // 重挂前先按官方约定通知系统「旧的这一条效果链结束」——CLOSE 用的是**旧** session，
        // 与下面 OPEN 的新 session 严格配对（sendSession 用的是 attachedSession）。
        release()
        return try {
            val e = Equalizer(0, session)
            eq = e
            attachedSession = session
            attachedPlayerId = playerId
            apply()
            // 官方约定：接管该 session 的音频效果链
            sendSession(AudioEffect.ACTION_OPEN_AUDIO_EFFECT_CONTROL_SESSION, session)
            // ⚠️ 日志前缀刻意保持 "attached, sessionId=" 可 grep（观察锚点），playerId 追加在后面
            Log.d(TAG, "attached, sessionId=$session playerId=$playerId bands=${e.numberOfBands}")
            info()
        } catch (t: Throwable) {
            eq = null
            attachedSession = -1
            attachedPlayerId = null
            Log.w(TAG, "attach failed (playerId=$playerId session=$session): ${t.message}")
            info()
        }
    }

    /// 把目标状态落到 effect 上（未附着时静默跳过，等下一次 open）
    private fun apply() {
        val e = eq ?: return
        runCatching {
            if (wantPreset in 0 until e.numberOfPresets.toInt()) {
                e.usePreset(wantPreset.toShort())
                wantPreset = -1 // 只需落一次，之后各段增益就是事实
            }
            val range = e.bandLevelRange
            val lo = maxOf(range[0].toInt(), -LEVEL_GUARD)
            val hi = minOf(range[1].toInt(), LEVEL_GUARD)
            val bands = e.numberOfBands.toInt()
            for (i in wantLevels.indices) {
                if (i >= bands) break
                val level = wantLevels[i].coerceIn(lo, hi).toShort()
                if (e.getBandLevel(i.toShort()) != level) {
                    e.setBandLevel(i.toShort(), level)
                }
            }
            if (e.enabled != wantEnabled) e.enabled = wantEnabled
        }.onFailure { Log.w(TAG, "apply failed: ${it.message}") }
    }

    /// 当前能力与状态快照（Dart 据此渲染 UI / 回读预设增益）
    private fun info(): Map<String, Any?> {
        val out = mutableMapOf<String, Any?>(
            "available" to (eq != null),
            // 回报"我现在对着哪个播放器的 session"：带了身份就查那个播放器自己那份，
            // 没带身份（老调用点）回落兼容格子 —— 与老调用点逐项一致
            "sessionId" to AudioSessionProvider.sessionOf(targetPlayerId),
            "enabled" to wantEnabled,
            "bands" to 0,
            "minLevel" to -1500,
            "maxLevel" to 1500,
            "centerFreqs" to emptyList<Int>(),
            "levels" to wantLevels.toList(),
            "presets" to emptyList<Map<String, Any?>>(),
            "currentPreset" to -1,
        )
        val e = eq ?: return out
        return runCatching {
            val bands = e.numberOfBands.toInt()
            val range = e.bandLevelRange
            out["enabled"] = e.enabled
            out["bands"] = bands
            out["minLevel"] = range[0].toInt()
            out["maxLevel"] = range[1].toInt()
            out["centerFreqs"] = (0 until bands).map { e.getCenterFreq(it.toShort()) }
            out["levels"] = (0 until bands).map { e.getBandLevel(it.toShort()).toInt() }
            out["presets"] = (0 until e.numberOfPresets.toInt()).map {
                mapOf<String, Any?>("index" to it, "name" to e.getPresetName(it.toShort()))
            }
            out["currentPreset"] = e.currentPreset.toInt()
            out
        }.getOrElse {
            Log.w(TAG, "info failed: ${it.message}")
            out
        }
    }

    /// 释放 effect，并按官方约定通知系统「本 session 的效果链已结束」。
    /// CLOSE 广播用的是 [attachedSession]（= 即将被放掉的那一个），
    /// 与下一次 [open] 成功后的 OPEN 广播严格配对。
    private fun release() {
        runCatching {
            eq?.let {
                it.enabled = false
                it.release()
            }
        }
        sendSession(AudioEffect.ACTION_CLOSE_AUDIO_EFFECT_CONTROL_SESSION, attachedSession)
        eq = null
        attachedSession = -1
        attachedPlayerId = null
    }

    private fun sendSession(action: String, session: Int) {
        if (session < 0) return
        runCatching {
            val intent = Intent(action).apply {
                putExtra(AudioEffect.EXTRA_PACKAGE_NAME, context.packageName)
                putExtra(AudioEffect.EXTRA_AUDIO_SESSION, session)
            }
            context.sendBroadcast(intent)
        }.onFailure { Log.w(TAG, "broadcast failed: ${it.message}") }
    }
}
