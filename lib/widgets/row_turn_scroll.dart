/// 「列表解锁滚动之后，上滑去下行那条手势仍然在」的**接线层**（三处共用）。
///
/// 它只做两件事：把滚动通知喂给纯逻辑 [RowTurnGesture]，以及判定说「该翻了」时
/// 找**外层垂直 `PageView`** 翻到下一页。判定一个字都不在这里 —— 那在
/// `lib/row_turn.dart`（歌单页 / 壁纸页 / 设置页**同一套**，⛔ 别各写一份）。
///
/// ## 判定语义
/// **一次滑动只干一件事**：手指按下时**已经在底部** ⇒ 这一次滑动才可能翻页；
/// **不在底部** ⇒ 这一次滑动只负责滚到底，拖多远都不翻，要翻得**再滑一次**。
/// 旧判定是「累积溢出 > [kRowTurnThreshold] 就翻」，于是「滚到底之后手指还没抬、
/// 又拖了 50px」会误翻页（设置页往下滚就跳到「自定义特效」页）。
///
/// 为什么要它：歌单页 / 壁纸页的列表原先写死 `NeverScrollableScrollPhysics`，
/// 一屏装不下时下面的行永远滑不出来（视口静默裁掉）。解锁滚动之后，内层滚动会吃掉
/// 垂直手势（Flutter 的手势竞技场里更深的 Scrollable 必胜），所以要把
/// 「滑到底之后再上滑 → 翻页」这条导航接回来。⚠️ 内容**装得下**时不用这条：那时
/// `ScrollPhysics.shouldAcceptUserOffset` 为假 ⇒ Flutter 连拖拽识别器都不注册
/// （`scrollable.dart:775-785`）⇒ 手势原样落给外层 `PageView`，观感**逐像素不变**。
library;

import 'package:flutter/material.dart';

import '../row_turn.dart';

/// 把 [child]（一棵**可滚动**的子树）包起来，接上「触底继续上滑 → 翻到下一行」。
///
/// 用法（physics 由调用方给）：
/// ```dart
/// RowTurnScroll(child: ListView(physics: const ClampingScrollPhysics(), …))
/// ```
/// ⚠️ physics 必须显式给 `ClampingScrollPhysics`：iOS/macOS 的默认物理是
/// `BouncingScrollPhysics`，它**不发** `OverscrollNotification`（越界靠自身弹簧回弹），
/// 这条判定在上面永远不触发。显式 Clamping 也让本机跑测试与真机一致。
class RowTurnScroll extends StatefulWidget {
  const RowTurnScroll({super.key, required this.child});

  final Widget child;

  @override
  State<RowTurnScroll> createState() => _RowTurnScrollState();
}

class _RowTurnScrollState extends State<RowTurnScroll> {
  final RowTurnGesture _gesture = RowTurnGesture();

  bool _handleScroll(ScrollNotification n) {
    if (n is ScrollStartNotification) {
      // ★ 手势开始：**只有带 dragDetails 的那条才算用户拖拽**。程序滚动
      // （jumpTo / animateTo，走 DrivenScrollActivity）也会发 ScrollStartNotification，
      // 但 dragDetails 是 null（实测：jumpTo 那三条全 drag=false，真拖拽是 drag=true）
      // —— 拿程序滚动当手势开始 = 把「代码跳到最底」误当成「用户这一次滑动开始时已在底」。
      if (n.dragDetails != null) {
        _gesture.onDragStart(
          pixels: n.metrics.pixels,
          maxScrollExtent: n.metrics.maxScrollExtent,
        );
      }
    } else if (n is OverscrollNotification) {
      if (_gesture.onOverscroll(n.overscroll)) _turnToNextRow();
    } else if (n is ScrollUpdateNotification) {
      // 未到底的正常滚动：复位累计，避免中间往回滚一点就误翻页
      _gesture.onScrollUpdate(
        pixels: n.metrics.pixels,
        maxScrollExtent: n.metrics.maxScrollExtent,
      );
    } else if (n is ScrollEndNotification) {
      _gesture.onScrollEnd();
    }
    return false; // 不拦截：通知继续往上走
  }

  /// 找到外层垂直 `PageView`，翻到下一页（= 下行）。
  ///
  /// 从当前 context 往上找**第一个**垂直 `PageView`。找不到（例如独立挂载、
  /// 没有外层翻页 —— `settings_page_battery_test.dart` 就是这么挂的）就什么都不做：
  /// 不许抛，也不许猜别的手势。
  void _turnToNextRow() {
    PageView? pageView;
    context.visitAncestorElements((el) {
      final w = el.widget;
      if (w is PageView && w.scrollDirection == Axis.vertical) {
        pageView = w;
        return false; // 找到即停
      }
      return true;
    });
    pageView?.controller?.nextPage(
      // 与设置页既有写法一致（观感/时长不许变）
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _handleScroll,
      child: widget.child,
    );
  }
}
