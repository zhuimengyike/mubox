/// 私密区域验证：调用系统**锁屏密码**（KeyguardManager）。
/// 不依赖 local_auth（它要求 FlutterFragmentActivity，与 audio_service 的基类冲突会黑屏）。
/// 用的是设备已设置的锁屏密码，App 不保存任何密码；未设置锁屏密码时返回 false。
library;

import 'package:flutter/services.dart';

class PrivateAuth {
  PrivateAuth._();

  static const MethodChannel _ch =
      MethodChannel('com.mubox.mu_box_phone/device_auth');

  /// 弹系统锁屏密码验证。成功 true；取消/失败/未设置密码 false。
  static Future<bool> authenticate() async {
    try {
      final ok = await _ch.invokeMethod<bool>('authenticate');
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }
}
