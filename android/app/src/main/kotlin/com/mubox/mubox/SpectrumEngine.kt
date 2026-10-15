package com.mubox.mubox

import android.media.audiofx.Visualizer
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import xyz.luan.audioplayers.AudioSessionProvider

/// 真实频谱引擎：attach 到自己播放器（audioplayers MediaPlayer）的 audio session，
/// 用 Visualizer 捕获 FFT 频域数据，通过 EventChannel 持续推给 Dart 层绘制频谱。
///
/// 为什么不 attach 输出混音(0)：Android 12+ 起 Google 禁用 `Visualizer(0)` 捕获输出
/// 混音（部分 ROM 的 Android 16 上直接抛 ERROR_INVALID_OPERATION）。attach 到自己的
/// session id 是标准做法，且不需要 RECORD_AUDIO 权限。
///
/// # 按播放器身份取 session
///
/// Dart 侧 `SpectrumEngine.receiveBroadcastStream` 订阅时把**播放器身份**当参数传进来
/// （`AudioPlayer.playerId`），这里用 `AudioSessionProvider.sessionOf(playerId)` 取该
/// 播放器**自己**的 session。于是双播放器（交叉淡变/预取）下不会挂错人 ——
/// 读全进程唯一格子时，谁最后 `setSource` 谁占。
///
/// **改绑入口 = 带新身份的重新订阅**（`streamHandler.onListen` 的 `arguments`）：
/// `Visualizer` **没有改绑 API**（构造时绑死 session），所以换播放器只能
/// `enabled=false` + `release()` 再 `Visualizer(新session)` 重建 —— 这条重建路径就是
/// [start] 里那句「running 但身份变了 ⇒ 先 stop 再建」，也是 Dart 侧
/// `SpectrumEngine.setTargetPlayerId()` 换场时走的同一条路。
class SpectrumEngine {
    companion object {
        private const val TAG = "SpectrumEngine"
        private const val MAX_RETRY = 8
    }

    private var visualizer: Visualizer? = null
    private var eventSink: EventChannel.EventSink? = null
    private var running = false
    private var retryCount = 0

    /// 已经挂上的那个播放器身份（null = 走兼容格子 / 还没挂）。
    private var attachedPlayerId: String? = null

    /// 这一轮要挂哪个播放器：退避重试必须带着它重进，否则重试会挂回默认格子。
    private var pendingPlayerId: String? = null

    private val handler = Handler(Looper.getMainLooper())
    private val retryRunnable = Runnable {
        if (!running) start(pendingPlayerId)
    }

    val streamHandler = object : EventChannel.StreamHandler {
        override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            eventSink = events
            // Dart 侧 receiveBroadcastStream(playerId) 的参数就是播放器身份
            start(if (arguments is String) arguments else null)
        }

        override fun onCancel(arguments: Any?) {
            stop()
            eventSink = null
        }
    }

    /// 启动 / **改绑**到 [playerId] 这个播放器。
    ///
    /// - 已经在挂同一个播放器 ⇒ 直接返回（不重建、不闪断）；
    /// - 已经在挂**另一个**播放器（交叉淡变换场）⇒ 先 [stop] 再重建
    ///   —— `Visualizer` 没有改绑 API，这是唯一的办法；
    /// - [playerId] 为 null = 老调用点（不带身份）⇒ 走 `AudioSessionProvider` 的兼容格子，
    ///   行为与老调用点逐项一致。
    private fun start(playerId: String? = pendingPlayerId) {
        pendingPlayerId = playerId
        if (running) {
            if (playerId == attachedPlayerId) return
            stop() // 换了播放器：重建（Visualizer 无改绑 API）
        }
        try {
            val sessionId = AudioSessionProvider.sessionOf(playerId)
            if (sessionId < 0) {
                throw IllegalStateException("audio session 未就绪（playerId=$playerId）")
            }
            // 采样点数取范围上限、但封顶 256：柱子只有 28 根，256 个采样分辨率足够
            val captureSize = Visualizer.getCaptureSizeRange()[1].coerceAtMost(256)
            val viz = Visualizer(sessionId)
            // 关键：默认 SCALING_MODE_NORMALIZED 会把 FFT 归一化到满量程，导致大量
            // bin 饱和（255）→ 每段取 max 后清一色满格。改成 AS_PLAYED 反映真实
            // 播放电平，幅度不再被人为拉满，配合 Dart 分位数归一化展开动态范围。
            viz.setScalingMode(Visualizer.SCALING_MODE_AS_PLAYED)
            viz.captureSize = captureSize
            viz.setDataCaptureListener(
                object : Visualizer.OnDataCaptureListener {
                    override fun onWaveFormDataCapture(
                        visualizer: Visualizer,
                        waveform: ByteArray,
                        samplingRate: Int,
                    ) = Unit

                    override fun onFftDataCapture(
                        visualizer: Visualizer,
                        fft: ByteArray,
                        samplingRate: Int,
                    ) {
                        // fft 是 real/imag 交错的有符号 byte（静音=0）：每两个 byte 一个复数点，
                        // 幅度 = sqrt(real^2 + imag^2)。转成无符号幅度数组再推给 Dart。
                        val pointCount = fft.size / 2
                        val mags = IntArray(pointCount)
                        for (i in 0 until pointCount) {
                            val real = fft[2 * i].toInt()
                            val imag = fft[2 * i + 1].toInt()
                            mags[i] = Math.sqrt((real * real + imag * imag).toDouble()).toInt()
                        }
                        eventSink?.success(mags)
                    }
                },
                Visualizer.getMaxCaptureRate(), // 最大捕获频率（约 20Hz）
                /* waveform = */ false,
                /* fft = */ true,
            )
            viz.enabled = true
            visualizer = viz
            running = true
            attachedPlayerId = playerId
            retryCount = 0
            // ⚠️ 日志前缀刻意保持 "Visualizer started, sessionId=" 可 grep：
            // 换场时频谱有没有重新起来就是拿这一行当锚点，playerId 追加在后面。
            Log.d(TAG, "Visualizer started, sessionId=$sessionId playerId=$playerId captureSize=$captureSize")
        } catch (e: Exception) {
            running = false
            retryCount++
            if (retryCount <= MAX_RETRY) {
                Log.w(TAG, "start failed (第 $retryCount 次), ${retryCount}s 后重试, playerId=$playerId sessionId=${AudioSessionProvider.sessionOf(playerId)}: ${e.message}")
                handler.postDelayed(retryRunnable, 1000L * retryCount)
            } else {
                Log.e(TAG, "重试 $MAX_RETRY 次仍失败，放弃（回退假动画）, playerId=$playerId sessionId=${AudioSessionProvider.sessionOf(playerId)}", e)
                // 通知 Dart：退避用尽，这一场是真的起不来了。
                // 以前这里只写 log —— lib/spectrum_engine.dart 的 onError 分支永远走不到，
                // 现象就是「频谱静默不动、UI 一个字都不提示」，只能靠翻 logcat 排查。
                // Dart 侧是 cancelOnError: true，收到后会取消订阅并清空引用计数（stop()）；
                // 下一次 acquire() 会重新 onListen，retryCount 已在 stop() 里归零，不会死循环。
                eventSink?.error(
                    "SPECTRUM_UNAVAILABLE",
                    "频谱不可用：原生 Visualizer 重试 $MAX_RETRY 次仍失败" +
                        "（常见原因：麦克风权限被系统忽略，见 adb shell cmd appops get " +
                        "com.mubox.mubox RECORD_AUDIO）",
                    e.message,
                )
            }
        }
    }

    private fun stop() {
        running = false
        retryCount = 0
        handler.removeCallbacks(retryRunnable)
        try {
            visualizer?.enabled = false
            visualizer?.release()
        } catch (_: Exception) {
        }
        visualizer = null
        attachedPlayerId = null
    }
}
