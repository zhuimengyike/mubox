/// `showCustomColorPicker` 那个弹层 —— **粘贴色卡 → 颜色/名称立刻跟着变**。
///
/// ## 要解决的是什么
/// 症状：**要新建抖音视频里那种颜色的时候不知道该怎么调，需要能输入某种信息直接获得**。
///
/// 模块 `lib/color_input.dart` 单独有 28 项纯逻辑断言（`color_input_test.dart`）；
/// **本文断言的是"接线"**：解析结果有没有真的推到滑杆 / 预览 / 回显 / 名称框，
/// 以及点「创建」拿到的 `AccentScheme` 对不对。
///
/// ## ⚠️ 两条本仓的量具纪律（沿用 `song_search_sheet_test.dart`）
/// 1. **禁 `pumpAndSettle`**（本仓页面挂着常驻动画会一直等），一律固定时长 `pump`；
/// 2. 颜色比较**一律用容差**：解析出来的颜色要过一趟 HSV（滑杆状态就是 HSV），
///    `HSVColor.fromColor(...).toColor()` 有取整误差 ⇒ 写 `==` 会随机红。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/color_input.dart';
import 'package:mu_box_phone/theme.dart';
import 'package:mu_box_phone/widgets/custom_color_sheet.dart';

/// 逻辑视口钉死（400×900：比默认的 800×600 高，弹层内容才不会一上来就溢出）。
void _setSurface(WidgetTester tester, [Size logical = const Size(400, 900)]) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.reset);
}

/// 走几拍稳定状态（不用 pumpAndSettle，见文件头纪律 1）。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 120));
  }
}

/// 弹层的返回值（没点「创建」就是 null）。
AccentScheme? _result;

/// 挂一个按钮，点它 = 打开真弹层（走 `showCustomColorPicker` 这条真入口）。
Future<void> _openSheet(WidgetTester tester,
    [Size surface = const Size(400, 900)]) async {
  _setSurface(tester, surface);
  _result = null;
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: TextButton(
              onPressed: () async {
                _result = await showCustomColorPicker(ctx);
              },
              child: const Text('开弹层'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('开弹层'));
  await _settle(tester);
  expect(find.byKey(kCustomColorPanelKey), findsOneWidget, reason: '前置：弹层开了');
}

/// 往输入框灌文本（走真 `TextField.onChanged`）。
Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byKey(kCustomColorInputKey), text);
  await tester.pump();
}

/// 颜色按 ARGB 比，**允许容差**（HSV 往返有取整误差，见文件头纪律 2）。
void _expectNear(Color got, int wantArgb, {int tol = 2, String? reason}) {
  final g = got.toARGB32();
  for (final shift in [16, 8, 0]) {
    final d = (((g >> shift) & 0xFF) - ((wantArgb >> shift) & 0xFF)).abs();
    expect(d, lessThanOrEqualTo(tol),
        reason: '${reason ?? ''} 通道@$shift：实际 #${g.toRadixString(16)} '
            '期望 #${wantArgb.toRadixString(16)}');
  }
}

Color _previewColor(WidgetTester tester) {
  final box = tester.widget<Container>(find.byKey(kCustomColorPreviewKey));
  final deco = box.decoration! as BoxDecoration;
  return (deco.gradient! as LinearGradient).colors.first;
}

List<double> _sliderValues(WidgetTester tester) => [
      for (final s in tester.widgetList<Slider>(find.byType(Slider))) s.value,
    ];

String _nameText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(kCustomColorNameKey)).controller!.text;

String _inputText(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(kCustomColorInputKey)).controller!.text;

String? _hint(WidgetTester tester) {
  final f = find.byKey(kCustomColorHintKey);
  if (f.evaluate().isEmpty) return null;
  return tester.widget<Text>(f).data;
}

String _echo(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(kCustomColorEchoKey)).data!;

Rect _r(WidgetTester tester, Finder f) => tester.getRect(f);

/// 抖音三/四行色卡（用户存的就是这种截图）。
const String _cardNeon = 'COLOR SHARING | 配色分享\n霓虹蓝\n#00F0FF\nCMYK\n60 0 15 0';
const String _cardPurple = '电光紫\n#9D00FF\nCMYK\n70 80 0 0';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ─────────────── 一、结构：原来那些东西一个都不许少 ───────────────

  testWidgets('★1 弹层结构：输入框 / 粘贴 / 预览 / 三滑杆 / 回显 / 名称 / 取消 / 创建 都在',
      (tester) async {
    await _openSheet(tester);

    expect(find.byKey(kCustomColorInputKey), findsOneWidget, reason: '新的输入/粘贴框');
    expect(find.byKey(kCustomColorPasteKey), findsOneWidget, reason: '「粘贴」按钮');
    expect(find.byKey(kCustomColorPreviewKey), findsOneWidget, reason: '圆形预览（原有）');
    expect(find.byType(Slider), findsNWidgets(3), reason: '色相/饱和度/明度三滑杆（原有）');
    for (final l in ['色相', '饱和度', '明度']) {
      expect(find.text(l), findsOneWidget, reason: '「$l」滑杆标签（原有）');
    }
    expect(find.byKey(kCustomColorNameKey), findsOneWidget, reason: '名称框（原有）');
    expect(find.text('取消'), findsOneWidget, reason: '取消（原有）');
    expect(find.text('创建'), findsOneWidget, reason: '创建（原有）');
    expect(find.text('自定义主题色'), findsOneWidget, reason: '标题（原有）');
    expect(_echo(tester), contains('#'), reason: '回显行');

    // 缺省状态 = 改动前那三根滑杆的初值，且不显示任何抱怨
    expect(_sliderValues(tester), [220.0, 0.7, 0.9], reason: '★ 初值必须还是 220/0.7/0.9');
    expect(_hint(tester), isNull,
        reason: '★ 刚打开时输入框是空的 ⇒ 不许显示"没认出来"（一开就报丧是噪音）');
    expect(_nameText(tester), isEmpty);
  });

  testWidgets('★2 版式：原有元素的相对间距一个像素都没动（带改动前的量具金标）',
      (tester) async {
    // 「改动前」的数字是用临时探针在**未改动的代码**上量出来的（400×900，dpr 1）：
    //   preview 64×64；slider0→slider1 = 73；slider1→slider2 = 73；
    //   「色相」标签顶 → 它的滑杆顶 = 25。
    // 插进去的输入区是**一整块**，只允许它把自己所在的那一处间距撑开。
    await _openSheet(tester);

    final preview = _r(tester, find.byKey(kCustomColorPreviewKey));
    expect(preview.width, 64, reason: '★ 预览圆球尺寸不许变');
    expect(preview.height, 64, reason: '★ 预览圆球尺寸不许变');

    final sliders = find.byType(Slider);
    final s0 = _r(tester, sliders.at(0));
    final s1 = _r(tester, sliders.at(1));
    final s2 = _r(tester, sliders.at(2));
    expect(s1.top - s0.top, 73, reason: '★ 色相→饱和度 的间距（改动前 = 73）');
    expect(s2.top - s1.top, 73, reason: '★ 饱和度→明度 的间距（改动前 = 73）');
    expect(s0.top - _r(tester, find.text('色相')).top, 25,
        reason: '★ 标签→滑杆 的间距（改动前 = 25）');

    // 顺序：标题 → 输入区 → 预览 → 滑杆 → 回显 → 名称 → 按钮
    final input = _r(tester, find.byKey(kCustomColorInputKey));
    final echo = _r(tester, find.byKey(kCustomColorEchoKey));
    final name = _r(tester, find.byKey(kCustomColorNameKey));
    final create = _r(tester, find.text('创建'));
    expect(input.bottom, lessThanOrEqualTo(preview.top),
        reason: '★ 输入区在预览**上方**（"在上面加一块输入区"）');
    expect(preview.bottom, lessThanOrEqualTo(s0.top));
    expect(s2.bottom, lessThanOrEqualTo(echo.top), reason: '回显行在滑杆下方');
    expect(echo.bottom, lessThanOrEqualTo(name.top), reason: '名称框在回显下方');
    expect(name.bottom, lessThanOrEqualTo(create.top), reason: '按钮在最下（原有顺序）');
  });

  // ─────────────── 二、核心：粘一张抖音色卡 ───────────────

  testWidgets('★3 灌三行色卡 ⇒ 滑杆/预览/回显/名称 全部跟着变', (tester) async {
    await _openSheet(tester);
    final before = _sliderValues(tester);

    await _type(tester, _cardNeon);

    // ① 三根滑杆同步到 #00F0FF（HSV = 184°, 1.0, 1.0）
    final v = _sliderValues(tester);
    expect(v, isNot(before), reason: '★ 滑杆必须真的动了');
    expect(v[0], closeTo(183.5, 1.5), reason: '★ 色相 = #00F0FF 的 H（≈184°）');
    expect(v[1], closeTo(1.0, 0.01), reason: '★ 饱和度 = 1.0');
    expect(v[2], closeTo(1.0, 0.01), reason: '★ 明度 = 1.0');

    // ② 预览圆球的主色 = 卡上的 HEX（容差比）
    _expectNear(_previewColor(tester), 0xFF00F0FF, reason: '★ 预览');

    // ③ 名称框被自动填成色卡上的名字（标题行 "COLOR SHARING | 配色分享" 不算）
    expect(_nameText(tester), '霓虹蓝', reason: '★ 名称自动填 = 色卡上的名字');

    // ④ 回显行：HEX · RGB · HSL（三段，顺序不变）
    final echo = _echo(tester);
    expect(echo, contains('#00F0FF'), reason: '回显 HEX：$echo');
    expect(echo, contains('RGB 0,240,255'), reason: '回显 RGB：$echo');
    expect(echo, contains('HSL 184° 100% 50%'), reason: '回显 HSL：$echo');
    expect(echo, isNot(contains('CMYK')),
        reason: '★ 回显里不许出现 CMYK（屏幕反算 100 6 0 0 与卡片印的 60 0 15 0 '
            '并排 = 两个互相矛盾的 CMYK，用户会以为 App 认错了）：$echo');
    expect(_hint(tester), isNull, reason: '卡上有 HEX ⇒ 不该弹 CMYK 那句提醒');

    // ⑤ 拖滑杆 ⇒ 回显跟着走（不是一次性快照）
    await tester.drag(find.byType(Slider).first, const Offset(-60, 0));
    await tester.pump();
    expect(_sliderValues(tester)[0], isNot(closeTo(183.5, 0.01)));
    expect(_echo(tester), isNot(echo), reason: '★ 拖滑杆后回显必须重新算');
  });

  testWidgets('★4 点「创建」⇒ 返回的 AccentScheme.name / primary 就是色卡上那套',
      (tester) async {
    await _openSheet(tester);
    await _type(tester, _cardNeon);

    await tester.tap(find.text('创建'));
    await _settle(tester);

    expect(_result, isNotNull, reason: '★ 必须真的返回一套方案（不是 null）');
    expect(_result!.name, '霓虹蓝');
    _expectNear(_result!.primary, 0xFF00F0FF, reason: '★ 返回的 primary');
    // 浅色 = 主色向白混 50%（本弹层既有公式，逐项不变）
    _expectNear(_result!.light, Color.lerp(const Color(0xFF00F0FF), Colors.white, 0.5)!
        .toARGB32(), reason: '★ 浅色仍是"主色向白混 50%"');
    expect(find.byKey(kCustomColorPanelKey), findsNothing, reason: '弹层已关');
  });

  testWidgets('★5 只有 CMYK 的卡 ⇒ 认出来 + 如实提示「可能对不上」', (tester) async {
    await _openSheet(tester);
    await _type(tester, '霓虹蓝\nCMYK\n60 0 15 0');

    _expectNear(_previewColor(tester), 0xFF66FFD9, reason: '★ 朴素反算 #66FFD9');
    expect(_nameText(tester), '霓虹蓝');
    final hint = _hint(tester);
    expect(hint, isNotNull, reason: '★ 只靠 CMYK 认出来必须有提示');
    expect(hint, contains('印刷色'), reason: '★ 不许粉饰：必须点明 CMYK 是印刷色');
    expect(hint, contains('#66FFD9'), reason: '提示里要给出反算值');
    expect(hint, contains('对不上'), reason: '★ 不许粉饰：必须说和屏幕色卡可能对不上');
    // ★ 回显行里**不许**再出现 CMYK：屏幕上这个颜色的朴素反算是 `100 6 0 0`，
    //   而卡片上印的是 `60 0 15 0` —— 两个 CMYK 并排 = 用户会以为 App 认错了。
    //   回显保留最初规定的三段：`#HEX · RGB r,g,b · HSL h° s% l%`，顺序不变。
    expect(_echo(tester), isNot(contains('CMYK')),
        reason: '★ 回显只留 HEX · RGB · HSL 三段（rgbToCmyk 仍在 color_input.dart 里导出，'
            '只是不再进回显行）');
    // 逐字核那三段（顺序也不许变）：拿预览色现算一遍期望串，不是"看起来像"
    final c = _previewColor(tester);
    final argb = c.toARGB32();
    final hsl = HSLColor.fromColor(c);
    expect(
        _echo(tester),
        '${hexOf(c)} · '
        'RGB ${(argb >> 16) & 0xFF},${(argb >> 8) & 0xFF},${argb & 0xFF} · '
        'HSL ${hsl.hue.round()}° ${(hsl.saturation * 100).round()}% '
        '${(hsl.lightness * 100).round()}%',
        reason: '★ 回显 = 最初规定的三段，逐字一致');
  });

  testWidgets('★6 认不出来 ⇒ 一句灰提示、不弹错、**不清掉已经拖好的颜色**',
      (tester) async {
    await _openSheet(tester);
    // 先拖出一个用户自己的颜色（这一步模拟"他已经调好了"）
    await tester.drag(find.byType(Slider).first, const Offset(40, 0));
    await tester.pump();
    final keptSliders = _sliderValues(tester);
    final keptColor = _previewColor(tester);
    expect(_hint(tester), isNull, reason: '前置：拖滑杆不该产生任何提示');

    // 再灌一段认不出来的东西
    await _type(tester, '这是一段胡说八道');
    expect(_hint(tester), '没认出来，可以直接拖下面的滑杆',
        reason: '★ 文案要一模一样（用户要的就是这句话）');
    expect(_sliderValues(tester), keptSliders,
        reason: '★ 认不出来时**不许动**滑杆（颜色是用户拖好的）');
    _expectNear(_previewColor(tester), keptColor.toARGB32(), tol: 0,
        reason: '★ 预览也不许被清掉');
    expect(tester.takeException(), isNull, reason: '★ 不许弹错/抛异常');

    // 负向对照：换一张真色卡 ⇒ 同一个输入框立刻能认（证明上面那条红的是"认不出"，
    // 不是"输入框坏了"）
    await _type(tester, _cardPurple);
    _expectNear(_previewColor(tester), 0xFF9D00FF, reason: '★ 换成真色卡必须立刻认出来');
    expect(_hint(tester), isNull);
  });

  testWidgets('★7 名称自动填的三条规矩：空则填 / 自动值可覆盖 / 用户手改过就不许覆盖',
      (tester) async {
    await _openSheet(tester);

    await _type(tester, _cardNeon);
    expect(_nameText(tester), '霓虹蓝', reason: '① 名称框空着 ⇒ 自动填');

    await _type(tester, _cardPurple);
    expect(_nameText(tester), '电光紫',
        reason: '② 上一次填进去的**就是自动值** ⇒ 允许被新卡覆盖（否则粘第二张卡名字永远是旧的）');

    // 用户手改
    await tester.enterText(find.byKey(kCustomColorNameKey), '我的蓝');
    await tester.pump();
    await _type(tester, _cardNeon);
    expect(_nameText(tester), '我的蓝',
        reason: '★ ③ 用户手改过 ⇒ 再粘色卡不许覆盖（否则他改的名字被冲掉）');
    // 颜色该变还是要变（只保护名字，不保护颜色）
    _expectNear(_previewColor(tester), 0xFF00F0FF, reason: '颜色照常解析');

    // 用户把名字清空 ⇒ 回到"空则填"
    await tester.enterText(find.byKey(kCustomColorNameKey), '');
    await tester.pump();
    await _type(tester, _cardPurple);
    expect(_nameText(tester), '电光紫', reason: '清空之后又该自动填了');
  });

  testWidgets('★8 「粘贴」按钮：读剪贴板 ⇒ 填进输入框 + 立刻解析 + 自动填名',
      (tester) async {
    // 剪贴板是平台通道（`SystemChannels.platform` 的 Clipboard.getData）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': _cardNeon};
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    await _openSheet(tester);
    await tester.tap(find.byKey(kCustomColorPasteKey));
    await _settle(tester);

    expect(_inputText(tester), _cardNeon, reason: '★ 剪贴板内容进了输入框');
    _expectNear(_previewColor(tester), 0xFF00F0FF, reason: '★ 粘贴后立刻解析（不用再点一下）');
    expect(_nameText(tester), '霓虹蓝');
    expect(_sliderValues(tester)[0], closeTo(183.5, 1.5));

    // 负向：剪贴板空 ⇒ 说一句话，别点了没反应，也别把输入框/颜色洗掉
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': ''};
      return null;
    });
    await tester.tap(find.byKey(kCustomColorPasteKey));
    await _settle(tester);
    expect(_hint(tester), contains('剪贴板'), reason: '★ 空剪贴板要说话');
    expect(_inputText(tester), _cardNeon, reason: '★ 但不许把用户已有的输入洗掉');
    _expectNear(_previewColor(tester), 0xFF00F0FF, reason: '★ 也不许把已解析出的颜色清掉');
  });

  // ─────────────── 三、键盘避让（不许溢出） ───────────────

  testWidgets('★9 键盘顶上来（inset 300）⇒ 不溢出 + 内容可滚 + 「创建」够得着',
      (tester) async {
    await _openSheet(tester);
    await _type(tester, _cardNeon);

    // 键盘弹出（真机上这是 viewInsets.bottom）
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));

    expect(tester.takeException(), isNull,
        reason: '★ 不许 RenderFlex overflow（改动前弹层内容 517 + 键盘 300 刚好塞得下 900，'
            '加了输入区之后必然超 —— 所以外面必须有那个滚动壳）');

    // **量具自证**：先证明"内容 + 键盘 > 屏幕"，否则上面那条断言是恒真的假绿
    final inner = tester.getSize(find
        .descendant(
          of: find.byKey(kCustomColorScrollKey),
          matching: find.byType(Column),
        )
        .first);
    expect(inner.height + 300, greaterThan(900),
        reason: '★ 内容 ${inner.height} + 键盘 300 > 屏幕 900 ⇒ 没有滚动壳就一定溢出');

    // 滚动壳真的能滚（maxScrollExtent > 0）
    // ⚠️ `.first` 是必须的：两个 TextField 内部**各自**还有一个 Scrollable
    //    （`EditableText` 自带），裸 find 会报 "Too many elements"。
    //    树序上最外层那个（SingleChildScrollView 自己的）排第一。
    final pos = tester
        .state<ScrollableState>(find
            .descendant(
              of: find.byKey(kCustomColorScrollKey),
              matching: find.byType(Scrollable),
            )
            .first)
        .position;
    expect(pos.maxScrollExtent, greaterThan(0),
        reason: '★ 键盘占掉 300 之后内容超出一屏 ⇒ 必须能滚，否则「创建」永远够不着');

    // 滚到底 ⇒ 「创建」点得到，弹层带着结果关掉
    await tester.ensureVisible(find.text('创建'));
    await tester.pump();
    await tester.tap(find.text('创建'));
    await _settle(tester);
    expect(_result?.name, '霓虹蓝',
        reason: '★ 键盘开着的时候也要能把颜色建出来');
    expect(find.byKey(kCustomColorPanelKey), findsNothing);
  });

  testWidgets('★10 键盘收回去 ⇒ 弹层立刻缩回原样（滚动壳在够用时不许留下空隙）',
      (tester) async {
    await _openSheet(tester);
    final h0 = _r(tester, find.byKey(kCustomColorPanelKey)).height;

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final h1 = _r(tester, find.byKey(kCustomColorPanelKey)).height;
    expect(h1, greaterThan(h0), reason: '键盘顶上来 ⇒ 弹层要让出位置');

    tester.view.viewInsets = FakeViewPadding.zero;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 120));
    final h2 = _r(tester, find.byKey(kCustomColorPanelKey)).height;
    expect(h2, h0,
        reason: '★ 键盘收回去必须与"从没弹过键盘"逐像素同高（滚动壳用不着时不留白）');
  });
}
