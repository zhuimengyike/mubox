/// 特效**位置参数**的精细化（`lib/effect_catalog.dart` 的 [FxFormat.position]）。
///
/// ## 要解决的是什么
/// 症状：**视觉特效的位置调整精细度不够，会跳过一些想要放置的地方**。
///
/// 根因只有一个：`lib/pages/effect_page.dart` 的 `_divisions()` 按显示格式定档，
/// 而视觉区 `v0~v7` 的「水平位置 / 垂直位置」原来声明成 [FxFormat.percent]
/// ⇒ 滑杆只有 **50 档**、**一格 2%（1080 宽 ≈ 9 个逻辑像素）**，
/// 想放的地方落在档与档之间就永远够不着（`setFx` 本身存原始 double，不丢精度）。
///
/// ## 每条断言在钉什么
/// - ★1：全表里 `position` 格式的参数**恰好是那 16 个**（`v0~v7` 各一对 x/y）
///   —— 多一个少一个都红，防「漏改一个」与「顺手把别的参数也改了」；
/// - ★2：每个位置参数都是 `position` 且范围 `0~1`；
/// - ★3：**缺省值与改动前逐字相同**（水平 0.5 / 垂直 0.47）—— 这是
///   「没动过的特效画面必须逐帧与改动前一致」的前提；
/// - ★4：键名 / 标签 / hint 文案逐字不变（同上，改一个字都是观感事故）；
/// - ★5：负向守卫 —— `percent` 仍是整数百分比，一个都没被带偏；
/// - ★6：读数带**一位小数**（`50.0%` / `50.1%` / `0.0%` / `100.0%`）；
/// - ★7：步长常量 `kFxPosStep = 0.001` ⇒ 滑杆 1000 档（页面那侧的分档断言在
///   `effect_page_position_test.dart`，这里只钉常量本身）；
/// - ★8：`v` 区**全部参数键**（77 个）一个不多一个不少 —— `_p` 换 `_pos` 这件事
///   只许换格式，不许顺手增删/改名任何参数。
///
/// ⚠️ 本文件是纯逻辑（不建 widget 树），页面级接线在 `effect_page_position_test.dart`。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/effect_catalog.dart';

/// 视觉区 8 个特效的 16 个位置参数键 —— **逐字写出来**（故意不程序生成：
/// 生成的话「少改了一个」会跟着少断言，断言就没牙了）。
const Set<String> kPosKeys = {
  'v0.x', 'v0.y',
  'v1.x', 'v1.y',
  'v2.x', 'v2.y',
  'v3.x', 'v3.y',
  'v4.x', 'v4.y',
  'v5.x', 'v5.y',
  'v6.x', 'v6.y',
  'v7.x', 'v7.y',
};

/// `v` 区每个特效的**全部**参数键（键名逐字写死：改动前台账）。
const Map<int, Set<String>> kVParams = {
  0: {
    'v0.x', 'v0.y', 'v0.tint', 'v0.link', 'v0.hands', 'v0.knot', 'v0.size',
    'v0.beat', 'v0.title', 'v0.line', 'v0.jitter', 'v0.tassel', 'v0.tasselN',
    'v0.sparks',
  },
  1: {'v1.x', 'v1.y', 'v1.tint', 'v1.size', 'v1.spin', 'v1.count', 'v1.depth', 'v1.line'},
  2: {
    'v2.x', 'v2.y', 'v2.tint', 'v2.size', 'v2.spin', 'v2.arms', 'v2.count',
    'v2.core', 'v2.spiral', 'v2.tail',
  },
  3: {
    'v3.x', 'v3.y', 'v3.tint', 'v3.size', 'v3.glow', 'v3.speed', 'v3.beat',
    'v3.rings', 'v3.dots', 'v3.veins', 'v3.pulse',
  },
  4: {'v4.x', 'v4.y', 'v4.tint', 'v4.size', 'v4.speed', 'v4.count', 'v4.scatter', 'v4.tail'},
  5: {'v5.x', 'v5.y', 'v5.tint', 'v5.size', 'v5.arms', 'v5.spin', 'v5.wiggle', 'v5.dots', 'v5.poly'},
  6: {'v6.x', 'v6.y', 'v6.tint', 'v6.size', 'v6.spin', 'v6.tilt', 'v6.depth', 'v6.count', 'v6.grid'},
  7: {'v7.x', 'v7.y', 'v7.tint', 'v7.size', 'v7.font', 'v7.wrap', 'v7.dim', 'v7.sub'},
};

void main() {
  // ─────────────────── 一、那 16 个键本身 ───────────────────

  group('★1~★2 位置参数就是那 16 个，且格式/范围都对', () {
    test('★1 全表里 position 格式的参数 == v0~v7 的 x/y（恰好 16 个）', () {
      final actual = <String>{
        for (final e in kFxEffects)
          for (final p in e.params)
            if (p.format == FxFormat.position) p.key,
      };
      expect(actual, kPosKeys,
          reason: '★ 多一个 = 有别的参数被顺手改成 position；'
              '少一个 = 有位置参数漏改了（还是 2% 一格）');
      expect(actual.length, 16, reason: '★ 视觉区 8 个特效 × 2 个位置 = 16');
      for (final k in kPosKeys) {
        expect(Fx.param(k), isNotNull, reason: '$k 必须还在册（键名不许改）');
      }
    });

    test('★2 每个位置参数：format == position，且 min == 0 && max == 1', () {
      for (final k in kPosKeys) {
        final p = Fx.param(k)!;
        expect(p.format, FxFormat.position, reason: k);
        expect(p.min, 0.0, reason: '$k 的下界必须是 0（屏幕比例位置）');
        expect(p.max, 1.0, reason: '$k 的上界必须是 1（屏幕比例位置）');
      }
    });
  });

  // ─────────── 二、缺省值与文案：必须与改动前逐字相同 ───────────

  group('★3~★4 缺省值 / 标签逐字不变（画面逐帧一致的前提）', () {
    test('★3 缺省值：水平全是 0.5、垂直全是 0.47（与改动前一致）', () {
      for (var i = 0; i < 8; i++) {
        expect(Fx.param('v$i.x')!.def, 0.5, reason: 'v$i.x 的缺省值是旧版布局的一半屏宽');
        expect(Fx.param('v$i.y')!.def, 0.47,
            reason: 'v$i.y 的缺省值是旧版布局的 0.47（不是 0.5！改了这个画面就整体下移）');
        // 绘制端读的就是 Fx.def（`fxv()` 的回落），一并钉死
        expect(Fx.def('v$i.x'), 0.5, reason: 'v$i.x 经 Fx.def 读出来也必须是 0.5');
        expect(Fx.def('v$i.y'), 0.47, reason: 'v$i.y 经 Fx.def 读出来也必须是 0.47');
      }
    });

    // `label` 是设置页上**真的会被画出来**的字：`pages/effect_page.dart:394`（滑块
    // 行）、`:452`（−/+ 微调按钮的 title）、`:472` 三处都读它 ⇒ 改了它用户立刻看得见，
    // 所以这条继续钉死。原来还在这里钉过一个 `hint` 字段，但那个字段全仓没有读取点
    // （只有这条用例自己在读），已随字段一并删除 —— 没有任何界面文案因此改变。
    test('★4 标签文案一个字都没改', () {
      for (var i = 0; i < 8; i++) {
        expect(Fx.param('v$i.x')!.label, '水平位置', reason: 'v$i.x 的标签');
        expect(Fx.param('v$i.y')!.label, '垂直位置', reason: 'v$i.y 的标签');
      }
    });
  });

  // ─────────────────── 三、显示格式 ───────────────────

  group('★5~★6 读数与「别的格式没被带偏」', () {
    test('★5 position 的读数带一位小数', () {
      final p = Fx.param('v0.x')!;
      expect(p.display(0.5), '50.0%');
      expect(p.display(0.501), '50.1%');
      expect(p.display(0.001), '0.1%');
      expect(p.display(0.999), '99.9%');
      expect(p.display(0), '0.0%');
      expect(p.display(1), '100.0%');
      // 8 个特效共用同一个 display()，逐个数一遍（防哪天给某一个特效单独写死）
      for (final k in kPosKeys) {
        expect(Fx.param(k)!.display(0.5), '50.0%', reason: k);
      }
    });

    test('★6 负向守卫：别的格式一个都没被带偏（percent 仍是整数百分比）', () {
      // ⚠️ 文档里写「`v0.size` 是 percent」——**与代码不符**：`v0.size` 走的是
      // `_x()` ⇒ [FxFormat.times]（显示 `×0.50`）。这里**按改动前的真实格式钉死**，
      // 而不是去把它"改回" percent：改格式就等于改这一页的显示与缺省语义。
      final size = Fx.param('v0.size')!;
      expect(size.format, FxFormat.times,
          reason: '★ 只许 v*.x / v*.y 换成 position；size 这类倍率参数一个都不许动');
      expect(size.display(0.5), '×0.50', reason: '★ 别的格式的显示一个字都不许改');
      // 真正是 percent 的那些（律动填充 / 氛围大星比例 / 主色↔浅色 / 暖度）逐个核：
      // 它们必须仍是**整数**百分比，不许跟着 position 变成一位小数。
      for (final k in ['r1.fill', 'a1.big', 'a3.big', 'a5.mix', 'a11.mix', 'a2.warm']) {
        final p = Fx.param(k)!;
        expect(p.format, FxFormat.percent, reason: k);
        expect(p.display(0.5), '50%', reason: '$k 的显示必须仍是整数百分比');
      }
      // 位置参数不许留在 percent 里（反过来也钉一次）
      for (final k in kPosKeys) {
        expect(Fx.param(k)!.format, isNot(FxFormat.percent), reason: k);
      }
    });
  });

  // ─────────────── 四、步长常量与「没顺手增删参数」 ───────────────

  group('★7~★8 步长常量 / v 区参数账', () {
    test('★7 kFxPosStep = 0.001 ⇒ 0~1 恰好 1000 档', () {
      expect(kFxPosStep, 0.001,
          reason: '★ 滑杆分档与 −/+ 按钮共用的就是这一个数，别在两边各写一个');
      expect(((1.0 - 0.0) / kFxPosStep).round(), 1000,
          reason: '★ 1000 档 = 0.1% 一格（原来是 50 档 / 2% 一格）');
    });

    test('★8 v 区每个特效的参数键表逐字不变（_p 换 _pos 不许增删改名）', () {
      for (final e in kVParams.entries) {
        final effect = Fx.find('v', e.key);
        expect(effect, isNotNull, reason: 'v${e.key} 必须还在架上');
        final keys = {for (final p in effect!.params) p.key};
        expect(keys, e.value, reason: 'v${e.key} 的参数键表');
      }
      // 全 v 区合计 77 个（14+8+10+11+8+9+9+8）
      expect(Fx.keysOf('v').toSet(),
          {for (final s in kVParams.values) ...s},
          reason: '★ 全表比对：少一个 = 参数被删了，多一个 = 被顺手加了');
      expect(Fx.keysOf('v').length, 77);
    });
  });
}
