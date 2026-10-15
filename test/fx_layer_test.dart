import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/effect_catalog.dart';

/// 视觉区「一特效多开 + 爱心牵手」的地基自检。
///
/// 这里守的是三条改坏了会**静默**出错的不变量（画面看不出来、但参数会串/错）：
/// ① 图层键 ↔ 基键双向解析；② 槽位 0 用老键（老用户存值一个都不动）；
/// ③ 牵手链的排布公式与绘制端共用同一套假设（间距 ≥ 心宽，否则心会叠在一起）。
void main() {
  group('图层键解析', () {
    test('基键 → 图层键 → 基键 往返一致', () {
      expect(fxInstanceKey('v0.size', 0), 'v0.size'); // 槽位 0 = 老键
      expect(fxInstanceKey('v0.size', 2), 'v0#2.size');
      expect(fxBaseKey('v0#2.size'), 'v0.size');
      expect(fxBaseKey('v0.size'), 'v0.size');
      // 往返
      for (final k in ['v0.x', 'v0.tasselN', 'a13.maxR', 'e5.lamps']) {
        for (final slot in [0, 1, 3, 12]) {
          expect(fxBaseKey(fxInstanceKey(k, slot)), k, reason: '$k @$slot');
        }
      }
    });

    test('槽位不串号（#3 不该匹配 #13）', () {
      expect(fxBaseKey('v0#13.count'), 'v0.count');
      expect(fxBaseKey('v0#3.count'), 'v0.count');
      // 前缀匹配用的标记带点号，所以 #3. 不会命中 #13.
      expect('v0#13.count'.contains('#3.'), isFalse);
      expect('v0#3.count'.contains('#3.'), isTrue);
    });

    test('图层键也能查到声明范围与缺省值（clamp 用得上）', () {
      final base = Fx.param('v0.size')!;
      final inst = Fx.param('v0#5.size');
      expect(inst, isNotNull);
      expect(inst!.min, base.min);
      expect(inst.max, base.max);
      expect(inst.def, base.def);
      expect(Fx.def('v0#5.size'), Fx.def('v0.size'));
      expect(Fx.param('v0#5.没这个参数'), isNull);
    });

    test('shared 参数永远用老键（整组公共项不受图层影响）', () {
      final link = Fx.param('v0.link')!;
      expect(link.shared, isTrue);
      expect(link.isToggle, isTrue);
      expect(fxInstanceKey(link.key, 2, shared: link.shared), 'v0.link');
      // 手线条数 / 牵手结也是整组公共的
      expect(Fx.param('v0.hands')!.shared, isTrue);
      expect(Fx.param('v0.knot')!.shared, isTrue);
      // 而每层各调的是这些
      expect(Fx.param('v0.size')!.shared, isFalse);
      expect(Fx.param('v0.x')!.shared, isFalse);
    });

    test('默认值等于画布上的「改动前」：牵手关着、手 5 条', () {
      expect(Fx.def('v0.link'), 0); // 关 → 老画面
      expect(Fx.def('v0.hands'), 5); // 与旧代码写死的 lineCount = 5 一致
      expect(Fx.def('v0.knot'), 1);
    });
  });

  group('牵手链排布', () {
    test('单颗不缩放（只开一颗爱心时画面与改动前逐帧一致）', () {
      expect(heartChainFit(0), 1.0);
      expect(heartChainFit(1), 1.0);
    });

    test('相邻两颗之间留得下一段手，且整条链不超出屏幕', () {
      for (var n = 2; n <= kMaxVisualLayers; n++) {
        final fit = heartChainFit(n);
        final gap = heartChainGap(n);
        final heartW = 0.66 * fit; // 心宽（屏宽比例），0.66 = 基础心宽
        // 间距必须 > 心宽，否则两颗心压在一起、手没有长度
        expect(gap, greaterThan(heartW), reason: 'n=$n');
        // 整条链（含两端拉向边缘的手）不越界：最外侧心边距 ≥ 0
        final half = gap * (n - 1) / 2 + heartW / 2;
        expect(half, lessThanOrEqualTo(0.5), reason: 'n=$n');
        // 缩放必须随条数单调变小（多了要更小才排得下）
        expect(fit, lessThanOrEqualTo(1.0));
      }
      expect(heartChainFit(3), lessThan(heartChainFit(2)));
      expect(heartChainFit(4), lessThan(heartChainFit(3)));
    });

    test('三颗排成一条线：中间那颗正好在屏幕正中', () {
      final gap = heartChainGap(3);
      const n = 3;
      final xs = [for (var i = 0; i < n; i++) 0.5 + (i - (n - 1) / 2) * gap];
      expect(xs[1], closeTo(0.5, 1e-9));
      expect(xs[0], lessThan(xs[1]));
      expect(xs[2], greaterThan(xs[1]));
      expect(xs[0], greaterThan(0.0));
      expect(xs[2], lessThan(1.0));
    });
  });

  group('图层表序列化', () {
    test('往返一致；坏数据被丢掉而不是整表崩掉', () {
      const l = VisualLayer(effect: 3, slot: 7, enabled: false);
      final back = VisualLayer.fromJson(l.toJson())!;
      expect(back, l);
      expect(back.hashCode, l.hashCode);

      expect(VisualLayer.fromJson({'effect': 0}), isNull); // 缺槽位
      expect(VisualLayer.fromJson({'effect': 'x', 'slot': 1}), isNull);
      expect(VisualLayer.fromJson({'effect': 1, 'slot': -2}), isNull);
      expect(VisualLayer.fromJson('乱七八糟'), isNull);
      // enabled 缺省 = 显示（老数据没有这个键）
      expect(VisualLayer.fromJson({'effect': 1, 'slot': 0})!.enabled, isTrue);
      expect(VisualLayer.fromJson({'effect': 1, 'slot': 0, 'enabled': false}),
          isNot(VisualLayer.fromJson({'effect': 1, 'slot': 0})));
    });

    test('copyWith 只改点名的那一项（槽位恒定，删层不挪别人的参数）', () {
      const l = VisualLayer(effect: 0, slot: 4);
      expect(l.copyWith(enabled: false).slot, 4);
      expect(l.copyWith(effect: 2).slot, 4);
      expect(l.copyWith(effect: 2).enabled, isTrue);
    });
  });
}
