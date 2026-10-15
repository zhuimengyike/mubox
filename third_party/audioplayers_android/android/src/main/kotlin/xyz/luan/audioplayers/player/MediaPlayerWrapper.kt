package xyz.luan.audioplayers.player

import android.media.MediaPlayer
import android.os.Build
import android.os.PowerManager
import xyz.luan.audioplayers.AudioContextAndroid
import xyz.luan.audioplayers.AudioSessionProvider
import xyz.luan.audioplayers.source.Source

class MediaPlayerWrapper(
    private val wrappedPlayer: WrappedPlayer,
) : PlayerWrapper {
    private val mediaPlayer = createMediaPlayer(wrappedPlayer)

    private fun createMediaPlayer(wrappedPlayer: WrappedPlayer): MediaPlayer {
        val mediaPlayer = MediaPlayer().apply {
            setOnPreparedListener {
                // prepare 完成后 audioSessionId 才稳定有效，此时登记供频谱/EQ/音效引擎按身份查询。
                // （MediaPlayer 刚构造、未 setDataSource 时 getAudioSessionId 返回 0，
                //  会让 Visualizer(0) 在 Android 12+ 抛 ERROR_INVALID_OPERATION(-3)。）
                AudioSessionProvider.put(wrappedPlayer.playerId, mediaPlayer.audioSessionId)
                wrappedPlayer.onPrepared()
            }
            setOnCompletionListener { wrappedPlayer.onCompletion() }
            setOnSeekCompleteListener { wrappedPlayer.onSeekComplete() }
            setOnErrorListener { _, what, extra -> wrappedPlayer.onError(what, extra) }
            setOnBufferingUpdateListener { _, percent -> wrappedPlayer.onBuffering(percent) }
        }
        wrappedPlayer.context.setAttributesOnPlayer(mediaPlayer)
        return mediaPlayer
    }

    override fun getDuration(): Int? {
        // media player returns -1 if the duration is unknown
        return mediaPlayer.duration.takeUnless { it == -1 }
    }

    override fun getCurrentPosition(): Int {
        return mediaPlayer.currentPosition
    }

    override fun getAudioSessionId(): Int = mediaPlayer.audioSessionId

    override fun setVolume(leftVolume: Float, rightVolume: Float) {
        mediaPlayer.setVolume(leftVolume, rightVolume)
    }

    override fun setRate(rate: Float) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            mediaPlayer.playbackParams = mediaPlayer.playbackParams.setSpeed(rate)
        } else if (rate == 1.0f) {
            mediaPlayer.start()
        } else {
            error("Changing the playback rate is only available for Android M/23+ or using LOW_LATENCY mode.")
        }
    }

    override fun setSource(source: Source) {
        reset()
        source.setForMediaPlayer(mediaPlayer)
        // setDataSource 之后 audioSessionId 已生效（不再是 0），尽早按**本播放器的身份**登记；
        // onPrepared 会再兜底一次。登记带身份 ⇒ 双播放器下互不抢（谁最后写都不影响别人查询）。
        AudioSessionProvider.put(wrappedPlayer.playerId, mediaPlayer.audioSessionId)
    }

    override fun setLooping(looping: Boolean) {
        mediaPlayer.isLooping = looping
    }

    override fun start() {
        // Setting playback rate instead of mediaPlayer.start().
        setRate(wrappedPlayer.rate)
    }

    override fun pause() {
        mediaPlayer.pause()
    }

    override fun stop() {
        mediaPlayer.stop()
    }

    override fun release() {
        mediaPlayer.reset()
        mediaPlayer.release()
        // MediaPlayer 没了 ⇒ 它那个 session 也死了：按身份的登记必须撤掉
        // （否则引擎会拿着一个死 session 去 attach，静默失败、还查不出原因）
        AudioSessionProvider.forget(wrappedPlayer.playerId)
    }

    override fun seekTo(position: Int) {
        mediaPlayer.seekTo(position)
    }

    override fun updateContext(context: AudioContextAndroid) {
        context.setAttributesOnPlayer(mediaPlayer)
        if (context.stayAwake) {
            mediaPlayer.setWakeMode(wrappedPlayer.applicationContext, PowerManager.PARTIAL_WAKE_LOCK)
        }
    }

    override fun prepare() {
        mediaPlayer.prepareAsync()
    }

    override fun reset() {
        mediaPlayer.reset()
    }

    override fun isLiveStream(): Boolean {
        val duration = getDuration()
        return duration == null || duration == 0
    }
}
