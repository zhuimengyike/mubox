/// 自定义主题色选择器：**粘贴/手输色值**（抖音色卡整段识别）+ HSV 三滑条
/// （色相/饱和度/明度）+ 实时预览 + 可选名称。
/// 返回一套 AccentScheme（浅色自动由主色向白色混出更柔和的次级色）；取消返回 null。
///
/// ## 顶部那块输入区是干什么的
///
/// 只有三根 HSV 滑杆时，照着色卡上印的数值**调不出来**。所以弹层顶部多一块输入区：
/// 输入/粘贴框（多行）+「粘贴」按钮 + 实时解析：
/// - 认出来 ⇒ 三根滑杆同步、预览与回显跟着变、名称框按「只在空着或还是自动填的值时覆盖」自动填；
/// - 只认出 CMYK ⇒ 显示 [ColorInputParse.note]（如实说和屏幕色卡可能对不上）；
/// - 认不出来 ⇒ 一句灰色提示，**不弹错、也不清掉用户已经拖好的颜色**。
///
/// ⚠️ 解析全在 `lib/color_input.dart`（纯逻辑、可单测、任何输入不抛异常），这里只管接线。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_config.dart';
import '../color_input.dart';
import '../theme.dart';
import 'glass_panel.dart';

/// 弹层里各块的 key：widget 测试要用，也方便一眼看出"这是哪一块"。
const Key kCustomColorPanelKey = Key('custom_color_panel');
const Key kCustomColorInputKey = Key('custom_color_input');
const Key kCustomColorPasteKey = Key('custom_color_paste');
const Key kCustomColorHintKey = Key('custom_color_hint');
const Key kCustomColorEchoKey = Key('custom_color_echo');
const Key kCustomColorPreviewKey = Key('custom_color_preview');
const Key kCustomColorNameKey = Key('custom_color_name');
const Key kCustomColorScrollKey = Key('custom_color_scroll');

/// 弹出自定义主题色选择器，返回用户创建的主题方案（取消返回 null）。
Future<AccentScheme?> showCustomColorPicker(BuildContext context) {
  return showModalBottomSheet<AccentScheme>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => const _CustomColorSheet(),
  );
}

class _CustomColorSheet extends StatefulWidget {
  const _CustomColorSheet();

  @override
  State<_CustomColorSheet> createState() => _CustomColorSheetState();
}

class _CustomColorSheetState extends State<_CustomColorSheet> {
  double _hue = 220;
  double _sat = 0.7;
  double _val = 0.9;
  late final TextEditingController _name = TextEditingController();

  /// 输入/粘贴框（多行：一整张色卡能塞进来）。
  final TextEditingController _input = TextEditingController();

  /// 上一次**自动**填进名称框的值。
  /// ⚠️ 用户手改过名称之后（`_name.text != _lastAutoName`）就不许再被覆盖 ——
  /// 否则他把「霓虹蓝」改成「我的蓝」之后再粘一张卡，名字就被冲掉了。
  String _lastAutoName = '';

  /// 上一次解析结果（初值 = 什么都没认出来）。
  ColorInputParse _parsed = const ColorInputParse();

  /// 输入框是不是空的（空着的时候不显示"没认出来"那句，别一打开就报丧）。
  bool _inputEmpty = true;

  /// 上一次点「粘贴」时剪贴板是空的（给用户一句回话，别点了没反应）。
  bool _clipboardEmpty = false;

  Color get _primary => HSVColor.fromAHSV(1, _hue, _sat, _val).toColor();

  /// 浅色 = 主色向白色混合，得到更柔和的次级强调色（与内置 40 套的搭配一致）。
  Color get _light => Color.lerp(_primary, Colors.white, 0.5)!;

  @override
  void dispose() {
    _name.dispose();
    _input.dispose();
    super.dispose();
  }

  // ────────────────────────── 解析接线 ──────────────────────────

  /// 输入变化 / 粘贴之后走这里：解析 → 同步滑杆 + 预览 + 回显 + 名称。
  ///
  /// ⚠️ **认不出来时什么都不动**：颜色保持用户已经拖好的那个，只换一句提示。
  void _applyInput(String raw) {
    final p = parseColorInput(raw);
    setState(() {
      _parsed = p;
      _inputEmpty = raw.trim().isEmpty;
      _clipboardEmpty = false;
      final c = p.color;
      if (c == null) return;
      final hsv = HSVColor.fromColor(c);
      _hue = hsv.hue;
      _sat = hsv.saturation;
      _val = hsv.value;
      _autoFillName(p.name);
    });
  }

  /// 名称自动填：**只在名称框空着、或上一次填进去的就是自动值**时覆盖。
  void _autoFillName(String? name) {
    if (name == null || name.isEmpty) return;
    if (_name.text.trim().isNotEmpty && _name.text != _lastAutoName) return;
    _name.text = name;
    _lastAutoName = name;
  }

  /// 「粘贴」按钮：读剪贴板 → 塞进输入框 → 立刻解析（用户从抖音复制过来一键就能贴）。
  Future<void> _paste() async {
    String text = '';
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      text = data?.text ?? '';
    } catch (_) {
      // 剪贴板通道异常不该让弹层崩（老 ROM / 无剪贴板服务）：当成"没读到"。
      text = '';
    }
    if (!mounted) return;
    if (text.trim().isEmpty) {
      // 剪贴板空：**什么都不动**（输入框里已有的内容与已解析出的颜色都保留），
      // 只把"没读到"这件事说出来 —— 别让用户点了没反应，也别把他手上的东西洗掉。
      setState(() => _clipboardEmpty = true);
      return;
    }
    final t = text.trim();
    _input.text = t;
    _applyInput(t);
  }

  /// 提示行要显示什么（`text == null` = 这一行不占位），以及它是不是"CMYK 那句提醒"
  /// （决定颜色与要不要带那颗 ⓘ）。
  ///
  /// 优先级：剪贴板空的回话 > 认出来了（有 note 就显示，没有就不占位）> 空输入（不打扰）
  /// > 没认出来。
  ///
  /// ⚠️ 「认出来了但 note 为 null」（HEX / RGB）**必须走中间那条**：
  /// 第一版把它漏成了最后那条兜底 ⇒ 粘一张带 HEX 的色卡反而显示"没认出来"
  /// （`test/custom_color_sheet_test.dart` 的 ★3 / ★6 就是钉这个的）。
  ({String? text, bool isNote}) get _hint {
    if (_clipboardEmpty) {
      return (text: '剪贴板里没有文字，可以直接拖下面的滑杆', isNote: false);
    }
    if (_parsed.color != null) {
      return (text: _parsed.note, isNote: _parsed.note != null);
    }
    if (_inputEmpty) return (text: null, isNote: false);
    return (text: '没认出来，可以直接拖下面的滑杆', isNote: false);
  }

  /// 回显行：当前颜色的 HEX · RGB · HSL（拖滑杆时同步变）。
  ///
  /// ⚠️ **刻意不显示 CMYK**：
  /// 色卡上印的 CMYK 是**印刷色**，和屏幕色的朴素反算对不上（`#00F0FF` 反算是
  /// `100 6 0 0`，卡片写的是 `60 0 15 0`）—— 同一行里并排显示两个互相矛盾的
  /// CMYK，用户会以为 App 认错了。`rgbToCmyk()` 仍留在 `color_input.dart` 里导出
  /// （它是 CMYK 那一路的逆运算证明，还有单测在用），
  /// 只是**不再进回显行**。
  String get _echoLine {
    final c = _primary;
    final argb = c.toARGB32();
    final hsl = HSLColor.fromColor(c);
    return '${hexOf(c)} · '
        'RGB ${(argb >> 16) & 0xFF},${(argb >> 8) & 0xFF},${argb & 0xFF} · '
        'HSL ${hsl.hue.round()}° ${(hsl.saturation * 100).round()}% '
        '${(hsl.lightness * 100).round()}%';
  }

  @override
  Widget build(BuildContext context) {
    final primary = _primary;
    final hint = _hint;
    return GlassPanel(
      key: kCustomColorPanelKey,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // ── 可滚区：内容 + 键盘一起顶上来时**不许溢出**（见文件末尾那条注释）──
              Flexible(
                child: SingleChildScrollView(
                  key: kCustomColorScrollKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          const Expanded(
                            child: Text(
                              '自定义主题色',
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.close,
                                size: 20, color: Colors.white54),
                            onPressed: () => Navigator.pop(context),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      _buildInputBlock(hint),
                      const SizedBox(height: 12),
                      // 实时预览：主色 → 浅色 对角渐变
                      Center(
                        child: Container(
                          key: kCustomColorPreviewKey,
                          width: 64,
                          height: 64,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [primary, _light],
                            ),
                            border: Border.all(color: Colors.white30, width: 2),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      _gradientSlider(
                        label: '色相',
                        value: _hue,
                        max: 360,
                        trackColors: [
                          for (var h = 0; h <= 360; h += 30)
                            HSVColor.fromAHSV(1, h.toDouble(), 1, 1).toColor(),
                        ],
                        onChanged: (v) => setState(() => _hue = v),
                      ),
                      _gradientSlider(
                        label: '饱和度',
                        value: _sat,
                        max: 1,
                        trackColors: [
                          HSVColor.fromAHSV(1, _hue, 0, _val).toColor(),
                          HSVColor.fromAHSV(1, _hue, 1, _val).toColor(),
                        ],
                        onChanged: (v) => setState(() => _sat = v),
                      ),
                      _gradientSlider(
                        label: '明度',
                        value: _val,
                        max: 1,
                        trackColors: [
                          Colors.black,
                          HSVColor.fromAHSV(1, _hue, _sat, 1).toColor(),
                        ],
                        onChanged: (v) => setState(() => _val = v),
                      ),
                      const SizedBox(height: 8),
                      // 回显行：拖滑杆 / 粘贴之后都跟着走
                      Text(
                        _echoLine,
                        key: kCustomColorEchoKey,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.35,
                          color: Colors.white54,
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        key: kCustomColorNameKey,
                        controller: _name,
                        style: const TextStyle(color: Colors.white),
                        decoration: const InputDecoration(
                          labelText: '名称（可选）',
                          labelStyle: TextStyle(color: Colors.white38),
                          hintText: '不填自动命名',
                          hintStyle: TextStyle(color: Colors.white30),
                          enabledBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white24),
                          ),
                          focusedBorder: UnderlineInputBorder(
                            borderSide: BorderSide(color: Colors.white),
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            style: TextButton.styleFrom(
                                foregroundColor: Colors.white70),
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消'),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: _confirm,
                            child: const Text('创建'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              // 键盘弹出时把内容整体顶上去：全局 resizeToAvoidBottomInset=false +
              // Manifest adjustNothing，bottom sheet 不会自动避让键盘，否则「名称」
              // 输入框会被键盘盖住（对话框有框架补 insets，sheet 没有）。
              //
              // ⚠️ 这一句**必须留在可滚区之外**：键盘高度算进滚动内容的话，
              // 滚到底也够不着「创建」（内容 + 键盘 = 1000+ > 屏幕 900）。
              SizedBox(height: MediaQuery.viewInsetsOf(context).bottom),
            ],
          ),
        ),
      ),
    );
  }

  /// 输入区：标签 + 粘贴按钮 + 多行输入框 + 提示行。
  Widget _buildInputBlock(({String? text, bool isNote}) hint) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '粘贴色卡 / 手输色值',
                style: TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ),
            TextButton.icon(
              key: kCustomColorPasteKey,
              onPressed: _paste,
              icon: const Icon(Icons.content_paste, size: 16),
              label: const Text('粘贴'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.primary,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 32),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        TextField(
          key: kCustomColorInputKey,
          controller: _input,
          maxLines: 3,
          minLines: 1,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(color: Colors.white, fontSize: 13, height: 1.35),
          onChanged: _applyInput,
          decoration: InputDecoration(
            isDense: true,
            hintText: '粘贴色卡整段，或直接输入 #00F0FF / RGB 0,240,255 / CMYK 60 0 15 0',
            hintStyle: const TextStyle(color: Colors.white30, fontSize: 12),
            hintMaxLines: 2,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Colors.white24),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: Colors.white),
            ),
          ),
        ),
        if (hint.text != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (hint.isNote) ...[
                  const Padding(
                    padding: EdgeInsets.only(top: 1),
                    child: Icon(Icons.info_outline,
                        size: 13, color: Colors.white54),
                  ),
                  const SizedBox(width: 4),
                ],
                Expanded(
                  child: Text(
                    hint.text!,
                    key: kCustomColorHintKey,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.35,
                      // CMYK 那句是"要看的提醒"（white70），
                      // "没认出来 / 剪贴板空"是灰提示（white38）—— 沿用本弹层既有的两档
                      color: hint.isNote ? Colors.white70 : Colors.white38,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  void _confirm() {
    var name = _name.text.trim();
    if (name.isEmpty) {
      name = '自定义 ${AppConfig.instance.customThemes.length + 1}';
    }
    Navigator.pop(context, AccentScheme(name, _primary, _light));
  }

  /// 通用渐变滑条：一条渐变色带 + 透明轨道的 Slider，滑块白色定位。
  Widget _gradientSlider({
    required String label,
    required double value,
    required double max,
    required List<Color> trackColors,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(fontSize: 13, color: Colors.white)),
            Text(
              label == '色相' ? '${value.round()}°' : '${(value * 100).round()}%',
              style: const TextStyle(fontSize: 12, color: Colors.white38),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Stack(
          alignment: Alignment.center,
          children: [
            Container(
              height: 10,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                gradient: LinearGradient(colors: trackColors),
              ),
            ),
            SliderTheme(
              data: const SliderThemeData(
                trackHeight: 10,
                activeTrackColor: Colors.transparent,
                inactiveTrackColor: Colors.transparent,
                thumbColor: Colors.white,
                overlayColor: Colors.white24,
              ),
              child: Slider(
                value: value,
                min: 0,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
