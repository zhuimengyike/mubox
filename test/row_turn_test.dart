/// `lib/row_turn.dart` 的单测 —— 「一次滑动 = 一个动作」的翻页判定。
///
/// ## 语义
/// * 手指按下时**已经在底部** ⇒ 这一次滑动才可能翻页（仍要越过 [kRowTurnThreshold]）；
/// * 手指按下时**不在底部** ⇒ 这一次滑动**只负责滚到底**，拖多远都不翻，
///   要翻必须**再滑一次**；
/// * 手势**中途**才到底 ⇒ 不算「已在底」（否则又回到误翻）。
///
/// 旧语义是「累积 overscroll > 50 就翻」，症状 = 往下滚列表、刚滚到底、手指还没抬又
/// 多拖了 50px ⇒ 直接翻到下一行（设置页被坑过好几次）。两种症状都只能靠手感发现，
/// 所以边界（负 overscroll / 阈值正好卡住 / 中途到底 / 手势开始才定资格 / 结束复位 /
/// 防重入）在这里逐条钉死。
///
/// ⚠️ 与接线层的关系：`ScrollStartNotification(dragDetails != null)` → [RowTurnGesture.onDragStart]，
/// 这条通知发出时 `metrics` 还没被本次拖拽改过（真页面实测见
/// `test/row_turn_scroll_test.dart` 的 ★6/★7）。本文件的 `atBottom: true/false` 就是那个状态。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/row_turn.dart';

/// 造一个「内容超出 N 像素、手指正停在底部」的手势。
RowTurnGesture _atBottom({double threshold = kRowTurnThreshold}) {
  final g = RowTurnGesture(threshold: threshold);
  g.onDragStart(pixels: 1000, maxScrollExtent: 1000);
  return g;
}

void main() {
  test('阈值常量仍是 50（与设置页既有取值一致，改它 = 改手感）', () {
    expect(kRowTurnThreshold, 50);
    expect(RowTurnGesture().threshold, 50);
  });

  test('① 已在底部：这一次滑动就能表态翻页（多条溢出通知累加，越过阈值才翻）', () {
    final g = _atBottom();
    expect(g.startedAtBottom, isTrue);
    expect(g.onOverscroll(20), isFalse);
    expect(g.accumulated, 20);
    expect(g.onOverscroll(20), isFalse, reason: '累计 40 ≤ 50，不翻');
    expect(g.onOverscroll(11), isTrue, reason: '累计 51 > 50 ⇒ 翻页');
  });

  test('①b 已在底部：阈值边界 —— 正好 50 不翻，50.5 才翻（`> 50` 逐字一致）', () {
    expect(_atBottom().onOverscroll(50), isFalse);
    expect(_atBottom().onOverscroll(50.0 + 0.5), isTrue);
  });

  test('①c 已在底部：差 1px 不翻（49 不翻、51 翻 —— 最小拖动量真有牙）', () {
    final g49 = _atBottom();
    expect(g49.onOverscroll(49), isFalse, reason: '49 < 50，差 1px 就是不翻');
    expect(g49.turning, isFalse);
    expect(g49.accumulated, 49, reason: '不翻不等于丢弃累计：再来 2px 就该翻');
    expect(g49.onOverscroll(2), isTrue, reason: '49 + 2 = 51 > 50');

    final g50 = _atBottom();
    expect(g50.onOverscroll(50), isFalse, reason: '恰好 50 不翻（旧版也是 `> 50`）');
    expect(g50.onOverscroll(0.01), isTrue, reason: '多一点点就翻 —— 边界是闭的');
  });

  test('② 不在底部：这一次滑动拖多远都不翻（这就是用户要的「第一次只滚到底」）', () {
    final g = RowTurnGesture();
    g.onDragStart(pixels: 0, maxScrollExtent: 1000); // 手指按下时在顶部
    expect(g.startedAtBottom, isFalse);
    // 滚到底（中途那次 ScrollUpdate 之后位置到了底）
    g.onScrollUpdate(pixels: 1000, maxScrollExtent: 1000);
    // 手指还按着，继续上滑 —— 真机上这一下溢出量是「拖拽距离 - 剩余距离」，可以很大
    expect(g.onOverscroll(200), isFalse, reason: '★ 不在底就不是这一次滑动的事');
    expect(g.onOverscroll(2000), isFalse, reason: '★ 拖到天边也不翻（不许留模糊地带）');
    expect(g.accumulated, 0, reason: '不在底时连累计都不该发生');
    expect(g.turning, isFalse);
  });

  test('②b 不在底部：松手（手势结束）后**再滑一次**才翻 —— 第二次的资格由它的起点决定', () {
    final g = RowTurnGesture();
    g.onDragStart(pixels: 0, maxScrollExtent: 1000); // 第一次：不在底
    expect(g.onOverscroll(500), isFalse);
    g.onScrollEnd();

    // 用户滑到底了：第二次手指按下时已经在底 ⇒ 这一次才翻
    g.onDragStart(pixels: 1000, maxScrollExtent: 1000);
    expect(g.startedAtBottom, isTrue);
    expect(g.onOverscroll(11), isFalse, reason: '11 ≤ 50 还不够');
    expect(g.onOverscroll(40), isTrue, reason: '★ 第二次滑动累计 51 > 50 ⇒ 翻页');
  });

  test('③ 手势**中途**才到底 ⇒ 不算「已在底部」（这条是防误翻的关键）', () {
    final g = RowTurnGesture();
    // 手指按下时离底还差 1px —— 就是不算，不给自己留解释空间
    g.onDragStart(pixels: 999, maxScrollExtent: 1000);
    expect(g.startedAtBottom, isFalse, reason: '★ 差 1px 也是「不在底」');
    g.onScrollUpdate(pixels: 1000, maxScrollExtent: 1000); // 这一拖把它带到了底
    expect(g.startedAtBottom, isFalse, reason: '★ 中途到底不改变资格');
    expect(g.onOverscroll(999), isFalse, reason: '★ 中途到底之后的溢出同样不翻');
  });

  test('③b 中途到底后又往回滚、再到底：资格还是「没有」（不会半路捡回来）', () {
    final g = RowTurnGesture();
    g.onDragStart(pixels: 500, maxScrollExtent: 1000);
    g.onScrollUpdate(pixels: 1000, maxScrollExtent: 1000); // 到底
    g.onScrollUpdate(pixels: 900, maxScrollExtent: 1000); // 又往回滚
    g.onScrollUpdate(pixels: 1000, maxScrollExtent: 1000); // 再到底
    expect(g.onOverscroll(500), isFalse, reason: '★ 一次手势只认开始那一刻的位置');
  });

  test('③c 已在底部：往回滚一点只清累计，**资格还在**（中途滚到哪都不撤销）', () {
    final g = _atBottom();
    expect(g.onOverscroll(40), isFalse);
    g.onScrollUpdate(pixels: 900, maxScrollExtent: 1000); // 往回滚了一段
    expect(g.accumulated, 0, reason: '没到底就复位累计');
    expect(g.startedAtBottom, isTrue, reason: '回到原问题：资格由手势开始时定，中途不撤销');
    expect(g.onOverscroll(40), isFalse, reason: '复位之后 40 又是 40，不够 50');
    expect(g.onOverscroll(11), isTrue, reason: '再攒到 51 就翻');
  });

  test('④ 负的 overscroll（在顶部继续下拉）不算，也不污染累计', () {
    final g = _atBottom();
    expect(g.onOverscroll(-500), isFalse, reason: '顶部下拉不是「去下行」');
    expect(g.accumulated, 0, reason: '负值不许进累计，否则往下拉也会翻页');
    // 负值之后正常攒，仍然能翻（负值没把状态搞坏）
    expect(g.onOverscroll(11), isFalse);
    expect(g.onOverscroll(40), isTrue);
  });

  test('④b 已在底部：负值只是不翻，不会把资格或防重入弄脏', () {
    final g = _atBottom();
    expect(g.onOverscroll(-1), isFalse);
    expect(g.turning, isFalse);
    expect(g.onOverscroll(60), isTrue);
    expect(g.turning, isTrue);
  });

  test('⑤ 手势结束 ⇒ 全部复位；下一次手势重新按新起点算资格（防重入解除）', () {
    final g = _atBottom();
    expect(g.onOverscroll(60), isTrue);
    expect(g.turning, isTrue, reason: '表过态了');
    expect(g.onOverscroll(60), isFalse, reason: '同一次手势内不许连翻两页（防重入）');
    g.onScrollEnd();
    expect(g.turning, isFalse);
    expect(g.accumulated, 0);
    expect(g.startedAtBottom, isFalse, reason: '结束就清资格 —— 不许跨手势残留');
    expect(g.onOverscroll(60), isFalse,
        reason: '★ 结束之后还没开始新拖拽 ⇒ 谁都不许翻（残留状态不许变成一次误翻）');
  });

  test('⑤b 新的拖拽开始 ⇒ 上一次的全部状态被整体重算（中途丢 ScrollEndNotification 也不怕）',
      () {
    final g = _atBottom();
    expect(g.onOverscroll(60), isTrue);
    // ⚠️ 故意不调 onScrollEnd（真机上这一条理论上可能不来）
    g.onDragStart(pixels: 0, maxScrollExtent: 1000);
    expect(g.turning, isFalse, reason: '★ 新拖拽一开始就清掉上一次的防重入');
    expect(g.accumulated, 0);
    expect(g.startedAtBottom, isFalse, reason: '新拖拽的起点说了算');
    expect(g.onOverscroll(500), isFalse, reason: '新拖拽不在底 ⇒ 不翻');
  });

  test('⑥ 装得下（maxScrollExtent == 0）时永远不算「已在底部」（本判定不参与）', () {
    final g = RowTurnGesture();
    g.onDragStart(pixels: 0, maxScrollExtent: 0);
    expect(g.startedAtBottom, isFalse,
        reason: '★ 装得下时手势归外层 PageView，这条判定一个字都不该说');
    expect(g.onOverscroll(999), isFalse);
  });

  test('⑥b 「已在底」的判定带半个像素容差（pixels 差零点几不算没到底）', () {
    expect(kRowTurnBottomEpsilon, 0.5);
    final g = RowTurnGesture();
    g.onDragStart(pixels: 999.6, maxScrollExtent: 1000);
    expect(g.startedAtBottom, isTrue, reason: '0.4px 在屏幕上不可分辨，算「已经在底」');
    expect(g.onOverscroll(11), isFalse);
    expect(g.onOverscroll(40), isTrue);

    final g2 = RowTurnGesture();
    g2.onDragStart(pixels: 999.0, maxScrollExtent: 1000);
    expect(g2.startedAtBottom, isFalse, reason: '差整整 1px 就该算没到底（容差只有 0.5）');
  });
}
