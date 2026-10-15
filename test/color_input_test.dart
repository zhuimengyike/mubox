/// `lib/color_input.dart` 的**整段粘贴识别**（抖音色卡）+ HEX / RGB / CMYK 手输。
///
/// ## 要解决的是什么
/// 症状：**要新建抖音视频里那种颜色的时候不知道该怎么调，需要能输入某种信息直接获得**。
///
/// 手头存了一批抖音「配色分享」截图，色卡三行/四行：
/// ```
/// 霓虹蓝          电光紫
/// #00F0FF         #9D00FF
/// CMYK            CMYK
/// 60 0 15 0       70 80 0 0
/// ```
/// 还有标题行噪音 `COLOR SHARING | 配色分享`。原来只能拖 HSV 三滑杆，调不出来。
///
/// ## 每条断言都在钉什么
/// - ★1~★6：HEX 六种写法（含 3 位短写、8 位 ARGB、裸 6 位、大小写）；
/// - ★7~★9：RGB 四种写法 + **「RGB 那三个数字不许被吃成 HEX」** 的正/负一对；
/// - ★10~★13：CMYK 四种写法（含**色卡的换行形状**）+ k=100 的除零边界；
/// - ★14~★16：名称识别（汉字优先 / 去噪 / 标签行与超长行不算）；
/// - ★17~★20：优先级 HEX > RGB > CMYK + **CMYK 的 note 不许粉饰**；
/// - ★21~★24：**任何输入都不许抛异常**（空串 / 纯中文 / 纯数字 / 超长垃圾串）；
/// - ★25~★27：`rgbToCmyk` 反向换算 + 与 `_cmykToColor` 的往返一致性。
/// - ★28~★30：**名称与色值写在同一行**（`电光紫 #9D00FF` / `霓虹蓝 #00F0FF CMYK 60 0 15 0`）
///   —— 早先的写法是「整行任意位置出现色值 ⇒ 整行作废」，那会让**颜色认得出、名字认不出**；
///   现在先把色值片段摘掉再按原门槛判，反向守卫是「整行都是色值 ⇒ 摘完为空 ⇒ 仍不是名字」。
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/color_input.dart';
import 'package:mu_box_phone/theme.dart';

/// 断颜色用 ARGB 整数比（`Color ==` 比的是颜色空间+分量，别拿它当断言）。
int _argb(Color? c) => c!.toARGB32();

void main() {
  // ─────────────────────────── 一、HEX ───────────────────────────

  group('★1~★6 HEX：六种写法', () {
    test('★1 带 # 的 6 位 / 裸 6 位 / 0x 前缀（大小写不敏感）', () {
      for (final s in [
        '#00F0FF',
        '00F0FF',
        '0x00F0FF',
        '0X00F0FF',
        '#00f0ff',
        '0x00f0ff',
        '  00F0FF  ',
      ]) {
        final p = parseColorInput(s);
        expect(p.kind, ColorInputKind.hex, reason: '「$s」应该是 HEX');
        expect(_argb(p.color), 0xFF00F0FF, reason: '「$s」的色值');
        expect(p.note, isNull, reason: 'HEX 是无损的 ⇒ 没什么要提醒的（note 必须为空）');
      }
    });

    test('★2 3 位短写：每位翻倍', () {
      expect(_argb(parseColorInput('#0FF').color), 0xFF00FFFF);
      expect(_argb(parseColorInput('0FF').color), 0xFF00FFFF);
      expect(_argb(parseColorInput('#abc').color), 0xFFAABBCC);
      expect(_argb(parseColorInput('f0f').color), 0xFFFF00FF);
      for (final s in ['#0FF', '0FF', '#abc']) {
        expect(parseColorInput(s).kind, ColorInputKind.hex, reason: '「$s」');
      }
    });

    test('★3 8 位 = ARGB（不透明与半透明都认）', () {
      for (final s in ['#FF00F0FF', '0xFF00F0FF', 'FF00F0FF']) {
        expect(_argb(parseColorInput(s).color), 0xFF00F0FF,
            reason: '「$s」= 不透明的 #00F0FF');
      }
      expect(_argb(parseColorInput('#8000F0FF').color), 0x8000F0FF,
          reason: '8 位的头两位是 alpha，别丢掉');
    });

    test('★4 整段粘贴：三行色卡（名称 + HEX + CMYK）', () {
      final p = parseColorInput('霓虹蓝\n#00F0FF\nCMYK\n60 0 15 0');
      expect(p.kind, ColorInputKind.hex,
          reason: '★ 卡上 HEX 与 CMYK 同时存在 ⇒ 必须取 HEX（CMYK 只是印刷近似值）');
      expect(_argb(p.color), 0xFF00F0FF);
      expect(p.name, '霓虹蓝');
      expect(p.note, isNull, reason: '有 HEX 就不该弹 CMYK 那句提醒');
    });

    test('★5 整段粘贴：带标题行噪音 + 前后噪音文字', () {
      final p = parseColorInput(
          'COLOR SHARING | 配色分享\n霓虹蓝\n#00F0FF\nCMYK\n60 0 15 0\n'
          '抖音 @某UP主');
      expect(_argb(p.color), 0xFF00F0FF);
      expect(p.name, '霓虹蓝', reason: '★ 标题行/水印行都不是名字，汉字行优先挑到真名字');
      final q = parseColorInput('这张图的颜色是 #F9B800 哦');
      expect(_argb(q.color), 0xFFF9B800, reason: '色值前后有噪音文字也要认');
    });

    test('★6 半个色卡 / 不完整写法 ⇒ 不认（不许猜）', () {
      final p = parseColorInput('霓虹蓝\n#00');
      expect(p.color, isNull, reason: '「#00」只有 2 位，不是合法写法');
      expect(p.kind, ColorInputKind.none);
      expect(p.name, '霓虹蓝', reason: '名称与色值相互独立：没认出颜色也可以给出名字');
      expect(parseColorInput('#12345').color, isNull, reason: '5 位不是合法写法');
      expect(parseColorInput('#1234567').color, isNull, reason: '7 位不是合法写法');
    });
  });

  // ─────────────────────────── 二、RGB ───────────────────────────

  group('★7~★9 RGB：四种写法 + 「别把数字吃成 HEX」', () {
    test('★7 rgb() / rgba() / 空格分隔 / alpha 忽略', () {
      for (final s in [
        'rgb(0,240,255)',
        'RGB(0 240 255)',
        'rgb(0, 240, 255)',
        'rgba(0,240,255,0.5)',
        'rgb(0,240,255,255)',
        'RGBA(0,240,255,1)',
      ]) {
        final p = parseColorInput(s);
        expect(p.kind, ColorInputKind.rgb, reason: '「$s」应该是 RGB');
        expect(_argb(p.color), 0xFF00F0FF, reason: '「$s」的色值');
        expect(p.note, isNull, reason: 'RGB 是无损的，不弹提醒');
      }
    });

    test('★8 带标签无括号 / 三数字裸写（逗号与空格两种分隔）', () {
      for (final s in ['RGB 0,240,255', 'rgb 0 240 255', '0,240,255', '0 240 255']) {
        final p = parseColorInput(s);
        expect(p.kind, ColorInputKind.rgb, reason: '「$s」应该是 RGB');
        expect(_argb(p.color), 0xFF00F0FF, reason: '「$s」的色值');
      }
    });

    test('★9 ★ 「RGB 那三个数字不许被吃成 HEX」—— 正/负一对（这条是本文件的重点）', () {
      // 正向：`240`/`255` 都是**合法的 3 位十六进制**（#240 = #224400），
      // 但它们在 RGB 上下文里必须是十进制的分量。
      final p = parseColorInput('rgb(0,240,255)');
      expect(p.kind, ColorInputKind.rgb,
          reason: '★ 若把 240 当成 3 位 HEX，这条会变成 hex + #224400（用户看到的颜色全错）');
      expect(_argb(p.color), 0xFF00F0FF);
      final q = parseColorInput('0 240 255');
      expect(q.kind, ColorInputKind.rgb, reason: '★ 裸写同理');
      expect(_argb(q.color), 0xFF00F0FF);
      // 负向对照：同一个 `240`，**加 # 之后**必须照认成 3 位 HEX
      // —— 证明上面那条不是"3 位 HEX 整个坏掉了"，而是刻意区分了上下文。
      expect(_argb(parseColorInput('#240').color), 0xFF224400,
          reason: '★ 带 # 的 3 位短写必须仍然认（门槛只加在"裸写"上）');
      expect(parseColorInput('#240').kind, ColorInputKind.hex);
      // 再一条负向：单独的 `240`（没有上下文）不认 —— 宁可不动，也不猜成 #224400
      expect(parseColorInput('240').color, isNull,
          reason: '★ 裸的 3 位纯十进制串不认：它更可能是 RGB 的一个分量');
    });

    test('★9b 分量越界 / 个数不对 ⇒ 一概不认', () {
      expect(parseColorInput('rgb(0,240,300)').color, isNull, reason: '300 > 255');
      expect(parseColorInput('rgb(0,240)').color, isNull, reason: '只有 2 个分量');
      expect(parseColorInput('0,240').color, isNull);
      expect(parseColorInput('0 240 255 7').color, isNull,
          reason: '★ 4 个数字且有一个 > 100 ⇒ 既不是 RGB（要恰好 3 个）也不是 CMYK（要 ≤100）');
      expect(parseColorInput('rgb(0,240,255,0.5,9)').color, isNull,
          reason: '括号里 5 个数字不是 rgb/rgba 的形状');
    });
  });

  // ────────────────────────── 三、CMYK ──────────────────────────

  group('★10~★13 CMYK：四种写法 + 边界', () {
    test('★10 cmyk() / CMYK 一行 / CMYK 换行 + 数字（色卡形状）/ 裸四数字', () {
      for (final s in [
        'cmyk(60,0,15,0)',
        'CMYK(60,0,15,0)',
        'CMYK 60 0 15 0',
        'CMYK\n60 0 15 0',
        'cmyk 60,0,15,0',
        '60 0 15 0',
        '60,0,15,0',
        '霓虹蓝\nCMYK\n60 0 15 0',
      ]) {
        final p = parseColorInput(s);
        expect(p.kind, ColorInputKind.cmyk, reason: '「$s」应该是 CMYK');
        expect(_argb(p.color), 0xFF66FFD9,
            reason: '「$s」朴素反算 = #66FFD9（60/0/15/0）');
      }
    });

    test('★11 CMYK 的 note 必须如实说可能对不上（不许粉饰）', () {
      final p = parseColorInput('霓虹蓝\nCMYK\n60 0 15 0');
      expect(p.kind, ColorInputKind.cmyk);
      expect(p.note, isNotNull, reason: '★ 只靠 CMYK 认出来时必须给一句提醒');
      // 逐个要素核，少一个都不行
      expect(p.note, contains('CMYK 60 0 15 0'), reason: 'note 要回显卡上的四个数');
      expect(p.note, contains('#66FFD9'), reason: 'note 要给出反算得到的屏幕色');
      expect(p.note, contains('印刷色'), reason: '★ 必须点明 CMYK 是印刷色');
      expect(p.note, contains('对不上'), reason: '★ 必须如实说和屏幕色卡可能对不上');
      expect(p.note, contains('滑杆'), reason: 'note 要告诉用户下一步能微调');
      expect(p.name, '霓虹蓝');
    });

    test('★12 k=100 ⇒ 纯黑，且不除零', () {
      for (final s in ['cmyk(0,0,0,100)', 'CMYK 10 20 30 100', '0 0 0 100']) {
        expect(_argb(parseColorInput(s).color), 0xFF000000, reason: '「$s」= 黑');
      }
      // 另一端：四个 0 = 白
      expect(_argb(parseColorInput('cmyk(0,0,0,0)').color), 0xFFFFFFFF);
      // rgbToCmyk 的黑也是提前返回（下面 ★25 还核一次），这里顺手把 k=100 的
      // 反算路径也堵上：不许出现 NaN / 除以 0 的 Infinity。
      final black = rgbToCmyk(const Color(0xFF000000));
      expect(black.k, 100);
      expect([black.c, black.m, black.y], [0, 0, 0]);
    });

    test('★13 CMYK 的分量 0~100：越界 / 个数不对 ⇒ 不认', () {
      expect(parseColorInput('CMYK 60 0 15 101').color, isNull, reason: '101 > 100');
      expect(parseColorInput('CMYK 60 0 15').color, isNull,
          reason: '★ CMYK 必须**恰好 4 个**数，标签后面只有 3 个 ⇒ 不认');
      // 3 个 ≤255 的数按用户定的规矩就是 RGB（60/0/15 → #3C000F），不是 CMYK。
      // 这两条合起来才钉得死"恰好 4 个"这条门槛：不然 `60 0 15 0` 会被读成 RGB(60,0,15)。
      final p = parseColorInput('60 0 15');
      expect(p.kind, ColorInputKind.rgb, reason: '3 个数 = RGB（哪怕都 ≤ 100）');
      expect(p.color!.toARGB32(), 0xFF3C000F);
      expect(p.kind, isNot(ColorInputKind.cmyk));
    });
  });

  // ─────────────────────────── 四、名称 ───────────────────────────

  group('★14~★16 名称识别', () {
    test('★14 含汉字的行优先（哪怕它排在英文行后面）', () {
      final p = parseColorInput('neon blue\n霓虹蓝\n#00F0FF');
      expect(p.name, '霓虹蓝', reason: '★ 汉字行优先于英文行');
      final q = parseColorInput('霓虹蓝\nneon blue\n#00F0FF');
      expect(q.name, '霓虹蓝');
    });

    test('★15 去噪：** 加粗 / 行首 # / 尾巴的冒号', () {
      expect(parseColorInput('**霓虹蓝**\n#00F0FF').name, '霓虹蓝');
      expect(parseColorInput('霓虹蓝：\n#00F0FF').name, '霓虹蓝');
      expect(parseColorInput('#霓虹蓝\n#00F0FF').name, '霓虹蓝');
      expect(parseColorInput('电光紫 :\n#9D00FF').name, '电光紫');
    });

    test('★16 标签行 / 超长行 / 全数字行 / 纯符号行都不算名字', () {
      expect(parseColorInput('COLOR SHARING\n#00F0FF').name, isNull,
          reason: '标签行不是名字');
      expect(parseColorInput('配色分享\n#00F0FF').name, isNull);
      expect(parseColorInput('这是一个特别特别长的颜色名称啦\n#00F0FF').name, isNull,
          reason: '长度 > 12 不算名字（抖音标题经常很长，宁可不填）');
      expect(parseColorInput('20241006\n#00F0FF').name, isNull, reason: '全数字不算');
      expect(parseColorInput('***\n#00F0FF').name, isNull, reason: '纯符号不算');
      // 12 字（含）以内要认
      expect(parseColorInput('一二三四五六七八九十十一\n#00F0FF').name,
          '一二三四五六七八九十十一');
    });
  });

  // ────────────────────────── 五、优先级 ──────────────────────────

  group('★17~★20 优先级与「两套色空间对不上」的实证', () {
    test('★17 HEX > RGB > CMYK（同一段文本里三种写法同时存在）', () {
      final p = parseColorInput(
          '霓虹蓝\n#00F0FF\nRGB 0,240,255\nCMYK\n60 0 15 0');
      expect(p.kind, ColorInputKind.hex);
      expect(_argb(p.color), 0xFF00F0FF);
    });

    test('★18 没有 HEX 时 RGB 压过 CMYK', () {
      final p = parseColorInput('霓虹蓝\nRGB 0,240,255\nCMYK 60 0 15 0');
      expect(p.kind, ColorInputKind.rgb);
      expect(_argb(p.color), 0xFF00F0FF);
      expect(p.note, isNull);
    });

    test('★19 电光紫那张卡：HEX 与 CMYK 同时存在 ⇒ 取 HEX', () {
      final p = parseColorInput('电光紫\n#9D00FF\nCMYK\n70 80 0 0');
      expect(p.kind, ColorInputKind.hex);
      expect(_argb(p.color), 0xFF9D00FF);
      expect(p.name, '电光紫');
      expect(p.note, isNull);
    });

    test('★20 实证「CMYK 反算和色卡对不上」（这就是 note 存在的理由）', () {
      // 卡上：HEX = #00F0FF，CMYK = 60 0 15 0
      const cardHex = Color(0xFF00F0FF);
      final fromCmyk = parseColorInput('CMYK 60 0 15 0');
      expect(_argb(fromCmyk.color), isNot(_argb(cardHex)),
          reason: '★ 朴素反算给 #66FFD9 ≠ 卡上的 #00F0FF ⇒ CMYK 不能当精确值');
      // 另一条：同一个屏幕色反算出的 CMYK 也和卡片对不上
      final back = rgbToCmyk(cardHex);
      expect([back.c, back.m, back.y, back.k], [100, 6, 0, 0],
          reason: '#00F0FF 的屏幕反算是 100 6 0 0，卡片写的是 60 0 15 0');
      expect([back.c, back.m, back.y, back.k], isNot([60, 0, 15, 0]),
          reason: '★ 两个方向都对不上 ⇒ note 里那句「可能对不上」是实话，不许删');
    });
  });

  // ─────────────────────── 六、不许抛异常 ───────────────────────

  group('★21~★24 任何输入都不许抛异常', () {
    test('★21 空串 / 纯空白', () {
      for (final s in ['', '   ', '\n\n', '\t']) {
        final p = parseColorInput(s);
        expect(p.kind, ColorInputKind.none, reason: '「$s」');
        expect(p.color, isNull);
        expect(p.name, isNull);
      }
    });

    test('★22 纯中文 / 纯数字 / 纯符号', () {
      final p = parseColorInput('霓虹蓝');
      expect(p.kind, ColorInputKind.none);
      expect(p.color, isNull, reason: '★ 明确不做「中文色名字典查色」——不许靠名字猜颜色');
      expect(p.name, '霓虹蓝');
      for (final s in ['12345', '999', '!!!', '***', '0x', '#', 'cmyk', 'rgb']) {
        final q = parseColorInput(s);
        expect(q.color, isNull, reason: '「$s」不该被认成颜色');
      }
      expect(parseColorInput('12345').name, isNull);
      expect(parseColorInput('999').name, isNull);
    });

    test('★23 超长垃圾串 / 随机串 / 半个色卡：returnsNormally', () {
      final rnd = math.Random(20261006);
      final junk = StringBuffer();
      for (var i = 0; i < 20000; i++) {
        junk.writeCharCode(rnd.nextInt(0x2FFF) + 1);
      }
      final cases = <String>[
        junk.toString(),
        '#' * 5000,
        'rgb(' * 2000,
        'CMYK\n' * 500,
        '霓虹蓝\n#00F0FF\nCMYK\n60 0 15 0\n' * 300,
        '0' * 100000,
        'A' * 99999,
        '￥%……&*（）——+{}|:"<>?',
        '\u0000\u0001\uFFFD\uD800', // 控制字符 + 半个代理对
      ];
      for (final s in cases) {
        expect(() => parseColorInput(s), returnsNormally,
            reason: '★ 这个函数挂在 TextField.onChanged 上：抛一次就是整个弹层崩');
      }
    });

    test('★24 幂等 / 可重复调用（同一输入两次结果一致）', () {
      const s = '霓虹蓝\n#00F0FF\nCMYK\n60 0 15 0';
      final a = parseColorInput(s);
      final b = parseColorInput(s);
      expect(a.kind, b.kind);
      expect(_argb(a.color), _argb(b.color));
      expect(a.name, b.name);
      expect(a.note, b.note);
    });
  });

  // ────────────────────── 七、rgbToCmyk 反算 ──────────────────────

  group('★25~★27 rgbToCmyk（回显用的反向换算）', () {
    test('★25 三个端点', () {
      final white = rgbToCmyk(const Color(0xFFFFFFFF));
      expect([white.c, white.m, white.y, white.k], [0, 0, 0, 0]);
      final black = rgbToCmyk(const Color(0xFF000000));
      expect([black.c, black.m, black.y, black.k], [0, 0, 0, 100],
          reason: '★ k = 100 是提前返回的（否则 (1-r-k)/(1-k) 会变成 0/0）');
      final red = rgbToCmyk(const Color(0xFFFF0000));
      expect([red.c, red.m, red.y, red.k], [0, 100, 100, 0]);
    });

    test('★26 与色卡反向对应：#66FFD9 → 60 0 15 0', () {
      final t = rgbToCmyk(const Color(0xFF66FFD9));
      expect([t.c, t.m, t.y, t.k], [60, 0, 15, 0],
          reason: '★ 朴素公式和卡上那四个数正好互为逆运算 ⇒ 说明卡片用的就是这套朴素关系，'
              '但它的 HEX 对不上（见 ★20）⇒ 两个色空间不同');
    });

    test('★27 往返一致：cmyk → rgb → cmyk（含 40 套内置主题色，误差 ≤ 2）', () {
      var checked = 0;
      var maxErr = 0;
      for (final s in kAccentSchemes) {
        final back = rgbToCmyk(s.primary);
        // 用朴素正向公式把反算值再打回 RGB，必须几乎回到原色。
        // ⚠️ 容差是 2 而不是 0/1：CMYK 在这里是**整数百分比**，
        //    k 取整 0.5% 就等价于整体亮度偏 ~1.3/255，c/m/y 再各偏 ~1.3/255 ⇒
        //    单通道最多差 2（实测 薄荷绿 #A4E2C6 的 R 就是差 2）。
        final r = (255 * (1 - back.c / 100) * (1 - back.k / 100)).round();
        final g = (255 * (1 - back.m / 100) * (1 - back.k / 100)).round();
        final b = (255 * (1 - back.y / 100) * (1 - back.k / 100)).round();
        final orig = s.primary.toARGB32();
        final e = [
          (r - ((orig >> 16) & 0xFF)).abs(),
          (g - ((orig >> 8) & 0xFF)).abs(),
          (b - (orig & 0xFF)).abs(),
        ].reduce(math.max);
        maxErr = math.max(maxErr, e);
        expect(e, lessThanOrEqualTo(2),
            reason: '${s.name}：往返误差 $e（反算 ${back.c} ${back.m} ${back.y} ${back.k}）');
        checked++;
      }
      expect(checked, 40, reason: '40 套内置主题色都过一遍（不是抽查）');
      expect(maxErr, lessThanOrEqualTo(2), reason: '实测最大往返误差 = $maxErr');
      // 分量范围：任何输入都落在 0~100 的整数上（回显要显示成整数）
      for (final v in [0, 1, 0x7F, 0xFF]) {
        final c = rgbToCmyk(Color.fromARGB(255, v, v, v));
        for (final x in [c.c, c.m, c.y, c.k]) {
          expect(x, inInclusiveRange(0, 100), reason: '分量必须是 0~100');
        }
      }
    });
  });

  // ────────────── 八、名称与色值写在同一行（B1）──────────────

  group('★28~★30 名称与色值写在同一行也要认出名字', () {
    test('★28 正向：先把色值片段摘掉，再按原门槛判名字', () {
      // 用户手输的那两行（这一单的由来：老写法「整行出现色值就作废」⇒
      // 颜色认得出、名字认不出，只能落到「自定义 N」）
      final a = parseColorInput('电光紫 #9D00FF');
      expect(a.name, '电光紫', reason: '★ 名称与色值同行的最基本形状');
      expect(_argb(a.color), 0xFF9D00FF, reason: '色值不受影响');
      expect(a.kind, ColorInputKind.hex);

      final b = parseColorInput('霓虹蓝 #00F0FF CMYK 60 0 15 0');
      expect(b.name, '霓虹蓝', reason: '★ 一行写全（名字 + HEX + CMYK 标签 + 四数字）');
      expect(_argb(b.color), 0xFF00F0FF, reason: 'HEX 仍然压过 CMYK');
      expect(b.kind, ColorInputKind.hex);
      expect(b.note, isNull, reason: '有 HEX 就不弹 CMYK 那句提醒');

      // 名字与色值之间没有空格 / 色值换几种写法，都要摘得掉
      expect(parseColorInput('电光紫#9D00FF').name, '电光紫');
      expect(parseColorInput('电光紫 0x9D00FF').name, '电光紫');
      expect(parseColorInput('电光紫 9D00FF').name, '电光紫', reason: '裸 6 位 HEX');
      expect(parseColorInput('霓虹蓝 rgb(0,240,255)').name, '霓虹蓝');
      expect(parseColorInput('霓虹蓝 RGB 0,240,255').name, '霓虹蓝');
      expect(parseColorInput('霓虹蓝 cmyk(60,0,15,0)').name, '霓虹蓝');
      expect(parseColorInput('霓虹蓝 0,240,255').name, '霓虹蓝');
      expect(parseColorInput('霓虹蓝 #00F0FF CMYK').name, '霓虹蓝',
          reason: '标签词也要摘掉（不然「CMYK」会跟着名字一起被当成长度超限）');
      // ⚠️ 摘掉的片段留下的是**空格**，用户手输时也可能多打空格：
      // 数字载荷被空格拆成两段的话，落单的那半截会跟着名字留下来
      expect(parseColorInput('霓虹蓝 CMYK 60  0 15 0').name, '霓虹蓝',
          reason: '四分量中间多打一个空格也要摘干净');
      expect(parseColorInput('霓虹蓝 #00F0FF   60 0 15 0').name, '霓虹蓝');
      expect(parseColorInput('霓虹蓝\t#00F0FF\tCMYK\t60 0 15 0').name, '霓虹蓝',
          reason: '用 Tab 分隔也一样');
    });

    test('★29 反向守卫：整行都是色值 ⇒ 摘完为空 ⇒ 仍然不是名字', () {
      for (final s in [
        '#00F0FF',
        '＃00F0FF',
        '0x00F0FF',
        '00F0FF',
        '60 0 15 0',
        '60,0,15,0',
        '0,240,255',
        '0 240 255',
        'CMYK',
        'RGB',
        'rgb(0,240,255)',
        'cmyk(60,0,15,0)',
        'RGB 0 240 255',
        'CMYK 60 0 15 0',
      ]) {
        expect(parseColorInput(s).name, isNull,
            reason: '★「$s」整行就是色值（或色值标签），摘完什么都不剩');
      }
      // 色卡那条老路（四行）仍然只认「霓虹蓝」——一个字节都没被这次改动带偏
      expect(parseColorInput('霓虹蓝\r\n#00F0FF\r\nCMYK\r\n60 0 15 0').name, '霓虹蓝');
    });

    test('★30 老规矩一个都没破：超长 / 标签 / 纯数字 / 纯符号行仍不算名字', () {
      expect(parseColorInput('COLOR SHARING | 配色分享').name, isNull,
          reason: '★ 作废理由是「超过 12 字」，不是「长得像色值」——'
              'COLOR / SHARING / 配色 这些栏目词不许在摘色值那一步被吃掉');
      expect(parseColorInput('COLOR SHARING | 配色分享\n霓虹蓝\n#00F0FF').name, '霓虹蓝');
      expect(parseColorInput('20241006\n#00F0FF').name, isNull, reason: '全数字不算名字');
      expect(parseColorInput('12345\n#00F0FF').name, isNull);
      expect(parseColorInput('***\n#00F0FF').name, isNull, reason: '纯符号不算名字');
      expect(parseColorInput('霓虹蓝：\n#00F0FF').name, '霓虹蓝', reason: '尾巴的冒号仍去掉');
      // ⚠️ 名字里**落单**的数字不许被当色值削掉（只摘「成组的数字载荷」）
      expect(parseColorInput('克莱因蓝 3号\n#002FA7').name, '克莱因蓝 3号');
      expect(parseColorInput('520 玫瑰\n#FF0000').name, '520 玫瑰');
    });
  });
}

