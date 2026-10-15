/// `lib/playback/queue.dart` 的单测 —— 队列 2.0 的**全部判定**都在这儿钉死。
///
/// 为什么这些判定必须离开 `player_service.dart`：它们全是下标算术（删当前曲之前的 /
/// 删当前曲 / 删当前曲之后的，三种各不一样）与「随机序」这种真机上根本试不出来的东西
/// —— 要手指拖、要杀进程、要听是不是同一首。搬进纯函数后这里可以穷举。
///
/// 三条硬性质（对应 [QueueOps] / [ShuffleOrder] 的文件头说明）：
/// 1. 当前曲下标**永远指着同一首歌**（[QueueOps] 每个函数的正向/负向成对用例）；
/// 2. 随机序由种子唯一决定，正负方向走**同一条**排列；
/// 3. 编解码逐项等价、读坏了返回 null（见 `queue_persist_test.dart`）。
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/playback/queue.dart';

/// 造一个队列状态：refs 用 'a','b',… 表示，index 就是当前曲下标。
QueueState st(List<String> refs, int index, [String title = '']) =>
    QueueState(refs: refs, index: index, sourceName: title);

void main() {
  // ════════════════════════════════════════════════════════════════════════
  group('QueueState：当前曲下标恒指着同一首歌（不变量）', () {
    test('空队列：index = -1、current = null', () {
      expect(QueueState.empty.index, -1);
      expect(QueueState.empty.current, isNull);
      expect(QueueState.empty.isEmpty, isTrue);
      expect(QueueState.empty.length, 0);
    });

    test('index 越界被夹进 [-1, length-1]（构造器就管，别指望调用方）', () {
      expect(st(['a', 'b', 'c'], 99).index, 2);
      expect(st(['a', 'b', 'c'], -5).index, -1);
      expect(st(['a', 'b', 'c'], 0).index, 0);
      // 队列为空时不论给什么都是 -1
      expect(st([], 0).index, -1);
      expect(st([], 7).index, -1);
    });

    test('current 就是 refs[index]', () {
      expect(st(['a', 'b', 'c'], 1).current, 'b');
    });

    test('refs 只读：外部拿到的列表改不动内部状态', () {
      final q = st(['a', 'b'], 0);
      expect(() => q.refs.add('c'), throwsUnsupportedError);
    });

    test('值相等：内容一样就相等（便于用例直接比整个状态）', () {
      expect(st(['a', 'b'], 1, 'x'), st(['a', 'b'], 1, 'x'));
      expect(st(['a', 'b'], 1, 'x'), isNot(st(['a', 'b'], 0, 'x')));
      expect(st(['a', 'b'], 1, 'x'), isNot(st(['b', 'a'], 1, 'x')));
      expect(st(['a', 'b'], 1, 'x'), isNot(st(['a', 'b'], 1, 'y')));
    });

    test('队列里允许同一首歌出现两次（「下一首播放」会插重复）', () {
      final q = st(['a', 'a', 'b'], 0);
      expect(q.length, 3);
      expect(QueueOps.removeRef(q, 'a').refs, ['a', 'b']); // 只删第一个
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('push：换一整个队列', () {
    test('下标越界夹进范围；负数 = 没点中任何一首（-1 = 不开播）', () {
      expect(QueueOps.push(['a', 'b', 'c'], 9).index, 2);
      expect(QueueOps.push(['a', 'b', 'c'], -1).index, -1);
      expect(QueueOps.push(['a', 'b', 'c'], 1).index, 1);
    });

    test('空队列 → index = -1（调用方据此不开播）', () {
      expect(QueueOps.push(const [], 0).index, -1);
    });

    test('来源名跟着一起换', () {
      expect(QueueOps.push(['a'], 0, title: '我喜欢').sourceName, '我喜欢');
    });

    test('入参列表被复制：外面再改它不影响队列', () {
      final src = ['a', 'b'];
      final q = QueueOps.push(src, 0);
      src.add('c');
      expect(q.refs, ['a', 'b']);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('append：跨歌单追加（当前曲不许挪窝）', () {
    test('追加到末尾，当前曲与下标都不动', () {
      final q = QueueOps.append(st(['a', 'b'], 1, '旧'), ['c', 'd']);
      expect(q.refs, ['a', 'b', 'c', 'd']);
      expect(q.index, 1);
      expect(q.current, 'b');
      expect(q.sourceName, '旧', reason: '追加不该改来源名');
    });

    test('追加空列表 = 原样返回（一个字节都不改）', () {
      final q = st(['a'], 0);
      expect(QueueOps.append(q, const []), same(q));
    });

    test('往空队列追加：下标仍是 -1，等调用方决定要不要开播', () {
      final q = QueueOps.append(QueueState.empty, ['a', 'b']);
      expect(q.refs, ['a', 'b']);
      expect(q.index, -1);
    });

    test('追加进来的歌可以重复（同一首歌两份）', () {
      final q = QueueOps.append(st(['a'], 0), ['a']);
      expect(q.refs, ['a', 'a']);
      expect(q.index, 0);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('insertAt / insertNext：下一首播放', () {
    test('插在当前曲后面 → 下标不动，下一首就是它', () {
      final q = QueueOps.insertNext(st(['a', 'b', 'c'], 1), 'x');
      expect(q.refs, ['a', 'b', 'x', 'c']);
      expect(q.index, 1);
      expect(q.current, 'b');
    });

    test('插在当前曲**前面** → 下标 +1（当前曲还是同一首歌）← 最容易写错的一处', () {
      final q = QueueOps.insertAt(st(['a', 'b', 'c'], 1), 0, 'x');
      expect(q.refs, ['x', 'a', 'b', 'c']);
      expect(q.index, 2);
      expect(q.current, 'b');
    });

    test('正好插在当前曲的位置上 → 新歌不抢当前曲，下标 +1', () {
      final q = QueueOps.insertAt(st(['a', 'b'], 1), 1, 'x');
      expect(q.refs, ['a', 'x', 'b']);
      expect(q.index, 2);
      expect(q.current, 'b');
    });

    test('插在末尾（越界）→ 夹到末尾，下标不动', () {
      final q = QueueOps.insertAt(st(['a', 'b'], 0), 99, 'x');
      expect(q.refs, ['a', 'b', 'x']);
      expect(q.index, 0);
    });

    test('负下标 → 夹到头部', () {
      final q = QueueOps.insertAt(st(['a', 'b'], 1), -3, 'x');
      expect(q.refs, ['x', 'a', 'b']);
      expect(q.index, 2);
    });

    test('往空队列 insertNext → 它就是当前曲', () {
      final q = QueueOps.insertNext(QueueState.empty, 'x');
      expect(q.refs, ['x']);
      expect(q.index, 0);
      expect(q.current, 'x');
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('removeAt：三种情形各有各的算法（穷举）', () {
    // 表格：原队列 / 当前曲下标 / 删哪一个 → 删完的队列与当前曲下标
    const cases = <({List<String> refs, int idx, int del, List<String> want, int wantIdx})>[
      // — 删当前曲**之前**的：当前曲没变，下标 -1 —
      (refs: ['a', 'b', 'c'], idx: 2, del: 0, want: ['b', 'c'], wantIdx: 1),
      (refs: ['a', 'b', 'c'], idx: 1, del: 0, want: ['b', 'c'], wantIdx: 0),
      // — 删当前曲**本身**：后一首顶上；原本是最后一首则落到新的最后一首 —
      (refs: ['a', 'b', 'c'], idx: 1, del: 1, want: ['a', 'c'], wantIdx: 1),
      (refs: ['a', 'b', 'c'], idx: 2, del: 2, want: ['a', 'b'], wantIdx: 1),
      (refs: ['a', 'b'], idx: 1, del: 1, want: ['a'], wantIdx: 0),
      // — 删当前曲**之后**的：下标纹丝不动 —
      (refs: ['a', 'b', 'c'], idx: 0, del: 2, want: ['a', 'b'], wantIdx: 0),
      (refs: ['a', 'b', 'c'], idx: 0, del: 1, want: ['a', 'c'], wantIdx: 0),
    ];

    for (final c in cases) {
      test('${c.refs} 当前=${c.refs[c.idx]} 删 ${c.refs[c.del]} → '
          '${c.want} 当前=${c.want[c.wantIdx]}', () {
        final q = QueueOps.removeAt(st(c.refs, c.idx), c.del);
        expect(q.refs, c.want);
        expect(q.index, c.wantIdx);
        expect(q.current, c.want[c.wantIdx], reason: '下标与内容必须对得上');
        // 正/负向成对的「正向」半边：**删的不是当前曲时，当前曲还得是同一首歌**
        // （删的就是它时当然会换人，那条由 wantIdx 单独钉住）
        if (c.del != c.idx) {
          expect(q.current, c.refs[c.idx],
              reason: '删了别的歌却把正在听的那首换掉了');
        }
      });
    }

    test('删光最后一首 → 当前曲消失（index = -1），来源名还留着', () {
      final q = QueueOps.removeAt(st(['a'], 0, '我喜欢'), 0);
      expect(q.refs, isEmpty);
      expect(q.index, -1);
      expect(q.current, isNull);
      expect(q.sourceName, '我喜欢');
    });

    test('越界下标 → 原样返回（不抛、不改）', () {
      final q = st(['a', 'b'], 0);
      expect(QueueOps.removeAt(q, -1), same(q));
      expect(QueueOps.removeAt(q, 2), same(q));
      expect(QueueOps.removeAt(QueueState.empty, 0).refs, isEmpty);
    });

    test('removeRef：第一首等于它的被删；不在队列里就原样返回', () {
      final q = st(['a', 'b', 'c'], 2);
      final r = QueueOps.removeRef(q, 'b');
      expect(r.refs, ['a', 'c']);
      expect(r.current, 'c');
      expect(QueueOps.removeRef(q, '没有这首歌'), same(q));
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('moveTo：拖拽排序（穷举 4 首队列的全部 from→to）', () {
    test('4 首队列 16 种移动全部满足「只挪一首、其余相对顺序不变、当前曲不变」', () {
      const refs = ['a', 'b', 'c', 'd'];
      for (var from = 0; from < 4; from++) {
        for (var to = 0; to < 4; to++) {
          if (from == to) continue;
          for (var idx = 0; idx < 4; idx++) {
            final q = QueueOps.moveTo(st(refs, idx), from, to);
            final moved = refs[from];
            final rest = [for (final r in refs) if (r != moved) r];
            // ① 队列长度不变；② 被挪的那首落在 to；③ 其余保持相对顺序
            expect(q.refs.length, 4, reason: 'from=$from to=$to idx=$idx');
            expect(q.refs[to], moved, reason: 'from=$from to=$to idx=$idx');
            expect(
              [for (final r in q.refs) if (r != moved) r],
              rest,
              reason: 'from=$from to=$to idx=$idx',
            );
            // ④ 当前曲**永远是同一首歌**（这条是硬不变量）
            expect(
              q.current,
              refs[idx],
              reason: 'from=$from to=$to 当前=$idx（下标算错就会把正在听的歌换掉）',
            );
            // ⑤ 没有丢歌也没有多歌
            expect(q.refs.toSet(), refs.toSet());
          }
        }
      }
    });

    test('拖的正好是当前曲 → 下标跟着它走', () {
      final q = QueueOps.moveTo(st(['a', 'b', 'c'], 0), 0, 2);
      expect(q.refs, ['b', 'c', 'a']);
      expect(q.index, 2);
      expect(q.current, 'a');
    });

    test('把后面的歌拖到前面 → 当前曲下标 +1', () {
      final q = QueueOps.moveTo(st(['a', 'b', 'c'], 1), 2, 0);
      expect(q.refs, ['c', 'a', 'b']);
      expect(q.index, 2);
      expect(q.current, 'b');
    });

    test('把前面的歌拖到后面 → 当前曲下标 -1', () {
      final q = QueueOps.moveTo(st(['a', 'b', 'c'], 1), 0, 2);
      expect(q.refs, ['b', 'c', 'a']);
      expect(q.index, 0);
      expect(q.current, 'b');
    });

    test('原地不动 / 越界 → 原样返回（不白算一遍）', () {
      final q = st(['a', 'b'], 0);
      expect(QueueOps.moveTo(q, 1, 1), same(q));
      expect(QueueOps.moveTo(q, -1, 0), same(q));
      expect(QueueOps.moveTo(q, 0, 5), same(q));
      expect(QueueOps.moveTo(QueueState.empty, 0, 1).refs, isEmpty);
    });

    test('moveBy：相对位移版（正=往后拖）', () {
      expect(QueueOps.moveBy(st(['a', 'b', 'c'], 0), 0, 2).refs, ['b', 'c', 'a']);
      expect(QueueOps.moveBy(st(['a', 'b', 'c'], 0), 2, -2).refs, ['c', 'a', 'b']);
      // 位移出界 → 夹不住就原样返回（ReorderableListView 不会给这种值）
      expect(QueueOps.moveBy(st(['a', 'b'], 0), 0, 9).refs, ['a', 'b']);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('清空', () {
    test('clearKeepingCurrent：只剩当前曲，下标 0，来源名留着', () {
      final q = QueueOps.clearKeepingCurrent(st(['a', 'b', 'c'], 1, '我喜欢'));
      expect(q.refs, ['b']);
      expect(q.index, 0);
      expect(q.current, 'b');
      expect(q.sourceName, '我喜欢');
    });

    test('clearKeepingCurrent 在空队列 / 没当前曲时 → 空队列（不抛）', () {
      expect(QueueOps.clearKeepingCurrent(QueueState.empty).index, -1);
      // 有歌但 index = -1（会话恢复的中间态）也算「没有当前曲」
      final q = QueueOps.clearKeepingCurrent(st(['a', 'b'], -1));
      expect(q.refs, isEmpty);
      expect(q.index, -1);
    });

    test('clearAll：一首不剩，但来源名不丢（界面标题不会突然变空）', () {
      final q = QueueOps.clearAll(st(['a', 'b'], 1, '我喜欢'));
      expect(q.refs, isEmpty);
      expect(q.index, -1);
      expect(q.sourceName, '我喜欢');
    });

    test('rename：只换来源名，队列与当前曲都不动', () {
      final q = QueueOps.rename(st(['a', 'b'], 1, '旧'), '新');
      expect(q.sourceName, '新');
      expect(q.refs, ['a', 'b']);
      expect(q.index, 1);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('组合操作：当前曲是一路跟到底的（真实使用序列）', () {
    test('点歌单第 3 首 → 追加一张歌单 → 删两首 → 拖一次：当前曲始终没变', () {
      var q = QueueOps.push(['a', 'b', 'c', 'd', 'e'], 2, title: '全部歌曲');
      expect(q.current, 'c');
      q = QueueOps.append(q, ['f', 'g']);
      expect(q.current, 'c');
      q = QueueOps.removeAt(q, 0); // 删 'a'（当前曲之前）
      expect(q.current, 'c');
      q = QueueOps.removeAt(q, 0); // 删 'b'（当前曲之前）
      expect(q.current, 'c');
      expect(q.index, 0);
      q = QueueOps.moveTo(q, 0, 4); // 把 'c' 自己拖到最后
      expect(q.current, 'c');
      expect(q.refs, ['d', 'e', 'f', 'g', 'c']);
      expect(q.index, 4);
      q = QueueOps.insertNext(q, 'x'); // 下一首播放
      expect(q.current, 'c');
      expect(q.index, 4);
      expect(q.refs.last, 'x', reason: '「下一首」插在当前曲后面（当前曲已在末尾）');
    });

    test('每一步都返回新实例：原状态一个字节都不许被改（可回滚）', () {
      final before = st(['a', 'b', 'c'], 1);
      final snapshot = QueueState(refs: before.refs, index: before.index);
      QueueOps.removeAt(before, 0);
      QueueOps.moveTo(before, 0, 2);
      QueueOps.insertAt(before, 0, 'x');
      QueueOps.clearKeepingCurrent(before);
      expect(before, snapshot);
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('ShuffleOrder：固定种子的随机序（验收判据「拉回上一首能回到同一首」）', () {
    test('排列是 0..n-1 的一个置换（不重不漏）', () {
      for (var n = 0; n <= 12; n++) {
        final perm = ShuffleOrder.create(n, 7).perm;
        expect(perm.length, n);
        expect(perm.toSet(), {for (var i = 0; i < n; i++) i}, reason: 'n=$n');
      }
    });

    test('同一种子 + 同一长度 → 逐项相同的排列；换种子 → 排列变样', () {
      for (final n in [2, 3, 8, 33]) {
        expect(ShuffleOrder.create(n, 12345).perm,
            ShuffleOrder.create(n, 12345).perm,
            reason: 'n=$n 必须可复现');
      }
      // 换种子在不同长度下都得换出一条不一样的（8 首两个种子撞车的概率 < 1/40320）
      expect(ShuffleOrder.create(8, 1).perm,
          isNot(ShuffleOrder.create(8, 2).perm));
    });

    test('0 / 1 首不炸', () {
      expect(ShuffleOrder.create(0, 5).perm, isEmpty);
      expect(ShuffleOrder.create(1, 5).perm, [0]);
      expect(ShuffleOrder.create(0, 5).step(0, 1), 0);
      expect(ShuffleOrder.create(1, 5).step(0, 1), 0, reason: '一首歌走不动');
    });

    test('★ 正向：下一首 → 上一首，精确回到同一首（穷举长度 2..12 × 3 个种子）', () {
      for (final n in [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]) {
        for (final seed in [1, 99, 20260930]) {
          for (var start = 0; start < n; start++) {
            final s = ShuffleOrder.create(n, seed);
            final nxt = s.step(start, 1);
            final back = s.step(nxt, -1);
            expect(back, start,
                reason: 'n=$n seed=$seed start=$start：回退漂到别处了');
          }
        }
      }
    });

    test('★ 负向：旧实现（前后各现抽一次随机）回不到同一首 —— 这把尺子确实有牙', () {
      // 旧实现 = player_service 里的 _randomIndexOtherThan：每次现抽一个「不是当前」的。
      // 这里原样复刻一遍，用来证明上面那条正向断言**不是恒真**的（否则它测不出东西）。
      final rng = Random(20260930);
      var misses = 0;
      const trials = 2000;
      for (var t = 0; t < trials; t++) {
        const n = 10;
        var cur = 3;
        // next：从 9 个候选里现抽
        final pool = [for (var i = 0; i < n; i++) if (i != cur) i];
        cur = pool[rng.nextInt(pool.length)];
        // prev：再独立现抽一个
        final pool2 = [for (var i = 0; i < n; i++) if (i != cur) i];
        final back = pool2[rng.nextInt(pool2.length)];
        if (back != 3) misses++;
      }
      expect(misses, greaterThan(trials ~/ 2),
          reason: '旧实现应该绝大多数回不到同一首 —— 如果这条不成立，说明上面那条正向'
              '断言在旧实现上也是绿的（尺子没牙）');
    });

    test('游标 / current 跟着 step 走，seekTo 能重新定位', () {
      final s = ShuffleOrder.create(5, 42);
      expect(s.current, isNull, reason: '还没定位过');
      final a = s.step(0, 1);
      expect(s.current, a);
      final b = s.step(a, 1);
      expect(s.current, b);
      expect(s.step(b, -1), a);
      expect(s.seekTo(3), isTrue);
      expect(s.cursor, s.perm.indexOf(3));
      expect(s.seekTo(99), isFalse, reason: '不在队列里 → false，调用方据此重建');
    });

    test('排除名单（不参与循环）被跳过，且不影响正反走同一格', () {
      const n = 6;
      final s = ShuffleOrder.create(n, 7);
      // 把「除当前曲之外」全排除掉 → 走不动，留在原地
      final others = {for (var i = 0; i < n; i++) if (i != 0) i};
      expect(s.step(0, 1, excluded: others), 0);
      // 只排除一个：跳过去之后，再走回来还是那一首
      final excl = {s.perm[2]};
      final a = s.step(s.perm[0], 1, excluded: excl);
      expect(excl.contains(a), isFalse);
      final back = s.step(a, -1, excluded: excl);
      expect(back, s.perm[0]);
    });

    test('装满一圈 = 把所有歌各播一遍（不重复、不漏）', () {
      const n = 7;
      final s = ShuffleOrder.create(n, 3);
      var cur = s.perm[0];
      final seen = <int>{cur};
      for (var k = 0; k < n - 1; k++) {
        cur = s.step(cur, 1);
        seen.add(cur);
      }
      expect(seen, {for (var i = 0; i < n; i++) i});
    });

    test('当前曲不在排列里（队列换过了）→ 原地返回，交给调用方重建', () {
      final s = ShuffleOrder.create(3, 7);
      expect(s.step(99, 1), 99);
    });
  });
}
