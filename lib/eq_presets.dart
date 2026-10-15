/// 均衡器「我的预设」的**纯数据层**（零 Flutter 依赖，可纯 Dart 单测）。
///
/// 与 `eq_engine.dart` 的分工：这里只管「一套预设长什么样、怎么增删改查、
/// 换设备频段数不同怎么对齐」，落盘与过桥全在引擎里（样板 `lib/ab_loop.dart`）。
///
/// ⚠️ **存储位置是 SharedPreferences 的 `eq_presets`（JSON 字符串），不是文件**。
/// 理由是实测出来的，不是猜的：`backup_service.dart` 的 `createBackup` 把 prefs
/// **全量**打进 `prefs.json`（`:48-58` 遍历 `sp.getKeys()`），恢复侧 `sp.clear()` 后
/// 全量写回（`:190-199`）⇒ 存 prefs 就自动进备份；而 `createBackup` 只特殊处理
/// `songs.json`（`:64-65`）、只遍历 `kBackupDirs` 里的**目录**（`:71-81`）⇒
/// 单文件如 `docs/eq_presets.json` **不会进备份**，换机/重装必丢（H4 同一类事故）。
///
/// 损坏隔离照 `Store._decode` 的规矩：**解析失败当空、绝不抛**。调用方（`EqEngine`）
/// 拿到 [EqPresetsParse.damaged] 后要把原始串留一份现场（`eq_presets_corrupt`），
/// 否则下一次「保存 / 删除」会把坏值永久盖掉 —— 那正是「读坏」变成「永久没了」的路径。
library;

import 'dart:convert';

/// 一套用户自定义的均衡器预设：名字 + 各频段增益（毫贝，100 mB = 1 dB）。
class EqUserPreset {
  const EqUserPreset({
    required this.id,
    required this.name,
    required this.levels,
  });

  /// 稳定 id（`p1` / `p2`…）：改名不动它，UI 与删除都按它认人
  final String id;

  /// 用户起的名字（已 trim；同名 = 同一套，见 [savePreset]）
  final String name;

  /// 各频段增益，单位毫贝
  final List<int> levels;

  EqUserPreset copyWith({String? name, List<int>? levels}) => EqUserPreset(
    id: id,
    name: name ?? this.name,
    levels: levels ?? this.levels,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'levels': levels,
  };

  /// 从 JSON 读一项；**认不出就返回 null（调用方跳过它）**，绝不抛。
  ///
  /// 一条曲线里有一段不是数字 ⇒ 这一项算坏（宁可不要，也不凭空补 0 dB 的假曲线）；
  /// 但**不影响同一份数据里的其它项**。
  static EqUserPreset? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final rawLevels = raw['levels'];
    if (rawLevels is! List || rawLevels.isEmpty) return null;
    final levels = <int>[];
    for (final e in rawLevels) {
      if (e is num) {
        levels.add(e.toInt());
      } else if (e is String && int.tryParse(e) != null) {
        levels.add(int.parse(e)); // 兼容被当成字符串存过的老值
      } else {
        return null;
      }
    }
    final id = raw['id'];
    return EqUserPreset(
      id: id is String ? id.trim() : '',
      name: name.trim(),
      levels: levels,
    );
  }
}

/// 解析结果：解析出来的预设 + 「原始串本身是不是坏的」。
class EqPresetsParse {
  const EqPresetsParse({required this.items, required this.damaged});

  final List<EqUserPreset> items;

  /// 原始串存在但**整体解析不了**（不是 JSON 数组）⇒ 调用方该留现场
  /// （`eq_presets_corrupt`）。坏的是**里面的某一项**时这里是 false：那种情况
  /// 照「坏的跳过、其余照读」处理，不算损坏。
  final bool damaged;
}

/// 解析 `eq_presets` 的原始串。**任何情况都不抛**：
/// 没存过 / 空串 / 坏 JSON / 不是数组 ⇒ 空列表；里面坏的一项跳过、其余照读。
EqPresetsParse parseEqPresets(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return const EqPresetsParse(items: [], damaged: false);
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const EqPresetsParse(items: [], damaged: true);
  }
  if (decoded is! List) {
    return const EqPresetsParse(items: [], damaged: true);
  }
  final out = <EqUserPreset>[];
  for (final e in decoded) {
    final p = EqUserPreset.fromJson(e);
    if (p == null) continue; // 坏的一项跳过，其余照读
    if (out.any((q) => q.name.toLowerCase() == p.name.toLowerCase())) {
      continue; // 同名项（手改过 / 老数据）只留第一套，否则「点这个高亮那个」
    }
    // id 缺失或与前面的撞车：补一个新号，别让两套预设共用一个 id（删除会误伤）
    var id = p.id.isEmpty ? nextPresetId(out) : p.id;
    if (out.any((q) => q.id == id)) id = nextPresetId(out);
    out.add(EqUserPreset(id: id, name: p.name, levels: p.levels));
  }
  return EqPresetsParse(items: out, damaged: false);
}

/// 序列化成存 prefs 的 JSON 文本（顶层就是一个数组）。
String encodeEqPresets(List<EqUserPreset> items) =>
    jsonEncode([for (final p in items) p.toJson()]);

/// 下一个可用的 id（`p1` / `p2`…）：取现有 `p<数字>` 的最大号 +1，绝不与现有 id 撞。
String nextPresetId(List<EqUserPreset> items) {
  var max = 0;
  for (final p in items) {
    final m = RegExp(r'^p(\d+)$').firstMatch(p.id);
    if (m == null) continue;
    final n = int.tryParse(m.group(1)!) ?? 0;
    if (n > max) max = n;
  }
  return 'p${max + 1}';
}

/// 名字是否算同一套：忽略首尾空格与大小写（中文名字就是逐字符相等）。
bool samePresetName(String a, String b) =>
    a.trim().toLowerCase() == b.trim().toLowerCase();

/// 保存一套曲线：**同名 → 覆盖那套的曲线**（id 与列表顺序都不动），
/// 否则追加一套新预设。名字为空（或全空格）时原样返回，不建无名预设。
List<EqUserPreset> savePreset(
  List<EqUserPreset> items, {
  required String name,
  required List<int> levels,
}) {
  final cleaned = name.trim();
  if (cleaned.isEmpty) return items;
  final out = List<EqUserPreset>.of(items);
  final i = out.indexWhere((p) => samePresetName(p.name, cleaned));
  if (i >= 0) {
    // 覆盖曲线的同时把用户这次输入的名字规范化（大小写/空格）后写回
    out[i] = out[i].copyWith(name: cleaned, levels: List<int>.of(levels));
    return out;
  }
  out.add(EqUserPreset(
    id: nextPresetId(out),
    name: cleaned,
    levels: List<int>.of(levels),
  ));
  return out;
}

/// 按 id 删除；找不到就原样返回（幂等）。
List<EqUserPreset> removePreset(List<EqUserPreset> items, String id) =>
    [for (final p in items) if (p.id != id) p];

/// 按 id 找；找不到返回 null。
EqUserPreset? presetById(List<EqUserPreset> items, String id) {
  for (final p in items) {
    if (p.id == id) return p;
  }
  return null;
}

/// 哪一套算「当前选中的」：**曲线逐段相等**才算。
///
/// ⚠️ 刻意不用原生 `currentPreset`：用户手动拖过圆点之后，ROM 给的是它自己的
/// 「自定义」，跟我们存的这套对不上，拿它高亮会永远不亮。
EqUserPreset? presetMatchingLevels(
  List<EqUserPreset> items,
  List<int> levels,
) {
  for (final p in items) {
    if (p.levels.length != levels.length) continue;
    var same = true;
    for (var i = 0; i < levels.length; i++) {
      if (p.levels[i] != levels[i]) {
        same = false;
        break;
      }
    }
    if (same) return p;
  }
  return null;
}

/// 把曲线的长度对齐到设备实际频段数（换 ROM / 换设备时长度可能不同）：
/// 段数不够 → 补 0 dB，段数多了 → 截掉。`bands <= 0`（原生还没附着）时原样返回。
List<int> fitLevels(List<int> levels, int bands) {
  if (bands <= 0) return List<int>.of(levels);
  return List<int>.generate(
    bands,
    (i) => i < levels.length ? levels[i] : 0,
  );
}

/// 每条增益夹到设备允许的范围（单位毫贝）。换 ROM 后范围可能变窄，
/// 越界值原生会直接拒绝 —— 夹一次保证「存下来的曲线 = 真生效的曲线」。
List<int> clampLevels(List<int> levels, {required int min, required int max}) {
  final lo = min <= max ? min : max;
  final hi = min <= max ? max : min;
  return [
    for (final v in levels)
      if (v < lo) lo else if (v > hi) hi else v,
  ];
}
