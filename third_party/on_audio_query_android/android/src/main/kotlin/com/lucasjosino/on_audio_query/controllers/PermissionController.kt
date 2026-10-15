package com.lucasjosino.on_audio_query.controllers

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import com.lucasjosino.on_audio_query.PluginProvider
import com.lucasjosino.on_audio_query.interfaces.PermissionManagerInterface
import io.flutter.Log
import io.flutter.plugin.common.PluginRegistry

class PermissionController : PermissionManagerInterface,
    PluginRegistry.RequestPermissionsResultListener {

    companion object {
        private const val TAG: String = "PermissionController"

        private const val REQUEST_CODE: Int = 88560
    }

    var retryRequest: Boolean = false

    // 本地补丁：只检查音频权限（Mu Box 只读音乐，不需要图片/存储写权限），
    // 否则 Android 13+ 上会因 READ_MEDIA_IMAGES 未授予而误判为无权限。
    private var permissions: Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(
                Manifest.permission.READ_MEDIA_AUDIO
            )
        } else {
            arrayOf(
                Manifest.permission.READ_EXTERNAL_STORAGE
            )
        }

    override fun permissionStatus(): Boolean = permissions.all {
        // After "leaving" this class, context will be null so, we need this context argument to
        // call the [checkSelfPermission].
        return ContextCompat.checkSelfPermission(
            PluginProvider.context(),
            it
        ) == PackageManager.PERMISSION_GRANTED
    }

    override fun requestPermission() {
        Log.d(TAG, "Requesting permissions.")
        Log.d(TAG, "SDK: ${Build.VERSION.SDK_INT}, Should retry request: $retryRequest")
        val activity = PluginProvider.activity()
        ActivityCompat.requestPermissions(activity, permissions, REQUEST_CODE)
    }

    // Second requestPermission, this one with the option "Never Ask Again".
    override fun retryRequestPermission() {
        val activity = PluginProvider.activity()
        // 本地补丁：原版写死读 permissions[0] 和 permissions[1]，但本 fork 的权限数组
        // 已被削到只剩 1 个元素（见上面 `permissions` 的定义）——
        // 一旦有人传 retryRequest=true 走进这里，permissions[1] 会抛
        // ArrayIndexOutOfBoundsException（`||` 短路：只有 permissions[0] 的 rationale
        // 为 false 时才求值右边）。改成遍历数组，将来加减权限都不会再越界。
        val shouldShowRationale = permissions.any {
            ActivityCompat.shouldShowRequestPermissionRationale(activity, it)
        }
        if (shouldShowRationale) {
            Log.d(TAG, "Retrying permission request")
            retryRequest = false
            requestPermission()
        } else {
            // 本地补丁：走到这里说明用户已经选了「不再询问」，系统不会再弹框，重试没有意义。
            // 原版此时**既不 success 也不 error** —— Dart 侧 `await permissionsRequest()`
            // 会**永久挂起**（已在设备上确认）：曲库停在「扫描中」转圈，之后再也不会请求权限。
            // 显式回 false，Dart 侧据此进「权限被拒」分支，界面才会给出重新授权入口。
            Log.d(TAG, "Cannot retry: rationale is false (Never Ask Again)")
            PluginProvider.result().success(false)
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ): Boolean {
        // When the incoming request code doesn't match the request codes defined by the on_audio_query
        // plugin return [false] to indicate the [on_audio_query] plugin is not handling the request
        // result and Android should continue executing other registered handlers.
        if (REQUEST_CODE != requestCode) return false

        // Check permission
        val isPermissionGranted = (grantResults.isNotEmpty()
                && grantResults[0] == PackageManager.PERMISSION_GRANTED)

        Log.d(TAG, "Permission accepted: $isPermissionGranted")

        // After all checks, we can handle the permission request.
        val result = PluginProvider.result()
        when {
            isPermissionGranted -> result.success(true)
            retryRequest -> retryRequestPermission()
            else -> result.success(false)
        }

        // Return [true] here to indicate that the [on_audio_query] plugin handled the permission request
        // result and Android should not continue executing other registered handlers.
        return true
    }
}