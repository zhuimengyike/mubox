/// 数据备份 / 恢复：把歌单、设置、壁纸、歌词、封面、歌曲副本打成 zip，
/// 换手机 / 换电脑时防丢。备份文件用 zip，内含：
///   prefs.json    —— SharedPreferences 全量（歌单 / 自定义标题 / 主题 / 动效开关等）
///   songs.json    —— 歌曲索引缓存
///   music/        —— App 内部的歌曲副本
///   wallpapers/   —— 壁纸图片
///   artwork/      —— 封面缓存
///   lyrics/       —— App 私有歌词缓存
///   imported_lyrics/ —— 用户导入 / 手写的主歌词
///   sub_lyrics/   —— 手写译文（每行主歌词挂一行）
///   visual_presets/  —— 视觉方案
///
/// ⚠️ 目录清单**不在这里**，在 `backup_plan.dart` 的 `kBackupDirs`
/// （有单测会扫源码核对它）。加新目录请改那儿。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_config.dart';
import 'backup_plan.dart';
import 'diagnostic_pack.dart';
import 'eq_engine.dart';
import 'library_core.dart';
import 'library_data.dart';
import 'models.dart';
import 'player_service.dart';
import 'store.dart';
import 'visual_presets.dart';

/// 备份包内的标记文件，恢复时用它校验「这是 Mu Box 备份」。
const String kBackupMarker = 'prefs.json';

/// 歌曲索引文件名（App 文档目录下）。备份里它是 zip 条目，恢复时**不走通写循环**。
const String _songsJsonName = 'songs.json';

class BackupService {
  /// 生成备份 zip 到临时目录，返回 zip 路径。调用方负责分享 / 清理临时文件。
  ///
  /// [cancel]：打包中途点「取消」用。**在 zip 条目之间**检查一次标志位
  /// （一个 250MB 的条目就是一次不可打断的 IO），命中就抛
  /// [CancellationException] —— 调用方要**删掉半成品 zip 与临时 prefs**
  /// （见 `settings_page._backupNow` 的 `finally`）。
  static Future<String> createBackup({CancelToken? cancel}) async {
    final docs = await getApplicationDocumentsDirectory();
    final tmp = await getTemporaryDirectory();
    // ⚠️ 建新备份**之前**先把上一个临时 zip 清掉：不清理的话每次备份都在
    //    App 私有 cache 里留一份（分享面板之外谁也拿不出来），越攒越大
    //    （实测能攒到 250MB）。挑谁删是纯函数 `planTempZipCleanup`：
    //    **只认 `mubox_backup_*.zip` 这个前缀 + `.zip` 后缀**、一次一个精确路径，
    //    ⛔ 绝不按通配删临时目录里别的东西（那里还有别的任务的临时文件）。
    //    本次建出来的那份由上面的 `keep` 排除，**永远不会被自己删掉**。
    final zipPath =
        '${tmp.path}/$kBackupTempPrefix${DateTime.now().millisecondsSinceEpoch}.zip';
    await _cleanupOldTempZips(tmp, keep: zipPath);

    // 本次打包的取消令牌：整个过程看的是**同一个号码**
    // （中途有人 `begin()` 开新任务也不会让这一次变得停不下来）。
    final tok = cancel?.token;
    tok?.throwIfCancelled();

    // 1. prefs.json：遍历 SharedPreferences 全量 key（跳过 flutter. 内部键），
    //    以后新增 key 也不用改备份代码。
    //
    //    私密区域开关（默认开）：开启时备份忽略私密歌曲 —— **不光是音频文件**，
    //    prefs 里所有能反推出私密歌身份的东西也要摘掉（见第 3 段的 marks 与
    //    `backup_plan.sanitizeBackupPrefs`）。
    //    ⚠️ 用户把开关关掉（「备份包含私密歌曲」）时 marks 是**空指纹** ⇒ 这一步
    //    天然变成 no-op：那时音频本身就在包里（条目名就是歌名），名单再藏也藏不住，
    //    倒是把名单丢掉会让恢复回来的私密歌**变成公开**。开关的语义 = 「这次备份
    //    可以带上私密东西」，所以两种状态下都不再额外藏。
    final marks = privateMarksFor(await Store.loadBackupSkipPrivate());

    final sp = await SharedPreferences.getInstance();
    final prefs = readPrefsRaw(sp);
    final prefsTmp = File('${tmp.path}/$kBackupPrefsTempName');
    await prefsTmp.writeAsString(jsonEncode(sanitizeBackupPrefs(prefs, marks)));
    tok?.throwIfCancelled();

    // 2. 流式写 zip（不吃内存），音乐/壁纸/封面/歌词目录递归收集
    //    ⚠️ 取消只能在**条目之间**生效：`enc.addFile` 内部是「读一个文件 → 压进包」，
    //    中途没有回调可插（一个 250MB 的音乐条目就是一次几秒的不可打断 IO）。
    //    所以下面两处 `throwIfCancelled` 各有一个：条目循环每轮开头一次
    //    （被叫停时那一份**一个字节都还没进包**），以及每个条目之后一次
    //    （点了取消最多再多等一个条目）。`finally` 保证 encoder 一定 close、
    //    临时 prefs 一定删掉，不让半成品留在 cache 里。
    final enc = ZipFileEncoder();
    try {
      enc.create(zipPath);
      await enc.addFile(prefsTmp, kBackupMarker);
      tok?.throwIfCancelled();
      // songs.json 同样要过私密过滤（第 2.1 段），传出去的是**过滤后**的那一份
      await _addSongsJson(enc, tmp, marks, docsPath: docs.path, tok: tok);
      tok?.throwIfCancelled();
      // 目录清单在 backup_plan.dart（kBackupDirs）：多一份都不在这儿写，
      // 免得「加了新数据目录、忘了加进备份」这种丢数据的漏再发生一次（H4）。
      for (final dir in kBackupDirs) {
        final d = Directory('${docs.path}/$dir');
        if (!await d.exists()) continue;
        await for (final e in d.list(recursive: true, followLinks: false)) {
          tok?.throwIfCancelled();
          if (e is! File) continue;
          // 备份忽略私密区域：跳过私密歌曲的文件
          if (dir == 'music' && _isPrivateMusicFile(e.path, marks)) continue;
          // 其余几个目录里的文件是**一歌一名**的（`<主名>.lrc/.sub.json/.jpg`）——
          // 私密歌的音频不进包，可它的歌词/译文/封面一旦进包，**名字就出门了**。
          if (dir != 'music' &&
              isPrivateBackupArtifact(dir, basenameOf(e.path), marks.stems)) {
            continue;
          }
          final rel = e.path.substring(d.path.length + 1).replaceAll('\\', '/');
          await enc.addFile(e, '$dir/$rel');
        }
      }
      await enc.close();
    } finally {
      // 取消 / 出错时**临时 prefs 必须删掉**（它是每次备份都复用的固定名字，
      // 留着就是 cache 里又一份僵尸），zip 的半成品由调用方按返回状态处置。
      try {
        if (await prefsTmp.exists()) await prefsTmp.delete();
      } catch (_) {
        // 删不掉只影响 cache 占用，不该把「已经取消」这件事变成别的错
      }
    }
    return zipPath;
  }

  /// 删掉临时目录里**上一个（或几个）**备份 zip。
  ///
  /// ⚠️ 两条铁律落在这一支里：
  /// 1. 挑谁删是纯函数（[planTempZipCleanup]）说了算 —— 前缀 + `.zip` 两道条件，
  ///    一次一个精确路径，⛔ 绝不 `Directory.delete(recursive)` / 通配删；
  /// 2. 目录列不出来、单个文件删不掉都**只打印、不抛** —— 清理失败不该让
  ///    「备份」这件事失败（那是两件事）。
  static Future<void> _cleanupOldTempZips(
    Directory tmp, {
    required String keep,
  }) async {
    try {
      final names = <String>[];
      await for (final e in tmp.list(followLinks: false)) {
        if (e is File) names.add(basenameOf(e.path));
      }
      final doomed = planTempZipCleanup(names, keep: basenameOf(keep));
      for (final n in doomed) {
        final f = File('${tmp.path}/$n');
        await f.delete();
        debugPrint('MuBox 备份：已清掉上一份临时 zip $n');
      }
    } catch (e) {
      debugPrint('MuBox 备份：清理旧临时 zip 失败（不影响本次备份）：$e');
    }
  }

  /// 备份包里的 prefs.json 文本：SharedPreferences 全量 key，**跳过 `flutter.` 内部键**。
  ///
  /// 抽出来是因为诊断包要的也是「设置里到底存了什么」这同一份东西
  /// （`buildDiagnosticFiles` 的 prefsJson）—— ⛔ 两处各扫一遍 key 早晚会走岔。
  ///
  /// ⚠️ 这里给的是**原文**（不做私密过滤）：过滤是备份那条线的事
  /// （`sanitizeBackupPrefs`）。诊断包**故意不过滤**，见 `diagnostic_pack.dart`。
  static Map<String, dynamic> readPrefsRaw(SharedPreferences sp) {
    final prefs = <String, dynamic>{};
    for (final k in sp.getKeys()) {
      if (k.startsWith('flutter.')) continue; // 插件内部键（含系统缓存），不是用户数据
      final v = sp.get(k);
      if (v != null) prefs[k] = v;
    }
    return prefs;
  }

  // ═════════════════════════════════════════════════════════════════════════
  // 落到公共 Documents/MuBox/（让电脑插上数据线直接看得见）
  // ═════════════════════════════════════════════════════════════════════════

  /// 导出通道（原生侧：`MainActivity` 的 `saveToDocuments` 分支）。
  /// 与 `export_service` 共用同一个通道名，只是方法名不同。
  static const MethodChannel _ch =
      MethodChannel('com.mubox.mu_box_phone/export');

  /// 把 App 私有目录里已有的一份文件复制到公共 `Documents/<subdir>/`。
  ///
  /// 参数名是**订好的契约**（原生侧 `argument<String>("src"/"name"/"subdir")`，
  /// `tool/check_save_to_documents.py` 会核对）—— ⛔ 一个都不许改。
  ///
  /// 返回值与 `export_service.exportSong` 同一套三态语义：
  /// * 原生回 map `{'status': 'exported'|'unchanged', 'uri': …}` ⇒ 按 status；
  /// * 原生回纯 uri 字符串（老回法 / 不带 `report` 时）⇒ 按 `exported`；
  /// * **null / 空 uri ⇒ 抛异常**（源文件不存在、名字非法）—— ⛔ 绝不当成功；
  /// * `PlatformException.code == 'SAVE_DOC_FAILED'` ⇒ 写失败（最常见是覆写
  ///   **别的 App 建的**同名条目被系统拒），原样往上抛。
  ///
  /// `unchanged` 是**正确**结果（上次那份逐字节相同），不是失败 ——
  /// 调用方文案不许写成「失败」（见 `saveResultText`）。
  static Future<SaveOutcome> saveToDocuments({
    required String src,
    required String name,
    String subdir = kDocumentsSubdir,
    bool report = true,
  }) async {
    if (name.isEmpty) throw Exception('保存失败：文件名为空');
    // 用 `Object?` 收：map 与纯 uri 字符串两种回法都要认
    // （强转 Map 会在老回法上抛 TypeError，那就把兼容那条路弄断了）。
    final Object? raw = await _ch.invokeMethod<Object?>('saveToDocuments', {
      'src': src,
      'name': name,
      'subdir': subdir,
      'report': report,
    });

    String? uri;
    var status = SaveStatus.exported;
    if (raw is Map) {
      final u = raw['uri'];
      if (u is String) uri = u;
      if (raw['status'] == 'unchanged') status = SaveStatus.unchanged;
    } else if (raw is String) {
      uri = raw; // 老回法：只有 uri
    }
    if (uri == null || uri.isEmpty) throw Exception('保存失败：$name');
    return SaveOutcome(
      status: status,
      // 到这儿 uri 一定非空（上一行抛过了）—— 顺带也是一道编译期保证：
      // 把上一行删掉**编译就不过**（`String?` 进不了 `String`，不是运行期才炸）。
      uri: uri,
      displayPath: documentsDisplayPath(subdir, name),
      name: name,
    );
  }

  /// 私密歌的四种身份写法（派生规则只用 `library_core` 那一套，别在这儿另算）。
  static PrivateMarks _marksOf(Set<String> privatePaths) {
    if (privatePaths.isEmpty) return kNoPrivateMarks;
    return (
      paths: privatePaths,
      names: {for (final p in privatePaths) basenameOf(p)},
      stems: {
        for (final p in privatePaths)
          if (basenameOf(p).isNotEmpty) splitNameExt(basenameOf(p)).stem,
      },
      ids: {for (final p in privatePaths) stableIdOfPath(p)},
    );
  }

  /// 按开关取私密指纹：**备份与诊断包共用这一条**（⛔ 别各写一份
  /// 「开关开了就过滤、关了就不管」的判定，两处走岔就是静默泄露）。
  ///
  /// [skipPrivate] = `Store.loadBackupSkipPrivate()`（缺省 true）。
  /// 关掉时返回 [kNoPrivateMarks]（空指纹 ⇒ 整套过滤变 no-op）。
  static PrivateMarks privateMarksFor(bool skipPrivate) =>
      skipPrivate ? _marksOf(Library.instance.privatePathSet) : kNoPrivateMarks;

  /// songs.json 的**过滤后文本**（诊断包用；备份那条线是直接写进 zip）。
  ///
  /// 三种情形与 `_addSongsJson` 完全一致（那支是 zip 版，本支是字符串版）：
  /// * 空指纹 ⇒ 原文返回（逐字节不变）；
  /// * 有私密歌 ⇒ 走 `Store.decodeSongs` / `encodeSongs` 摘掉私密记录；
  /// * 索引本身解析不了 ⇒ 原样返回**空 JSON 对象**，并打印一行 ——
  ///   坏索引在 App 眼里本来就等于没有，而它的原文可能正夹着私密歌明文。
  static Future<String> filteredSongsJson(
    String raw,
    PrivateMarks marks,
  ) async {
    if (marks.paths.isEmpty) return raw;
    try {
      final kept = [
        for (final s in Store.decodeSongs(raw))
          if (!marks.paths.contains(s.filePath)) s,
      ];
      return Store.encodeSongs(kept);
    } catch (e) {
      debugPrint('MuBox 诊断包：曲库索引解析不了，songs.json 留空（$e）');
      return '{}';
    }
  }

  /// 把一组「名字 → 文本」写成临时目录里的一个 zip，返回 zip 路径。
  ///
  /// 给诊断包用。**写完自检**：少一份该有的条目就抛（诊断包缺文件 =
  /// 用户以为拿到了全部信息，那是最坏的一种「看着成功」）。
  /// 临时 zip 由调用方负责删（它就在 cache 里，别留着）。
  static Future<String> writeZip({
    required Directory dir,
    required String fileName,
    required List<DiagnosticFile> files,
    bool requireInfo = true,
  }) async {
    final missing = diagnosticMissing(files.map((f) => f.name), requireInfo: requireInfo);
    if (missing.isNotEmpty) {
      throw StateError('诊断包内容不全，缺：${missing.join(', ')}');
    }
    final path = '${dir.path}/$fileName';
    final enc = ZipFileEncoder();
    try {
      enc.create(path);
      for (final f in files) {
        final tmp = File('${dir.path}/mubox_diag_${f.name}');
        try {
          await tmp.writeAsString(f.content);
          await enc.addFile(tmp, f.name);
        } finally {
          try {
            if (await tmp.exists()) await tmp.delete();
          } catch (_) {}
        }
      }
    } finally {
      await enc.close();
    }
    return path;
  }

  /// `music/` 里的这个文件是不是私密歌的音频。
  ///
  /// 先按**完整路径**比（原来就是这么比的），再按**文件名**兜一层：
  /// `docs/music` 是平目录、名字由 `planInternalNames` 保证唯一 ⇒ 两种比法等价；
  /// 而文件名那一层顺带绕开分隔符差异：「Android 上两边都是 `/`、本机跑单测时
  /// `Directory.list()` 给的是 `\`，而 `Song.filePath` 是 `'${dir.path}/<名>'`」——
  /// 只比完整路径的话，这个过滤器在 Windows 上**静默放行**，私密音频照样进包。
  static bool _isPrivateMusicFile(String path, PrivateMarks marks) =>
      marks.paths.contains(path) || marks.names.contains(basenameOf(path));

  /// 把 `docs/songs.json` 放进包 —— **私密歌的记录要摘掉**。
  ///
  /// 为什么非摘不可：这份索引里存的是明文 `title` / `artist` / `filePath`，
  /// 私密歌的音频虽然没进包，索引照样会把「有几首私密歌、叫什么名字、路径是什么」
  /// 全抖出来（用户开「备份忽略私密」要的正是**这个不出门**）。
  ///
  /// 三种情形：
  /// * 没有私密歌（[PrivateMarks.paths] 空）⇒ 原文件直接进包（既有行为逐字节不变）；
  /// * 有私密歌 ⇒ 走 `Store.decodeSongs` / `encodeSongs`（songs.json 形状的**唯一**定义）
  ///   过滤后写入临时文件再进包；
  /// * 索引本身**解析不了** ⇒ **不带它**：坏索引在 App 眼里等于没有（下次启动本来
  ///   就要重扫，见 `library_data` 的孤儿挽救），而它的原文可能正夹着私密歌明文。
  static Future<void> _addSongsJson(
    ZipFileEncoder enc,
    Directory tmp,
    PrivateMarks marks, {
    required String docsPath,
    CancelTokenHandle? tok,
  }) async {
    final songsFile = File('$docsPath/$_songsJsonName');
    if (!songsFile.existsSync()) return;
    tok?.throwIfCancelled();
    if (marks.paths.isEmpty) {
      await enc.addFile(songsFile, _songsJsonName);
      return;
    }
    final String filtered;
    try {
      final kept = [
        for (final s in Store.decodeSongs(await songsFile.readAsString()))
          if (!marks.paths.contains(s.filePath)) s,
      ];
      filtered = Store.encodeSongs(kept);
    } catch (_) {
      return; // 解析不了：不带它（见上面的理由）
    }
    tok?.throwIfCancelled();
    final f = File('${tmp.path}/mubox_songs.json');
    try {
      await f.writeAsString(filtered);
      await enc.addFile(f, _songsJsonName);
    } finally {
      // 取消 / 写失败都要把这份临时索引删掉（和临时的 mubox_prefs.json 一个道理）
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  /// 从备份 zip 恢复全部数据。会覆盖当前数据，调用前需用户确认。
  static Future<void> restoreFromZip(String zipPath) async {
    final docs = await getApplicationDocumentsDirectory();
    final archive = ZipDecoder().decodeBytes(await File(zipPath).readAsBytes());

    // 校验：必须有 prefs.json 标记
    final hasMarker =
        archive.files.any((f) => f.isFile && f.name == kBackupMarker);
    if (!hasMarker) {
      throw const FormatException('不是 Mu Box 备份文件');
    }

    // 1. 停止播放并重置播放器状态（清队列 / 当前曲 / 通知栏）
    final ps = playerService;
    if (ps != null) await ps.resetForRestore();

    // 2. 先落文件（除 prefs.json / songs.json），按相对路径覆盖写到 app 文档目录。
    //    顺序依赖：重写 songs.json / wallpaper_path 都需要文件已在位。
    Map<String, dynamic>? prefsMap;
    String? songsJson; // zip 里的歌曲索引**原文**，下面单独走原子写入口
    for (final f in archive.files) {
      if (!f.isFile) continue;
      final name = _cleanZipName(f.name);
      if (name == null) continue;
      if (name == kBackupMarker) {
        prefsMap =
            jsonDecode(utf8.decode(f.content)) as Map<String, dynamic>;
        continue;
      }
      if (name == _songsJsonName) {
        // songs.json **不在这儿就地覆盖** —— 走 Store.saveSongs（先写 tmp 再原子改名）。
        // 这条通写循环原先连它一起直接 writeAsBytes，绕开了全仓唯一的原子入口：
        // 写到一半被杀就留下截断的索引，下次启动被判「无缓存」→ 全量重扫 + 重新索要权限。
        // （下面第 3 段那句「别再直接 File.writeAsString」说的就是这个，原先只改了第 3 段。）
        songsJson = utf8.decode(f.content);
        continue;
      }
      final target = _joinSafe(docs.path, name);
      if (target == null) continue; // 非法路径（zip-slip）直接跳过
      File(target).parent.createSync(recursive: true);
      await File(target).writeAsBytes(f.content, flush: true);
    }
    if (songsJson != null) {
      try {
        await Store.saveSongs(Store.decodeSongs(songsJson));
      } catch (_) {
        // zip 里的索引本身坏了：**保持磁盘上现有索引不动**，不拿垃圾去盖它。
        // 下面第 3 段照常按文件名修路径，坏索引的问题留给下次刷新自愈。
      }
    }

    // 3. 重建 songs.json 的 filePath：换机后 App 内部 music/ 路径不同，
    //    按文件名（basename）在新 docs/music 里找回，命中才改写。
    //    走 Store.loadSongs / Store.saveSongs —— **别再直接 File.writeAsString**：
    //    那条路绕开了「先写 tmp 再原子改名」的约定，被打断就会留下截断的索引文件
    //    （下次启动判定「无缓存」→ 全量重扫 + 重新索要权限）。
    final songsFile = File('${docs.path}/$_songsJsonName');
    if (songsFile.existsSync()) {
      try {
        final list = await Store.loadSongs();
        final musicDir = Directory('${docs.path}/music');
        var changed = false;
        final patched = <Song>[];
        for (final s in list) {
          final base = basenameOf(s.filePath);
          final cand = base.isEmpty ? '' : '${musicDir.path}/$base';
          if (cand.isNotEmpty && s.filePath != cand && File(cand).existsSync()) {
            // 换过 filePath 必须重算稳定 id（身份 = 内部副本路径的散列），
            // 否则 id 与路径对不上，歌单/顺序里指向这首歌的条目会失联。
            patched.add(withStableId(s.copyWith(filePath: cand)));
            changed = true;
          } else {
            patched.add(s);
          }
        }
        if (changed) await Store.saveSongs(patched);
      } catch (_) {
        // songs.json 损坏不影响恢复主体，跳过重写
      }
    }

    // 4. 写 SharedPreferences：先清空再按类型写回。
    //    wallpaper_path 特殊处理：按文件名匹配新的 docs/wallpapers。
    //    font_path 指向外部字体文件，新机大概率不存在，保留原值（main.dart 已优雅降级）。
    final sp = await SharedPreferences.getInstance();
    // 先把现有设置落盘成一份回滚快照（H7）：sp.clear() 之后磁盘上的设置就没了，
    // 若此刻进程被系统回收 / 断电，**只存在内存里的那份副本会随进程一起消失**
    // → 用户看到的是「歌单 / 自定义歌名 / 顺序 / 收藏 / 私密名单 / 上次会话全空」。
    // 落盘之后由 recoverInterruptedRestore()（main.dart 启动时调）自己收场。
    final backup = <String, Object>{
      for (final k in sp.getKeys()) k: sp.get(k)!,
    };
    final rollbackFile = File('${docs.path}/$kRestoreRollbackFile');
    var snapshotOnDisk = false;
    try {
      await rollbackFile.writeAsString(
        buildRollbackSnapshot(backup, state: kRestoreStatePending),
        flush: true,
      );
      snapshotOnDisk = true;
    } catch (_) {
      // 落盘失败（磁盘满 / 只读）不该拦住恢复本身：退回原先的「内存回滚」语义
    }
    await sp.clear();
    try {
      if (prefsMap != null) {
        final wp = prefsMap['wallpaper_path'];
        if (wp is String && wp.isNotEmpty) {
          final base = wp.split(RegExp(r'[/\\]')).last;
          final cand = '${docs.path}/wallpapers/$base';
          if (File(cand).existsSync()) prefsMap['wallpaper_path'] = cand;
        }
        await _writePrefs(sp, prefsMap);
      }
    } catch (e) {
      // 回滚：宁可「恢复失败」也不要「设置被清空」
      // ignore: avoid_print
      print('恢复备份写设置失败，已回滚到恢复前的设置：$e');
      try {
        await sp.clear();
        await _writePrefs(sp, backup);
      } catch (_) {
        // 回滚也失败：已尽力，继续往下走让界面反映现状
      }
    }
    // 新设置已经全部写完：把快照标成 committed 再删。
    // 标记的意义：万一进程死在这两步之间，下次启动只会把残留文件删掉，
    // **不会**把刚刚恢复成功的设置又回滚回旧值。
    if (snapshotOnDisk) {
      try {
        await rollbackFile.writeAsString(
          buildRollbackSnapshot(const {}, state: kRestoreStateCommitted),
          flush: true,
        );
        await rollbackFile.delete();
      } catch (_) {}
    }

    // 5. 重建单例并刷新 UI：AppConfig 重建主题/字体/壁纸，Library 重建歌曲/歌单。
    //    各页面用 ListenableBuilder 监听它们，notifyListeners 即触发全 UI 重建。
    await AppConfig.instance.reload();
    // 5.1 EQ 的「我的预设」也存在 prefs（`eq_presets`）里，上面全量写回已经落地，
    //     但 EqEngine 内存里还是恢复**之前**那份列表，而 init() 有 `_inited` 早退
    //     ⇒ 不重读的话，用户接着点一次「保存 / 删除」就会拿旧列表把刚恢复出来的
    //     预设覆盖掉（跟 kBackupDirs 那类丢数据是同一回事，只是发生在内存侧）。
    await EqEngine.instance.reloadPresets();
    await _reloadCustomFont();
    await Library.instance.reload();
    // 6. 重读视觉方案：zip 通写循环已把 visual_presets/ 里的方案文件写回 docs，
    //    这里刷新内存列表，让界面能看到恢复回来的方案。
    await VisualPresets.instance.refresh();
  }

  /// 复制 main.dart 的字体恢复逻辑：恢复后按新配置重新注册自定义字体。
  static Future<void> _reloadCustomFont() async {
    final path = AppConfig.instance.fontPath;
    final family = AppConfig.instance.fontFamily;
    if (path == null || family.isEmpty) return;
    final f = File(path);
    if (!f.existsSync()) return;
    try {
      final bytes = await f.readAsBytes();
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
    } catch (_) {
      // 字体文件损坏/被删：忽略，回退默认字体
    }
  }

  /// 按类型把一份 key→值 写回 SharedPreferences（SharedPreferences 只有这 5 种 setter）。
  /// 抽出来是因为「正式写」和「失败回滚」和「启动回滚」三处逻辑完全一样。
  static Future<void> _writePrefs(
    SharedPreferences sp,
    Map<String, Object?> map,
  ) async {
    for (final e in map.entries) {
      final v = e.value;
      if (v is bool) {
        await sp.setBool(e.key, v);
      } else if (v is int) {
        await sp.setInt(e.key, v);
      } else if (v is double) {
        await sp.setDouble(e.key, v);
      } else if (v is String) {
        await sp.setString(e.key, v);
      } else if (v is List) {
        await sp.setStringList(e.key, v.cast<String>());
      }
    }
  }

  /// **启动时调**：上次「恢复备份」若在写设置的中途被打断（进程被系统回收 / 断电），
  /// 把设置回滚回恢复之前的样子。返回 true 表示真的回滚了。
  ///
  /// 为什么必须在 `AppConfig.load()` **之前**调：否则读到的就是那份被清空 /
  /// 只写了一半的 prefs，界面会先按坏数据建起来一遍。
  ///
  /// 三条路（判定逻辑在 `backup_plan.dart`，有单测）：
  /// - 没有快照 → 正常启动（绝大多数情况，只多一次 `exists`）
  /// - 快照是 `pending` → 上次没写完 → 写回旧设置
  /// - 快照是 `committed` → 新设置已写完，只是没删掉文件 → 删掉，别回滚
  ///
  /// 全程不抛：这是启动路径，任何异常都不该把 App 拦在门外。
  static Future<bool> recoverInterruptedRestore() async {
    try {
      final docs = await getApplicationDocumentsDirectory();
      final f = File('${docs.path}/$kRestoreRollbackFile');
      if (!await f.exists()) return false;
      final raw = await f.readAsString();
      switch (restoreRecoveryOf(raw)) {
        case RestoreRecovery.none:
          // 认不出来的快照：**不删也不动**，宁留下让下次再看到，也不拿它盖设置
          return false;
        case RestoreRecovery.discard:
          await f.delete();
          return false;
        case RestoreRecovery.rollback:
          final prefs = parseRollbackSnapshot(raw);
          if (prefs == null) return false;
          final sp = await SharedPreferences.getInstance();
          await sp.clear();
          await _writePrefs(sp, prefs);
          await f.delete();
          // ignore: avoid_print
          print('检测到上次「恢复备份」没走完，已把设置回滚到恢复前的状态');
          return true;
      }
    } catch (_) {
      return false;
    }
  }
}

/// 清洗 zip 条目名：拒绝绝对路径、.. 穿越；返回归一化相对路径，非法返回 null。
String? _cleanZipName(String name) {
  var n = name.replaceAll('\\', '/');
  if (n.startsWith('/')) n = n.substring(1);
  if (n.isEmpty || n.startsWith('..') || n.split('/').contains('..')) return null;
  if (n.length > 1 && n[1] == ':') return null; // 盘符开头
  return n;
}

/// 把相对路径安全拼到 base 下；越界（穿越到 base 之外）返回 null。
String? _joinSafe(String base, String rel) {
  final clean = _cleanZipName(rel);
  if (clean == null) return null;
  final target = File('$base/$clean').path;
  final normalized = File(target).absolute.path;
  if (!normalized.startsWith(File(base).absolute.path)) return null;
  return target;
}
