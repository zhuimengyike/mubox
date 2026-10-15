package com.mubox.mubox

import android.app.KeyguardManager
import android.content.BroadcastReceiver
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.PowerManager
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import com.ryanheise.audioservice.AudioServiceActivity
import java.io.File

class MainActivity : AudioServiceActivity() {
    private val noisyChannel = "com.mubox.mu_box_phone/noisy"
    private val powerSaveChannel = "com.mubox.mu_box_phone/power_save"
    private val exportChannel = "com.mubox.mu_box_phone/export"
    private val galleryChannel = "com.mubox.mu_box_phone/gallery"
    private val deviceAuthChannel = "com.mubox.mu_box_phone/device_auth"
    private val equalizerChannel = "com.mubox.mu_box_phone/equalizer"
    private val extraEffectsChannel = "com.mubox.mu_box_phone/extra_effects"
    private val reqDeviceCred = 1001
    private var deviceAuthResult: MethodChannel.Result? = null
    private var becomingNoisyReceiver: BroadcastReceiver? = null
    private var powerSaveReceiver: BroadcastReceiver? = null
    private val spectrumEngine = SpectrumEngine()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // 真实频谱：EventChannel 由 Dart 端 listen/cancel 控制 Visualizer 启停
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "com.mubox.mu_box_phone/spectrum")
            .setStreamHandler(spectrumEngine.streamHandler)
        // 均衡器：把 Dart 侧的增益设置落到 android.media.audiofx.Equalizer
        // （attach 到自己播放器的 audio session，与频谱共用同一个 sessionId）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, equalizerChannel)
            .setMethodCallHandler(EqualizerEngine(applicationContext).methodHandler)
        // 音效增强：低音增强(BassBoost) + 响度增强(LoudnessEnhancer)，同样 attach 到
        // 自己播放器的 audio session；与 EQ 各自独立挂载，互不干扰
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, extraEffectsChannel)
            .setMethodCallHandler(ExtraEffectsEngine().methodHandler)
        // 省电模式：EventChannel 推送系统省电开关变化，Dart 层据此降帧省电
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, powerSaveChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                    val receiver = object : BroadcastReceiver() {
                        override fun onReceive(context: Context?, intent: Intent?) {
                            if (intent?.action == PowerManager.ACTION_POWER_SAVE_MODE_CHANGED) {
                                events.success(isPowerSaveMode())
                            }
                        }
                    }
                    powerSaveReceiver = receiver
                    ContextCompat.registerReceiver(
                        this@MainActivity,
                        receiver,
                        IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
                        ContextCompat.RECEIVER_EXPORTED,
                    )
                    // 立即回推一次当前状态，避免 Dart 侧等到下一次变化才知道
                    events.success(isPowerSaveMode())
                }

                override fun onCancel(arguments: Any?) {
                    powerSaveReceiver?.let { runCatching { unregisterReceiver(it) } }
                    powerSaveReceiver = null
                }
            })
        // 导出 App 内的歌曲到手机公共 Music/MuBox 目录（MediaStore 写入，Android 10+ 免运行时权限）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, exportChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "export" -> {
                        val src = call.argument<String>("src")
                        val name = call.argument<String>("name")
                        // report=true 时回 {"status": …, "uri": …}，让 Dart 侧能区分
                        // 「真写了 / 内容一致没重写 / 不存在」；不带此参数的老调用方仍拿到
                        // 纯 uri 字符串（逐个字节的向后兼容，别删这条分支）。
                        val report = call.argument<Boolean>("report") ?: false
                        try {
                            val r = exportToMusic(src, name)
                            val u = r?.uri?.toString()
                            if (u == null) {
                                result.success(null)
                            } else if (report) {
                                result.success(mapOf("status" to r.status, "uri" to u))
                            } else {
                                result.success(u)
                            }
                        } catch (e: Exception) {
                            result.error("EXPORT_FAILED", e.message, null)
                        }
                    }
                    // App 内备份（zip）写到**公共 Documents/MuBox/**，让用户在电脑上直接看得见
                    // （原来只落在 App 私有 cache，分享面板里只有「发给某个 App」，拿不出来）。
                    // 回包形状与 export 完全一致：出错码另用一个（SAVE_DOC_FAILED），
                    // 不带 report 时仍回纯 uri 字符串。
                    "saveToDocuments" -> {
                        val src = call.argument<String>("src")
                        val name = call.argument<String>("name")
                        val subDir = call.argument<String>("subdir")
                        val report = call.argument<Boolean>("report") ?: false
                        try {
                            val r = saveToDocuments(src, name, subDir)
                            val u = r?.uri?.toString()
                            if (u == null) {
                                result.success(null)
                            } else if (report) {
                                result.success(mapOf("status" to r.status, "uri" to u))
                            } else {
                                result.success(u)
                            }
                        } catch (e: Exception) {
                            result.error("SAVE_DOC_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 壁纸保存到系统相册（Pictures/MuBox，已有同名则跳过，返回已有 uri）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, galleryChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveImage" -> {
                        val src = call.argument<String>("src")
                        val name = call.argument<String>("name")
                        try {
                            result.success(saveImageToGallery(src, name)?.toString())
                        } catch (e: Exception) {
                            result.error("SAVE_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        // 监听有线/蓝牙耳机拔出广播，通知 Dart 层暂停播放，避免突然外放
        becomingNoisyReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, noisyChannel)
                        .invokeMethod("becomingNoisy", null)
                }
            }
        }
        registerReceiver(
            becomingNoisyReceiver,
            IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY)
        )
        // 私密区域：系统锁屏密码验证（不需要 FlutterFragmentActivity，避免与 audio_service 冲突）
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceAuthChannel)
            .setMethodCallHandler { call, result ->
                if (call.method == "authenticate") {
                    val km = getSystemService(Context.KEYGUARD_SERVICE) as KeyguardManager
                    if (!km.isDeviceSecure) {
                        // 未设置锁屏密码：无法验证
                        result.success(false)
                    } else {
                        try {
                            val intent = km.createConfirmDeviceCredentialIntent("验证身份", "进入私密区域")
                            if (intent != null) {
                                deviceAuthResult = result
                                startActivityForResult(intent, reqDeviceCred)
                            } else {
                                result.success(false)
                            }
                        } catch (e: Exception) {
                            result.error("AUTH_FAILED", e.message, null)
                        }
                    }
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == reqDeviceCred) {
            deviceAuthResult?.success(resultCode == RESULT_OK)
            deviceAuthResult = null
        }
    }

    private fun isPowerSaveMode(): Boolean {
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        return pm.isPowerSaveMode
    }

    /// 导出结果：uri = 公共 Music/MuBox 里的目标；status = "exported" / "unchanged"
    /// （源文件不存在时 exportToMusic 返回 null，与旧行为一致，不给 Dart 侧新状态）。
    private data class ExportResult(val uri: Uri, val status: String)

    /// 把 App 内部歌曲文件复制一份到共享 Music/MuBox 目录（MediaStore 插入，返回 content uri）。
    ///
    /// ⚠️ **同名 ≠ 同一份内容**：Music/MuBox 里已有同名条目时**先比对内容**（大小 + sha256），
    /// 逐字节一致才跳过（status="unchanged"）；只要内容不同就在**原 uri 上原地覆写**
    /// （`openOutputStream(uri, "rwt")`，rwt 的 t = 截断，见 ContentResolver#openOutputStream
    /// 与官方「访问共享存储空间中的媒体文件」页），不删条目、不换 uri。
    /// 旧实现「命中同名直接 return 旧 uri」会把老文件当成功导出报给用户（旧歌名/旧封面/旧码率
    /// 一直留在公共目录），这里不再允许出现那条路径。
    private fun exportToMusic(srcPath: String?, name: String?): ExportResult? {
        if (srcPath == null || name == null) return null
        val src = File(srcPath)
        if (!src.exists()) return null
        val existing = queryByName(name)
        if (existing != null && sameContent(src, existing)) {
            return ExportResult(existing, "unchanged")
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeOf(name))
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_MUSIC + "/MuBox")
            put(MediaStore.Audio.Media.IS_MUSIC, 1)
            put(MediaStore.MediaColumns.TITLE, name.substringBeforeLast('.'))
        }
        val collection = if (Build.VERSION.SDK_INT >= 29) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }
        val resolver = contentResolver
        // 目标已存在但内容不同 ⇒ 复用它的 uri 覆写；不存在 ⇒ 新建一条。
        // 覆写走 "rwt"（write + truncate）：只写不截断会把「变短的新文件」尾部留成旧数据。
        // ⚠️ 不用删除重插：那会产生新 uri，别的 App 存的引用会失效。
        // ⚠️ 不捕 RecoverableSecurityException：那个异常只在「动别的 App 创建的条目」时抛，
        //    这里的条目全部由本 App 自己 insert，正常路径上不会出现（真抛了会走 EXPORT_FAILED 报错）。
        val uri = existing ?: resolver.insert(collection, values) ?: return null
        val mode = if (existing != null) "rwt" else "w"
        try {
            resolver.openOutputStream(uri, mode)?.use { out -> src.inputStream().use { it.copyTo(out) } }
                ?: throw IllegalStateException("无法写入 $name")
            return ExportResult(uri, "exported")
        } catch (e: Exception) {
            // 只清掉本次新建的条目；覆写失败时旧文件仍在（宁可保留旧的也别删用户的文件）
            if (existing == null) runCatching { resolver.delete(uri, null, null) }
            throw e
        }
    }

    /// 查询 Music/MuBox 下是否已有同名文件，返回其 content uri；没有返回 null。
    private fun queryByName(name: String): Uri? {
        if (Build.VERSION.SDK_INT < 29) return null // 老机型没有 RELATIVE_PATH，查询不可靠
        val collection =
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val proj = arrayOf(MediaStore.Audio.Media._ID)
        val sel = "${MediaStore.Audio.Media.RELATIVE_PATH}=? AND ${MediaStore.Audio.Media.DISPLAY_NAME}=?"
        val args = arrayOf(Environment.DIRECTORY_MUSIC + "/MuBox/", name)
        contentResolver.query(collection, proj, sel, args, null)?.use { c ->
            if (c.moveToFirst()) {
                return ContentUris.withAppendedId(collection, c.getLong(0))
            }
        }
        return null
    }

    /// 公共目录里那个同名文件，是不是和 App 内源文件**逐字节同一份内容**。
    /// 只比大小是不够的（换码率/重下过的同名文件可能恰好等长），所以大小相同还要比 sha256。
    /// 任何一步读不出来（被占用/条目已失效/权限）一律返回 false ⇒ 走覆写，**绝不谎报「已导出」**。
    /// 大小都拿不到时返回 false（同样宁可多写一遍）。
    private fun sameContent(src: File, uri: Uri): Boolean = try {
        val resolver = contentResolver
        val size = resolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.SIZE),
            null,
            null,
            null
        )?.use { c -> if (c.moveToFirst()) c.getLong(0) else -1L } ?: -1L
        if (size < 0L || size != src.length()) {
            false
        } else {
            val a = resolver.openInputStream(uri)?.use { sha256Of(it) }
            a != null && a == src.inputStream().use { sha256Of(it) }
        }
    } catch (e: Exception) {
        false
    }

    private fun sha256Of(input: java.io.InputStream): String {
        val md = java.security.MessageDigest.getInstance("SHA-256")
        val buf = ByteArray(64 * 1024)
        while (true) {
            val n = input.read(buf)
            if (n < 0) break
            md.update(buf, 0, n)
        }
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun mimeOf(name: String): String = when (name.lowercase().substringAfterLast('.', "mp3")) {
        "flac" -> "audio/flac"
        "ogg", "oga", "opus" -> "audio/ogg"
        "wav" -> "audio/wav"
        "m4a", "aac" -> "audio/mp4"
        "wma" -> "audio/x-ms-wma"
        else -> "audio/mpeg"
    }

    // ------------------------------------------------------------------
    // 备份文件（zip 等）→ 公共 Documents/<子目录>/（默认 MuBox）
    //
    // 与「导出全部歌曲」是**两条独立的路**：目标目录不同、集合不同、MIME 也不同。
    // 刻意**不复用 exportToMusic**（那条有静态检查脚本 tool/check_export_no_reuse.py 逐行盯着，
    // 抽公共函数会把那个脚本的靶子搬走），所以这里是同策略的第二份实现：
    // 同名先比 size + sha256，一致才跳过，不一致原地覆写（"rwt" 截断）。
    // ------------------------------------------------------------------

    /// 把 App 私有目录里的一个**已存在的文件**（App 内备份 zip 等）写到公共
    /// `Documents/<子目录>/`（子目录默认 `MuBox`），让用户插数据线就能在电脑上看见。
    ///
    /// **为什么用 `MediaStore.Files` 而不是 `MediaStore.Audio` / `MediaStore.Downloads`：**
    /// * 官方 API 参考对 `MediaStore.Files` 的定义是「Media provider table containing an index of
    ///   all files in the media storage, **including non-media files**. This should be used by
    ///   applications that work with **non-media file types (text, HTML, PDF, etc)**」⇒ zip 正是
    ///   非媒体文件，这张表就是为它准备的；
    ///   `MediaStore.Audio` 是**音频表**，zip 进去会被当音频索引（也不该出现在音乐库里）。
    /// * `MediaStore.Downloads` 是 Download/ 那张表（`getContentUri(String)` 标注 Added in API 29），
    ///   这里的目标目录是 `Documents/` 而不是 `Download/`，且它在 API 29 以下不存在。
    /// * `MediaStore.Files.getContentUri(String)` 是 API 11 就有的；`RELATIVE_PATH`（API 29+）
    ///   使 Android 10+ 写自己的条目**免存储权限**（与 exportToMusic 同一套写法）。
    /// * 官方「访问共享存储空间中的媒体文件」页也明确：把**通用/非媒体文件**放进 `Documents/`
    ///   或 `Download/` 是可行的（它只是更推荐 SAF）—— 这里走 MediaStore 是为了「写完就在文件
    ///   管理器/电脑上看得见」，SAF 需要用户先手动选目录。
    ///
    /// ⚠️ **同名 ≠ 同一份内容**（与 `exportToMusic` 逐条同策略）：命中同名条目先比
    /// 大小 + sha256，**逐字节一致才跳过**（status="unchanged"）；内容不同就在**原 uri 上原地覆写**
    /// （`openOutputStream(uri, "rwt")`，rwt 的 t = 截断，见 ContentResolver#openOutputStream），
    /// 不删条目、不换 uri；失败**只删本次新建**的条目。
    ///
    /// 源文件不存在 ⇒ 返回 null（与 exportToMusic 同语义，调用方回 null）。
    private fun saveToDocuments(srcPath: String?, name: String?, subDir: String?): ExportResult? {
        if (srcPath == null || name == null) return null
        val src = File(srcPath)
        if (!src.exists()) return null
        val safeName = safeDocName(name) ?: return null
        val relDir = docRelativeDir(subDir)
        val existing = queryDocByName(safeName, relDir)
        if (existing != null && sameContent(src, existing)) {
            return ExportResult(existing, "unchanged")
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, safeName)
            put(MediaStore.MediaColumns.MIME_TYPE, docMimeOf(safeName))
            put(MediaStore.MediaColumns.RELATIVE_PATH, relDir)
            // ⚠️ 刻意**不写 `TITLE`**（exportToMusic 给歌写了）：`title` 这一列在 `files` 表里
            //    存不存在**本机未验证**（拿不到 AOSP MediaProvider 的建表语句，android.jar 只有
            //    stub），写进去万一不被认就是 IllegalArgumentException ⇒ 整条路失败；
            //    而 zip 的 title 不影响电脑上看到的名字（那是 DISPLAY_NAME）。
            //    官方「Add an item」样例对这张表也只写 DISPLAY_NAME / MIME_TYPE / RELATIVE_PATH。
            //    同理**不写 `IS_PENDING`**（官方样例有、exportToMusic 没有）—— 那条路要与导出一致。
        }
        val collection = if (Build.VERSION.SDK_INT >= 29) {
            MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            // ⚠️ `MediaStore.Files` **没有** EXTERNAL_CONTENT_URI 这个常量（javap 实测 + 官方参考页
            //    里搜不到；kotlinc 对 android-37.0/android.jar 报 unresolved reference），
            //    所以老机型这一支用等价的 getContentUri("external")（API 11 起就有）。
            // 与 exportToMusic 同形：老机型没有 RELATIVE_PATH，查不出同名条目（见 queryDocByName），
            // 只会走新建那一支（且需要 WRITE_EXTERNAL_STORAGE，清单里 maxSdkVersion=28 已声明）。
            // ⚠️ API 24~28 这条路**本机未验证**（目标机是 Android 15+），与 exportToMusic 一样是空的。
            MediaStore.Files.getContentUri("external")
        }
        val resolver = contentResolver
        // 目标已存在但内容不同 ⇒ 复用它的 uri 覆写；不存在 ⇒ 新建一条。
        // ⚠️ 不用删除重插：那会产生新 uri，别的 App 存的引用会失效。
        val uri = existing ?: resolver.insert(collection, values) ?: return null
        val mode = if (existing != null) "rwt" else "w"
        try {
            resolver.openOutputStream(uri, mode)?.use { out -> src.inputStream().use { it.copyTo(out) } }
                ?: throw IllegalStateException("无法写入 $safeName")
            return ExportResult(uri, "exported")
        } catch (e: Exception) {
            // 只清掉本次新建的条目；覆写失败时旧文件仍在（宁可保留旧的也别删用户的文件）
            if (existing == null) runCatching { resolver.delete(uri, null, null) }
            throw e
        }
    }

    /// 查询公共 `Documents/<子目录>/` 下是否已有同名文件，返回其 content uri；没有返回 null。
    /// 与 `queryByName` 同形，只是换成 `MediaStore.Files` 表（非媒体文件）+ Documents 路径。
    private fun queryDocByName(name: String, relDir: String): Uri? {
        if (Build.VERSION.SDK_INT < 29) return null // 老机型没有 RELATIVE_PATH，查询不可靠
        val collection = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val proj = arrayOf(MediaStore.Files.FileColumns._ID)
        val sel = "${MediaStore.Files.FileColumns.RELATIVE_PATH}=? AND " +
            "${MediaStore.Files.FileColumns.DISPLAY_NAME}=?"
        // MediaStore 存的 RELATIVE_PATH 带末尾斜杠（与 exportToMusic 的 "Music/MuBox/" 同一个写法）
        val args = arrayOf("$relDir/", name)
        contentResolver.query(collection, proj, sel, args, null)?.use { c ->
            if (c.moveToFirst()) {
                return ContentUris.withAppendedId(collection, c.getLong(0))
            }
        }
        return null
    }

    /// 子目录归一化：只保留安全的路径片段，`..` / `.` / 空段一律丢掉；全空 ⇒ 回落 `MuBox`。
    /// ⛔ 不许让 `..` 跑进 RELATIVE_PATH（那会写到自己该管的目录之外）。
    private fun safeSubDir(subDir: String?): String {
        val parts = (subDir ?: "").replace('\\', '/').split('/')
            .map { it.trim() }
            .filter { it.isNotEmpty() && it != "." && it != ".." && !it.contains(':') }
        return if (parts.isEmpty()) "MuBox" else parts.joinToString("/")
    }

    /// 子目录的完整 RELATIVE_PATH（写入用；查询时另加末尾斜杠）。
    private fun docRelativeDir(subDir: String?): String =
        Environment.DIRECTORY_DOCUMENTS + "/" + safeSubDir(subDir)

    /// 目标文件名归一化：DISPLAY_NAME 只能是**单个**路径片段 ⇒ 取最后一段；
    /// 空 / `.` / `..` 一律判非法（返回 null，调用方原样回 null）。
    private fun safeDocName(name: String): String? {
        val base = name.replace('\\', '/').substringAfterLast('/').trim()
        return if (base.isEmpty() || base == "." || base == "..") null else base
    }

    /// 公共 Documents 里那些文件的 MIME —— **由文件名后缀推**。
    /// ⚠️ zip 必须是 `application/zip`：⛔ 不能落到 `mimeOf`（那是音频表，未知后缀回 audio/mpeg）
    /// 去 —— 把备份 zip 标成音频会让系统/文件管理器拿它当歌。
    /// 后缀不认识一律 `application/octet-stream`（不猜）。
    private fun docMimeOf(name: String): String = when (name.lowercase().substringAfterLast('.', "")) {
        "zip" -> "application/zip"
        "json" -> "application/json"
        "txt", "lrc", "log", "md" -> "text/plain"
        "pdf" -> "application/pdf"
        "mp3" -> "audio/mpeg"
        "flac" -> "audio/flac"
        "m4a", "aac" -> "audio/mp4"
        "ogg", "oga", "opus" -> "audio/ogg"
        "wav" -> "audio/wav"
        "jpg", "jpeg" -> "image/jpeg"
        "png" -> "image/png"
        "webp" -> "image/webp"
        else -> "application/octet-stream"
    }

    /// 把 App 内壁纸保存到系统相册 Pictures/MuBox；相册已有同名则跳过（返回已有 uri）。
    /// ⚠️ **本条仍是「同名即复用」的老毛病**（和 exportToMusic 修掉的那条一模一样）：
    /// 换了壁纸但文件名不变时，相册里那张旧图不会被刷新。**已知限制，此处故意不动**
    /// （改法与 exportToMusic 相同：内容不一致就原地覆写）。
    private fun saveImageToGallery(srcPath: String?, name: String?): Uri? {
        if (srcPath == null || name == null) return null
        // 相册已有同名图片：跳过，返回已有 uri（不重复保存）
        galleryQueryByName(name)?.let { return it }
        val src = File(srcPath)
        if (!src.exists()) return null
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, name)
            put(MediaStore.MediaColumns.MIME_TYPE, imageMimeOf(name))
            put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_PICTURES + "/MuBox")
            put(MediaStore.MediaColumns.TITLE, name.substringBeforeLast('.'))
        }
        val collection = if (Build.VERSION.SDK_INT >= 29) {
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val resolver = contentResolver
        var uri = resolver.insert(collection, values) ?: return null
        try {
            resolver.openOutputStream(uri)?.use { out -> src.inputStream().use { it.copyTo(out) } }
                ?: throw IllegalStateException("无法写入 $name")
            return uri
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }

    /// 查询相册 Pictures/MuBox 下是否已有同名图片，返回其 content uri；没有返回 null。
    private fun galleryQueryByName(name: String): Uri? {
        if (Build.VERSION.SDK_INT < 29) return null
        val collection =
            MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val proj = arrayOf(MediaStore.Images.Media._ID)
        val sel = "${MediaStore.Images.Media.RELATIVE_PATH}=? AND ${MediaStore.Images.Media.DISPLAY_NAME}=?"
        val args = arrayOf(Environment.DIRECTORY_PICTURES + "/MuBox/", name)
        contentResolver.query(collection, proj, sel, args, null)?.use { c ->
            if (c.moveToFirst()) {
                return ContentUris.withAppendedId(collection, c.getLong(0))
            }
        }
        return null
    }

    private fun imageMimeOf(name: String): String = when (name.lowercase().substringAfterLast('.', "jpg")) {
        "png" -> "image/png"
        "webp" -> "image/webp"
        "gif" -> "image/gif"
        "bmp" -> "image/bmp"
        "heic", "heif" -> "image/heic"
        else -> "image/jpeg"
    }

    override fun onDestroy() {
        becomingNoisyReceiver?.let { runCatching { unregisterReceiver(it) } }
        becomingNoisyReceiver = null
        powerSaveReceiver?.let { runCatching { unregisterReceiver(it) } }
        powerSaveReceiver = null
        super.onDestroy()
    }
}
