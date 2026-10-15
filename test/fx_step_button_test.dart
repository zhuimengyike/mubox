/// `lib/widgets/fx_step_button.dart` 的 −/+ 微调按钮（**组件级**）。
///
/// ## 每条断言在钉什么
/// - ★1 点一下 = **恰好挪一格**（`clampRound(value + delta)`），两半都测（+/−）；
/// - ★2 长按累计**不许出脏值**（`0.3 + 0.001×3` 必须正好是 `0.303`，
///   不是 `0.30000000000000004`）—— 这条是「取整再 clamp」的断言；
/// - ★3 按住不放 = **连续挪**：`onLongPressStart` 起表、60ms 一拍、每拍一格
///   （逐拍记账，多一拍少一拍都红）；松手 `onLongPressEnd` ⇒ **停表**；
/// - ★4 **到边界停**：顶到上界就停住、按钮置灰（`onTap == null` + 图标变白 24）、
///   按住不放也**不许再空转回调**；下界对称测一遍；
/// - ★5 🔴 **中途把树拆掉之后定时器不再回调**（防僵尸表）。⚠️ 这条的牙是
///   **框架自己那条断言**：定时器没在 `dispose()` 里取消的话，
///   用例结束会报 `A Timer is still pending even after the widget tree was disposed`；
/// - ★6 `onLongPressCancel` 也要停表（侧滑抢走手势时那一路）；
/// - ★7 外观：触摸区 **48×48**（Material 最小触摸目标 —— 36 时"近失手"会落到滑杆
///   最右/最左端、把值甩到 1.0/0.0，断言在 `effect_page_position_test.dart` ★5）、
///   图标 18、可用 `white70` / 置灰 `white24`。
///
/// ⚠️ 本文件只测**组件自己**（值由宿主持有并回传，模拟设置页那条「父层传值」的路）；
/// 真页面上的接线（1000 档 + 写进哪个键）在 `effect_page_position_test.dart`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/effect_catalog.dart';
import 'package:mu_box_phone/widgets/fx_step_button.dart';

const ValueKey<String> _kUp = ValueKey<String>('t_up');
const ValueKey<String> _kDown = ValueKey<String>('t_down');

/// 宿主：**真正持有值 + 真正 setState 重建**（父层是唯一真相源，见组件文档）。
class _Host extends StatefulWidget {
  const _Host({required this.initial});

  final double initial;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late double value = widget.initial;

  /// 回调记账：次数 + 每次收到的值（★2/★3/★4 都靠它）。
  int calls = 0;
  final List<double> seen = [];

  void _onChanged(double v) {
    calls++;
    seen.add(v);
    setState(() => value = v);
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            FxStepButton(
              key: _kDown,
              icon: Icons.remove,
              delta: -kFxPosStep,
              value: value,
              min: 0,
              max: 1,
              onChanged: _onChanged,
            ),
            FxStepButton(
              key: _kUp,
              icon: Icons.add,
              delta: kFxPosStep,
              value: value,
              min: 0,
              max: 1,
              onChanged: _onChanged,
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _mount(WidgetTester tester, {required double initial}) async {
  await tester.pumpWidget(_Host(initial: initial));
  await tester.pump();
}

_HostState _host(WidgetTester tester) => tester.state<_HostState>(find.byType(_Host));

Icon _iconOf(WidgetTester tester, Key key) => tester.widget<Icon>(
    find.descendant(of: find.byKey(key), matching: find.byType(Icon)));

InkWell _inkOf(WidgetTester tester, Key key) => tester.widget<InkWell>(
    find.descendant(of: find.byKey(key), matching: find.byType(InkWell)));

void main() {
  // ───────────────────── 一、点一下 ─────────────────────

  group('★1~★2 点一下 = 挪一格，且不许出脏值', () {
    testWidgets('★1 点「+」⇒ 0.5 → 0.501；再点「−」⇒ 回到 0.5', (tester) async {
      await _mount(tester, initial: 0.5);
      expect(_host(tester).value, 0.5, reason: '前置：宿主从 0.5 起步');

      await tester.tap(find.byKey(_kUp));
      await tester.pump();
      expect(_host(tester).value, 0.501,
          reason: '★ 点一下恰好一格（kFxPosStep = 0.001）');
      expect(_host(tester).seen, [0.501], reason: '回调也只该发生一次');

      await tester.tap(find.byKey(_kDown));
      await tester.pump();
      expect(_host(tester).value, 0.5, reason: '★ 反向一格回到 0.5');
      expect(_host(tester).seen, [0.501, 0.5]);
    });

    testWidgets('★2 长按累计的取整：0.3 连点 3 下 ⇒ 正好 0.303（不是 0.30000000000000004）',
        (tester) async {
      await _mount(tester, initial: 0.3);
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(_kUp));
        await tester.pump();
      }
      expect(_host(tester).value, 0.303,
          reason: '★ 每挪一格都按 3 位小数取整 ⇒ 累计不出浮点脏值');
      expect(_host(tester).value.toString(), '0.303',
          reason: '★ 落盘/回显用的就是这个值，别带一串 9');
      expect(_host(tester).seen, [0.301, 0.302, 0.303]);
    });
  });

  // ───────────────────── 二、长按连发 ─────────────────────

  group('★3 按住不放 = 连续挪；松开就停', () {
    testWidgets('★3 长按 60ms 一拍逐拍挪，松手后 600ms 一格格都不许再动', (tester) async {
      await _mount(tester, initial: 0.5);
      final g = await tester.startGesture(tester.getCenter(find.byKey(_kUp)));

      // 越过长按门槛（kLongPressTimeout = 500ms）⇒ onLongPressStart 起表
      await tester.pump(const Duration(milliseconds: 520));
      await tester.pump(const Duration(milliseconds: 60)); // 第 1 拍
      expect(_host(tester).value, 0.501,
          reason: '★ 按下不放之后第一拍就该挪一格（起表了）');

      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(_host(tester).value, closeTo(0.506, 1e-9),
          reason: '★ 再 5 拍 = 再挪 5 格（每拍恰好一格）');
      expect(_host(tester).seen, [0.501, 0.502, 0.503, 0.504, 0.505, 0.506],
          reason: '★ 逐拍记账：多一拍少一拍都红（连发不能一次跳好几格）');

      await g.up();
      await tester.pump();
      final afterUp = _host(tester).value;
      final callsAtUp = _host(tester).calls;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(_host(tester).value, afterUp, reason: '★ 松手必须停表');
      expect(_host(tester).calls, callsAtUp,
          reason: '★ 松手后 600ms 里一格都不许再回调（表还在跑就是僵尸）');
      // 负向对照：长按这条路**不该**再叠一次 onTap（识别器已被长按赢走）
      expect(_host(tester).calls, 6,
          reason: '★ 长按这一串回调恰好 6 次：松手那一下不许再被当成一次点击');
    });
  });

  // ───────────────────── 三、边界 ─────────────────────

  group('★4 到边界停表 + 置灰', () {
    testWidgets('★4a 上界：顶到 1.0 停住、按钮置灰、按住不放也不许再空转', (tester) async {
      await _mount(tester, initial: 0.998);
      final g = await tester.startGesture(tester.getCenter(find.byKey(_kUp)));
      await tester.pump(const Duration(milliseconds: 520));
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(_host(tester).value, 1.0, reason: '★ 顶到上界就停住，不许越过 max');
      expect(_host(tester).seen, [0.999, 1.0],
          reason: '★ 只挪了该挪的两格（0.998 → 0.999 → 1.0）');

      final callsAtLimit = _host(tester).calls;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(_host(tester).value, 1.0);
      expect(_host(tester).calls, callsAtLimit,
          reason: '★ 到边界后那张连发表必须停 —— 别让用户按住不放一直空转');

      // 置灰：图标变白 24、onTap 为 null（点不动）
      expect(_inkOf(tester, _kUp).onTap, isNull, reason: '★ 到上界后「+」必须点不动');
      expect(_iconOf(tester, _kUp).color, Colors.white24, reason: '★ 置灰的观感');
      expect(_inkOf(tester, _kDown).onTap, isNotNull, reason: '反方向仍要能用');
      expect(_iconOf(tester, _kDown).color, Colors.white70);

      await tester.tap(find.byKey(_kUp));
      await tester.pump();
      expect(_host(tester).calls, callsAtLimit,
          reason: '★ 置灰的按钮点一下也不许回调（不是"回调了但被 clamp 回去"）');

      await g.up();
      await tester.pump();
    });

    testWidgets('★4b 下界（对称）：顶到 0.0 停住，「−」置灰', (tester) async {
      await _mount(tester, initial: 0.002);
      await tester.tap(find.byKey(_kDown));
      await tester.pump();
      await tester.tap(find.byKey(_kDown));
      await tester.pump();
      expect(_host(tester).value, 0.0, reason: '★ 下界也是 0，不许变负');
      expect(_host(tester).seen, [0.001, 0.0]);

      await tester.tap(find.byKey(_kDown));
      await tester.pump();
      expect(_host(tester).calls, 2, reason: '★ 到了 0 之后「−」点一下也不许回调');
      expect(_inkOf(tester, _kDown).onTap, isNull);
      expect(_iconOf(tester, _kDown).color, Colors.white24);
      expect(_inkOf(tester, _kUp).onTap, isNotNull);
    });
  });

  // ───────────────── 四、僵尸定时器 / 手势取消 ─────────────────

  group('★5~★6 表只能活到该活的时候', () {
    testWidgets('★5 ★ 连发中把整棵树拆掉 ⇒ 定时器不再回调（dispose 必须取消）',
        (tester) async {
      await _mount(tester, initial: 0.5);
      final st = _host(tester); // 拆树前抓住 State（拆完 find 就找不到了）
      final g = await tester.startGesture(tester.getCenter(find.byKey(_kUp)));
      await tester.pump(const Duration(milliseconds: 520));
      await tester.pump(const Duration(milliseconds: 60));
      expect(st.value, 0.501, reason: '前置：表确实在跑');
      final callsBefore = st.calls;

      // 表还在跑的时候把树拆掉（模拟"用户按住不放时退出了这一页"）
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(st.calls, callsBefore,
          reason: '★ 树没了之后一格都不许再回调');
      // ⚠️ 真正的牙在下一条：`dispose()` 没取消定时器的话，用例结束会报
      // `A Timer is still pending even after the widget tree was disposed`
      // （框架自己抛，收在这里也是红的）。负向对照已实测。
      await g.up();
      await tester.pump();
    });

    testWidgets('★6 onLongPressCancel 也要停表（手势被抢走的那一路）', (tester) async {
      await _mount(tester, initial: 0.5);
      final g = await tester.startGesture(tester.getCenter(find.byKey(_kUp)));
      await tester.pump(const Duration(milliseconds: 520));
      await tester.pump(const Duration(milliseconds: 60));
      expect(_host(tester).value, 0.501, reason: '前置：表在跑');

      await g.cancel(); // 侧滑 / 外层滚动把长按抢走
      await tester.pump();
      final callsAtCancel = _host(tester).calls;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
      expect(_host(tester).calls, callsAtCancel, reason: '★ 取消之后必须停表');
      expect(_host(tester).value, 0.501);
    });
  });

  // ───────────────────── 五、外观 ─────────────────────

  group('★7 外观（触摸区 / 图标 / 颜色）', () {
    testWidgets('★7 触摸区 48×48、图标 18、可用白 70', (tester) async {
      await _mount(tester, initial: 0.5);
      for (final k in [_kUp, _kDown]) {
        final size = tester.getSize(find.byKey(k));
        expect(size.width, 48, reason: '$k 的触摸区宽（= Material 最小触摸目标）');
        expect(size.height, 48, reason: '$k 的触摸区高（与 Slider 默认的 48 齐平 ⇒ 行高不变）');
        expect(_iconOf(tester, k).size, 18, reason: '$k 的图标大小');
        expect(_iconOf(tester, k).color, Colors.white70, reason: '$k 的图标颜色');
      }
      expect(_iconOf(tester, _kUp).icon, Icons.add);
      expect(_iconOf(tester, _kDown).icon, Icons.remove);
    });
  });
}
