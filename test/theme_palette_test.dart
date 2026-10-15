/// 内置 40 套主题色**整表冻结**（名字 / primary / light 逐项比对）+ 结构守卫。
///
/// ## 这张表怎么来的
/// 原第 23~40 项（`牛油果` → `石板灰`）**又暗又脏**，删掉，
/// 从 `主题色.md`（抖音「配色分享」色卡）里另选 18 个补回来。
/// 做法 = **原地替换槽位 22~39**，前 22 项（`经典蓝` → `葡萄紫`）逐字节不动，
/// **总数仍然是 40**。
///
/// ## 为什么「总数 40」是硬约束（这就是本文件存在的理由）
/// 下标在本仓是**持久化身份**，不是"列表位置"：
/// - `AppConfig.themeIndex` 存的选中项、`hiddenDefaultThemes` 存的已删内置色；
/// - 每个特效的 `<prefix>.tint` 颜色槽位（`0~39` = 内置主题色，`40+` = 自定义色，
///   `1000+` = 旧的氛围色，见 `theme.dart` 的 `kFxTintPresets`）。
///
/// ⇒ 少一项 / 多一项 / 挪一位 = 老用户选中的颜色和已配好的特效色**整体错位**。
/// 所以本文件的第一个断言就是 `length == 40`，第二个是**整张表逐项比对**。
///
/// ## ⚠️ 这里比对的是**写死在期望表里的 40 组常量**，不是"和它自己比"
/// 期望表是从 `lib/theme.dart` 与给定的 18 行**抄下来的快照**。
/// 以后谁改了一个色值、挪了一行、把两行调换，这里必须**当场红**（`reason` 会指出是第几槽位）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/theme.dart';

/// 40 组期望值：(名称, primary ARGB, light ARGB)。
///
/// **槽位顺序就是身份**：下标 0~21 = 要求"一行都不许动"的既有 22 套；
/// 下标 22~39 = 换上的 18 套抖音色卡色（按色相排序）。
///
/// ⚠️ 抄写纪律：这张表只许**从 `lib/theme.dart` 原文抄**，⛔ 不许"顺手调一下顺序"。
const List<(String, int, int)> kFrozenPalette = [
  // ── 槽位 0~21：既有 22 套，逐字节冻结 ──
  ('经典蓝', 0xFF6089EE, 0xFFA9BDF7),
  ('翡翠绿', 0xFF2BB673, 0xFF7FD9B0),
  ('日落橙', 0xFFFF8A50, 0xFFFFC9A3),
  ('樱花粉', 0xFFF270A0, 0xFFFAB6D0),
  ('星空紫', 0xFF9B6BFF, 0xFFC9B0FF),
  ('薄荷青', 0xFF2BC7B5, 0xFF8AE5DD),
  ('珊瑚红', 0xFFFF6B6B, 0xFFFFB0B0),
  ('琥珀金', 0xFFE8A33D, 0xFFF5CE8B),
  ('天湖蓝', 0xFF4FC3F7, 0xFFA5E0FF),
  ('青草绿', 0xFF7CB342, 0xFFAED581),
  ('玫红', 0xFFE84A7E, 0xFFF59BB7),
  ('靛蓝', 0xFF6C7BD9, 0xFFA7B1EB),
  ('薰衣草', 0xFFB09BEA, 0xFFD8CCF5),
  ('暖阳黄', 0xFFF5C94F, 0xFFF9E59C),
  ('柠檬青', 0xFFAAD450, 0xFFD2E89A),
  ('孔雀蓝', 0xFF1E9CB0, 0xFF6FD2DF),
  ('雾蓝', 0xFF7FA9CE, 0xFFBBD6EA),
  ('藕荷', 0xFFCF93B3, 0xFFE5C4D6),
  ('咖啡', 0xFFC58B59, 0xFFE0BC96),
  ('银灰', 0xFF9AA7B5, 0xFFC2CDD9),
  ('桃粉', 0xFFFF9E9E, 0xFFFFC9C9),
  ('葡萄紫', 0xFF9B59B6, 0xFFC9A8DC),
  // ── 槽位 22~39：换上的 18 套（按色相排序，顺序照抄给定清单）──
  ('杏粉', 0xFFF2B6B6, 0xFFF8DADA),
  ('暖橘', 0xFFFF6F2C, 0xFFFFB796),
  ('蛋壳黄', 0xFFF8C387, 0xFFFCE1C3),
  ('琥珀黄', 0xFFF9B800, 0xFFFCDC80),
  ('晴棠', 0xFFFFE76F, 0xFFFFF3B7),
  ('柠檬黄绿', 0xFFF0FF0A, 0xFFF8FF84),
  ('莽芜绿', 0xFF88AE1B, 0xFFC4D68D),
  ('荧光绿', 0xFFB2FC06, 0xFFD8FE82),
  ('薄荷绿', 0xFFA4E2C6, 0xFFD2F0E2),
  ('冰绡', 0xFF31FCF7, 0xFF98FEFB),
  ('亮青蓝', 0xFF1DDFFF, 0xFF8EEFFF),
  ('海蓝', 0xFF1E9BFF, 0xFF8ECDFF),
  ('菖蒲紫', 0xFF694D9F, 0xFFB4A6CF),
  ('电光紫', 0xFF9D00FF, 0xFFCE80FF),
  ('璎珞紫', 0xFFED35F9, 0xFFF69AFC),
  ('多巴胺粉', 0xFFFF007D, 0xFFFF80BE),
  ('酒莓', 0xFFA82F4F, 0xFFD497A7),
  ('绛绯', 0xFFD50E3D, 0xFFEA869E),
];

/// 明度窗口：低于下限 = 当主题色看不清（炭黑/深褐），高于上限 = 白到没颜色（云白）。
const double kLightnessFloor = 0.35;
const double kLightnessCeil = 0.87;

/// 饱和度下限：**HSV 饱和度**（`(max-min)/max`，与 HSL 的 saturation 不是一回事）。
/// 低于它基本就是灰阶 —— 当主题色等于"没有颜色"。
const double kSaturationFloor = 0.28;

/// ⚠️ **不达标白名单（恰好这三条，且必须逐条说明来路）**。
///
/// 说明：给定的阈值（饱和度 ≥ 0.28）与**被冻结的色值**有冲突 ——
/// 三条既有/指定的颜色本来就在阈值之下：
/// - `银灰` #9AA7B5（槽位 19，S=0.15）：**明确要求前 22 项一行都不许动**，
///   它是既有的灰族色，删不得也改不得；
/// - `杏粉` #F2B6B6（槽位 22，S=0.25）：亲自指定（抖音色卡）；
/// - `薄荷绿` #A4E2C6（槽位 30，S=0.27）：同上。
///
/// ⇒ 处理办法：**不改色值、也不放宽阈值**（放宽阈值 = 守卫失效），改成白名单。
/// 守卫的作用因此精确地变成要的那件事：**以后不许再混进新的灰/黑/白**。
const List<String> kLowSaturationAllowlist = ['银灰', '杏粉', '薄荷绿'];

void main() {
  test('★1 槽位总数仍是 40（kDefaultThemeCount 跟着是 40 = 自定义色的起点）', () {
    expect(kAccentSchemes, hasLength(40),
        reason: '★ 用户的选择与特效色槽位全按下标定位：多一个/少一个都会让老数据整体错位');
    expect(kFrozenPalette, hasLength(40), reason: '期望表自己也必须是 40 条（少一条就是漏抄）');
    expect(kDefaultThemeCount, 40,
        reason: '★ 自定义色的稳定槽位从 40 起（`40+` = customThemes），'
            '它 = kAccentSchemes.length，别改成写死或改成 const');
  });

  test('★2 整表冻结：40 组 (名称, primary, light) 逐项比对', () {
    for (var i = 0; i < 40; i++) {
      final want = kFrozenPalette[i];
      final got = kAccentSchemes[i];
      expect(got.name, want.$1, reason: '槽位 $i 的名字被改动了');
      expect(got.primary.toARGB32(), want.$2,
          reason: '槽位 $i（${want.$1}）的 primary 被改动了');
      expect(got.light.toARGB32(), want.$3,
          reason: '槽位 $i（${want.$1}）的 light 被改动了');
    }
  });

  test('★3 名字 40 个互不重复；primary 的 ARGB 值 40 个互不重复', () {
    final names = kAccentSchemes.map((s) => s.name).toList();
    expect(names.toSet(), hasLength(40),
        reason: '★ 重名 ⇒ 主题选择页上两个条目长得一样，用户分不清自己选的是哪个');
    final argbs = kAccentSchemes.map((s) => s.primary.toARGB32()).toList();
    expect(argbs.toSet(), hasLength(40),
        reason: '★ 同一主色出现两次 ⇒ 换了主题看着没变（且期望表里两项会互相掩护）');
  });

  test('★4 结构守卫：40 个 primary 的 HSL 明度 ∈ [0.35, 0.87]', () {
    final out = <String>[];
    for (var i = 0; i < kAccentSchemes.length; i++) {
      final s = kAccentSchemes[i];
      final l = HSLColor.fromColor(s.primary).lightness;
      if (l < kLightnessFloor || l > kLightnessCeil) {
        out.add('${s.name}(槽位 $i, L=${l.toStringAsFixed(3)})');
      }
    }
    expect(out, isEmpty,
        reason: '★ 明度必须落在 [$kLightnessFloor, $kLightnessCeil]：'
            '太暗（< $kLightnessFloor）当主题色看不见按钮/高亮，'
            '太白（> $kLightnessCeil）等于没颜色 —— 用户删掉的「石板灰」就是这一类。'
            '实际越界：$out');
  });

  test('★5 结构守卫：40 个 primary 的 HSV 饱和度 ≥ 0.28（白名单之外不许有新的）', () {
    final low = <String>[
      for (var i = 0; i < kAccentSchemes.length; i++)
        if (HSVColor.fromColor(kAccentSchemes[i].primary).saturation <
            kSaturationFloor)
          kAccentSchemes[i].name,
    ];
    // 白名单恰好等于这三条 —— 这条断言同时做两件事：
    // ① 正向：新的灰/黑/白混进来 ⇒ 列表变长 ⇒ 红；
    // ② **量具自证**：把阈值放宽（或有人把这三条"修"成高饱和）⇒ 列表变短 ⇒ 红。
    //    没有 ② 的话，一个恒返回空的守卫也能全绿（假绿）。
    expect(low, kLowSaturationAllowlist,
        reason: '★ 饱和度 < $kSaturationFloor 的必须是且仅是那三条既有/指定色'
            '（银灰=用户冻结的既有灰、杏粉+薄荷绿=用户亲自指定的抖音色卡色）。'
            '多一条 = 混进了新的"看不见的颜色"；少一条 = 白名单过期，'
            '多半是有人偷偷放宽了阈值或改了色值。实际：$low');
  });

  test('★6 换上去的 18 套（槽位 22~39）没有一套是"旧 18 套"的残留', () {
    const removed = [
      '牛油果', '苔藓绿', '海军蓝', '宝蓝', '酒红', '砖橙', '南瓜橙', '芥末黄',
      '森林绿', '松绿', '青蓝', '深紫', '玫瑰红', '正红', '蓝灰', '巧克力',
      '橄榄绿', '石板灰',
    ];
    final names = kAccentSchemes.map((s) => s.name).toSet();
    expect(names.intersection(removed.toSet()), isEmpty,
        reason: '★ 用户点名说这 18 个「又暗又脏」要删掉，一个都不许留在表里');
    // 负向对照的另一半：这三条（既有前缀里的）必须还在 —— 证明上面那条不是"整表被清空"式的假绿
    expect(names.containsAll(['经典蓝', '葡萄紫', '银灰']), isTrue,
        reason: '★ 前 22 项（含银灰）必须原样留着；这条红了说明有人删过头了');
  });
}
