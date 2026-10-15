/// 播放队列浮层「打开时把当前曲滚进视口」的判定 —— **纯函数，零 Flutter 依赖**。
///
/// ## 为什么单独一个文件
/// 队列列表是 lazy 的 `ListView.builder`（`lib/widgets/player_bar.dart` 的
/// `_buildQueuePanel`）。「当前曲在不在视口里 / 该滚到第几像素」这件事：
///
/// * 真机上只能靠眼睛看，量不出数字；
/// * 而它又必须**可判**（症状：打开浮层看不到当前曲）。
///
/// 所以判定压成这个纯函数，用穷举单测钉住；
/// 控件那一侧的几何约束由拿真 `PlayerBar` + 真 `ListView` 的测试守着
/// （读 `ScrollPosition.pixels` 与行的实际矩形）。
library;

/// 队列浮层打开时该把列表滚到的像素位置；**返回 null = 一个像素都不许动**。
///
/// 四种情况返回 null：
/// 1. `index` 越界（当前曲不在队列里 —— 比如历史和队列不同步）；
/// 2. `itemCount <= 0`，或 `rowExtent` / `viewportExtent` 不是正有限数
///    （拿不到几何，宁可不滚，也不许糊一个位置出来）；
/// 3. `maxScrollExtent <= 0`：整个队列装得下，滚也滚不动；
/// 4. ★ **当前曲已经完整落在视口里** —— 刻意不动。
///    理由：打开浮层就先跳一下会让用户**失去方向感**（他刚滚到某处、一开一关就跑了）。
///    只有当用户**真的看不到**当前曲时，跳这一下才是净收益。
///    这条是**产品语义选择**，不是几何必然；代码里没有更强的既有约定，所以按用户的倾向定。
///
/// 否则返回「把当前曲那一行的**上边缘**顶到视口顶部」的位置，并夹进 `[0, maxScrollExtent]`。
///
/// 顶对齐（而不是居中）是有意的：队列末尾那几首**居中做不到**（会被夹到 `maxScrollExtent`），
/// 观感上变成「停在底部」；统一顶对齐可预测，也和「滚动条刚露头」的手感一致。
///
/// [currentOffset] 允许越界（回弹动画中途读到的值可能超出范围），内部会先夹一次。
double? queueScrollTarget({
  required int index,
  required int itemCount,
  required double rowExtent,
  required double viewportExtent,
  required double currentOffset,
  required double maxScrollExtent,
}) {
  if (itemCount <= 0) return null;
  if (index < 0 || index >= itemCount) return null;
  if (!rowExtent.isFinite || rowExtent <= 0) return null;
  if (!viewportExtent.isFinite || viewportExtent <= 0) return null;

  final double maxOffset =
      (maxScrollExtent.isFinite && maxScrollExtent > 0) ? maxScrollExtent : 0;
  if (maxOffset <= 0) return null;

  final double top = index * rowExtent;
  final double bottom = top + rowExtent;
  final double viewTop = currentOffset.isFinite
      ? currentOffset.clamp(0.0, maxOffset).toDouble()
      : 0.0;
  final double viewBottom = viewTop + viewportExtent;

  // ★ 当前曲已经完整可见 ⇒ 不动。半露（只看得见一半 / 只看得见一行字）也算「看不到」，
  //   要滚到完整为止 —— 这正是用户报的那个现象的形状。
  if (top >= viewTop && bottom <= viewBottom) return null;

  return top.clamp(0.0, maxOffset).toDouble();
}
