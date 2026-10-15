/// 从「一整段文本」里认出颜色：抖音「配色分享」色卡的**整段粘贴识别** + HEX / RGB / CMYK 手输。
///
/// ## 为什么要有这个模块
/// 用户存了一批抖音「配色分享」视频截图，色卡长这样（三行或四行）：
/// ```
/// 霓虹蓝
/// #00F0FF
/// CMYK
/// 60 0 15 0
/// ```
/// 另一张：
/// ```
/// 电光紫
/// #9D00FF
/// CMYK
/// 70 80 0 0
/// ```
/// 还有标题行噪音（`COLOR SHARING | 配色分享`）。用户的话是
/// 「用户自己要新建这种抖音视频中的颜色的时候会不知道怎么调，我需要能输入某种信息直接获得」——
/// 他原来只能拖 HSV 三滑杆，调不出来。这个模块就是那一步「输入某种信息」。
///
/// ## 契约（谁改都得守住）
/// 1. **纯逻辑**：除 `dart:ui` 的 [Color] 外不依赖 Flutter widget，可单测；
/// 2. **任何输入都不抛异常**（空串 / 纯中文 / 纯数字 / 超长垃圾串 / 半个色卡都只返回
///    [ColorInputKind.none]，⛔ 不许 throw，因为它是挂在 `TextField.onChanged` 上的）；
/// 3. **优先级 HEX > RGB > CMYK**：HEX 无损；CMYK 是印刷色（见 [_cmykToColor] 的注释）。
///
/// ## 认的写法（大小写不敏感、允许前后有噪音文字与换行）
/// | 类别 | 例 |
/// |---|---|
/// | HEX | `#00F0FF`、`00F0FF`、`0x00F0FF`、`#0FF`/`0FF`（3 位每位翻倍）、`#FF00F0FF`/`0xFF00F0FF`/裸 `FF00F0FF`（8 位 = ARGB） |
/// | RGB | `rgb(0,240,255)`、`RGB(0 240 255)`、`rgba(0,240,255,0.5)`（alpha 忽略）、`RGB 0,240,255`、裸 `0,240,255` / `0 240 255` |
/// | CMYK | `cmyk(60,0,15,0)`、`CMYK 60 0 15 0`、`CMYK` 单独一行 + 下一行 `60 0 15 0`、裸 `60 0 15 0` |
/// | 名称 | 第一行「**摘掉色值片段之后**既不是色值、也不是 `CMYK`/`RGB`/`COLOR SHARING` 这类标签、也不全是数字」的短行；**含中日韩汉字的行优先**；≤ 12 字（所以 `电光紫 #9D00FF` 这种**一行写全**的也认得出 `电光紫`，见 [_stripColorValues]） |
library;

import 'dart:math' as math;
import 'dart:ui' show Color;

/// 认出来的颜色是用哪种写法给的（没认出来 = [ColorInputKind.none]）。
enum ColorInputKind { none, hex, rgb, cmyk }

/// 一次解析的结果：颜色（没认出来 = null）+ 顺带认出来的名称 + 写法 + 给 UI 的一句话。
class ColorInputParse {
  const ColorInputParse({
    this.name,
    this.color,
    this.kind = ColorInputKind.none,
    this.note,
  });

  /// 从整段文本里认出来的名称（可能为 null）。
  ///
  /// ⚠️ **它和 [color] 相互独立**：整段只有「霓虹蓝」两个字时 [color] 是 null 而
  /// [name] 是「霓虹蓝」。UI 侧的规矩是「**先认出色值才自动填名字**」，
  /// 别拿 name 非空当"认出来了"。
  final String? name;

  /// 认出来的颜色（没认出来 = null）。
  final Color? color;

  /// 是用哪种写法认出来的。
  final ColorInputKind kind;

  /// 给 UI 显示的一句话。**只有 CMYK 这一路非 null**，而且措辞不许粉饰：
  /// CMYK 是印刷色空间，和屏幕上的色卡可能对不上（见 [_cmykToColor]）。
  /// HEX / RGB 是无损的 ⇒ 这里为 null（没有什么要提醒的）。
  final String? note;

  /// 是否认出了颜色（UI 判断"要不要同步滑杆/回显"就看它）。
  bool get recognized => color != null;

  @override
  String toString() => 'ColorInputParse(kind: ${kind.name}, color: $color, '
      'name: $name, note: $note)';
}

// ───────────────────────────── 对外入口 ─────────────────────────────

/// 解析一整段文本，认出里面的颜色与名称。**任何输入都不抛异常**。
///
/// 找不到颜色时返回 `kind: none, color: null`（名称仍可能被认出来）。
ColorInputParse parseColorInput(String raw) {
  if (raw.trim().isEmpty) return const ColorInputParse();

  // ① 带前缀的 HEX（`#`/`＃`/`0x`）：无歧义，最高优先级。
  //    ⚠️ 它必须排在最前 —— 色卡上 HEX 与 CMYK 同时出现时（就是抖音那种四行卡），
  //    HEX 才是屏幕上真正的颜色，CMYK 只是印刷近似值。
  final hex = _findPrefixedHex(raw);
  if (hex != null) {
    return ColorInputParse(
        name: _findName(raw), color: hex, kind: ColorInputKind.hex);
  }

  // ② 裸 HEX（6 位 / 8 位整词）。排在 RGB/CMYK 之前 = 用户说的「HEX > RGB > CMYK」。
  //    ⚠️ 它和"三/四个裸数字"不会打架：`0,240,255` 里没有 6/8 位的整词
  //    （`240`/`255` 只有 3 位，而 3 位裸 HEX 另有更严的门槛，见 ⑧）。
  final bareHex = _findBareHex(raw);
  if (bareHex != null) {
    return ColorInputParse(
        name: _findName(raw), color: bareHex, kind: ColorInputKind.hex);
  }

  // ③ `rgb(...)` / `rgba(...)`（括号里的 alpha 忽略）。
  final rgbCall = _findRgbCall(raw);
  if (rgbCall != null) {
    return ColorInputParse(
        name: _findName(raw), color: rgbCall, kind: ColorInputKind.rgb);
  }

  // ④ `RGB 0,240,255` 这种带标签没括号的。
  final rgbLabeled = _findRgbLabeled(raw);
  if (rgbLabeled != null) {
    return ColorInputParse(
        name: _findName(raw), color: rgbLabeled, kind: ColorInputKind.rgb);
  }

  // ⑤ 裸三数字（**恰好** 3 个 0~255 的整数，否则不认）。
  final bareRgb = _findBareNumbers(raw, 3, 255);
  if (bareRgb != null) {
    return ColorInputParse(
        name: _findName(raw),
        color: Color.fromARGB(255, bareRgb[0], bareRgb[1], bareRgb[2]),
        kind: ColorInputKind.rgb);
  }

  // ⑥ `cmyk(60,0,15,0)` / `CMYK 60 0 15 0` / `CMYK` 换行 + `60 0 15 0`
  //    （最后那种形状就是抖音色卡）。
  final cmyk = _findCmykCall(raw) ?? _findCmykLabeled(raw);
  if (cmyk != null) return _cmykResult(raw, cmyk);

  // ⑦ 裸四数字（**恰好** 4 个 0~100 的整数）。
  final bareCmyk = _findBareNumbers(raw, 4, 100);
  if (bareCmyk != null) return _cmykResult(raw, bareCmyk);

  // ⑧ 最后才轮到 3 位裸 HEX（`0FF`）。见 [_findShortBareHex] 的门槛说明。
  final shortHex = _findShortBareHex(raw);
  if (shortHex != null) {
    return ColorInputParse(
        name: _findName(raw), color: shortHex, kind: ColorInputKind.hex);
  }

  return ColorInputParse(name: _findName(raw));
}

/// RGB → CMYK 的反向换算（朴素公式，和 [_cmykToColor] 互为逆运算），给「回显」用。
///
/// 返回 0~100 的整数百分比。⚠️ 这是**屏幕色的朴素换算**，不是印刷色卡上那个 CMYK：
/// 例如 `#00F0FF` 反算是 `100 6 0 0`，而抖音色卡上写的是 `60 0 15 0`
/// —— 两者对不上是**色空间不同**，不是算错了（详见 [_cmykToColor]）。
({int c, int m, int y, int k}) rgbToCmyk(Color color) {
  final argb = color.toARGB32();
  final r = ((argb >> 16) & 0xFF) / 255.0;
  final g = ((argb >> 8) & 0xFF) / 255.0;
  final b = (argb & 0xFF) / 255.0;
  final k = 1 - math.max(r, math.max(g, b));
  // k = 1（纯黑）时下面是 0/0 —— 提前返回，别除零。
  if (k >= 1.0) return (c: 0, m: 0, y: 0, k: 100);
  final d = 1 - k;
  int pct(double v) => ((v / d) * 100).round().clamp(0, 100);
  return (
    c: pct(1 - r - k),
    m: pct(1 - g - k),
    y: pct(1 - b - k),
    k: (k * 100).round().clamp(0, 100),
  );
}

// ───────────────────────────── 内部实现 ─────────────────────────────

/// CMYK（0~100）→ 色彩，用**教科书那条朴素公式**：
/// `K = k/100; R = 255*(1-c/100)*(1-K)`，G/B 同理；k = 100 时三个通道都是 0（纯黑）。
///
/// ## ⚠️ 为什么只有"没给 HEX"时才用它（源码级理由，别删这段注释）
/// 抖声色卡上的 CMYK 是**印刷色空间**，不是屏幕色：
/// - 卡片上写 `60 0 15 0`，同一张卡片的 HEX 是 `#00F0FF`；
/// - 把 `60 0 15 0` 用上面那条朴素公式反算，得到的是 **`#66FFD9`** ——
///   **和 `#00F0FF` 对不上**（反算 `#00F0FF` 得到的 CMYK 是 `100 6 0 0`，也和卡片对不上）。
///
/// 两条路都通不了 ⇒ 结论只有一个：**CMYK 不能当精确值用**。
/// 所以 [parseColorInput] 的优先级是 HEX > RGB > CMYK，
/// 且只靠 CMYK 认出来时 [ColorInputParse.note] 必须**如实告诉用户可能对不上**（不许粉饰）。
Color _cmykToColor(int c, int m, int y, int k) {
  final kk = (k.clamp(0, 100)) / 100.0;
  final cc = (c.clamp(0, 100)) / 100.0;
  final mm = (m.clamp(0, 100)) / 100.0;
  final yy = (y.clamp(0, 100)) / 100.0;
  int ch(double v) => (255 * v * (1 - kk)).round().clamp(0, 255);
  return Color.fromARGB(255, ch(1 - cc), ch(1 - mm), ch(1 - yy));
}

/// CMYK 那一路的统一出口：颜色 + 那句**不许粉饰**的 note。
ColorInputParse _cmykResult(String raw, List<int> cmyk) {
  final color = _cmykToColor(cmyk[0], cmyk[1], cmyk[2], cmyk[3]);
  final note = 'CMYK ${cmyk[0]} ${cmyk[1]} ${cmyk[2]} ${cmyk[3]} → '
      '${hexOf(color)}（CMYK 是印刷色，和屏幕色卡可能对不上，可再拖滑杆微调）';
  return ColorInputParse(
      name: _findName(raw),
      color: color,
      kind: ColorInputKind.cmyk,
      note: note);
}

/// 颜色的 `#RRGGBB` 大写十六进制串（给回显/note 用；alpha 不显示）。
String hexOf(Color color) {
  final argb = color.toARGB32();
  final s = ((argb >> 16) & 0xFF).toRadixString(16).padLeft(2, '0') +
      ((argb >> 8) & 0xFF).toRadixString(16).padLeft(2, '0') +
      (argb & 0xFF).toRadixString(16).padLeft(2, '0');
  return '#${s.toUpperCase()}';
}

/// 带前缀的 HEX：`#` / `＃`（全角，中文输入法下很常见）/ `0x`。
final RegExp _prefixedHexRe = RegExp(r'(?:#|＃|0[xX])([0-9a-fA-F]{3,8})');

Color? _findPrefixedHex(String text) {
  for (final m in _prefixedHexRe.allMatches(text)) {
    final c = _colorFromHexDigits(m.group(1)!);
    if (c != null) return c;
  }
  return null;
}

/// 3 / 6 / 8 位十六进制 → 颜色；其它长度一律返回 null（由调用方继续往后找）。
///
/// - 3 位：每位翻倍（`0FF` → `00FFFF`）
/// - 6 位：补不透明 alpha（`00F0FF` → `FF00F0FF`）
/// - 8 位：按 ARGB 解（`FF00F0FF` → 不透明的 `#00F0FF`）
Color? _colorFromHexDigits(String d) {
  switch (d.length) {
    case 3:
      final s = d.split('').map((c) => '$c$c').join();
      return Color(0xFF000000 | int.parse(s, radix: 16));
    case 6:
      return Color(0xFF000000 | int.parse(d, radix: 16));
    case 8:
      return Color(int.parse(d, radix: 16));
    default:
      return null;
  }
}

/// 整词扫描用的"十六进制字符"正则（裸写形式全靠它切词）。
final RegExp _hexTokenRe = RegExp(r'[0-9a-fA-F]+');
final RegExp _wordCharRe = RegExp(r'[0-9A-Za-z_]');

/// 这个 match 是不是一个**独立的整词**（前后都不是字母/数字/下划线，也不是 `#`）。
bool _isStandaloneToken(String text, int start, int end) {
  if (start > 0) {
    final p = text[start - 1];
    if (_wordCharRe.hasMatch(p) || p == '#' || p == '＃') return false;
  }
  if (end < text.length) {
    if (_wordCharRe.hasMatch(text[end])) return false;
  }
  return true;
}

/// 裸 HEX：独立的 6 位或 8 位整词。
///
/// ⚠️ 已知的取舍：一个**只由 a~f 组成的 6 字母英文单词**（`decade`/`facade`）会被当成
/// `#DECADE`/`#FACADE`。这是"裸 6 位要认"这条要求的必然代价（没前缀就无从区分），
/// 认了它才不会漏掉手输的 `00F0FF`。带 `#`/`0x` 的写法永不受影响。
Color? _findBareHex(String text) {
  for (final m in _hexTokenRe.allMatches(text)) {
    if (!_isStandaloneToken(text, m.start, m.end)) continue;
    final d = m.group(0)!;
    if (d.length == 6 || d.length == 8) {
      final c = _colorFromHexDigits(d);
      if (c != null) return c;
    }
  }
  return null;
}

/// 3 位裸 HEX（`0FF`）。
///
/// ⚠️ **门槛：必须至少含一个 a~f 字母**。理由就是用户点出来的那条 ——
/// 「不能让 RGB 那三个数字被误吃成 HEX」：`rgb(0,240,255)` / `0 240 255` 里的
/// `240`、`255` 都是**合法的 3 位十六进制**，不加这条门槛，`240` 会变成 `#224400`。
/// 纯十进制的 3 位串当作数字（RGB/CMYK 分量）远比当作颜色合理；
/// 真要用十六进制，写 `#240` 或 `0x240` 就照认（走 ① 的带前缀分支）。
Color? _findShortBareHex(String text) {
  final hasLetter = RegExp(r'[a-fA-F]');
  for (final m in _hexTokenRe.allMatches(text)) {
    if (!_isStandaloneToken(text, m.start, m.end)) continue;
    final d = m.group(0)!;
    if (d.length == 3 && hasLetter.hasMatch(d)) return _colorFromHexDigits(d);
  }
  return null;
}

final RegExp _numberRe = RegExp(r'\d+(?:\.\d+)?');

List<double> _numbersIn(String s) =>
    [for (final m in _numberRe.allMatches(s)) double.parse(m.group(0)!)];

/// `rgb(...)` / `rgba(...)`：括号里的数字**恰好 3 个**（或 4 个，第 4 个是 alpha，忽略）。
final RegExp _rgbCallRe = RegExp(r'\brgba?\s*\(([^)]*)\)', caseSensitive: false);

Color? _findRgbCall(String text) {
  for (final m in _rgbCallRe.allMatches(text)) {
    final nums = _numbersIn(m.group(1)!);
    final c = _rgbFromFirst3(nums, strictCount: true);
    if (c != null) return c;
  }
  return null;
}

/// 从一串数字里取前 3 个当 RGB。
///
/// - [strictCount] = true（`rgb(...)` 括号里）：**恰好 3 或 4 个**（4 个时第 4 个是 alpha，
///   忽略）—— 括号把参数表框住了，多一个少一个都是写法不对。
/// - [strictCount] = false（`RGB 0,240,255` 这种带标签的）：取**头 3 个**即可。
///   ⚠️ 这条是实测踩出来的：色卡上 `RGB 0,240,255` 的下一行往往就是 `CMYK 60 0 15 0`，
///   窗口里会有 7 个数字；要求"总数恰好 3/4"的话，带 RGB 标签的卡会**整条认不出来**，
///   掉到 CMYK 分支去（`test/color_input_test.dart` ★18 就是钉这个的）。
Color? _rgbFromFirst3(List<double> nums, {bool strictCount = true}) {
  if (strictCount && nums.length != 3 && nums.length != 4) return null;
  if (nums.length < 3) return null;
  final v = <int>[];
  for (var i = 0; i < 3; i++) {
    final d = nums[i];
    if (d != d.roundToDouble() || d < 0 || d > 255) return null;
    v.add(d.round());
  }
  return Color.fromARGB(255, v[0], v[1], v[2]);
}

final RegExp _rgbWordRe = RegExp(r'\brgba?\b', caseSensitive: false);

/// `RGB 0,240,255` / `RGBA 0 240 255 0.5`：标签后面（本行 + 下一行）的**头 3 个**数字。
Color? _findRgbLabeled(String text) {
  for (final m in _rgbWordRe.allMatches(text)) {
    if (m.end < text.length && text[m.end] == '(') continue; // 括号写法已由 ③ 处理
    final nums = _numbersIn(_segmentAfter(text, m.end, 2));
    final c = _rgbFromFirst3(nums, strictCount: false);
    if (c != null) return c;
  }
  return null;
}

final RegExp _cmykWordRe = RegExp(r'\bcmyk\b', caseSensitive: false);

/// `CMYK 60 0 15 0` / `CMYK` 单独一行 + 下一行 `60 0 15 0`
/// —— **抖音色卡就是这个形状**，所以窗口取「本行 + 下一行」。
List<int>? _findCmykLabeled(String text) {
  for (final m in _cmykWordRe.allMatches(text)) {
    if (m.end < text.length && text[m.end] == '(') continue; // 括号写法另有分支
    final nums = _numbersIn(_segmentAfter(text, m.end, 2));
    final v = _intsInRange(nums, 4, 100);
    if (v != null) return v;
  }
  return null;
}

/// `cmyk(60,0,15,0)`：被 ⑥ 的 `\bcmyk\b` 跳过（后面就是 `(`），这里单独认。
/// ⚠️ 顺序上它排在 [_findCmykLabeled] **之前**由 [parseColorInput] 保证：
/// 否则 `cmyk(60,0,15,0)` 会被当成"标签后头 4 个数字"（其实也认得出，但别依赖巧合）。
List<int>? _findCmykCall(String text) {
  for (final m in RegExp(r'\bcmyk\s*\(([^)]*)\)', caseSensitive: false)
      .allMatches(text)) {
    final v = _intsInRange(_numbersIn(m.group(1)!), 4, 100);
    if (v != null) return v;
  }
  return null;
}

/// 取前 [n] 个 0~[max] 的整数；不足 [n] 个或有一个越界/非整数 ⇒ null。
List<int>? _intsInRange(List<double> nums, int n, int max) {
  if (nums.length < n) return null;
  final v = <int>[];
  for (var i = 0; i < n; i++) {
    final d = nums[i];
    if (d != d.roundToDouble() || d < 0 || d > max.toDouble()) return null;
    v.add(d.round());
  }
  return v;
}

/// 裸数字行（只含数字 + 常见分隔符）里**恰好** [n] 个 0~[max] 的整数。
///
/// 用户点名的两条都在这里：
/// - `0,240,255` / `0 240 255` ⇒ 恰好 3 个 0~255 的数才算 RGB；
/// - `60 0 15 0` ⇒ 恰好 4 个 0~100 的数才算 CMYK。
/// 「恰好」是刻意的：不严格的话 `60 0 15 0` 会被读成 `RGB(60,0,15)`（一个深红），
/// 而它其实是深青。
List<int>? _findBareNumbers(String text, int n, int max) {
  final lines = text.split(RegExp(r'[\r\n]+'));
  for (final line in lines) {
    final t = line.trim();
    if (t.isEmpty) continue;
    if (!_numericLineRe.hasMatch(t)) continue; // 不是"纯数字行"就不参与裸写判定
    final nums = _numbersIn(t);
    if (nums.length != n) continue; // 「恰好 n 个」是硬条件（见本函数文档）
    final v = _intsInRange(nums, n, max);
    if (v != null) return v;
  }
  return null;
}

/// 「纯数字行」的字符集：数字 + 空白 + 常见分隔符（含全角逗号、`%`、正负号、点）。
final RegExp _numericLineRe = RegExp(r'^[\s0-9,，、;；/|+\-.%]+$');

/// 取 [from] 起到第 [lines] 行末的片段（`lines = 2` ⇒ 本行 + 下一行）。
String _segmentAfter(String text, int from, int lines) {
  if (from >= text.length) return '';
  var end = from;
  var seen = 0;
  while (end < text.length) {
    if (text.codeUnitAt(end) == 10) {
      seen++;
      if (seen >= lines) break;
    }
    end++;
  }
  return text.substring(from, end);
}

// ───────────────────────────── 名称识别 ─────────────────────────────

/// 标签类行（这些行是"栏目名"，不是颜色名）。
const List<String> _kLabelWords = [
  'cmyk', 'rgb', 'rgba', 'hsl', 'hsb', 'hsv', 'hex', 'color', 'colour',
  'colors', 'colours', 'sharing', '配色', '色彩', '色卡', '颜色', '色值', '分享',
];

final RegExp _cjkRe = RegExp(
    r'[\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF]');
final RegExp _letterOrCjkRe = RegExp(
    r'[A-Za-z\u3400-\u4DBF\u4E00-\u9FFF\uF900-\uFAFF\u3040-\u30FF\uAC00-\uD7AF]');

/// 从整段文本里挑名字：第一个合格的行，**含中日韩汉字的行优先**。
String? _findName(String text) {
  String? firstAny;
  for (final raw in text.split(RegExp(r'[\r\n]+'))) {
    final cand = _cleanNameLine(raw);
    if (cand == null) continue;
    if (_cjkRe.hasMatch(cand)) return cand; // 汉字行优先：直接返回第一个
    firstAny ??= cand;
  }
  return firstAny;
}

/// 把一行整理成候选名字；不合格返回 null。
///
/// 不合格 = 空 / 摘掉色值后为空 / 是标签 / 全是数字 / 没有字母或汉字 / 去噪后长度 > 12。
String? _cleanNameLine(String raw) {
  // ① 先把这一行里的**色值片段**摘掉（名称与色值写在同一行时也要认得出名字）
  var s = _stripColorValues(raw.trim());
  if (s.isEmpty) return null;
  s = s.replaceAll('*', '').trim(); // 去掉 markdown 的 ** 加粗
  s = s.replaceAll(RegExp(r'^[#＃\-–—\s]+'), '').trim(); // 去掉行首 # / 破折号
  s = s.replaceAll(RegExp(r'[：:\s]+$'), '').trim(); // 去掉尾巴的 ：/:
  if (s.isEmpty || s.length > 12) return null;
  final low = s.toLowerCase();
  for (final w in _kLabelWords) {
    if (low.contains(w)) return null;
  }
  if (RegExp(r'^\d+$').hasMatch(s)) return null; // 全数字不算名字
  if (!_letterOrCjkRe.hasMatch(s)) return null; // 至少得有一个字母/汉字
  return s;
}

/// 摘掉一行里的**全部色值片段**，剩下的才拿去当候选名字。
///
/// ## 为什么要有这一步（用户踩的那一下）
/// 老写法是「整行任意位置出现色值 ⇒ **整行作废**」：用户手输 `电光紫 #9D00FF`
/// 时**颜色认得出、名字认不出**，只能落到「自定义 N」。现在改成先把色值摘掉，
/// 再按原来的门槛判名字。
///
/// 摘的东西**恰好等于老 `_lineHasColorValue` 认作"色值"的那些**（不多摘，
/// 免得把名字里的数字/字母也吃掉）：
/// 1. 带前缀 HEX（`#00F0FF` / `0x00F0FF`）；
/// 2. `rgb(...)` / `rgba(...)` / `cmyk(...)` 调用（连括号里的数字一起）；
/// 3. 独立的 `RGB` / `RGBA` / `CMYK` 标签词；
/// 4. 独立成词的裸 HEX（6 / 8 位，同 [_findBareHex] 的门槛）；
/// 5. **成组的数字载荷**：连着 ≥3 个"纯数字词"（RGB 三个 / CMYK 四个），
///    或一个自带分隔符的数字词（`0,240,255`）。
///    ⚠️ 落单的数字留着（`520 玫瑰` 这种名字不该被削成 `玫瑰`）。
///
/// ⛔ **别顺手摘 `COLOR` / `配色` / `SHARING` 这类栏目词**：它们该留到下面
/// `_kLabelWords` 那一步才作废 —— `COLOR SHARING | 配色分享` 的作废理由是
/// 「超过 12 字」，不是「长得像色值」（`color_input_test.dart` ★5/★16 钉这个）。
String _stripColorValues(String line) {
  if (line.isEmpty) return '';
  var s = line.replaceAll(_prefixedHexRe, ' '); // ① 带前缀 HEX
  s = s.replaceAll(_rgbCallRe, ' '); // ② rgb() / rgba()
  s = s.replaceAll(_cmykCallRe, ' '); // ② cmyk()
  s = s.replaceAll(_valueLabelRe, ' '); // ③ RGB / RGBA / CMYK 标签词
  s = _dropBareHexTokens(s); // ④ 裸 6/8 位 HEX 整词
  s = _dropNumberPayloads(s); // ⑤ 成组数字载荷
  return s.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).join(' ').trim();
}

/// `cmyk(...)` 调用（与 [_findCmykCall] 同一条式子；那边靠 `\bcmyk\b` 跳过它）。
final RegExp _cmykCallRe = RegExp(r'\bcmyk\s*\(([^)]*)\)', caseSensitive: false);

/// 色值**标签词**：只收老 `_lineHasColorValue` 认的那两族（RGB / CMYK）。
final RegExp _valueLabelRe = RegExp(r'\b(?:rgba?|cmyk)\b', caseSensitive: false);

/// 数字词：只有数字 + 常见分隔符（`60` / `0,240,255` / `0-15` / `50%`）。
final RegExp _numberTokenRe = RegExp(r'^[\d.,，、;；/+%\-]+$');

/// 自带分隔符的数字词（`0,240,255`）—— 一个词就是一段色值载荷。
final RegExp _separatedNumbersRe = RegExp(r'[0-9][,，、;；/][0-9]');

/// 丢掉**独立成词**的裸 6 / 8 位 HEX（与 [_findBareHex] 完全同一套门槛）。
String _dropBareHexTokens(String s) {
  final buf = StringBuffer();
  var last = 0;
  for (final m in _hexTokenRe.allMatches(s)) {
    final d = m.group(0)!;
    if (d.length != 6 && d.length != 8) continue;
    if (!_isStandaloneToken(s, m.start, m.end)) continue;
    buf.write(s.substring(last, m.start));
    buf.write(' ');
    last = m.end;
  }
  if (last == 0) return s;
  buf.write(s.substring(last));
  return buf.toString();
}

/// 丢掉成组的数字载荷：连着 ≥3 个数字词（RGB 三 / CMYK 四），
/// 或单个自带分隔符的数字词（`0,240,255`）。落单的数字原样留着。
String _dropNumberPayloads(String s) {
  final parts = s.split(RegExp(r'\s+'));
  final out = <String>[];
  var i = 0;
  while (i < parts.length) {
    if (!_numberTokenRe.hasMatch(parts[i])) {
      out.add(parts[i]);
      i++;
      continue;
    }
    var j = i;
    var separated = false;
    while (j < parts.length && _numberTokenRe.hasMatch(parts[j])) {
      if (_separatedNumbersRe.hasMatch(parts[j])) separated = true;
      j++;
    }
    if (j - i >= 3 || separated) {
      i = j; // 整段是色值载荷 ⇒ 全丢
      continue;
    }
    out.addAll(parts.sublist(i, j)); // 落单的数字留着
    i = j;
  }
  return out.join(' ');
}

