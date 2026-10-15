/// 系统省电模式监听：通过 EventChannel 接收原生推送的省电模式开关变化。
/// 省电模式下，全屏氛围层降帧绘制以省电。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class PowerMonitor {
  PowerMonitor._();

  static final PowerMonitor instance = PowerMonitor._();

  static const EventChannel _channel =
      EventChannel('com.mubox.mu_box_phone/power_save');

  /// 当前是否处于系统省电模式（Android「省电模式」/低电量模式）
  final ValueNotifier<bool> powerSaveMode = ValueNotifier(false);

  bool _listening = false;

  /// 启动监听（幂等）：常驻氛围层初始化时调用一次即可。
  void start() {
    if (_listening) return;
    _listening = true;
    _channel.receiveBroadcastStream().listen(
      (data) {
        if (data is bool) powerSaveMode.value = data;
      },
      onError: (Object e) {
        // 原生不支持/异常时保持 false，不降帧
      },
    );
  }
}
