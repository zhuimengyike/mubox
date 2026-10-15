package xyz.luan.audioplayers.player

import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.annotation.RequiresApi
import xyz.luan.audioplayers.AudioContextAndroid

abstract class FocusManager {
    abstract val player: WrappedPlayer
    abstract val onGranted: () -> Unit
    abstract val onLoss: (isTransient: Boolean) -> Unit

    /// 系统**明确拒绝**了焦点请求（`AUDIOFOCUS_REQUEST_FAILED`）**且重试用尽**时收尾。
    abstract val onDenied: () -> Unit

    abstract var context: AudioContextAndroid

    companion object {
        fun create(
            player: WrappedPlayer,
            onGranted: () -> Unit,
            onLoss: (isTransient: Boolean) -> Unit,
            onDenied: () -> Unit,
        ): FocusManager {
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                ModernFocusManager(player, onGranted, onLoss, onDenied)
            } else {
                LegacyFocusManager(player, onGranted, onLoss, onDenied)
            }
        }

        /// 焦点被拒之后的**重试退避表**（毫秒）—— **表长 = 重试次数**，用尽才认输。
        ///
        /// 为什么要有重试：`AUDIOFOCUS_REQUEST_FAILED` 绝大多数是**瞬态**
        /// （来电 / 导航播报 / 别的 App 正 transient 持有焦点 / 系统策略抖动）。
        /// 这里**什么都不做**的话 ⇒ `onGranted` 不跑 ⇒ 播放器永不 `start()`，
        /// 而 Dart 侧已经把状态置成 playing ⇒ **App 显示在播、却一声不响**。
        ///
        /// 为什么是这三个值（250 / 750 / 2000，共 3 次重试、总窗口 ≈3s）：
        /// - 第一次重试压在 **250ms**：瞬态占用通常几百毫秒内就让出焦点，用户听到的只是
        ///   「起播稍慢」，远小于人耳判定"卡住了"的门槛。
        /// - 退避逐级放大到 **2s**：覆盖"上一次占用持续到秒级"的情况（铃声 / 导航播报 /
        ///   别的 App 切曲的典型时长），同时不让请求变成忙等（4 次请求摊在 3s 里）。
        /// - 总窗口 **≈3s 是上限**：超过它就该说真话（[onDenied]）而不是继续假装在播 ——
        ///   「一直安静地不响」正是这个缺陷的形态。
        /// - **3 次**（= 首次 + 3 = 共 4 次请求）是"瞬态能救回来"与"失败要快点说出口"的折中；
        ///   退避表是纯数据，不依赖 Android 运行时，可以直接被单元测试驱动。
        private val RETRY_DELAYS_MS = longArrayOf(250L, 750L, 2000L)
    }

    private val mainHandler: Handler by lazy { Handler(Looper.getMainLooper()) }

    /// 已经排出去几次重试（0 = 还没重试过）。
    private var retryAttempt = 0

    /// 是否已有一个重试任务在途（防叠加，也防 `maybeRequestAudioFocus()` 重复发请求）。
    private var retryPending = false

    private val retryRunnable = Runnable {
        retryPending = false
        if (!player.playing) {
            // 用户在重试窗口里自己停了/暂停了：这条重试线就此收工，不去抢焦点、也不报"被拒"
            retryAttempt = 0
            return@Runnable
        }
        requestAudioFocus()
    }

    protected abstract fun hasAudioFocusRequest(): Boolean

    protected abstract fun updateAudioFocusRequest()

    protected val audioManager: AudioManager
        get() = player.audioManager

    fun maybeRequestAudioFocus() {
        if (context != player.context) {
            context = player.context
            updateAudioFocusRequest()
        }
        // 已经有一个重试在跑：由它接着请焦点，别叠加（否则一次播放会打出成倍的请求）
        if (retryPending) return
        if (hasAudioFocusRequest()) {
            requestAudioFocus()
        } else {
            // Grant without requesting focus, if it is AudioManager.AUDIOFOCUS_NONE
            onGranted()
        }
    }

    /// 放弃在途的重试（用户暂停 / 停止 / 释放 / 换音频上下文时都该调）。
    fun cancelPendingRetry() {
        if (retryPending) {
            mainHandler.removeCallbacks(retryRunnable)
            retryPending = false
        }
        retryAttempt = 0
    }

    protected abstract fun requestAudioFocus()

    abstract fun handleStop()

    protected fun handleFocusResult(result: Int) {
        when (result) {
            AudioManager.AUDIOFOCUS_REQUEST_GRANTED -> {
                cancelPendingRetry()
                onGranted()
            }

            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                onLoss(true)
            }

            AudioManager.AUDIOFOCUS_LOSS -> {
                onLoss(false)
            }

            // 系统**明确拒绝**（不是"暂时丢了"，是"现在不给你"）。
            // 没有这个分支 ⇒ `playing` 已是 true 而 `start()` 永不调用。
            AudioManager.AUDIOFOCUS_REQUEST_FAILED -> {
                retryOrDeny()
            }
        }
        // Keep playing source on `AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` as sound is ducked.
        // `AUDIOFOCUS_REQUEST_DELAYED`（=2）在本插件里**不可达**：从不 setAcceptsDelayedFocusGain(true)，
        // 系统只在请求显式接受延迟授予时才可能回它 ⇒ 刻意不为它加分支（那条分支永远走不到）。
    }

    private fun retryOrDeny() {
        if (!player.playing) {
            // 请求出去之后用户已经不要播了（暂停/停止）：不重试，也不该弹"被拒"
            cancelPendingRetry()
            return
        }
        if (retryAttempt >= RETRY_DELAYS_MS.size) {
            cancelPendingRetry()
            onDenied()
            return
        }
        val delay = RETRY_DELAYS_MS[retryAttempt]
        retryAttempt++
        retryPending = true
        mainHandler.postDelayed(retryRunnable, delay)
    }
}

private class LegacyFocusManager(
    override val player: WrappedPlayer,
    override val onGranted: () -> Unit,
    override val onLoss: (isTransient: Boolean) -> Unit,
    override val onDenied: () -> Unit,
) : FocusManager() {
    override var context: AudioContextAndroid = player.context

    // Deprecated variant of listening to focus changes
    private var audioFocusChangeListener: AudioManager.OnAudioFocusChangeListener? = null

    init {
        updateAudioFocusRequest()
    }

    override fun hasAudioFocusRequest(): Boolean {
        return audioFocusChangeListener != null
    }

    override fun updateAudioFocusRequest() {
        audioFocusChangeListener = if (context.audioFocus == AudioManager.AUDIOFOCUS_NONE) {
            // Mix sound with others
            null
        } else {
            AudioManager.OnAudioFocusChangeListener { handleFocusResult(it) }
        }
    }

    override fun handleStop() {
        cancelPendingRetry()
        if (hasAudioFocusRequest()) {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(audioFocusChangeListener)
        }
    }

    override fun requestAudioFocus() {
        @Suppress("DEPRECATION")
        val result = audioManager.requestAudioFocus(
            audioFocusChangeListener,
            AudioManager.STREAM_MUSIC,
            context.audioFocus,
        )
        handleFocusResult(result)
    }
}

@RequiresApi(Build.VERSION_CODES.O)
private class ModernFocusManager(
    override val player: WrappedPlayer,
    override val onGranted: () -> Unit,
    override val onLoss: (isTransient: Boolean) -> Unit,
    override val onDenied: () -> Unit,
) : FocusManager() {
    override var context: AudioContextAndroid = player.context

    // Listen also for focus changes, e.g. if interrupt playing with a phone call and resume afterward.
    private var audioFocusRequest: AudioFocusRequest? = null

    init {
        updateAudioFocusRequest()
    }

    override fun hasAudioFocusRequest(): Boolean {
        return audioFocusRequest != null
    }

    override fun updateAudioFocusRequest() {
        audioFocusRequest = if (context.audioFocus == AudioManager.AUDIOFOCUS_NONE) {
            // Mix sound with others
            null
        } else {
            AudioFocusRequest.Builder(context.audioFocus).setAudioAttributes(context.buildAttributes())
                .setOnAudioFocusChangeListener { handleFocusResult(it) }.build()
        }
    }

    override fun handleStop() {
        cancelPendingRetry()
        if (hasAudioFocusRequest()) {
            audioFocusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        }
    }

    override fun requestAudioFocus() {
        val result = audioManager.requestAudioFocus(audioFocusRequest!!)
        handleFocusResult(result)
    }
}
