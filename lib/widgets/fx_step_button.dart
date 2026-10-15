/// 特效位置参数的 **−/+ 微调按钮**：点一下挪一格，按住不放连续挪。
///
/// ## 为什么要有它
/// 用户原话：「视觉特效的位置调整的精细度还不够，会跳过一些我想要放置的地方」。
/// 滑杆的档数已经按 `kFxPosStep` 提到 1000 档（0.1% 一格），但**手指在滑杆上
/// 一抖就是好几档** —— 颗粒度够了、可控性还是不够。所以位置那两行额外配一对按钮：
/// **手指拖个大概、按钮对准**。
///
/// ## 为什么不用 `IconButton`
/// `IconButton` **没有 `onLongPress`**，长按连发得自己起表 —— 那就等于自己写，
/// 不如把这个（唯一）需要长按的控件单独收成一个小而自洽的组件，
/// 定时器的生命周期只在这一个文件里，测试也只有一份。
///
/// ## 三条硬约束（谁改都得守住）
/// 1. 🔴 **`dispose()` 必须取消定时器**，回调里先判 `mounted` —— 不留僵尸定时器；
/// 2. **到边界停**：`value <= min`（或 `>= max`）时对应方向置灰，**连发中的表也要停**，
///    别让用户按住不放一直空转；
/// 3. **取整再 clamp**：长按累计会出 `0.30000000000000004` 这种脏值（滑杆 0.001
///    一档显示不出来、落盘也别扭），所以每挪一格都按 3 位小数取整。
library;

import 'dart:async';

import 'package:flutter/material.dart';

class FxStepButton extends StatefulWidget {
  const FxStepButton({
    super.key,
    required this.icon,
    required this.delta,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  /// 通常 [Icons.remove]（减）或 [Icons.add]（加）。
  final IconData icon;

  /// 一次挪多少：`+kFxPosStep` / `-kFxPosStep`。
  /// 步长由**调用方**传（本组件不认识 catalog，只认「一格」）。
  final double delta;

  /// 当前值（父层传；父层是唯一真相源，本组件不自己存值）。
  final double value;

  final double min;
  final double max;

  /// 收到的是**已经 clamp、并已按 3 位小数取整**的新值。
  final ValueChanged<double> onChanged;

  @override
  State<FxStepButton> createState() => _FxStepButtonState();
}

class _FxStepButtonState extends State<FxStepButton> {
  /// 长按连发的表。🔴 只有本文件管它的生死。
  Timer? _repeat;

  /// 触摸区 48×48 = **Material 的最小触摸目标**（`kMinInteractiveDimension`）。
  ///
  /// 🔴 **为什么必须是 48，不能缩到 36**（有具体失效路径，不是审美）：
  /// 这个控件在设置页里排成 `Row[按钮, Expanded(滑杆), 按钮]`，而**滑杆的命中区
  /// 就是整个 `Expanded` 框**。命中区只有 36 时，用户想点「+」却偏出去 4px
  /// （落在距行右缘 40px 处）就已经**出界**、落点变成滑杆最右端 ⇒
  /// `_getValueFromGlobalPosition` 把值直接夹到 **1.0**（左侧对称：夹到 0）。
  /// 对一个主打「精准摆放」的控件来说，「差一点点没点中就把特效甩到屏幕边上」
  /// 是最坏的失效模式 —— 48 之后那 4px 仍然落在按钮里。
  ///
  /// ⚠️ 放大命中区**不改变可见外观**：这一支没有底色、没有描边
  /// （`SizedBox → GestureDetector → Material(transparent) → InkWell → Icon(size: 18)`），
  /// 图标仍是 18、仍然居中；唯一区别是按下时墨迹圆圈大一圈（那是更好的反馈）。
  /// 有单测钉住 ★5（近失手）+ ★6（行高没被撑高）。
  static const double _kTouch = 48;

  /// 连发间隔（约 16 格/秒：够快，又不至于一格都点不准）。
  static const Duration _kRepeatEvery = Duration(milliseconds: 60);

  /// 这一方向还能不能走：到边界就置灰 + 停表。
  bool get _atLimit => widget.delta > 0
      ? widget.value >= widget.max
      : widget.value <= widget.min;

  /// 新值 = **先按 3 位小数取整，再 clamp**（见文件头第 3 条）。
  double _stepped() {
    final v = ((widget.value + widget.delta) * 1000).roundToDouble() / 1000;
    return v.clamp(widget.min, widget.max);
  }

  void _step() {
    if (_atLimit) return; // 置灰那条只是半个守卫，这里再挡一次
    widget.onChanged(_stepped());
  }

  void _startRepeat() {
    _stopRepeat();
    if (_atLimit) return;
    _repeat = Timer.periodic(_kRepeatEvery, (_) {
      if (!mounted) return; // 回调里先判 mounted
      if (_atLimit) {
        _stopRepeat(); // 到边界停表：别让用户按住不放一直空转
        return;
      }
      widget.onChanged(_stepped());
    });
  }

  void _stopRepeat() {
    _repeat?.cancel();
    _repeat = null;
  }

  @override
  void didUpdateWidget(FxStepButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 值被别人挪到边界（拖滑杆 / 另一颗按钮）⇒ 自己这张表也停掉。
    if (_atLimit) _stopRepeat();
  }

  @override
  void dispose() {
    _stopRepeat(); // 🔴 不留僵尸定时器
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = !_atLimit;
    // ⚠️ 长按必须挂在 **GestureDetector** 上：`InkWell`/`InkResponse` 只有
    // `onLongPress`，**没有** `onLongPressStart/End/Cancel`，而连发要靠
    // 「按下开始 / 松开结束」这一对事件。两颗识别器同场竞技时：
    // 快点 ⇒ 内层 InkWell 的 Tap 赢（点一下挪一格）；按住 500ms ⇒
    // 外层 LongPress 先宣告胜出，Tap 被拒 ⇒ **不会**再多挪一格。
    return SizedBox(
      width: _kTouch,
      height: _kTouch,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPressStart: on ? (_) => _startRepeat() : null,
        onLongPressEnd: on ? (_) => _stopRepeat() : null,
        onLongPressCancel: on ? _stopRepeat : null,
        child: Material(
          // 透明 Material 只为了给 InkWell 一个墨迹宿主（页面背景是玻璃面板）
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            // 圆角 = 触摸区的一半 ⇒ 正圆，与本页其它小控件（返回 / 删除 / 色卡圆点）同一套观感
            customBorder: const CircleBorder(),
            onTap: on ? _step : null,
            onTapUp: on ? (_) => _stopRepeat() : null,
            child: Center(
              child: Icon(
                widget.icon,
                size: 18,
                color: on ? Colors.white70 : Colors.white24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
