/// 主题系统：多套配色方案 + 动态 ThemeData。
library;

import 'package:flutter/material.dart';

import 'app_config.dart';

/// 一套主题配色：主色（按钮/图标/高亮）+ 浅色（渐变/次强调）。
class AccentScheme {
  final String name;
  final Color primary;
  final Color light;
  const AccentScheme(this.name, this.primary, this.light);
}

/// 40 套舒适配色
const List<AccentScheme> kAccentSchemes = [
  AccentScheme('经典蓝', Color(0xFF6089EE), Color(0xFFA9BDF7)),
  AccentScheme('翡翠绿', Color(0xFF2BB673), Color(0xFF7FD9B0)),
  AccentScheme('日落橙', Color(0xFFFF8A50), Color(0xFFFFC9A3)),
  AccentScheme('樱花粉', Color(0xFFF270A0), Color(0xFFFAB6D0)),
  AccentScheme('星空紫', Color(0xFF9B6BFF), Color(0xFFC9B0FF)),
  AccentScheme('薄荷青', Color(0xFF2BC7B5), Color(0xFF8AE5DD)),
  AccentScheme('珊瑚红', Color(0xFFFF6B6B), Color(0xFFFFB0B0)),
  AccentScheme('琥珀金', Color(0xFFE8A33D), Color(0xFFF5CE8B)),
  AccentScheme('天湖蓝', Color(0xFF4FC3F7), Color(0xFFA5E0FF)),
  AccentScheme('青草绿', Color(0xFF7CB342), Color(0xFFAED581)),
  AccentScheme('玫红', Color(0xFFE84A7E), Color(0xFFF59BB7)),
  AccentScheme('靛蓝', Color(0xFF6C7BD9), Color(0xFFA7B1EB)),
  AccentScheme('薰衣草', Color(0xFFB09BEA), Color(0xFFD8CCF5)),
  AccentScheme('暖阳黄', Color(0xFFF5C94F), Color(0xFFF9E59C)),
  AccentScheme('柠檬青', Color(0xFFAAD450), Color(0xFFD2E89A)),
  AccentScheme('孔雀蓝', Color(0xFF1E9CB0), Color(0xFF6FD2DF)),
  AccentScheme('雾蓝', Color(0xFF7FA9CE), Color(0xFFBBD6EA)),
  AccentScheme('藕荷', Color(0xFFCF93B3), Color(0xFFE5C4D6)),
  AccentScheme('咖啡', Color(0xFFC58B59), Color(0xFFE0BC96)),
  AccentScheme('银灰', Color(0xFF9AA7B5), Color(0xFFC2CDD9)),
  AccentScheme('桃粉', Color(0xFFFF9E9E), Color(0xFFFFC9C9)),
  AccentScheme('葡萄紫', Color(0xFF9B59B6), Color(0xFFC9A8DC)),
  AccentScheme('杏粉', Color(0xFFF2B6B6), Color(0xFFF8DADA)),
  AccentScheme('暖橘', Color(0xFFFF6F2C), Color(0xFFFFB796)),
  AccentScheme('蛋壳黄', Color(0xFFF8C387), Color(0xFFFCE1C3)),
  AccentScheme('琥珀黄', Color(0xFFF9B800), Color(0xFFFCDC80)),
  AccentScheme('晴棠', Color(0xFFFFE76F), Color(0xFFFFF3B7)),
  AccentScheme('柠檬黄绿', Color(0xFFF0FF0A), Color(0xFFF8FF84)),
  AccentScheme('莽芜绿', Color(0xFF88AE1B), Color(0xFFC4D68D)),
  AccentScheme('荧光绿', Color(0xFFB2FC06), Color(0xFFD8FE82)),
  AccentScheme('薄荷绿', Color(0xFFA4E2C6), Color(0xFFD2F0E2)),
  AccentScheme('冰绡', Color(0xFF31FCF7), Color(0xFF98FEFB)),
  AccentScheme('亮青蓝', Color(0xFF1DDFFF), Color(0xFF8EEFFF)),
  AccentScheme('海蓝', Color(0xFF1E9BFF), Color(0xFF8ECDFF)),
  AccentScheme('菖蒲紫', Color(0xFF694D9F), Color(0xFFB4A6CF)),
  AccentScheme('电光紫', Color(0xFF9D00FF), Color(0xFFCE80FF)),
  AccentScheme('璎珞紫', Color(0xFFED35F9), Color(0xFFF69AFC)),
  AccentScheme('多巴胺粉', Color(0xFFFF007D), Color(0xFFFF80BE)),
  AccentScheme('酒莓', Color(0xFFA82F4F), Color(0xFFD497A7)),
  AccentScheme('绛绯', Color(0xFFD50E3D), Color(0xFFEA869E)),
];

/// 旧的「氛围色调」5 套（全局一档的年代用的），现在并入「特效颜色」列表。
/// **槽位固定在 [kFxTintPresetBase] 起**（1000+），与主题色的内置 0~39、自定义 40+
/// 都不冲突；`FxParam._c` 的上界要 ≥ 最后一个槽位，`setFx` 的 clamp 才不会砍掉它。
class AmbientTint {
  final String name;
  final Color primary;
  final Color light;
  const AmbientTint(this.name, this.primary, this.light);
}

const int kFxTintPresetBase = 1000;

const List<AmbientTint> kFxTintPresets = [
  AmbientTint('水蓝', Color(0xFF9DD9FF), Color(0xFFD7EDFF)),
  AmbientTint('暖金', Color(0xFFFFC966), Color(0xFFFFE4B5)),
  AmbientTint('星紫', Color(0xFFC9B0FF), Color(0xFFE6D9FF)),
  AmbientTint('薄荷', Color(0xFF8AE5DD), Color(0xFFD3F5F1)),
  AmbientTint('樱粉', Color(0xFFFAB6D0), Color(0xFFFDE2EC)),
];

/// 水蓝的槽位：「星空/彩星/极光/气泡/水面/波纹」的**默认**颜色。
/// ⚠️ 改动前这六个特效的默认色就是固定的水蓝（旧 `AppConfig.ambientTint = 1`），
/// 不是「跟随主题」—— 缺省别写回 -1，否则默认观感会整体换色。
const double kFxTintDefault = kFxTintPresetBase + 0;

/// 一条可选的「特效颜色」：tint = -1 表示跟随主题，0~39 内置主题色、40+ 用户自定义色，
/// 1000+ 旧的氛围色调（见 [kFxTintPresets]）。
typedef FxTintChoice = ({int tint, String name, Color primary, Color light});

/// 某个特效可选的全部颜色：跟随主题 + 未被隐藏的内置主题色 + 用户自定义色 +
/// 旧的氛围色调。特效设置页的颜色选择条就按这个列表渲染。
List<FxTintChoice> fxTintChoices(
    AppConfig cfg, Color themePrimary, Color themeLight) {
  final list = <FxTintChoice>[
    (tint: -1, name: '跟随主题', primary: themePrimary, light: themeLight),
  ];
  for (var i = 0; i < kDefaultThemeCount; i++) {
    if (cfg.hiddenDefaultThemes.contains(i)) continue; // 被删掉的颜色不再出现
    final s = kAccentSchemes[i];
    list.add((tint: i, name: s.name, primary: s.primary, light: s.light));
  }
  for (var j = 0; j < cfg.customThemes.length; j++) {
    final s = cfg.customThemes[j];
    list.add((
      tint: kDefaultThemeCount + j,
      name: s.name,
      primary: s.primary,
      light: s.light,
    ));
  }
  for (var i = 0; i < kFxTintPresets.length; i++) {
    final s = kFxTintPresets[i];
    list.add((
      tint: kFxTintPresetBase + i,
      name: s.name,
      primary: s.primary,
      light: s.light,
    ));
  }
  return list;
}

/// 把某个特效选的「颜色」槽位解析成实际两色。
/// -1 / 越界 / 该自定义色已被删 → 一律回落到当前主题色（观感不会突然变成怪颜色）。
(Color, Color) fxTintColors(int tint, Color themePrimary, Color themeLight) {
  if (tint < 0) return (themePrimary, themeLight);
  if (tint >= kFxTintPresetBase) {
    final pi = tint - kFxTintPresetBase;
    if (pi >= 0 && pi < kFxTintPresets.length) {
      final s = kFxTintPresets[pi];
      return (s.primary, s.light);
    }
    return (themePrimary, themeLight);
  }
  if (tint < kDefaultThemeCount) {
    final s = kAccentSchemes[tint];
    return (s.primary, s.light);
  }
  final ci = tint - kDefaultThemeCount;
  final customs = AppConfig.instance.customThemes;
  if (ci >= 0 && ci < customs.length) {
    return (customs[ci].primary, customs[ci].light);
  }
  return (themePrimary, themeLight);
}

/// 全局背景底色
const Color kBgColor = Color(0xFF12141A);

/// 卡片/面板底色
const Color kSurfaceColor = Color(0xFF1C1F27);

/// 内置默认主题色数量（自定义主题色的稳定槽位索引从它往后排：40、41、42…）。
/// 用 final 而不是 const：Dart 不允许在 const 表达式里取 List.length。
final int kDefaultThemeCount = kAccentSchemes.length;

/// 把一套主题方案编码成可持久化的 JSON（颜色存 ARGB int）。
Map<String, dynamic> accentSchemeToJson(AccentScheme s) => {
  'name': s.name,
  'primary': s.primary.toARGB32(),
  'light': s.light.toARGB32(),
};

/// 从 JSON 还原一套主题方案。
AccentScheme accentSchemeFromJson(Map<String, dynamic> m) => AccentScheme(
  m['name'] as String,
  Color(m['primary'] as int),
  Color(m['light'] as int),
);

/// 解析当前选中的主题方案：themeIndex 是「稳定槽位」——0~39 为内置默认，40+ 为自定义。
/// 选中项被隐藏/越界时，回退到第一个可见内置色 → 第一个自定义色 → 第一套默认色。
AccentScheme resolveThemeScheme(AppConfig config) {
  final i = config.themeIndex;
  if (i < kDefaultThemeCount) {
    if (i >= 0 && !config.hiddenDefaultThemes.contains(i)) {
      return kAccentSchemes[i];
    }
  } else {
    final ci = i - kDefaultThemeCount;
    if (ci >= 0 && ci < config.customThemes.length) return config.customThemes[ci];
  }
  for (var j = 0; j < kDefaultThemeCount; j++) {
    if (!config.hiddenDefaultThemes.contains(j)) return kAccentSchemes[j];
  }
  if (config.customThemes.isNotEmpty) return config.customThemes.first;
  return kAccentSchemes.first;
}

/// 主题扩展：提供 primary 之外的"浅色"强调色（频谱渐变等用）。
@immutable
class MuBoxColors extends ThemeExtension<MuBoxColors> {
  /// 主题主色：背景动效（频谱/雨滴/粒子/壁纸光晕）与主题选择页专用，与界面控件解耦。
  final Color accent;
  /// 主题浅色：频谱渐变等次强调。
  final Color accentLight;
  const MuBoxColors({required this.accent, required this.accentLight});

  @override
  MuBoxColors copyWith({Color? accent, Color? accentLight}) => MuBoxColors(
        accent: accent ?? this.accent,
        accentLight: accentLight ?? this.accentLight,
      );

  @override
  MuBoxColors lerp(MuBoxColors? other, double t) {
    if (other == null) return this;
    return MuBoxColors(
      accent: Color.lerp(accent, other.accent, t)!,
      accentLight: Color.lerp(accentLight, other.accentLight, t)!,
    );
  }
}

extension MuBoxColorsX on BuildContext {
  Color get accent =>
      Theme.of(this).extension<MuBoxColors>()?.accent ?? kAccentSchemes.first.primary;
  Color get accentLight =>
      Theme.of(this).extension<MuBoxColors>()?.accentLight ?? kAccentSchemes.first.light;
}

ThemeData buildTheme(AppConfig config) {
  final acc = resolveThemeScheme(config);
  return ThemeData(
    brightness: Brightness.dark,
    fontFamily: config.fontFamily.isEmpty ? null : config.fontFamily,
    scaffoldBackgroundColor: kBgColor,
    colorScheme: ColorScheme.dark(
      primary: acc.primary,
      secondary: acc.light,
      surface: const Color(0xFF181B22),
      onSurface: const Color(0xFFE6E8EE),
    ),
    // 主题色只上到「刻意」的按钮/控件/高亮；光标、点击水波纹、文本选中等
    // 「有的没的」位置保持中性，避免灰色主题把整页染脏。
    splashColor: Colors.white24,
    highlightColor: Colors.white12,
    focusColor: Colors.white24,
    hoverColor: Colors.white12,
    textSelectionTheme: const TextSelectionThemeData(
      cursorColor: Colors.white70,
      selectionColor: Colors.white24,
      selectionHandleColor: Colors.white70,
    ),
    extensions: [MuBoxColors(accent: acc.primary, accentLight: acc.light)],
    useMaterial3: true,
  );
}
