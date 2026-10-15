/// 音乐库的**纯计算**逻辑：排序 / 命名 / 路径理解 / 稳定 id。
///
/// 刻意与平台、持久化解耦——本文件**不 import** 任何平台包
/// （不碰 dart:io / path_provider / shared_preferences / on_audio_query 运行时代码），
/// 需要的所有数据都由调用方当作参数传入，函数本身是纯函数。
///
/// 好处：这些逻辑最容易出 bug（歌单顺序、标题映射、重排、扫描 id），
/// 抽出来可用纯 Dart 单测直接验证，也让 `Library` 这个单例类更瘦、更聚焦。
library;

import 'models.dart';
import 'pinyin_sort.dart';

/// 「全部歌曲」固定歌单名（不参与自建歌单排序，恒第一）。
const String kAllSongs = '全部歌曲';

/// 「喜欢」收藏歌单名（自动汇总收藏的歌曲，不占自建歌单）。
const String kLikes = '喜欢';

/// 文件系统扫描支持的主流音频扩展名（小写，不含点）。
/// MediaStore 一般只可靠索引 mp3，flac/m4a/ogg/wav 等无损或冷门格式常被漏掉，
/// 需要按扩展名补扫，作为 querySongs 的补充。
///
/// ⚠️ 定义在**零 Flutter 依赖**的纯逻辑层，因为 [planOrphanRescue]（孤儿内部副本挽救）
/// 也要用它；`library_data.dart` 已经 `export` 了本文件的常量，import 方无需改。
const List<String> kAudioExts = [
  'mp3',
  'flac',
  'm4a',
  'aac',
  'wav',
  'ogg',
  'oga',
  'opus',
  'wma',
  'ape',
  'aif',
  'aiff',
  'mka',
];

/// 「专辑 · 歌手」视图里没有标签的兜底组名（恒排在列表最后）。
const String kUnknownAlbum = '未知专辑';
const String kUnknownArtist = '未知歌手';

/// 路径 → basename（兼容 `/` 与 Windows 的 `\`）。
String basenameOf(String path) => path.split(RegExp(r'[/\\]')).last;

/// 路径散列（31 位，非负）。
/// [salt] 只在「两条不同路径的散列撞在一起」这种极端情况下加长用；
/// 默认 7 是全仓既有取值 —— **不许改**：`scannedId` 的取值已经被用户数据引用了。
int _pathHash(String path, [int salt = 7]) {
  var h = salt;
  for (final c in path.codeUnits) {
    h = (h * 31 + c) & 0x7fffffff;
  }
  return h;
}

/// 路径的稳定 id：对路径做 31 位散列后取负，避开 MediaStore 的正整数 id。
/// 同一路径每次扫描得到相同 id，歌单/「全部歌曲」顺序在刷新后仍能匹配。
int scannedId(String path) => -_pathHash(path);

/// 拆出「主名 / 扩展名」：`a.mp3` → (`a`, `.mp3`)。
/// 没有扩展名、或点是首字符（`.nomedia` 这类）时整段当主名，扩展名为空。
({String stem, String ext}) splitNameExt(String base) {
  final dot = base.lastIndexOf('.');
  if (dot <= 0) return (stem: base, ext: '');
  return (stem: base.substring(0, dot), ext: base.substring(dot));
}

/// 「撞名的内部副本」用的名字：`01.mp3` + 源路径 → `01-1a2b3c4d.mp3`。
/// 后缀**只由 [path] 决定** —— 同一条源路径无论跟谁撞名，名字都一样（稳定可预期）。
/// [salt] 只在两条路径散列真的撞车时加长用，正常不传。
String suffixedName(String base, String path, [int salt = 7]) {
  final e = splitNameExt(base);
  return '${e.stem}-${_pathHash(path, salt).toRadixString(16).padLeft(8, '0')}${e.ext}';
}
/// 歌曲的**稳定 id**：对**内部副本路径**散列取负。
///
/// 为什么身份认内部副本路径，而不是手机上的原始源路径：
/// - 内部副本路径由 App 自己命名，[planInternalNames] 规则 1 保证它**一旦入库就不再变**
///   ⇒ 刷新/重扫不会换 id ⇒ 歌单、「全部歌曲」顺序、收藏都不会失去指向；
/// - 私密名单 / 收藏 / 自定义歌名 / 歌词校准 / 播放历史 / 上次会话
///   **本来就全部按内部副本路径存**，身份与它们对齐＝一处改、处处一致；
/// - 原始源路径可能已经不存在了（用户删了手机上的原文件），拿它当身份就还得改 id。
int stableIdOfPath(String filePath) => scannedId(filePath);

/// 让 [s] 的 id 与它的内部副本路径对齐。
/// **换过 `filePath` 之后必须过一道这个**（备份恢复会按 basename 重写路径），
/// 否则 id 与路径对不上，歌单/顺序里指向这首歌的条目会失联。
Song withStableId(Song s) {
  if (s.filePath.isEmpty) return s;
  final id = stableIdOfPath(s.filePath);
  return id == s.id ? s : s.copyWith(id: id);
}

/// 内部副本文件名的**规划**（纯函数，不碰 IO、不依赖分配顺序）。
///
/// 背景：内部副本原先直接拿 basename 当目标名，于是 `/Music/A/01.mp3` 与
/// `/Music/B/01.mp3` 都写到 `docs/music/01.mp3` —— 后者覆盖前者，再经按 filePath
/// 合并去重，**其中一首整条从库消失**，留下的那条播的还是别人的音频。
///
/// 规则：
/// 1. [keep]（源路径 → 它现在用的内部文件名）**逐字符保留**。已在库的歌**永不改名**：
///    改名会连带打断 `private_songs` / `fav_songs` / `title_overrides` /
///    `lyric_calibration` / `play_history` / `last_session` 这些**按内部路径存**的键。
/// 2. 其余源路径：basename 在本次扫描里**唯一**、且没被规则 1 或 [occupied] 占用
///    → **逐字符用 basename**（不撞名 ⇒ 老库零影响）。
/// 3. 否则（同 basename 撞名，或名字已被占）→ `主名-<8位路径散列>.扩展名`。
///
/// [occupied] 是「库里已经在用的内部文件名」（含 srcPath 查不出来的老歌）——
/// 有它才能保证**新导入永不覆盖老文件**：老库只认内部路径，覆盖了就是丢歌。
Map<String, String> planInternalNames(
  List<String> srcPaths, {
  Map<String, String> keep = const {},
  Set<String> occupied = const {},
}) {
  final out = <String, String>{};
  // 规则 1：老名字先占位。每个源路径的名字互相独立，处理顺序不影响结果（排序只为可复现）。
  //
  // ⚠️ [keep] 必须**先于** [occupied] 判定：`occupied` 按定义就包含老歌自己在用的名字
  // （它就是「库里所有内部文件名」），拿它去拦 keep 等于把每一首都判成「名字被占」
  // → 全部加哈希 → **存量文件名全变**。
  // 真实数据上踩到过：干跑算出 0 改名、落盘代码算出 16 改名，就栽在这两行。
  final keepNames = <String>{};
  for (final p in keep.keys.toList()..sort()) {
    final n = keep[p];
    if (n == null || n.isEmpty) continue;
    if (!keepNames.add(n)) continue; // keep 自己重名（本该不可能）：后来者让路
    out[p] = n;
  }
  // 规则 2/3 的占用表：库里在用的名字 + 刚认领的老名字
  final taken = <String>{...occupied, ...keepNames};
  // 规则 2/3：同一源路径被 MediaStore 与文件系统两条通道各扫到一次，只算一次。
  final rest = <String>[];
  final seen = <String>{};
  for (final p in srcPaths) {
    if (p.isEmpty || out.containsKey(p)) continue;
    if (seen.add(p)) rest.add(p);
  }
  rest.sort();
  final baseCount = <String, int>{};
  for (final p in rest) {
    final b = basenameOf(p);
    baseCount[b] = (baseCount[b] ?? 0) + 1;
  }
  for (final p in rest) {
    final b = basenameOf(p);
    if (b.isEmpty) continue; // 空名字：调用方跳过这首歌
    if (baseCount[b] == 1 && !taken.contains(b)) {
      out[p] = b;
      taken.add(b);
      continue;
    }
    // 极端情况（两条不同路径的散列相同）：加长散列直到不重复。仍与分配顺序无关。
    var salt = 7;
    var name = suffixedName(b, p, salt);
    while (taken.contains(name)) {
      name = suffixedName(b, p, ++salt);
    }
    out[p] = name;
    taken.add(name);
  }
  return out;
}

/// MediaStore 的 `content://media/external/audio/media/<id>` 里的 id。
final RegExp _mediaIdRe = RegExp(r'/media/(\d+)$');

/// 从 content uri 里取回 MediaStore 的 id（取不到返回 null）。用处：老数据
/// （歌单 / 「全部歌曲」顺序）存的是 MediaStore id，换身份之后靠这条通道把歌认回来。
int? mediaIdOfUri(String uri) {
  final m = _mediaIdRe.firstMatch(uri);
  if (m == null) return null;
  return int.tryParse(m.group(1)!);
}

/// 「旧 id → 稳定 id」映射，两条通道：
/// ① 歌现在挂着的 id（`songs.json` 里存的那个）；
/// ② 歌的 `uri` 里带的 MediaStore id —— 半途状态（`songs.json` 已换成新 id、
///    歌单/顺序还没换，进程被杀时会出现）靠它自愈。
Map<int, int> stableIdMapOf(List<Song> songs) {
  final m = <int, int>{};
  for (final s in songs) {
    if (s.filePath.isEmpty) continue;
    m[s.id] = stableIdOfPath(s.filePath);
  }
  for (final s in songs) {
    if (s.filePath.isEmpty) continue;
    final legacy = mediaIdOfUri(s.uri);
    if (legacy != null) m.putIfAbsent(legacy, () => stableIdOfPath(s.filePath));
  }
  return m;
}

/// 把遗留身份的条目翻译成稳定 id。
/// **翻不动的原样保留** —— 那是用户数据（悬空的歌单条目就是这么活下来的），
/// 哪怕暂时对不上任何歌也不许顺手清理。
List<int> translateLegacyIds(List<int> entries, Map<int, int> idMap) =>
    [for (final e in entries) idMap[e] ?? e];

/// 「身份 → 歌」索引：**双键**。除了歌自己的 id（稳定 id），
/// 还登记 `uri` 里的 MediaStore id —— 老数据存的正是后者，读时直接认回来。
Map<int, Song> songIndex(List<Song> songs) {
  final byId = <int, Song>{for (final s in songs) s.id: s};
  for (final s in songs) {
    final legacy = mediaIdOfUri(s.uri);
    // 稳定 id 恒为负、MediaStore id 恒为正，不会互相顶掉；同名再保险用 putIfAbsent
    if (legacy != null) byId.putIfAbsent(legacy, () => s);
  }
  return byId;
}

/// 是否为「导出到手机 Music/MuBox」的副本路径：这类文件不该进库，
/// 避免导出后刷新又被当成新歌扫一次。
bool isMuBoxCopyPath(String path) {
  final p = path.replaceAll('\\', '/').toLowerCase();
  return p.contains('/music/mubox/');
}

/// 从文件路径解析「歌手 - 歌名」；无分隔符则整段视为歌名，空歌名兜底为「未知歌曲」。
({String title, String artist}) parseSongName(String path) {
  final base = basenameOf(path);
  final dot = base.lastIndexOf('.');
  final name = dot > 0 ? base.substring(0, dot) : base;
  final sep = name.indexOf(' - ');
  final artist = sep > 0 ? name.substring(0, sep).trim() : '';
  final title = (sep > 0 ? name.substring(sep + 3) : name).trim();
  return (title: title.isEmpty ? '未知歌曲' : title, artist: artist);
}

/// 从文件路径构造 [Song]（无 MediaStore 元数据）：时长未知置 0（播放后回写），
/// 无 content uri、无专辑封面。
///
/// 这里 `filePath` 还是**外部源路径**（导入前），`id` 是它的散列 ——
/// 导入到内部副本后由 `Library._scanAndSave` 换成稳定 id（内部副本路径的散列），
/// 所以这个 id 只用于扫描期去重，不落盘。`srcPath` 就是这条外部路径。
Song songFromFilePath(String path) {
  final name = parseSongName(path);
  return Song(
    id: scannedId(path),
    title: name.title,
    artist: name.artist,
    durationMs: 0,
    uri: '',
    filePath: path,
    albumId: null,
    srcPath: path,
  );
}

/// **孤儿内部副本挽救**：从「内部副本目录里实际存在的文件名」规划出该补回库里的歌。
///
/// ## 为什么需要它（会让整库消失的那条故障链）
/// 1. `Store.loadSongs`：`songs.json` 整个文件不是合法 JSON ⇒ 留一份 `.corrupt` 现场，
///    **返回 `[]`**（`store.dart`）；
/// 2. `Library._doInit` 把空列表判成「无缓存」⇒ 全量重扫 + 重新索要权限；
/// 3. 扫描范围 = MediaStore + `/Music` `/Download` `/Documents` ——
///    **App 私有目录 `docs/music/` 不在其中**；
/// 4. ⇒ 只存在于内部副本里的歌（**原文件已被用户删掉的歌**）
///    整批从库里消失，且没有任何入口能找回：文件还在磁盘上，成了孤儿。
///
/// ## 规则（纯函数，不碰 IO；顺序确定）
/// 1. **只新增**：调用方把「库里已经认识的内部副本名」传进 [knownNames]，一个都不重复加；
/// 2. **黑名单优先**：用户删过的歌不许被「救」回来 —— 删歌黑名单存的是**源路径**
///    （`srcPath` 为空时退化成基名，见 `Library.deleteSongs`），而孤儿副本的 `srcPath`
///    本来就不可知，所以这里**按基名比对**：只要某个黑名单条目的 basename 等于这个文件名，
///    就跳过。取舍见文件末尾注释；
/// 3. 只认 [audioExts] 里的音频扩展名（`.nomedia` / 封面之类一律不当歌）；
/// 4. 元数据救不回来就留空：时长 0、无 uri、无 albumId、`srcPath` 空串 ——
///    **不猜、不联网**；歌名走既有规则 [parseSongName]（与 [songFromFilePath] 同一套）；
/// 5. 身份 = **内部副本路径的散列**（[stableIdOfPath] = `scannedId('docs/music/<名>')`）——
///    与 `Library._importIfNeeded` 造出来的路径逐字符一致，所以救回来之后
///    `playlists` / `all_order` / `private_songs` / `fav_songs` / `title_overrides` /
///    `lyric_calibration` / `play_history` 这些**按内部路径（或它的散列 id）存**的键
///    会自动重新对上：歌单里有它、私密歌仍然是私密。
///
/// [fileNames] 收**文件名**而不是绝对路径：调用方那边路径分隔符可能是 `\`（Windows 上跑单测）
/// 或 `/`（Android），按完整路径比对会**静默不相等** ⇒ 每条都判成孤儿、全库重复一遍。
/// 同一目录内文件名唯一，按名字比对既等价又与平台无关。
List<Song> planOrphanRescue(
  String musicDir, {
  required List<String> fileNames,
  required Set<String> knownNames,
  required Set<String> deletedPaths,
  List<String> audioExts = kAudioExts,
}) {
  // 黑名单两种形态都认，与 `_scanAndSave` 的 `contains(src) || contains(base)` 同一套。
  final deletedNames = <String>{for (final d in deletedPaths) basenameOf(d)};
  final out = <Song>[];
  final seen = <String>{};
  for (final raw in fileNames) {
    final name = basenameOf(raw);
    if (name.isEmpty || !seen.add(name)) continue;
    final lower = name.toLowerCase();
    if (!audioExts.any((x) => lower.endsWith('.$x'))) continue;
    if (knownNames.contains(name)) continue;
    if (deletedNames.contains(name)) continue;
    final path = '$musicDir/$name';
    final parsed = parseSongName(path);
    out.add(
      Song(
        id: stableIdOfPath(path),
        title: parsed.title,
        artist: parsed.artist,
        durationMs: 0,
        uri: '',
        filePath: path,
        albumId: null,
        // 原始源路径已经不可知（下载进来的歌本来就是空串）
        srcPath: '',
      ),
    );
  }
  // 顺序确定：文件系统的列目录顺序不保证，直接按路径排序，结果与调用次数无关。
  out.sort((a, b) => a.filePath.compareTo(b.filePath));
  return out;
}

/// 把「歌名覆盖」（filePath -> 标题）映射到当前歌曲列表的 id（按路径匹配）。
/// 刷新后 MediaStore 的 id 变了也不怕——路径稳定。
Map<int, String> mapTitleOverrides(
  List<Song> songs,
  Map<String, String> overrides,
) {
  final map = <int, String>{};
  for (final s in songs) {
    final t = overrides[s.filePath];
    if (t != null && t.isNotEmpty) map[s.id] = t;
  }
  return map;
}

/// 通用重排：把 [input] 中 [oldIndex] 处的元素移动到 [newIndex]。
/// 约定 [newIndex] 是「移除旧元素后的目标位置」（Flutter 的 `onReorderItem` 已修正，
/// 无需再减一），并对越界做 clamp。返回新列表，不改动输入。
List<T> reorderMove<T>(List<T> input, int oldIndex, int newIndex) {
  final list = List<T>.of(input);
  if (oldIndex < 0 || oldIndex >= list.length) return list;
  final item = list.removeAt(oldIndex);
  list.insert(newIndex.clamp(0, list.length), item);
  return list;
}

/// 「全部歌曲」列表：按自定义顺序 [allOrder] 排列，缺失的兜底追加到末尾，过滤私密。
List<Song> allSongsOrdered(
  List<Song> songs,
  List<int> allOrder,
  Set<String> privatePaths,
) {
  final byId = songIndex(songs);
  final ordered = <Song>[];
  // ⚠️ 去重按**歌自己的 id**，不能按 entry：双键下同一个 entry 既可能是稳定 id、
  //    也可能是 `uri` 里的旧 MediaStore id；按 entry 记会让同一首歌在兜底追加时**再出现一次**。
  final have = <int>{};
  for (final id in allOrder) {
    final s = byId[id];
    if (s != null && have.add(s.id)) ordered.add(s);
  }
  // 防御：allOrder 缺失的歌曲兜底追加到末尾，避免歌曲显示丢失。
  ordered.addAll(songs.where((s) => !have.contains(s.id)));
  return ordered.where((s) => !privatePaths.contains(s.filePath)).toList();
}

/// 自建歌单列表：按歌单内 id 顺序排列，过滤私密。
List<Song> playlistSongsOrdered(
  List<Song> songs,
  List<int> ids,
  Set<String> privatePaths,
) {
  final byId = songIndex(songs);
  final ordered = <Song>[];
  final have = <int>{};
  for (final id in ids) {
    final s = byId[id];
    // 同 allSongsOrdered：按歌自己的 id 去重，双键下同一条目可能被两条通道命中
    if (s != null && have.add(s.id)) ordered.add(s);
  }
  return ordered.where((s) => !privatePaths.contains(s.filePath)).toList();
}

/// 「喜欢」歌单：收藏且非私密的歌。
List<Song> likesSongs(
  List<Song> songs,
  Set<String> favPaths,
  Set<String> privatePaths,
) =>
    songs
        .where((s) =>
            !privatePaths.contains(s.filePath) && favPaths.contains(s.filePath))
        .toList();

/// 计算某歌单的歌曲数。与返回完整列表不同：这里只统计「仍在库中且非私密」的 id，
/// 不构建完整 Song 映射，避免网格里每张卡片跑一遍 O(N) 的 [Library.songsOf]
/// （大音乐库 + 多次刷新时能省不少开销）。
///
/// [liveIds] 是调用方预先算好的「仍在库中且非私密」id 集合（见 `Library._liveIds`）。
/// 网格里一张卡算一次，不给的话每张卡都要重建一遍整个集合 —— 10 个歌单 × 500 首
/// 就是 5000 次插入，而它们本该共用同一份。
int countPlaylistSongs(
  String playlist,
  List<Song> songs,
  List<int> allOrder,
  Map<String, List<int>> playlists,
  Set<String> privatePaths,
  Set<String> favPaths, {
  Set<int>? liveIds,
}) {
  if (playlist == kAllSongs) {
    return songs.where((s) => !privatePaths.contains(s.filePath)).length;
  }
  if (playlist == kLikes) {
    return songs
        .where((s) =>
            !privatePaths.contains(s.filePath) && favPaths.contains(s.filePath))
        .length;
  }
  final ids = playlists[playlist];
  if (ids == null || ids.isEmpty) return 0;
  final live = liveIds ??
      songs
          .where((s) => !privatePaths.contains(s.filePath))
          .map((s) => s.id)
          .toSet();
  return ids.where(live.contains).length;
}

// ---- 曲库分组（专辑 / 歌手）----
// 纯计算：给「专辑 · 歌手」页用。过滤私密歌的规则与歌单列表一致，
// 这样私密歌不会从分组视图里漏出来。

/// 一个分组：分组名 + 组内歌曲（保持传入顺序）。
typedef SongGroup = ({String name, List<Song> songs});

/// 专辑分组键：用标签里的专辑名；没有标签就归到 [kUnknownAlbum]。
///
/// ⚠️ **不要改回「回退到所在文件夹名」**：
/// `Song.filePath` 存的是 **App 内部副本** 路径（`docs/music/<文件名>`），
/// 不是手机上的原始路径 —— 导入设计见 `Library._importIfNeeded`。
/// 于是 `folderNameOf(filePath)` 对每一首歌都返回同一个 `music`，
/// 「无专辑标签的歌」会被堆进一个名叫 **music 的假专辑**里，而不是「未知专辑」。
/// 真要知道来源文件夹，用 `Song.srcPath`（扫描时会另存原始源路径），
/// **不要**拿 `filePath` 猜；但「未知专辑」这个兜底行为本身仍然不动
/// （用户看惯的就是「未知专辑」，改成文件夹名等于改观感）。
String albumKeyOf(Song s) {
  final a = s.album.trim();
  return a.isEmpty ? kUnknownAlbum : a;
}

/// 歌手分组键：无 artist 标签（含 MediaStore 的占位 `<unknown>`）归到 [kUnknownArtist]。
String artistKeyOf(Song s) {
  final a = s.artist.trim();
  if (a.isEmpty || a.toLowerCase() == '<unknown>') return kUnknownArtist;
  return a;
}

/// 按 [keyOf] 分组：过滤私密歌、组内保持传入顺序、组间按**拼音**排序，
/// 而「未知」组恒排最后（它是兜底桶，不该夹在正常专辑/歌手中间）。
///
/// 排序键来自 [pinyinSortKey]（汉字取拼音首字母，见 `pinyin_sort.dart`）——
/// 于是「陈奕迅」排在「周杰伦」前面，而不是按 Unicode 码点把「周」顶到最前。
/// 那张 24 KB 的首字母表由 `tool/gen_pinyin_table.py` 从 lpinyin 一次性抽出来，
/// **不引运行时依赖**（包不维护了也不影响）；表里没有的生僻字排到最后，
/// 同首字母内退化成码点序（结果稳定）。
List<SongGroup> groupSongs(
  List<Song> songs,
  Set<String> privatePaths,
  String Function(Song) keyOf,
  String unknownKey,
) {
  final buckets = <String, List<Song>>{};
  for (final s in songs) {
    if (privatePaths.contains(s.filePath)) continue;
    buckets.putIfAbsent(keyOf(s), () => <Song>[]).add(s);
  }
  final groups = [
    for (final e in buckets.entries) (name: e.key, songs: e.value),
  ];
  // 排序键预计算：放进比较函数里现算的话，同一个分组名会被重复计算 O(log n) 次
  final keys = {for (final g in groups) g.name: pinyinSortKey(g.name)};
  groups.sort((a, b) {
    final au = a.name == unknownKey;
    final bu = b.name == unknownKey;
    if (au != bu) return au ? 1 : -1;
    final c = keys[a.name]!.compareTo(keys[b.name]!);
    // 拼音键相同时用码点序兜底，保证结果稳定（同名分组不会来回抖）
    return c != 0 ? c : a.name.compareTo(b.name);
  });
  return groups;
}

/// 按专辑分组（键见 [albumKeyOf]）。
List<SongGroup> groupByAlbum(List<Song> songs, Set<String> privatePaths) =>
    groupSongs(songs, privatePaths, albumKeyOf, kUnknownAlbum);

/// 按歌手分组（键见 [artistKeyOf]）。
List<SongGroup> groupByArtist(List<Song> songs, Set<String> privatePaths) =>
    groupSongs(songs, privatePaths, artistKeyOf, kUnknownArtist);
