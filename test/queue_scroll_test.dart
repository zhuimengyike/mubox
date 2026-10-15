/// `lib/queue_scroll.dart` 的穷举单测 —— 「打开队列浮层该滚到第几像素」的**判定本身**。
///
/// 与 `test/queue_panel_scroll_test.dart` 分工：
/// * 本文件量**判定**（纯函数，能把边界穷举完）；
/// * 那边量**接线 + 真几何**（真 `PlayerBar`、真 `ListView`、真 `ScrollPosition`）。
///
/// 改动 `queueScrollTarget` 之前先看下面 §3 的两条不变量 —— 它们是**穷举**的，
/// 不是挑几个样例。
library;

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/queue_scroll.dart';

/// 真机尺寸（实测值，见 `test/queue_panel_scroll_test.dart` 的打印）：
/// 队列浮层里列表视口高 165、单行 48 ⇒ 一次只装得下 3 行多一点。
/// 这就是用户报「只显示 3 行、看不到当前曲」的那把尺子。
const double _kRow = 48;
const double _kViewport = 165;

double _maxOffset(int itemCount) =>
    math.max(0, itemCount * _kRow + 4 - _kViewport);

double? _target(
  int index,
  int itemCount, {
  double offset = 0,
  double? row,
  double? viewport,
  double? max,
}) =>
    queueScrollTarget(
      index: index,
      itemCount: itemCount,
      rowExtent: row ?? _kRow,
      viewportExtent: viewport ?? _kViewport,
      currentOffset: offset,
      maxScrollExtent: max ?? _maxOffset(itemCount),
    );

void main() {
  group('§1 用户报的那个现象：打开浮层停在顶部，当前曲在第 37 行', () {
    test('★ 正向：列表停在 0、当前曲第 37 行（视口只装得下 3 行）⇒ 必须给出滚动目标',
        () {
      final t = _target(37, 40);
      expect(t, isNotNull, reason: '当前曲完全在视口外，必须滚');
      // 第 37 行上边缘在 1776，但整个列表只滚得到 1759 ⇒ 夹到 1759（贴底不越界）
      expect(t, math.min(37 * _kRow, _maxOffset(40)),
          reason: '顶对齐，然后夹进 [0, maxScrollExtent]');
      final rowTop = 37 * _kRow;
      expect(rowTop, greaterThanOrEqualTo(t! - 1e-9), reason: '行上边要进视口');
      expect(rowTop + _kRow, lessThanOrEqualTo(t + _kViewport + 1e-9),
          reason: '整行都要在视口里');
      expect(t, isNot(0.0), reason: '0 就是「停在顶部」，正是要修的那个状态');
    });

    test('★ 负向对照（旧的默认行为）：这个目标绝不是 0 —— 0 就是「停在顶部」',
        () {
      // 改动前没有 ScrollController，ListView 的初始 offset 恒为 0。
      // 这条断言保证「沉默地返回 0」不会被当成修好了。
      expect(_target(37, 40), isNot(0.0));
      expect(0.0, lessThan(37 * _kRow),
          reason: '0 落在第 0 行 ⇒ 第 37 行不可能可见');
    });

    test('末尾那一首：目标夹到 maxScrollExtent（顶对齐做不到就贴底）', () {
      final t = _target(39, 40);
      expect(t, _maxOffset(40));
      // 且夹完之后那一行仍然**完整**在视口里
      expect(39 * _kRow >= t!, isTrue);
      expect(39 * _kRow + _kRow <= t + _kViewport, isTrue);
    });
  });

  group('§2 「已经看得见就别动」这条语义（返回 null 的全部情形）', () {
    test('当前曲完整可见 ⇒ null（打开浮层不许跳）', () {
      expect(_target(0, 40), isNull, reason: '第 0 行 + 停在顶部 = 本来就看得见');
      expect(_target(2, 40), isNull, reason: '第 2 行也整行在视口里');
      expect(_target(5, 40, offset: 5 * _kRow), isNull, reason: '正好顶对齐');
      expect(_target(37, 40, offset: 37 * _kRow - 20), isNull,
          reason: '当前曲离顶 20px，整行都在视口里');
    });

    test('只露一半 ⇒ 不算「看得见」，要滚到完整（半截字正是要修掉的形状）', () {
      // 第 5 行 [240, 288]；视口 [250, 415] ⇒ 上边被吃掉 10px
      expect(_target(5, 40, offset: 250), isNotNull);
      // 视口 [200, 365] ⇒ 第 5 行下边 288 在里面，整行都在 ⇒ null
      expect(_target(5, 40, offset: 200), isNull);
      // 只差 1px 露不全 ⇒ 仍然要滚
      expect(_target(5, 40, offset: 241), isNotNull);
      expect(_target(5, 40, offset: 240), isNull);
    });

    test('当前曲在视口【上方】（用户往下翻过头了）⇒ 往回滚', () {
      final t = _target(5, 40, offset: 20 * _kRow);
      expect(t, 5 * _kRow);
    });

    test('下标越界 / 空队列 ⇒ null（当前曲不在队列里，宁可不滚）', () {
      expect(_target(-1, 40), isNull);
      expect(_target(40, 40), isNull);
      expect(_target(0, 0), isNull);
      expect(_target(0, -3), isNull);
    });

    test('整个队列装得下（maxScrollExtent = 0）⇒ null（滚也滚不动）', () {
      expect(_target(2, 3), isNull, reason: '3 首 × 48 = 144 < 165，本来就全看得见');
      expect(_target(2, 3, max: 0), isNull);
      expect(_target(2, 3, max: -5), isNull, reason: '负值也当滚不动处理');
    });

    test('几何拿不到（0 / NaN / Infinity）⇒ null，不糊一个位置出来', () {
      expect(_target(5, 40, row: 0), isNull);
      expect(_target(5, 40, row: -48), isNull);
      expect(_target(5, 40, row: double.nan), isNull);
      expect(_target(5, 40, row: double.infinity), isNull);
      expect(_target(5, 40, viewport: 0), isNull);
      expect(_target(5, 40, viewport: double.nan), isNull);
      expect(_target(5, 40, viewport: double.infinity), isNull);
    });

    test('currentOffset 越界（回弹中途）不崩，先夹再用', () {
      // 负 offset（下拉回弹）：当 0 处理
      expect(_target(37, 40, offset: -500), math.min(37 * _kRow, _maxOffset(40)));
      // 超过 max（上拉回弹）：当 max 处理 ⇒ 视角落在列表底部，
      // 第 37 行本来就在底部视口里 ⇒ 判「不动」（不是不崩，是判对了）
      expect(_target(37, 40, offset: 99 * _kRow), isNull,
          reason: '夹到 max 之后第 37 行正好完整可见 ⇒ 不许无谓地跳');
      // 同一批夹取之后，靠前的行仍然在视口外 ⇒ 必须滚
      final t = _target(30, 40, offset: 99 * _kRow);
      expect(t, isNotNull);
      expect(t, lessThanOrEqualTo(_maxOffset(40)));
      // NaN offset 落到 0：第 0 行以外都要滚
      expect(_target(37, 40, offset: double.nan),
          math.min(37 * _kRow, _maxOffset(40)));
      expect(_target(0, 40, offset: double.nan), isNull);
    });
  });

  group('§3 ★★ 两条穷举不变量（40 首 × 每首 × 3 个位置 = 480 组）', () {
    test('不变量 A：返回非 null ⇒ 结果必在 [0, max] 内，且当前行**完整**落在结果视口里',
        () {
      var checked = 0;
      for (var n = 1; n <= 40; n++) {
        final max = _maxOffset(n);
        final offsets = <double>[0, max / 2, max];
        for (var i = 0; i < n; i++) {
          for (final off in offsets) {
            final t = _target(i, n, offset: off);
            checked++;
            if (t == null) continue;
            expect(t, greaterThanOrEqualTo(0.0),
                reason: 'n=$n i=$i off=$off ⇒ $t 越下界');
            expect(t, lessThanOrEqualTo(max + 1e-9),
                reason: 'n=$n i=$i off=$off ⇒ $t 越上界');
            final rowTop = i * _kRow;
            final rowBottom = rowTop + _kRow;
            expect(rowTop, greaterThanOrEqualTo(t - 1e-9),
                reason: 'n=$n i=$i off=$off：行上边 $rowTop 没进视口顶 $t');
            expect(rowBottom, lessThanOrEqualTo(t + _kViewport + 1e-9),
                reason: 'n=$n i=$i off=$off：行下边 $rowBottom 超出视口底 ${t + _kViewport}');
          }
        }
      }
      expect(checked, 40 * 41 ~/ 2 * 3, reason: '穷举组数：Σn × 3');
    });

    test('不变量 B：返回 null ⇒ 当前行**本来就已经**完整可见（null 绝不等于「看不见」）',
        () {
      var nulls = 0;
      for (var n = 1; n <= 40; n++) {
        final max = _maxOffset(n);
        final offsets = <double>[0, max / 2, max];
        for (var i = 0; i < n; i++) {
          for (final off in offsets) {
            final t = _target(i, n, offset: off);
            if (t != null) continue;
            nulls++;
            if (max <= 0) continue; // 整队列装得下 ⇒ 天然全可见
            final rowTop = i * _kRow;
            final rowBottom = rowTop + _kRow;
            expect(rowTop, greaterThanOrEqualTo(off - 1e-9),
                reason: 'n=$n i=$i off=$off：返回了 null，行上边却在视口外');
            expect(rowBottom, lessThanOrEqualTo(off + _kViewport + 1e-9),
                reason: 'n=$n i=$i off=$off：返回了 null，行下边却在视口外');
          }
        }
      }
      expect(nulls, greaterThan(0), reason: '不变量 B 必须有样本，否则它是死的');
    });

    test('不变量 C：同一批量里，「已可见」组与「要滚」组都非空（判据两侧都有样本）',
        () {
      var moved = 0;
      var stayed = 0;
      for (var i = 0; i < 40; i++) {
        final t = _target(i, 40);
        if (t == null) {
          stayed++;
        } else {
          moved++;
        }
      }
      expect(moved, greaterThan(0));
      expect(stayed, greaterThan(0), reason: '前 3 行本来就看得见，必须判「不动」');
    });
  });
}
