/// 本地持久化：歌单 / 自定义标题 / 播放模式 / 歌曲索引。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';
import 'playback/queue.dart';

class Store {
  /// 读一个 JSON 存值并解析；**解析失败时先把原始串另存一份**到 `<key>_corrupt`，
  /// 再按「空」返回。
  ///
  /// 为什么非要留这一手：这些名单读取失败一律按空处理，而下一次写操作
  /// （新建歌单 / 删一首歌 / 收藏一首 / 把一首歌设为私密）会把空值**整体写回去**
  /// —— 「读坏了」就变成了「永久没了」。最坏的是私密名单：清空 = 私密歌全部
  /// 变回公开。留一份 `<key>_corrupt` 至少还能人工捞回来。
  static T? _decode<T>(
    SharedPreferences sp,
    String key,
    T Function(dynamic raw) build,
  ) {
    final raw = sp.getString(key);
    if (raw == null) return null;
    try {
      return build(jsonDecode(raw));
    } catch (_) {
      // 已经有了就不覆盖：留最早那份现场
      if (!sp.containsKey('${key}_corrupt')) {
        sp.setString('${key}_corrupt', raw).ignore();
      }
      return null;
    }
  }

  static Future<Map<String, List<int>>> loadPlaylists() async {
    final sp = await SharedPreferences.getInstance();
    return _decode(sp, 'playlists', (raw) {
      final map = raw as Map<String, dynamic>;
      return map.map(
        (k, v) => MapEntry(k, List<int>.from(v as List)),
      );
    }) ??
        {};
  }

  static Future<void> savePlaylists(Map<String, List<int>> pl) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('playlists', jsonEncode(pl));
  }

  /// 「全部歌曲」的自定义顺序（用户拖拽排序后刷新也不会丢）。
  /// 存歌曲 id 列表；为空表示用默认扫描顺序。
  static Future<List<int>> loadAllOrder() async {
    final sp = await SharedPreferences.getInstance();
    return _decode(sp, 'all_order', (raw) => List<int>.from(raw as List)) ?? [];
  }

  static Future<void> saveAllOrder(List<int> order) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('all_order', jsonEncode(order));
  }

  /// 自定义歌名覆盖：按文件路径持久化（filePath -> 标题）。
  /// 用路径而不是 MediaStore 的歌曲 id，刷新后 id 可能变化，路径更稳定，
  /// 保证「刷新以 app 内编辑过的歌名为准」。
  static Future<Map<String, String>> loadTitleOverrides() async {
    final sp = await SharedPreferences.getInstance();
    return _decode(sp, 'title_overrides', (raw) {
      final map = raw as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, v as String));
    }) ??
        {};
  }

  static Future<void> saveTitleOverride(String filePath, String title) async {
    final sp = await SharedPreferences.getInstance();
    final map = await loadTitleOverrides();
    if (title.isEmpty) {
      map.remove(filePath);
    } else {
      map[filePath] = title;
    }
    await sp.setString('title_overrides', jsonEncode(map));
  }

  static Future<String> loadMode() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getString('mode') ?? 'list';
  }

  static Future<void> saveMode(String m) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('mode', m);
  }

  static Future<double> loadSpeed() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getDouble('speed') ?? 1.0;
  }

  static Future<void> saveSpeed(double v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setDouble('speed', v);
  }

  // ---- 歌曲索引缓存（存 app 文档目录，启动直接读取，避免每次重扫）----

  static Future<File> _songsFile() => _docsFile('songs.json');

  /// 文档目录下的一个文件（songs.json / queue.json 都从这儿取路径）。
  static Future<File> _docsFile(String name) async {
    final docs = await getApplicationDocumentsDirectory();
    return File('${docs.path}/$name');
  }

  /// 文档目录下**按固定文件名原子写 JSON** 的写入队列：**所有**写入都从这里排队，
  /// 前一次落完才轮到下一次。
  ///
  /// 为什么要排队：写盘有 4 个调用点，其中 `Library.updateDuration` 是
  /// 「播放拿到真实时长就回写」的 fire-and-forget 路径（见 player_service 的
  /// onDurationChanged），完全可能和「刷新音乐库 / 下载完成 / 删除歌曲」撞在一起。
  /// 原实现共用一个固定 `songs.json.tmp`：后一次 writeAsString 会截断前一次正在写的
  /// 文件（落盘成半个 JSON），或者前一次先 rename 走了 tmp、后一次的 rename 直接抛
  /// FileSystemException（没人 await，异常静默丢失）。
  /// 两道保险：① 排队串行；② tmp 文件名带自增序号，天然不会互相覆盖。
  static Future<void> _jsonWriteQueue = Future<void>.value();
  static int _jsonTmpSeq = 0;

  /// 往文档目录下的 [name] **原子写一段 JSON 文本**：先写 `<name>.<n>.tmp` 再 rename。
  ///
  /// 全仓共用同一条排队（各文件本来就没有共享 tmp，串行只是保险）：`songs.json`
  /// 与 `queue.json` 谁也不会截断对方正在写的那一份。
  static Future<void> _writeJsonAtomic(String name, String data) {
    final prev = _jsonWriteQueue;
    final task = prev.then((_) async {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}/$name');
      final tmp = File('${f.path}.${++_jsonTmpSeq}.tmp');
      try {
        await tmp.writeAsString(data, flush: true);
        await tmp.rename(f.path);
      } catch (e) {
        // 写失败要清掉残留 tmp，别在文档目录里越积越多；异常继续往上抛给调用方
        try {
          if (await tmp.exists()) await tmp.delete();
        } catch (_) {}
        rethrow;
      }
    });
    // 队列自身不能被某一次失败掐断：吞掉异常继续往下传，调用方拿到的仍是带异常的 task
    _jsonWriteQueue = task.then((_) {}, onError: (_) {});
    return task;
  }

  /// 原子写 songs.json（**唯一的写入口**，备份恢复也走这里）：
  /// 先写 `songs.json.<n>.tmp` 再 rename —— 写到一半被杀进程/断电也不会留下
  /// 截断的 songs.json（那会让下次启动判定「无缓存」而全量重扫并重新索要权限）。
  static Future<void> saveSongs(List<Song> songs) =>
      _writeJsonAtomic('songs.json', encodeSongs(songs));

  /// 歌曲列表 → songs.json 的**文本**。抽出来是为了让「备份包里的 songs.json」
  /// 也走同一份形状定义（`backup_service` 要把私密歌从索引里摘掉再进包，
  /// 见 `backup_plan.sanitizeBackupPrefs`）—— 两处各写一遍迟早会漂移。
  static String encodeSongs(List<Song> songs) => jsonEncode(
    songs
        .map(
          (s) => {
            'id': s.id,
            'title': s.title,
            'artist': s.artist,
            'album': s.album,
            'durationMs': s.durationMs,
            'uri': s.uri,
            'filePath': s.filePath,
            'albumId': s.albumId,
            // 原始源路径；老索引里没有这个键，读侧走 `?? ''`
            'srcPath': s.srcPath,
          },
        )
        .toList(),
  );

  /// 读取缓存的歌曲索引；无缓存/文件损坏返回空列表。
  ///
  /// **逐条容错**：原先整表一个 try 包住全部记录，任何一条坏记录（少字段、类型变了）
  /// 都会让整表返回 []，进而被判定成「无缓存」→ 全量重扫 + 重新索要权限；
  /// 用户要是拒了权限，界面就是一个空音乐库。现在坏的那条跳过，其余照常读出来。
  static Future<List<Song>> loadSongs() async {
    final f = await _songsFile();
    if (!f.existsSync()) return [];
    final String raw;
    try {
      raw = await f.readAsString();
    } catch (_) {
      return [];
    }
    try {
      return decodeSongs(raw);
    } catch (_) {
      // 整个文件都不是合法 JSON：留一份现场再放弃，别让下一次写盘把它彻底盖掉
      try {
        await f.copy('${f.path}.corrupt');
      } catch (_) {}
      return [];
    }
  }

  /// 把 songs.json 的**原文**解析成歌曲列表：坏的那一条跳过，不拖垮整库。
  /// 顶层不是 JSON 数组时**抛异常**，调用方据此判定「整个文件坏了」并留现场。
  ///
  /// 抽成公开函数是为了让**恢复备份**也能走同一条路 —— zip 里的 songs.json
  /// 原先由通写循环就地覆盖（绕开了 tmp + 原子改名），被打断会留下截断的索引。
  /// 现在那条路改成 `decodeSongs` + [saveSongs]，与全仓其它写入同一入口。
  static List<Song> decodeSongs(String raw) {
    final list = jsonDecode(raw) as List;
    final out = <Song>[];
    for (final e in list) {
      try {
        final m = e as Map<String, dynamic>;
        out.add(
          Song(
            id: m['id'] as int,
            title: m['title'] as String,
            artist: m['artist'] as String,
            // 老索引（加专辑名之前存的）没有这个键，缺了当空串 —— 用 `as String`
            // 直接强转会抛，而整表抛掉就等于「无缓存」。
            album: (m['album'] as String?) ?? '',
            durationMs: m['durationMs'] as int,
            uri: m['uri'] as String,
            filePath: m['filePath'] as String,
            albumId: m['albumId'] as int?,
            // ⚠️ 新加的键：**老 songs.json 里根本没有它**。写成 `as String`
            // 强转会抛 → 这一条被跳过还算好，整表抛掉就等于「无缓存」→
            // 全量重扫 + 重新索要权限（代价极高，别踩）。
            srcPath: (m['srcPath'] as String?) ?? '',
          ),
        );
      } catch (_) {
        // 这一条坏了就跳过它，别拖垮整库
      }
    }
    return out;
  }

  // ---- 一次性迁移标记 ----

  /// 「补全 albumId 的重扫」是否已经做过（见 `Library._doInit`）。
  /// 老缓存没有 albumId 字段时要重扫一次补专辑封面；但那个判断
  /// （`every((s) => s.albumId == null)`）对「整库都没专辑标签」的曲库恒为真，
  /// 会变成**每次冷启动全量重扫**。改用这个一次性标记，做过就不再触发。
  static Future<bool> loadAlbumIdMigrated() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool('album_id_migrated') ?? false;
  }

  static Future<void> saveAlbumIdMigrated() async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('album_id_migrated', true);
  }

  // ---- 播放历史（filePath 列表，新→旧）----
  //
  // 存路径而不是歌曲 id：刷新音乐库后 MediaStore 的 id 会变，路径稳定。
  // 号码与「全部歌曲顺序」「上次会话队列」用的是同一套身份约定。

  /// 读播放历史（filePath，新→旧）。
  /// ⚠️ 用 `List<String>.from` 而不是 `.cast<String>()`：后者是惰性视图，元素类型
  /// 不对时异常会推迟到「遍历那一刻」才抛，那就漏到调用方去了。
  static Future<List<String>> loadHistory() async {
    final sp = await SharedPreferences.getInstance();
    return _decode(sp, 'play_history', (raw) => List<String>.from(raw as List)) ??
        [];
  }

  static Future<void> saveHistory(List<String> paths) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('play_history', jsonEncode(paths));
  }

  // ---- 上次播放会话 = 播放队列（filePath + 当前 index + 位置 + 随机种子）----
  //
  // 这份数据早先从 SharedPreferences 的 `last_session` 键
  // **搬到文档目录的 `queue.json` 文件**，理由是它的身份变了：
  //   ① 它现在是「用户自己攒出来的队列」（拖过序、删过歌、插过下一首），
  //      不再只是「上次播到哪儿」的临时记录；
  //   ② 文件才走得了与 `songs.json` 同一条「先写 tmp 再原子改名」的路，
  //      而 SharedPreferences 写一半被杀就留下半个 JSON（= 队列没了）；
  //   ③ 备份 zip 只单独特判 `songs.json` 一个文件，其余文档目录里的东西
  //      **本来就随「先落文件」那一段一起进包** ⇒ queue.json 白捡一份备份。
  //
  // ⚠️ 老数据（prefs 里的 `last_session`）**只读不迁**：读得到就用，读不到就算了，
  // 绝不把迁移结果写回去 —— 那会在「queue.json 被人为删掉」时把老队列又翻出来。
  //
  // ⚠️ [saveLastSession] 的 `mode` 只是**顺手记一笔**（打开这个文件一眼能看出当时
  // 是什么模式）：mode 的单一真相源仍是 prefs 的 `mode` 键（`Store.loadMode`，
  // `PlayerService.init` 读它）。**别改成从这儿读** —— 那就有了两个真相源，
  // 而 `setMode` 不落盘的话它们立刻不一致。

  /// 队列文件里 JSON 的键（读写两侧唯一定义在这儿，别在某一边手写字符串）。
  static const String kQueueFile = 'queue.json';
  static const String kQueuePosMs = 'posMs';

  /// 保存上次播放会话。队列用 filePath（刷新后 MediaStore id 会变、路径稳定）。
  ///
  /// [mode] / [seed] / [cursor] 是可选的：随机模式要连「固定种子 + 走到哪一格」一起
  /// 存下来，重启后「上一首」才回得到同一首。
  static Future<void> saveLastSession(
    List<String> paths,
    int index,
    int posMs,
    String title, {
    String? mode,
    int? seed,
    int? cursor,
  }) {
    final data = QueueCodec.encode(
      QueueState(refs: paths, index: index, sourceName: title),
      mode: mode,
      seed: seed,
      cursor: cursor,
    );
    data[kQueuePosMs] = posMs;
    // 走原子写入口：写到一半被杀进程/断电不会留下截断的 queue.json
    return _writeJsonAtomic(kQueueFile, jsonEncode(data));
  }

  /// 读取上次播放会话；没有 / 读不回来一律返回 null。
  ///
  /// 读侧**一律宽松**（与老实现同语义：老实现除了缺 `paths` 之外几乎不挑类型）：
  /// 它只是「启动时顺手恢复上次队列」，坏一点点就把整条队列判死是过度反应
  /// —— 真正要防的是「写坏」，那由上面的原子写兜住。
  static Future<Map<String, dynamic>?> loadLastSession() async {
    final f = await _docsFile(kQueueFile);
    if (f.existsSync()) {
      try {
        final m = jsonDecode(await f.readAsString());
        if (m is Map) return _sessionMapOf(m);
      } catch (_) {
        // 坏文件：**什么都不写**（尤其不许写空队列盖掉现场），静默降级到下面的旧键
      }
    }
    // 旧键：更早的版本存在 prefs 里，没有 queue.json 时照旧读得出来
    final sp = await SharedPreferences.getInstance();
    final raw = sp.getString('last_session');
    if (raw == null) return null;
    try {
      final m = jsonDecode(raw);
      if (m is Map) return _sessionMapOf(m);
    } catch (_) {
      // 旧键也坏了：当没有，不写现场（它已经不再是我们写的键了）
    }
    return null;
  }

  /// 把队列 JSON（新文件或旧 prefs 键）里的值取出来。
  /// 缺的 / 类型不对的按「没有」处理；`paths` 里的非字符串元素逐项跳过。
  static Map<String, dynamic>? _sessionMapOf(Map m) {
    final q = QueueCodec.decode(m);
    if (q == null) return null; // 连 paths 都没有 → 这条记录没意义
    final pos = m[kQueuePosMs];
    return {
      'paths': q.refs.toList(),
      'index': q.index,
      'posMs': pos is int ? pos : 0,
      'title': q.sourceName,
      'mode': QueueCodec.modeOf(m),
      'seed': QueueCodec.seedOf(m),
      'cursor': QueueCodec.cursorOf(m),
    };
  }

  // ---- 已删除歌曲黑名单（存文件名，刷新导入时跳过，防止删了又被导回）----
  static Future<Set<String>> loadDeletedPaths() async {
    final sp = await SharedPreferences.getInstance();
    return _decode(sp, 'deleted_names', (raw) => Set<String>.from(raw as List)) ??
        {};
  }

  static Future<void> saveDeletedPaths(Set<String> names) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('deleted_names', jsonEncode(names.toList()));
  }

  // ---- 纯音乐名单（存文件名，标记后不再为它找词，避免给纯音乐配错词）----

  static Future<Set<String>> loadInstrumental() async {
    final sp = await SharedPreferences.getInstance();
    return _decode(
          sp,
          'instrumental_names',
          (raw) => Set<String>.from(raw as List),
        ) ??
        {};
  }

  static Future<void> saveInstrumental(Set<String> names) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('instrumental_names', jsonEncode(names.toList()));
  }

  // ---- 歌词时间偏移（按 filePath 持久化，长按校准音频歌词对不齐）----

  static Future<Map<String, int>> loadLyricOffsets() async {
    final sp = await SharedPreferences.getInstance();
    return _decode(sp, 'lyric_offsets', (raw) {
      final m = raw as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(k, v as int));
    }) ??
        {};
  }

  // ---- 歌词校准（支持单点/多点；单点 = 一条 [0, offset]，多点 = 沿时间轴插值）----
  // 兼容旧数据：老版本把整曲偏移存在 lyric_offsets，这里读到 lyric_calibration 缺失时自动迁移。

  /// 读取全部校准点（filePath -> 按时间升序的校准点列表）。
  static Future<Map<String, List<CalibrationPoint>>> loadCalibration() async {
    final sp = await SharedPreferences.getInstance();
    final m = _decode(sp, 'lyric_calibration', (raw) {
      final mm = raw as Map<String, dynamic>;
      return mm.map((k, v) => MapEntry(
          k,
          (v as List)
              .map((e) => CalibrationPoint.fromJson(e as List))
              .toList()));
    });
    if (m != null) return m;
    // 这里返回 null 有两种情况：① 本来就没存过；② 存过但坏了（原始串已被 _decode
    // 隔离到 `lyric_calibration_corrupt`）。第 ② 种不能接着走下面的迁移 ——
    // 那会把旧的单点偏移写回去，把现场盖掉。
    if (sp.containsKey('lyric_calibration')) return {};
    // 迁移旧的单点偏移（key=filePath, value=offsetMs）→ 统一成 [0, offset] 的单点校准。
    final old = await loadLyricOffsets();
    if (old.isNotEmpty) {
      final migrated = <String, List<CalibrationPoint>>{
        for (final e in old.entries) e.key: [CalibrationPoint(0, e.value)],
      };
      await saveCalibration(migrated);
      return migrated;
    }
    return {};
  }

  /// 读取某首歌的校准点（按时间升序；无记录返回空列表）。
  static Future<List<CalibrationPoint>> loadCalibrationFor(String filePath) async {
    final all = await loadCalibration();
    final pts = all[filePath];
    if (pts == null) return [];
    return [...pts]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
  }

  static Future<void> saveCalibration(
      Map<String, List<CalibrationPoint>> calibration) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(
      'lyric_calibration',
      jsonEncode({
        for (final e in calibration.entries)
          e.key: e.value.map((p) => p.toJson()).toList(),
      }),
    );
  }

  /// 保存某首歌的校准点（先按时间排序，保证插值稳定）。
  static Future<void> saveCalibrationFor(
      String filePath, List<CalibrationPoint> pts) async {
    final all = await loadCalibration();
    final sorted = [...pts]..sort((a, b) => a.timeMs.compareTo(b.timeMs));
    if (sorted.isEmpty) {
      all.remove(filePath);
    } else {
      all[filePath] = sorted;
    }
    await saveCalibration(all);
  }

  /// 清除某首歌的全部校准点。
  static Future<void> clearCalibrationFor(String filePath) async {
    final all = await loadCalibration();
    all.remove(filePath);
    await saveCalibration(all);
  }

  // ---- 歌词分段校准（进阶/终极：一段一段标记起止行与起止音频时间）----

  /// 读取全部歌词段（filePath -> LyricSegment 列表）。
  static Future<Map<String, List<LyricSegment>>> loadSegments() async {
    final sp = await SharedPreferences.getInstance();
    return _decode(sp, 'lyric_segments', (raw) {
      final m = raw as Map<String, dynamic>;
      return m.map((k, v) => MapEntry(
          k, (v as List).map((e) => LyricSegment.fromJson(e as List)).toList()));
    }) ??
        {};
  }

  /// 读取某首歌的歌词段（无记录返回空列表）。
  static Future<List<LyricSegment>> loadSegmentsFor(String filePath) async {
    final all = await loadSegments();
    return all[filePath] ?? [];
  }

  /// 保存某首歌的歌词段（按 startIdx 排序）。
  static Future<void> saveSegmentsFor(
      String filePath, List<LyricSegment> segs) async {
    final sp = await SharedPreferences.getInstance();
    final all = await loadSegments();
    final sorted = [...segs]..sort((a, b) => a.startIdx.compareTo(b.startIdx));
    if (sorted.isEmpty) {
      all.remove(filePath);
    } else {
      all[filePath] = sorted;
    }
    await sp.setString(
      'lyric_segments',
      jsonEncode({
        for (final e in all.entries)
          e.key: e.value.map((s) => s.toJson()).toList(),
      }),
    );
  }

  /// 清除某首歌的全部歌词段。
  static Future<void> clearSegmentsFor(String filePath) async {
    final sp = await SharedPreferences.getInstance();
    final all = await loadSegments();
    all.remove(filePath);
    await sp.setString(
      'lyric_segments',
      jsonEncode({
        for (final e in all.entries)
          e.key: e.value.map((s) => s.toJson()).toList(),
      }),
    );
  }

  // ---- 私密歌曲（私密区域：指纹/密码进入后可见；公共歌单过滤掉）----

  /// 读取私密歌曲的文件路径集合（按 filePath，稳定）。
  static Future<Set<String>> loadPrivateSongs() async {
    final sp = await SharedPreferences.getInstance();
    // 这份名单最怕「读坏了当空」：清空 = 私密歌全部变回公开，所以 _decode 的
    // 损坏隔离在这里尤其重要。
    return _decode(sp, 'private_songs', (raw) => Set<String>.from(raw as List)) ??
        {};
  }

  static Future<void> savePrivateSongs(Set<String> paths) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('private_songs', jsonEncode(paths.toList()));
  }

  // ---- 收藏/喜欢歌曲（按 filePath，形成「喜欢」歌单）----

  static Future<Set<String>> loadFavs() async {
    final sp = await SharedPreferences.getInstance();
    return _decode(sp, 'fav_songs', (raw) => Set<String>.from(raw as List)) ?? {};
  }

  static Future<void> saveFavs(Set<String> paths) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString('fav_songs', jsonEncode(paths.toList()));
  }

  // ---- 私密区域：备份是否忽略私密歌曲（默认开启，防私密歌被备份带走）----

  static Future<bool> loadBackupSkipPrivate() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool('backup_skip_private') ?? true; // 默认开启
  }

  static Future<void> saveBackupSkipPrivate(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool('backup_skip_private', v);
  }
}
