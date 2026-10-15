/// 「滑到底之后继续上滑 ⇒ 翻到下一行」的判定（纯逻辑，零 Flutter 依赖）。
///
/// ## 语义（旧版是「累积 overscroll > 50 就翻」）
///
/// **一次滑动只干一件事**：
/// * 手指按下时**内容已经在底部** ⇒ 这一次滑动可以翻页（仍要越过 [kRowTurnThreshold]，
///   免得轻点/手抖就翻）。
/// * 手指按下时**不在底部** ⇒ 这一次滑动**只负责滚到底**，无论拖多远都**不翻页**；
///   要翻必须松手、**再滑一次**。
///
/// 旧判定（累积溢出 > 50px 就翻）会在「往下滚、刚滚到底、手指还没抬、
/// 继续多拖了 50px」时误翻页 —— 设置页往下滚就跳到「自定义特效」页。
///
/// ⚠️ 手势**中途**才到底 ⇒ **不算**「已在底部」（否则又回到误翻）：只看
/// **拖拽开始时**那一刻的 `pixels / maxScrollExtent`，一次手势只认一次，中途不改。
///
/// ⚠️ 内容**装得下**（`maxScrollExtent == 0`）时本判定**根本不参与**：那时
/// `ScrollPhysics.shouldAcceptUserOffset` 为假 ⇒ Flutter 连拖拽识别器都不注册
/// （`scrollable.dart:775-785`）⇒ 手势原样落给外层 `PageView`，直接翻页，观感
/// **逐像素不变**。有单测钉住 ★2 / ★5。
///
/// 为什么单独一个文件：这条手势原先只长在设置页里（`settings_page.dart` 的
/// `_handleScroll`），歌单页与壁纸页的列表又被锁成 `NeverScrollableScrollPhysics`（一屏装
/// 不下时下面的行永远滑不出来），解锁滚动就必须把「上滑去下行」接回来 ——
/// 三处必须是**同一套**判定，所以抽成纯类 + 单测；收手势的 Flutter 那一半在
/// `widgets/row_turn_scroll.dart`（三个页面都用它，不再各写一份）。
///
/// 本文件**不许 import Flutter / 任何插件**，否则又变成只能靠 widget 测。
library;

/// 触发阈值（像素）：**已经在底部**的那一次滑动，还要再上滑多少才翻页。
///
/// **故意保持 50 不变**（不改手感）：旧版同样是「溢出 > 50 才翻」，所以「已经在底」
/// 这条路径的手指行程（≈ 50 + 拖拽 slop ≈ 70px）与改动前**逐像素相同**；
/// 改小会让「到底之后顺手再带一下」又变成误翻，改大会让已经到底的用户觉得滑了没反应。
const double kRowTurnThreshold = 50;

/// 「拖拽开始时内容已经在底部」的容差（逻辑像素）。
///
/// 半个像素在屏幕上不可分辨；不留容差会出现「明明已经滑到底了，却因为 `pixels` 差
/// 零点几像素被判成没到底 ⇒ 这一次滑动白滑」—— 那对用户就是个复现不了的怪 bug。
const double kRowTurnBottomEpsilon = 0.5;

/// 「一次滑动 = 一个动作」的状态机。
class RowTurnGesture {
  RowTurnGesture({this.threshold = kRowTurnThreshold});

  /// 触发阈值（像素）。
  final double threshold;

  bool _startedAtBottom = false;
  double _overscroll = 0;
  bool _turning = false;

  /// 当前累积量（测试与日志用，判定不读它）。
  double get accumulated => _overscroll;

  /// 是否已经表过态、还没等到这次手势结束（防重入）。
  bool get turning => _turning;

  /// 这一次手势**开始时**内容是否已经在底部（= 有没有资格翻页）。
  /// 仅测试读它，判定本身不看这个 getter。
  bool get startedAtBottom => _startedAtBottom;

  /// 一次**用户拖拽**的开始（来自带 `dragDetails` 的 `ScrollStartNotification`）。
  ///
  /// [pixels] / [maxScrollExtent] 取那一刻的 `ScrollNotification.metrics` ——
  /// 实测这一条通知发出时位置**还没被本次拖拽改过**（`test/row_turn_scroll_test.dart`
  /// 的 ★6/★7 依赖这一点：底部拖 120px 时它给的是 `pixels == max`）。
  ///
  /// ⚠️ 只有带 `dragDetails` 的那条才算手势开始：**程序滚动**（`jumpTo`/`animateTo`，走
  /// `DrivenScrollActivity`）也会发 `ScrollStartNotification`，但 `dragDetails` 是 null
  /// —— 实测（3.44.4）`jumpTo` 发的那三条全是 `drag=false`，真拖拽那条才是 `drag=true`。
  /// 拿程序滚动当手势开始，等于把「代码把列表跳到最底」当成「用户这一次滑动开始时已经在底」，
  /// 之后随便一次溢出（程序动画越界 / 别处的手势）都会白捡一次翻页。
  /// 源码依据：`scroll_activity.dart:484-492`（`DragScrollActivity` 才往通知里塞 dragDetails）。
  void onDragStart({required double pixels, required double maxScrollExtent}) {
    // 装得下（max == 0）时不算「已在底」：那种列表压根不接拖拽，
    // 这一条只是把「本判定不参与」写死，免得将来 physics 变了被静默带进来。
    _startedAtBottom =
        maxScrollExtent > 0 && pixels >= maxScrollExtent - kRowTurnBottomEpsilon;
    _overscroll = 0;
    _turning = false;
  }

  /// 一条越界通知：返回 true = 该翻页了。
  ///
  /// [overscroll] 取 `OverscrollNotification.overscroll`（溢出量，触底继续上滑为正）。
  bool onOverscroll(double overscroll) {
    // ★ 核心：手势开始时不在底 ⇒ 这一次滑动只负责滚到底，拖多远都不翻。
    if (!_startedAtBottom) return false;
    if (overscroll <= 0) return false;
    _overscroll += overscroll;
    if (_overscroll > threshold && !_turning) {
      _turning = true;
      return true;
    }
    return false;
  }

  /// 一条正常滚动通知：**没到底就复位累计**（往回滚一点就误翻页是最容易踩的坑）。
  ///
  /// ⚠️ 它**只清累计，不动** [startedAtBottom]：一次手势开始时的位置已经定死了
  /// 「有没有资格翻页」，中途滚到哪都不改变这个结论 —— 否则「中途才到底」又会溜回来。
  void onScrollUpdate({
    required double pixels,
    required double maxScrollExtent,
  }) {
    if (pixels < maxScrollExtent) _overscroll = 0;
  }

  /// 一次手势结束：全部复位（下一次手势从零开始）。
  ///
  /// ⚠️ `ScrollEndNotification` 理论上可能不来（页面在手势中途被销毁/换行）；
  /// 那也不影响正确性 —— [onDragStart] 在每次拖拽开始时**整体重算**所有状态，
  /// 残留状态不可能跨手势存活成一次误翻。
  void onScrollEnd() {
    _startedAtBottom = false;
    _overscroll = 0;
    _turning = false;
  }
}
