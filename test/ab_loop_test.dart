/// A-B 片段循环的纯逻辑单测：`lib/ab_loop.dart`。
///
/// 这一组用例存在的理由：打点顺序（没 A 就打 B / B 打在 A 前面 / 重复打 A）
/// 是纯边界问题，真机上很难一条条试；而错法的后果是「循环到一半不动了」
/// 或者「一圈比一圈短」，用户只会觉得这功能坏了。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/ab_loop.dart';

void main() {
  const none = AbLoop.none;

  group('三态与生效判定', () {
    test('未打点：不生效、不绕回、标签为空', () {
      expect(none.hasA, isFalse);
      expect(none.active, isFalse);
      expect(none.shouldWrap(const Duration(seconds: 30)), isFalse);
      expect(none.label, '');
    });

    test('只有 A 点：还不生效', () {
      final s = none.markA(const Duration(seconds: 12));
      expect(s.hasA, isTrue);
      expect(s.active, isFalse);
      expect(s.shouldWrap(const Duration(seconds: 99)), isFalse);
      expect(s.label, 'A 0:12');
    });

    test('A、B 都有且 B 在 A 之后才生效', () {
      final s = none.markA(const Duration(seconds: 12)).markB(const Duration(seconds: 35));
      expect(s.active, isTrue);
      expect(s.label, '0:12 → 0:35');
    });

    test('A、B 相等不生效（空区间）', () {
      final s = const AbLoop(a: Duration(seconds: 12), b: Duration(seconds: 12));
      expect(s.active, isFalse);
    });
  });

  group('该不该绕回', () {
    test('到 B 点那一刻就绕回（>= 而不是 >）', () {
      final s = none.markA(const Duration(seconds: 12)).markB(const Duration(seconds: 35));
      expect(s.shouldWrap(const Duration(seconds: 34, milliseconds: 999)), isFalse);
      expect(s.shouldWrap(const Duration(seconds: 35)), isTrue);
      expect(s.shouldWrap(const Duration(seconds: 40)), isTrue);
    });

    test('还没到 B 点不绕回', () {
      final s = none.markA(const Duration(seconds: 12)).markB(const Duration(seconds: 35));
      expect(s.shouldWrap(const Duration(seconds: 20)), isFalse);
    });
  });

  group('打点顺序', () {
    test('只打 B：自动补 A = 0（从头循环到这儿）', () {
      final s = none.markB(const Duration(seconds: 20));
      expect(s.active, isTrue);
      expect(s.a, Duration.zero);
      expect(s.b, const Duration(seconds: 20));
      expect(s.label, '0:00 → 0:20');
    });

    test('B 打在 A 前面：这次打点无效，原样返回（界面据此提示）', () {
      final s = none.markA(const Duration(seconds: 30));
      expect(s.markB(const Duration(seconds: 10)), s);
      expect(s.markB(const Duration(seconds: 30)), s);
      expect(s.markB(const Duration(seconds: 30)).active, isFalse);
    });

    test('重打 A：B 在新 A 之后则保留（用户是在微调起点）', () {
      final s = none.markA(const Duration(seconds: 10)).markB(const Duration(seconds: 40));
      final moved = s.markA(const Duration(seconds: 20));
      expect(moved.a, const Duration(seconds: 20));
      expect(moved.b, const Duration(seconds: 40));
      expect(moved.active, isTrue);
    });

    test('重打 A 越过 B：B 作废，回到「只有 A」', () {
      final s = none.markA(const Duration(seconds: 10)).markB(const Duration(seconds: 40));
      final moved = s.markA(const Duration(seconds: 50));
      expect(moved.a, const Duration(seconds: 50));
      expect(moved.b, isNull);
      expect(moved.active, isFalse);
    });

    test('重打 A 正好落在 B 上：同样作废（不能留下空区间）', () {
      final s = none.markA(const Duration(seconds: 10)).markB(const Duration(seconds: 40));
      final moved = s.markA(const Duration(seconds: 40));
      expect(moved.b, isNull);
      expect(moved.active, isFalse);
    });
  });

  group('进度条高亮带的比例', () {
    test('正常区间按比例换算', () {
      final s = none.markA(const Duration(seconds: 30)).markB(const Duration(seconds: 60));
      final f = s.fractions(const Duration(seconds: 120));
      expect(f, isNotNull);
      expect(f!.$1, closeTo(0.25, 1e-9));
      expect(f.$2, closeTo(0.50, 1e-9));
    });

    test('未生效 / 总长为 0 时不给比例（界面就不画）', () {
      final onlyA = none.markA(const Duration(seconds: 30));
      expect(onlyA.fractions(const Duration(seconds: 120)), isNull);
      final full = onlyA.markB(const Duration(seconds: 60));
      expect(full.fractions(Duration.zero), isNull);
      expect(full.fractions(const Duration(seconds: -1)), isNull);
    });

    test('B 超出总长时收拢到 100%（真实时长比标签短的情况）', () {
      final s = none.markA(const Duration(seconds: 30)).markB(const Duration(seconds: 300));
      final f = s.fractions(const Duration(seconds: 120));
      expect(f!.$1, closeTo(0.25, 1e-9));
      expect(f.$2, 1.0);
    });
  });

  group('值语义', () {
    test('相同打点相等（ChangeNotifier 里靠它判「值没变就别通知」）', () {
      final x = none.markA(const Duration(seconds: 5)).markB(const Duration(seconds: 9));
      final y = none.markA(const Duration(seconds: 5)).markB(const Duration(seconds: 9));
      expect(x, y);
      expect(x.hashCode, y.hashCode);
    });
  });
}
