/// 备份 / 恢复的**纯逻辑**：备份该带哪些目录 · 恢复被打断了该怎么收场。
///
/// 为什么单独一个文件：`backup_service.dart` 直接依赖 SharedPreferences /
/// path_provider / zip 库，没法在单测里跑；而这两条规则恰恰是**最该钉死**的
/// —— 一条漏了会丢数据（译文目录曾经不在清单里），一条错了会清空设置
/// （恢复中途被杀时没回滚）。所以把它们抽成零依赖的纯函数 + 常量，配单测。
///
/// 本文件**不许 import Flutter / 任何插件**（只许 `dart:convert`），否则又测不了。
library;

import 'dart:convert';

/// 备份包内随 `docs/` 一起带走的目录（相对 App 文档目录）。
///
/// ⚠️ **新增任何「用户数据目录」都必须加进这里**，否则换机 / 重装时那份数据必丢。
/// 怎么判断是不是用户数据目录：`lib/` 里凡是用 `'${docs.path}/<名>'` 建出来的都算。
/// （`songs.json` 是文件不是目录，单独由 `backup_service` 处理。）
///
/// ⚠️ 有单测会**扫 `lib/` 源码**核对这份清单 ——
/// 以后有人再加一个目录却忘了往这儿添，测试当场红。
const List<String> kBackupDirs = [
  'music', // 音频内部副本（防误删设计：手机上的原文件被删也不丢歌）
  'wallpapers', // 壁纸图片
  'artwork', // 封面缓存（含用户手动设的 1:1 歌曲图标）
  'lyrics', // App 私有歌词缓存
  'imported_lyrics', // 用户导入 / 手写的主歌词（.lrc）
  'sub_lyrics', // 手写译文（每行主歌词挂一行）
  'visual_presets', // 视觉方案（截图 + 参数）
];

/// 恢复前把旧设置落盘的回滚快照文件名（放 App 文档目录）。
///
/// 它同时充当「恢复中」标记：**文件存在 = 上次恢复没走完**。
/// 所以这个文件只在恢复流程里出现，别拿它存别的东西。
const String kRestoreRollbackFile = 'restore_rollback.json';

// ═══════════════════════════════════════════════════════════════════════════
// 私密歌的**身份指纹**：备份包里凡是能认出私密歌的东西，一律不出门
// ═══════════════════════════════════════════════════════════════════════════
//
// 详见 `backup_service.dart` 的调用点与 `test/backup_private_test.dart`。
// 一句话：`backup_skip_private`（默认开）只过滤 `music/` 里的**音频文件**，
// 而曲库的身份到处都是 —— prefs 里的名单/键、`songs.json` 的明文记录、
// 那几个「一歌一名」的目录（lyrics / imported_lyrics / sub_lyrics / artwork）。
// 于是原先「文件没出门，名单出门了」：拿到 zip 的人能数出有几首私密歌、
// 叫什么名字、路径是什么。下面这套判定的唯一目的就是把这条路堵死。

/// 私密歌在备份里的四种身份写法。
///
/// ⚠️ 四个集合**都由调用方从同一份 [Library.privatePathSet] 派生**（见
/// `backup_service.createBackup`），派生规则只有一份（`library_core` 的
/// `basenameOf` / `splitNameExt` / `stableIdOfPath`）—— 本文件是零依赖纯逻辑，
/// 不许 import `library_core`（那会把 `models.dart` 与 on_audio_query 拖进来），
/// 所以只收「已经算好的集合」。
typedef PrivateMarks = ({
  /// 内部副本的**绝对路径**（`fav_songs` / `title_overrides` / `lyric_*` 的键、
  /// `music/` 里音频的身份）。
  Set<String> paths,

  /// 内部副本的**文件名**（`deleted_names` / `instrumental_names` / `blocked_names`）。
  Set<String> names,

  /// 内部副本名去掉扩展名的**主名**（`lyrics/<主名>.lrc` 这类文件名的前缀）。
  Set<String> stems,

  /// **稳定 id**（`stableIdOfPath(path)`；`all_order` / `playlists` 存的是它）。
  Set<int> ids,
});

/// 空指纹（= 不过滤任何东西）。`backup_skip_private` 关掉时用的就是它。
const PrivateMarks kNoPrivateMarks = (
  paths: <String>{},
  names: <String>{},
  stems: <String>{},
  ids: <int>{},
);

/// **整键丢掉**的 prefs 键：值本身就是一份「歌单名单」，没有用户创作内容 ——
/// 丢掉不影响换机恢复，留下就等于把私密歌名单塞进 zip。
///
/// * `private_songs` —— 就是私密名单本体（路径）；
/// * `play_history` —— 私密歌也会进播放历史（`player_service.dart` 的注释明说）；
/// * `last_session` —— 旧版队列键，存的是**路径列表**；已被
///   `queue.json` 取代（`Store.loadLastSession` 只读不迁），备份里它只是又一份名单。
const Set<String> kBackupPrefsDropped = {
  'private_songs',
  'play_history',
  'last_session',
};

/// 「损坏隔离」现场键的后缀（`Store._decode` 写的 `<key>_corrupt`）。
/// 它的内容是**坏掉的原文**，里面可能正是一份私密名单（读坏的就是它）——
/// 而且它没有任何回读路径（纯诊断），所以整键丢。
const String kBackupCorruptSuffix = '_corrupt';

/// 「值里带歌曲身份」的 prefs 键的形态：决定该摘掉哪几条。
enum PrefsSongRefShape {
  /// JSON `List<路径>`：摘掉私密路径。
  pathList,

  /// JSON `List<文件名>`：摘掉基名等于私密歌内部副本名的条目。
  nameList,

  /// JSON `Map<路径, …>`：摘掉拿私密路径当键的那几条。
  pathMap,

  /// JSON `List<稳定 id>`：摘掉私密歌的 id。
  idList,

  /// JSON `Map<歌单名, List<稳定 id>>`：逐张歌单摘掉私密歌的 id。
  idMap,
}

/// 键 → 形态。**加新键时要么进这儿，要么在下面的「不动」清单里有理由**
/// （`test/backup_private_test.dart` 会扫这份表核对每个 prefs 键都有判定）。
const Map<String, PrefsSongRefShape> kBackupSongKeyShapes = {
  'fav_songs': PrefsSongRefShape.pathList,
  'deleted_names': PrefsSongRefShape.nameList,
  'instrumental_names': PrefsSongRefShape.nameList,
  'blocked_names': PrefsSongRefShape.nameList,
  'title_overrides': PrefsSongRefShape.pathMap,
  'lyric_offsets': PrefsSongRefShape.pathMap,
  'lyric_calibration': PrefsSongRefShape.pathMap,
  'lyric_segments': PrefsSongRefShape.pathMap,
  'all_order': PrefsSongRefShape.idList,
  'playlists': PrefsSongRefShape.idMap,
};

/// 「按歌曲身份命名」的备份目录 → 文件名后缀（前缀 = 该歌内部副本名的主名）。
///
/// 命名来源（**改动那三处时这里必须跟着改**）：
/// * `lyrics/`          ← `lrc.dart` 的 `LyricsStore._name`（`<主名>.lrc`）
/// * `imported_lyrics/` ← `lrc.dart` 的 `ImportedLyricsStore._file`（`<主名>.lrc`）
/// * `sub_lyrics/`      ← `sub_lyrics.dart` 的 `_file`（`<主名>.sub.json`）
/// * `artwork/`         ← `artwork.dart` 的 `ArtworkStore._name`（`<主名>.jpg`）
///
/// `music/` 与 `wallpapers/` 不在这里：前者按**完整路径**判（走 [PrivateMarks.paths]），
/// 后者与歌曲身份无关。
const Map<String, String> kBackupSongNamedSuffix = {
  'lyrics': '.lrc',
  'imported_lyrics': '.lrc',
  'sub_lyrics': '.sub.json',
  'artwork': '.jpg',
};

/// [kBackupDirs] 里这个文件是不是**只属于私密歌**（名字由它的内部副本名派生）。
///
/// [privateStems] 取 [PrivateMarks.stems]；空集 ⇒ 恒 false（= 整套过滤是 no-op）。
bool isPrivateBackupArtifact(
  String dir,
  String fileName,
  Set<String> privateStems,
) {
  if (privateStems.isEmpty) return false;
  final suffix = kBackupSongNamedSuffix[dir];
  if (suffix == null || !fileName.endsWith(suffix)) return false;
  return privateStems.contains(
    fileName.substring(0, fileName.length - suffix.length),
  );
}

/// 把 prefs 全量里**能反推出私密歌身份**的东西摘掉（纯函数，不碰 IO）。
///
/// 规则：
/// 1. [kBackupPrefsDropped] 里的纯名单键 + 一切 `*_corrupt` 现场键：**整键丢掉**；
/// 2. [kBackupSongKeyShapes] 里那 10 个「按歌曲身份存」的键：**只摘掉属于私密歌的
///    那几条**，其余原样保留 —— ⛔ 整键丢掉就是丢用户数据（自定义歌名 / 歌词校准 /
///    歌单 / 顺序全没），那是本仓最忌讳的事；
/// 3. 其余键（设置 / 主题 / 特效参数 / 壁纸 / EQ 预设…）**一个字节都不动**；
/// 4. 某个身份键的值**解析不了** ⇒ 把这个键丢掉：坏值在 App 眼里本来就等于空
///    （`Store._decode` 读坏即按空返回），留着却可能带着私密歌的原文出门。
///
/// [marks] 为空（`backup_skip_private` 关掉、或本来就没有私密歌）时**原样返回**，
/// 保证既有备份逐字节不变。
Map<String, Object?> sanitizeBackupPrefs(
  Map<String, Object?> prefs,
  PrivateMarks marks,
) {
  if (marks.paths.isEmpty && marks.names.isEmpty && marks.ids.isEmpty) {
    return prefs;
  }
  final out = <String, Object?>{};
  for (final e in prefs.entries) {
    final key = e.key;
    if (kBackupPrefsDropped.contains(key)) continue;
    if (key.endsWith(kBackupCorruptSuffix)) continue;
    final shape = kBackupSongKeyShapes[key];
    if (shape == null) {
      out[key] = e.value; // 与歌曲身份无关：原样带走
      continue;
    }
    final cleaned = _filterSongKey(shape, e.value, marks);
    if (cleaned != null) out[key] = cleaned;
  }
  return out;
}

/// 按形态摘掉私密条目。解析不了 / 类型不对 ⇒ 返回 null（调用方据此丢掉整个键）。
String? _filterSongKey(
  PrefsSongRefShape shape,
  Object? raw,
  PrivateMarks marks,
) {
  if (raw is! String) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null; // 坏值：App 眼里本来就是空，留着却可能带着私密原文
  }
  switch (shape) {
    case PrefsSongRefShape.pathList:
      if (decoded is! List) return null;
      return jsonEncode([
        for (final v in decoded)
          if (v is String && !marks.paths.contains(v)) v,
      ]);
    case PrefsSongRefShape.nameList:
      if (decoded is! List) return null;
      return jsonEncode([
        for (final v in decoded)
          if (v is String && !marks.names.contains(v)) v,
      ]);
    case PrefsSongRefShape.pathMap:
      if (decoded is! Map) return null;
      return jsonEncode({
        for (final e in decoded.entries)
          if (e.key is String && !marks.paths.contains(e.key)) e.key: e.value,
      });
    case PrefsSongRefShape.idList:
      if (decoded is! List) return null;
      return jsonEncode([
        for (final v in decoded)
          if (v is int && !marks.ids.contains(v)) v,
      ]);
    case PrefsSongRefShape.idMap:
      if (decoded is! Map) return null;
      return jsonEncode({
        for (final e in decoded.entries)
          if (e.value is List)
            e.key: [
              for (final v in e.value as List)
                if (v is int && !marks.ids.contains(v)) v,
            ],
      });
  }
}

/// 快照状态：正在恢复 —— 磁盘上的设置此刻可能已经被清空 / 只写了一半。
const String kRestoreStatePending = 'pending';

/// 快照状态：新设置已经**全部写完**，只剩删文件这一步没做。
const String kRestoreStateCommitted = 'committed';

/// 恢复被打断后，下次启动该怎么办。
enum RestoreRecovery {
  /// 没有快照（或快照不认得）：正常启动，什么都不用做。
  none,

  /// 快照还在 `pending`：上次恢复没写完就死了 → **把旧设置写回去**。
  rollback,

  /// 快照是 `committed`：新设置已经写完，只是没来得及删文件 → 删掉即可，**别回滚**。
  discard,
}

/// 由快照文件的**原始文本**判定该走哪条路。
///
/// 解析不了就返回 [RestoreRecovery.none] —— 不认识的格式**一律不乱动**
/// （宁可留着那个文件让下次启动再看到，也不拿它去覆盖用户的设置）。
RestoreRecovery restoreRecoveryOf(String? raw) {
  if (raw == null) return RestoreRecovery.none;
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return RestoreRecovery.none;
  }
  if (decoded is! Map) return RestoreRecovery.none;
  return switch (decoded['state']) {
    kRestoreStatePending => RestoreRecovery.rollback,
    kRestoreStateCommitted => RestoreRecovery.discard,
    _ => RestoreRecovery.none,
  };
}

/// 打包成落盘用的 JSON 文本。[prefs] 是恢复前的 SharedPreferences 全量快照。
String buildRollbackSnapshot(
  Map<String, Object?> prefs, {
  required String state,
}) => jsonEncode({'state': state, 'prefs': prefs});

/// 从落盘 JSON 里取回旧设置；拿不到 / 类型不对返回 null。
///
/// 只认 SharedPreferences 支持的那几种值（bool / int / double / String /
/// `List<String>`）—— JSON 解出来的 `List<dynamic>` 在这里**收窄成 `List<String>`**，
/// 否则 `sp.setStringList` 会在回滚那一刻抛，回滚就白做了。
Map<String, Object>? parseRollbackSnapshot(String raw) {
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return null;
  }
  if (decoded is! Map) return null;
  final prefs = decoded['prefs'];
  if (prefs is! Map) return null;
  final out = <String, Object>{};
  for (final e in prefs.entries) {
    final k = e.key;
    if (k is! String) continue;
    final v = e.value;
    if (v is bool || v is int || v is double || v is String) {
      out[k] = v as Object;
    } else if (v is List) {
      out[k] = <String>[for (final e in v) '$e'];
    }
    // 其余类型（null / 嵌套 Map）一律丢掉：写回 prefs 也没有对应的 setter
  }
  return out;
}
