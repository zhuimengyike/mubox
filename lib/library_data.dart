/// 音乐库数据单例：歌曲 / 歌单 / 自定义标题，供各页面与播放栏共享。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:path_provider/path_provider.dart';

import 'artwork.dart';
import 'diagnostic_pack.dart';
import 'library_core.dart';
import 'lrc.dart';
import 'models.dart';
import 'player_service.dart';
import 'store.dart';

// 常量在 library_core 里统一定义；这里重导出，保持既有 import 方（页面等）不变。
export 'library_core.dart' show kAllSongs, kLikes, kAudioExts;

/// 「刷新 / 扫描导入」的结果（纯数据，`library_data` 内部用）。
///
/// 为什么要有它：取消之后**必须如实报「完成 X/Y」**，而 `_scanAndSave` 原先只
/// 返回 void —— 页面只能靠「曲库多了几首」反推，取消时那个数根本推不出来。
class ScanOutcome {
  const ScanOutcome({
    this.cancelled = false,
    this.completed = 0,
    this.total = 0,
    this.permDenied = false,
  });

  /// 被用户叫停了吗（true ⇒ **一个字节都没落盘**，内存状态保持原样）。
  final bool cancelled;

  /// 真的复制进内部并入库的条数。
  final int completed;

  /// 这趟打算处理的条数。
  final int total;

  /// 是「权限被拒」那条早退路吗。
  final bool permDenied;
}

/// 「刷新音乐库 / 扫描导入」的取消标志位。
///
/// 为什么是**模块级**的一个（而不是 `Library` 的字段）：页面要能叫停一趟正在跑的
/// 扫描，而它手上只有 `Library.instance` —— 走一个具名全局，页面侧
/// `libraryScanCancel.cancel()` 一句话就够，且不走通知/重建那条线。
///
/// ⚠️ 一轮扫描 = 一次 `begin()`：`begin` 会把号码换新，**上一轮残留的取消状态
/// 就此作废**（否则「取消过一次，以后每趟扫描第一步就自杀」）。
/// ⚠️ **只有**「刷新 / 扫描导入」那条路看它（`_scanAndSave`）。恢复备份后的
/// `reload()` **刻意不看**：那条路有自己的回滚快照兜底，停在一半才是真危险
/// （与「从备份恢复不加取消」同一条理由）。
final CancelToken libraryScanCancel = CancelToken();

/// 文件系统扫描的候选根目录（只扫常见音乐位置，不全盘扫避免过慢）。
const List<String> kScanRoots = [
  '/storage/emulated/0/Music',
  '/storage/emulated/0/Download',
  '/storage/emulated/0/Documents',
];

class Library extends ChangeNotifier {
  Library._();

  static final Library instance = Library._();

  final OnAudioQuery _audioQuery = OnAudioQuery();

  bool loading = true;
  bool permDenied = false;
  List<Song> songs = [];
  Map<String, List<int>> playlists = {};
  Map<int, String> titles = {}; // 自定义标题覆盖（songId -> 标题）
  List<int> allOrder = []; // 「全部歌曲」的自定义顺序（默认按扫描顺序）
  Set<String> deletedPaths = {}; // 已删除歌曲的文件名黑名单，刷新导入时跳过
  Set<String> instrumentalNames = {}; // 纯音乐（文件名），标记后不再为它找词
  Set<String> _privatePaths = {}; // 私密歌曲（filePath）：公共歌单隐藏，仅私密区域可见
  Set<String> _favPaths = {}; // 收藏/喜欢歌曲（filePath），汇总成「喜欢」歌单

  bool _initialized = false;
  bool _refreshing = false; // refresh 并发守卫（连点两次会并发导入两遍）

  /// 初始化音乐库：优先读取已缓存的歌曲索引，无需重新扫描。
  /// 仅首次使用（无缓存）才请求权限并扫描；权限被拒可重试。
  Future<void> init() async {
    if (_initialized) return;
    try {
      await _doInit();
    } catch (e) {
      // 初始化失败（播放服务/权限/IO 异常）：记录并结束加载态——否则歌单页会永远
      // 停在「加载中」转圈（调用方不接异常），且 _initialized 卡死后再也无法重试。
      debugPrint('音乐库初始化失败：$e');
      loading = false;
      _initialized = false;
      notifyListeners();
    }
  }

  /// init 的实际加载流程（外层只负责失败兜底）。
  Future<void> _doInit() async {
    await playerService!.init();
    await ArtworkStore.ensureInit(); // 确定封面缓存目录，供通知栏大图 file:// URI 用
    playlists = await Store.loadPlaylists();
    deletedPaths = await Store.loadDeletedPaths();
    instrumentalNames = await Store.loadInstrumental();
    _privatePaths = await Store.loadPrivateSongs();
    _favPaths = await Store.loadFavs();
    // 有缓存索引就直接加载，不请求权限、不扫描 MediaStore
    final cached = await Store.loadSongs();
    if (cached.isNotEmpty) {
      // 过滤掉已失效的文件（内部副本被删/清数据的歌）
      final valid =
          cached.where((s) => s.filePath.isEmpty || File(s.filePath).existsSync()).toList();
      // 老数据迁移：有歌的 filePath 还没指向内部副本 → 重新扫描导入
      final dir = await _musicDir();
      final needsImport = valid.isNotEmpty &&
          valid.any((s) => s.filePath.isNotEmpty && !s.filePath.startsWith(dir.path));
      // 老缓存没有 albumId 字段（旧版本），重扫一次补全专辑封面。
      // ⚠️ 这是一次性迁移：`every((s) => s.albumId == null)` 对「整库都没专辑标签」
      // 的曲库（下载进来的歌 + 手动扫描的 flac，albumId 天生是 null）**恒为真**，
      // 于是每次冷启动都要全量重扫 + 重新索要权限 + 递归遍历三个目录。
      final needsAlbumId = valid.isNotEmpty &&
          !await Store.loadAlbumIdMigrated() &&
          valid.every((s) => s.albumId == null);
      if (valid.isEmpty || needsImport || needsAlbumId) {
        // 重新扫描 + 导入音频到内部
        // ⚠️ **只有 `valid.isEmpty`（缓存里的歌连文件都没了）才算「被判为空」** ——
        // needsImport / needsAlbumId 是「缓存有效、只是要重扫一次」，不是缺索引，
        // 那条路上跑孤儿挽救就等于给正常启动加副作用。
        await _scanAndSave(rescueOrphans: valid.isEmpty);
        await _restoreLastSession();
        notifyListeners();
        return;
      }
      songs = valid;
      allOrder = await Store.loadAllOrder();
      // 身份升级（幂等）：歌单 /「全部歌曲」顺序里遗留的旧 id 翻译成稳定 id，
      // 歌自己的 id 也换成稳定 id。必须在 `titles` 之前 —— titles 是按歌 id 存的。
      await _migrateToStableIds();
      if (allOrder.isEmpty) allOrder = songs.map((s) => s.id).toList();
      await _reloadTitles(songs);
      loading = false;
      _initialized = true;
      await _restoreLastSession();
      notifyListeners();
      return;
    }
    // 没有缓存索引（首次启动 / songs.json 丢失或损坏）：同样是「曲库被判为空」那条路，
    // 扫描时顺手把只存在于内部副本里的歌救回来（见 _scanAndSave）。
    await _scanAndSave(rescueOrphans: true);
    await _restoreLastSession();
    notifyListeners();
  }

  /// 恢复上次播放会话（队列 + 当前曲 + 位置）。按 filePath 匹配，跳过已删除的文件。
  Future<void> _restoreLastSession() async {
    // 播放历史也要等 songs 就位才能把 filePath 映射回 Song —— 放这儿一次覆盖
    // 「读缓存 / 重扫 / 首次扫描」三条路径（它们都收敛到这个函数）。
    playerService!.restoreHistory(songs);
    final session = await Store.loadLastSession();
    if (session == null) return;
    final paths = (session['paths'] as List).cast<String>();
    final byPath = <String, Song>{for (final s in songs) s.filePath: s};
    final queue = <Song>[];
    for (final p in paths) {
      final s = byPath[p];
      if (s != null) queue.add(s);
    }
    if (queue.isEmpty) return;
    final idx = (session['index'] as int).clamp(0, queue.length - 1);
    final posMs = session['posMs'] as int;
    final title = session['title'] as String? ?? '';
    // 随机序的固定种子 + 走到哪一格：一起恢复，「上一首」才回得到同一首。
    // 老 queue.json / 老 prefs 键里没有这两个字段 → null，播放服务自己重新摇。
    final seed = session['seed'];
    final cursor = session['cursor'];
    await playerService!.restoreSession(
      queue,
      idx,
      posMs,
      title: title,
      seed: seed is int ? seed : null,
      cursor: cursor is int ? cursor : null,
    );
  }

  /// 恢复备份后整体重建音乐库：清空内存数据 → 重新读持久化。
  /// init 有 _initialized 守卫，必须先置 false 才会重新加载。
  Future<void> reload() async {
    loading = true;
    _initialized = false;
    songs = [];
    playlists = {};
    titles = {};
    allOrder = [];
    deletedPaths = {};
    instrumentalNames = {};
    _privatePaths = {}; // 私密/收藏按 filePath 记，恢复备份后必须一起清，否则残留旧标记
    _favPaths = {};
    notifyListeners();
    await init();
  }

  /// 权限被拒后点"重新授权"走这里，重置状态再扫一遍。
  Future<void> retry() async {
    loading = true;
    permDenied = false;
    _initialized = false;
    notifyListeners();
    // 曲库还空着（权限被拒时连缓存都没读上）⇒ 这一趟也要救孤儿。
    // 否则「songs.json 坏了 + 先拒权限 + 随后授权」这条路上，歌要等到**下次冷启动**
    // 才回来；而 `songs` 非空（本来就加载好了、只是刷新时被拒权限）时不该救 ——
    // 那不是「曲库被判为空」。
    await _scanAndSave(rescueOrphans: songs.isEmpty);
  }

  /// 手动刷新：重新扫描系统媒体库并更新本地索引。
  /// 新下载/删除的音乐需要点设置页的刷新按钮才会重新读取。
  ///
  /// 这趟**可以取消**：设置页那颗按钮在 `loading` 期间变成「点此停止」，
  /// 点它就 `libraryScanCancel.cancel()`（见 [_scanAndSave] 的取消语义）。
  ///
  /// 返回这趟的结算（[ScanOutcome]）：取消时页面要如实报「已取消：完成 X/Y」。
  /// ⚠️ 并发守卫那条早退（`_refreshing`）回的是**空结算**，不是「取消」。
  Future<ScanOutcome> refresh() async {
    if (_refreshing) return const ScanOutcome();
    _refreshing = true;
    loading = true;
    libraryScanCancel.begin(); // 令牌换新：上一趟的取消状态作废
    notifyListeners();
    try {
      return await _scanAndSave(cancel: libraryScanCancel.token);
    } finally {
      _refreshing = false;
    }
  }

  /// 扫描系统媒体库 → 更新歌曲列表 → 持久化索引。
  ///
  /// [rescueOrphans]：**只在「曲库被判为空 / 无缓存」那条路上传 true**（见 `_doInit`）。
  /// 那时 `songs.json` 丢了或坏了，而扫描范围（MediaStore + 三个公共目录）**不含**
  /// App 私有目录 `docs/music/` ⇒ 只存在于内部副本里的歌（原文件已被用户
  /// 删掉的）会整批从库里消失。true 时扫完再用内部副本目录里的音频把身份补回来
  /// （判定是纯函数 [planOrphanRescue]；黑名单里的歌不救）。
  ///
  /// [cancel]：**只有「刷新音乐库」那条路传它**（[refresh] 传 `libraryScanCancel`）。
  /// 启动 / 恢复 / 重新授权那几条路不传 —— 启动被打断一半才是真危险。
  ///
  /// 取消语义：**在每首歌之间检查标志位就退出，不许留下半写状态**。
  /// * 复制循环在**每一步开头**读标志 ⇒ 被叫停的那一首一个字节都还没复制
  ///   （`runImportLoop` 保证）；已经复制完的整首留在盘上 —— **已入库的照旧保留**；
  /// * 命中取消后**直接 return，不落盘**（songs.json / 歌单 / all_order 一个字节都不写）：
  ///   写一份「只导入了一半」的索引，下次启动看到的是半份库。
  ///   内存里的 `songs` 也保持原样，UI 回到可用状态等下一趟扫描。
  /// * 拒绝权限那条早退路排在取消检查**之后**（权限提示优先，别让取消把它吞了）。
  Future<ScanOutcome> _scanAndSave({
    bool rescueOrphans = false,
    CancelTokenHandle? cancel,
  }) async {
    final granted = await _audioQuery.permissionsRequest();
    if (!granted) {
      permDenied = true;
      loading = false;
      notifyListeners();
      return ScanOutcome(permDenied: true, total: 0);
    }
    try {
      final result = await _audioQuery.querySongs();
      final mediaList = result
          .where((s) => (s.duration ?? 0) > 0)
          .map(Song.fromModel)
          .toList();
      // 补充：文件系统手动扫描，把 MediaStore 漏索引的非 mp3（flac/m4a/ogg/wav 等）收进来
      final scanned = await _scanFilesystem();
      // 用户可能在「查询 + 遍历目录」这几秒里就点了停止：那就别白干后面的活。
      // ⚠️ 也要报 `cancelled: true`：不然页面会走到「音乐库已刷新」那句上，
      //    用户明明点了停止却看到「已刷新」—— 那是骗人。
      if (cancel?.isCancelled ?? false) {
        loading = false;
        notifyListeners();
        return const ScanOutcome(cancelled: true);
      }
      // 跳过「导出到手机 Music/MuBox」的副本：那是给用户拷电脑用的拷贝，不该当新歌再进库
      final list = <Song>[...mediaList, ...scanned]
          .where((s) => !isMuBoxCopyPath(s.filePath))
          .toList();
      // ① 老库补 srcPath（一次性）。**必须赶在身份升级之前** —— 反查靠的是扫描期 id。
      _backfillSrcPaths(list);
      // ② 身份升级：翻译歌单/顺序里遗留的旧 id，再把歌 id 换成稳定 id（幂等）。
      //    顺序不能反：先换 id 的话，那些旧条目就再也认不回歌了（H2 的破坏机制）。
      await _migrateToStableIds();
      // 把外部音频复制进 App 内部（用户数据目录），filePath 指向内部副本
      final dir = await _musicDir();
      // 已在库的歌（内部副本还在）：它们的内部文件名**永不改**（见 planInternalNames 规则 1）
      final existing = songs
          .where((s) => s.filePath.isNotEmpty && File(s.filePath).existsSync())
          .toList();
      final keep = <String, String>{
        for (final s in existing)
          if (s.srcPath.isNotEmpty) s.srcPath: basenameOf(s.filePath),
      };
      // 库里所有在用的内部文件名（含 srcPath 查不出来的老歌 —— 它们只认内部路径）。
      // 有这份占用表，新导入才**永不会覆盖老文件**（覆盖 = 老歌整条变成别人的音频）。
      final occupied = {for (final s in songs) basenameOf(s.filePath)};
      final names = planInternalNames(
        [for (final s in list) s.filePath],
        keep: keep,
        occupied: occupied,
      );
      // 导入清单（纯数据）：黑名单 / 空名字 / 规划不出名字的都在**进循环之前**剔掉，
      // 于是循环里的「已处理条数」就是用户看到的那条进度，不会对不上。
      final plan = <ImportPlanItem>[
        for (final s in list)
          if (!deletedPaths.contains(s.filePath) &&
              !deletedPaths.contains(basenameOf(s.filePath)) &&
              (names[s.filePath] ?? '').isNotEmpty)
            ImportPlanItem(
              src: s.filePath,
              base: basenameOf(s.filePath),
              targetName: names[s.filePath]!,
              extra: s,
            ),
      ];
      // ③ 复制循环：**每一步之间看一次取消标志**（判定在纯函数 `runImportLoop` 里，
      //    有单测钉「置位后 N 步内退出、计数与实际处理数一致」）。
      //    `copy` 里就地把扫描记录换成内部副本记录（`srcPath` 留着原始源路径）。
      final loop = await runImportLoop<Song>(
        plan,
        cancel: cancel,
        copy: (item, targetName) async {
          final internal = await _importIfNeeded(item.src, dir, targetName);
          if (internal == null) return null; // 复制失败跳过
          final s = item.extra! as Song;
          return Song(
            // 身份 = 内部副本路径的散列（不是 MediaStore id、也不是扫描期散列）
            id: stableIdOfPath(internal),
            title: s.title,
            artist: s.artist,
            album: s.album,
            durationMs: s.durationMs,
            uri: s.uri,
            filePath: internal,
            albumId: s.albumId,
            srcPath: item.src,
          );
        },
      );
      if (!loop.completed) {
        // 取消：内存状态**一个字段都不动**（songs/allOrder/playlists/songs.json
        // 全部保持原样），已复制好的内部副本留在盘上，下次扫描按
        // 「同名同大小直接用」认回来。
        loading = false;
        notifyListeners();
        debugPrint(
          'MuBox 曲库：已取消（完成 ${loop.done}/${loop.total}，未落盘，'
          '已复制的内部副本保留）',
        );
        return ScanOutcome(
          cancelled: true,
          completed: loop.done,
          total: loop.total,
        );
      }
      final imported = loop.imported;
      // 合并：保留已入库且内部副本仍存在的旧歌（外部删了内部副本也不丢）
      final seen = existing.map((s) => s.filePath).toSet();
      final merged = <Song>[...existing];
      for (final s in imported) {
        if (seen.add(s.filePath)) merged.add(s);
      }
      // ③ 孤儿内部副本挽救（只在「曲库被判为空」那条路上，见 `_doInit`）：
      //    内部副本目录里的音频如果不属于库里任何一首歌，就是丢索引留下的孤儿 ——
      //    用文件名重建记录（元数据留空、身份 = 内部副本路径的散列）。
      //    ⚠️ 必须排在**导入之后**：源文件还在的歌会先按原名复用同一个内部副本
      //    （`_importIfNeeded` 的「同名同大小直接用」），那时它的路径已在 `merged` 里，
      //    这里就不会再造一条重复记录、也不会多出一份磁盘副本。
      if (rescueOrphans) {
        final known = <String>{
          for (final s in merged)
            if (s.filePath.isNotEmpty) basenameOf(s.filePath),
        };
        final found = <String>[];
        try {
          await for (final e in dir.list(followLinks: false)) {
            if (e is File) found.add(basenameOf(e.path));
          }
        } catch (_) {
          // 目录列不出来（权限 / IO）：当没有孤儿处理，别把整次扫描带崩
        }
        final rescued = planOrphanRescue(
          dir.path,
          fileNames: found,
          knownNames: known,
          deletedPaths: deletedPaths,
        );
        if (rescued.isNotEmpty) {
          merged.addAll(rescued);
          // 常驻日志（release 包里翻不到私有目录，只能靠这行留痕）
          debugPrint(
            'MuBox 曲库：索引里没有、内部副本却还在的歌 ${rescued.length} 首已救回'
            '（${rescued.map((s) => basenameOf(s.filePath)).join(', ')}）',
          );
        }
      }
      songs = merged;
      await _reloadTitles(merged);
      // 刷新后合并「全部歌曲」顺序：保留已有的，新导入的追加到末尾
      final have = merged.map((s) => s.id).toSet();
      final kept = allOrder.where((id) => have.contains(id)).toList();
      final keptIds = kept.toSet(); // Set 查表：原先逐首 kept.contains 是 O(n²)
      final appended =
          merged.where((s) => !keptIds.contains(s.id)).map((s) => s.id).toList();
      allOrder = [...kept, ...appended];
      if (allOrder.isEmpty) allOrder = merged.map((s) => s.id).toList();
      await Store.saveAllOrder(allOrder);
      await Store.savePlaylists(playlists);
      await Store.saveSongs(merged);
      await Store.saveAlbumIdMigrated(); // 一次性迁移标记：以后冷启动不再为 albumId 重扫
      // 常驻日志：存量内部副本**改名**是「按内部路径存的那些键」（私密/收藏/自定义歌名/
      // 歌词校准/播放历史/上次会话）静默失联的唯一前兆，且 release 包装不了 run-as、
      // 手机上翻不到 docs/music 的目录清单 —— 所以每次刷新打一行，好事坏事都留痕。
      final renamed = [
        for (final s in existing)
          if (s.srcPath.isNotEmpty &&
              names[s.srcPath] != null &&
              names[s.srcPath] != basenameOf(s.filePath))
            '${basenameOf(s.filePath)}→${names[s.srcPath]}',
      ];
      debugPrint(
        'MuBox 曲库：扫描 ${list.length} 条源路径 / 入库 ${merged.length} 首 / '
        '${renamed.isEmpty ? '存量文件名零改动' : '⚠️ 改名 ${renamed.length} 个：$renamed'}',
      );
      loading = false;
      _initialized = true;
      notifyListeners();
      return ScanOutcome(
        completed: loop.total,
        total: loop.total,
      );
    } catch (e) {
      // 扫描/导入失败（权限、IO、解析）：记录原因并回到非加载态，避免界面卡在「扫描中」
      debugPrint('音乐库扫描失败：$e');
      loading = false;
      notifyListeners();
      return ScanOutcome();
    }
  }

  /// 给「还没存过 `srcPath`」的老歌补上原始源路径（一次性迁移）。
  ///
  /// 两条通道，先精确后兜底：
  /// ① 按 **扫描期 id** 反查 —— MediaStore 歌的 id 就是 `_id`，手动扫描歌的 id 是
  ///    `scannedId(源路径)`，两条都能精确命中（本机实测 16/16 命中）；
  /// ② 按 **basename 唯一** 反查 —— 万一身份已经升级过（id 换了），① 就失效；
  ///    内部副本名在不撞名时逐字符等于源 basename，所以唯一命中也是精确的。
  ///
  /// 查不出来的（外部原文件已被用户删掉）就留空串 —— 不影响身份，只影响
  /// 「撞名判定 / 删歌黑名单」，那两处对空串都有兜底。
  void _backfillSrcPaths(List<Song> scannedSongs) {
    final byId = <int, String>{};
    final byBase = <String, List<String>>{};
    for (final s in scannedSongs) {
      byId.putIfAbsent(s.id, () => s.filePath);
      byBase.putIfAbsent(basenameOf(s.filePath), () => []).add(s.filePath);
    }
    var changed = false;
    final next = <Song>[];
    for (final s in songs) {
      if (s.srcPath.isNotEmpty) {
        next.add(s);
        continue;
      }
      var hit = byId[s.id];
      if (hit == null) {
        final cands = byBase[basenameOf(s.filePath)];
        if (cands != null && cands.toSet().length == 1) hit = cands.first;
      }
      if (hit == null || hit == s.filePath) {
        next.add(s);
        continue;
      }
      next.add(s.copyWith(srcPath: hit));
      changed = true;
    }
    if (changed) songs = next;
  }

  /// 「歌的身份」升级（幂等）：把歌单 /「全部歌曲」顺序里遗留的旧 id 翻译成**稳定 id**，
  /// 并把每首歌的 id 换成稳定 id（内部副本路径的散列，见 `stableIdOfPath`）。
  ///
  /// 为什么两件事必须一起做：歌单与顺序存的就是 id。**先翻译、后换 id**；
  /// 反过来（先换 id）旧条目就再也认不回歌了 —— 那正是 H2 把用户歌单打空的机制。
  ///
  /// - **翻不动的条目原样保留**：那是用户数据，哪怕暂时对不上任何歌也不许顺手清理。
  /// - **幂等**：已经升级过时 [stableIdMapOf] 给出的是恒等映射，翻译前后逐项一致，
  ///   于是 `dirty` 为 false、一个字节都不写。
  Future<void> _migrateToStableIds() async {
    final idMap = stableIdMapOf(songs);
    var songsDirty = false;
    final nextSongs = <Song>[];
    for (final s in songs) {
      final mapped = withStableId(s);
      if (!identical(mapped, s)) songsDirty = true;
      nextSongs.add(mapped);
    }
    final nextOrder = translateLegacyIds(allOrder, idMap);
    final orderDirty = !listEquals(nextOrder, allOrder);
    final nextPlaylists = <String, List<int>>{};
    var listsDirty = false;
    for (final e in playlists.entries) {
      final next = translateLegacyIds(e.value, idMap);
      if (!listEquals(next, e.value)) listsDirty = true;
      nextPlaylists[e.key] = next;
    }
    if (songsDirty) songs = nextSongs;
    if (orderDirty) allOrder = nextOrder;
    if (listsDirty) playlists = nextPlaylists;
    // 常驻日志：歌单/顺序存的是 id，而它们在 release 包里是**翻不到的私有数据** ——
    // 「升级有没有吃掉条目」只能靠这行日志在真机上留痕（好事坏事都打）。
    debugPrint(
      'MuBox 身份：歌曲 ${songs.length} 首（id 改写 ${songsDirty ? '有' : '无'}）'
      ' / all_order ${allOrder.length} 条（翻译 ${orderDirty ? '有' : '无'}）'
      ' / 歌单 ${playlists.entries.map((e) => '${e.key}:${e.value.length}').join(' ')}'
      '，合计 ${playlists.values.fold<int>(0, (a, b) => a + b.length)} 条'
      '（翻译 ${listsDirty ? '有' : '无'}）',
    );
    if (!songsDirty && !orderDirty && !listsDirty) return;
    // 先写歌曲索引再写 id 列表：半途被杀时 songs.json 已是新 id，
    // 而顺序里的旧 MediaStore id 还能靠 `uri` 那条通道认回来（见 stableIdMapOf）。
    if (songsDirty) await Store.saveSongs(songs);
    if (orderDirty) await Store.saveAllOrder(allOrder);
    if (listsDirty) await Store.savePlaylists(playlists);
  }

  /// 文件系统手动扫描：按扩展名收集 MediaStore 没索引到的音频，作为 querySongs 的补充。
  /// 只扫常见音乐目录（kScanRoots）；无权限/目录异常时静默跳过该目录，不影响 MediaStore 结果。
  Future<List<Song>> _scanFilesystem() async {
    final files = <String>[];
    for (final root in kScanRoots) {
      final dir = Directory(root);
      if (!await dir.exists()) continue;
      try {
        await for (final e in dir.list(recursive: true, followLinks: false)) {
          if (e is! File) continue;
          final p = e.path.toLowerCase();
          if (kAudioExts.any((x) => p.endsWith('.$x'))) files.add(e.path);
        }
      } catch (_) {
        // 无权限 / scoped storage 限制：跳过该目录继续扫别的
      }
    }
    return files.map(songFromFilePath).toList();
  }

  /// 播放后回写真实时长（手动扫描的歌初始时长未知为 0）。
  Future<void> updateDuration(int songId, int ms) async {
    if (ms <= 0) return;
    final i = songs.indexWhere((s) => s.id == songId);
    if (i < 0) return;
    if (songs[i].durationMs > 0) return; // 已有时长，跳过避免重复写盘
    songs[i] = songs[i].copyWith(durationMs: ms);
    await Store.saveSongs(songs);
    notifyListeners();
  }

  /// App 内部音乐目录（用户数据，非 cache，清理缓存不会动到）。
  Future<Directory> _musicDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/music');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 把外部音频复制进内部音乐目录，返回内部路径；失败返回 null。
  ///
  /// [targetName] 由 `planInternalNames` 规划（纯函数）：
  /// **不撞名的 basename 逐字符不变**，撞名的才加 `-<路径散列>` 后缀。
  /// 原先这里直接拿 basename 当目标名 —— 两个不同目录的同名文件会写到同一个
  /// `docs/music/<名字>`，后者覆盖前者，**其中一首整条从库里消失**。
  ///
  /// `dst` 已存在且大小一致 → 认定是同一份，直接用（省一次全量复制）。
  Future<String?> _importIfNeeded(
    String srcPath,
    Directory dir,
    String targetName,
  ) async {
    if (targetName.isEmpty) return null;
    final target = '${dir.path}/$targetName';
    try {
      final src = File(srcPath);
      final dst = File(target);
      if (await dst.exists() && await src.length() == await dst.length()) return target;
      await src.copy(target);
      return target;
    } catch (_) {
      return null; // 外部文件被删/权限不足，跳过这首歌
    }
  }

  /// 删除歌曲：删内部副本文件 + 从库/歌单移除 + 加黑名单（防刷新重新导入）。
  /// 不碰手机上的原文件。
  Future<void> deleteSongs(Set<int> ids) async {
    if (ids.isEmpty) return;
    for (final s in songs.where((s) => ids.contains(s.id)).toList()) {
      // 黑名单存**原始源路径**（老记录是 basename，`_scanAndSave` 两种都认）：
      // 存 basename 会把「别的目录里的同名歌」一起拉黑，用户从别处再放一份就再也进不来。
      deletedPaths.add(s.srcPath.isNotEmpty ? s.srcPath : basenameOf(s.filePath));
      try {
        final f = File(s.filePath);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
    songs.removeWhere((s) => ids.contains(s.id));
    allOrder.removeWhere((id) => ids.contains(id));
    playerService?.pruneHistory(ids); // 历史里的同款也要清，否则浮层留着点不动的死记录
    for (final name in playlists.keys) {
      playlists[name] = (playlists[name] ?? []).where((id) => !ids.contains(id)).toList();
    }
    await Store.saveSongs(songs);
    await Store.saveAllOrder(allOrder);
    await Store.savePlaylists(playlists);
    await Store.saveDeletedPaths(deletedPaths);
    notifyListeners();
  }

  /// 从持久化读取自定义歌名（按文件路径），映射到当前歌曲列表的 id。
  /// 刷新后 MediaStore 的 id 变了也不怕，路径匹配即可。纯映射逻辑在 library_core。
  Future<Map<int, String>> _loadAllTitles(List<Song> list) async {
    return mapTitleOverrides(list, await Store.loadTitleOverrides());
  }

  /// 重新读一遍自定义歌名，并把结果同步给通知栏/锁屏。
  ///
  /// `titles` 全仓共 **3 个写点**（`grep 'titles ='` 与 `grep 'titles\\['` 可复核）：
  /// 本方法（`init` 与 `_scanAndSave` 各一处调用）、[editTitle]、以及 [reload]() 里
  /// 那句**中转的清空**。前两个都会过 [_publishTitlesToSession]；
  /// [reload]() 那句**刻意不接**：它清空之后紧跟的 `init()` 会经本方法重推一次，
  /// 接上去反而会让通知栏在重扫那段窗口里先闪回原名。
  Future<void> _reloadTitles(List<Song> list) async {
    titles = await _loadAllTitles(list);
    _publishTitlesToSession();
  }

  /// 自定义歌名变了之后，重推通知栏/锁屏上那一份 metadata。
  ///
  /// 为什么曲库侧要管这件事：通知栏标题是 `PlayerService.mediaItem` 的**快照**，
  /// 只在「换歌」时推（`playQueue` / `restoreSession` / `playAt`）。改名不改歌 ⇒
  /// 没有任何一次 `playAt` ⇒ 通知栏会一直挂着改名前的旧名
  /// （症状：App 内已显示新名，通知栏仍挂着旧名）。
  void _publishTitlesToSession() => playerService?.refreshMediaItem();

  /// 歌单内歌曲，按歌单自身顺序返回（拖拽排序 / 添加顺序都体现在这里）。
  /// 「全部歌曲」按 allOrder 排序；自建歌单按 id 列表顺序。
  /// 私密歌曲（isPrivate）从公共列表隐藏。
  List<Song> songsOf(String playlist) {
    // 排序/过滤为纯逻辑，委托 library_core；Library 只提供状态数据。
    if (playlist == kAllSongs) return allSongsOrdered(songs, allOrder, _privatePaths);
    if (playlist == kLikes) return likesSongs(songs, _favPaths, _privatePaths);
    return playlistSongsOrdered(songs, playlists[playlist] ?? [], _privatePaths);
  }

  /// 歌单卡片/抽屉用的歌曲数：只数「仍存在库中」的歌，不构建完整 Song 映射，
  /// 避免网格里每张卡片都跑一遍 songOf 的 O(N) 开销（大音乐库 + 多次刷新时省）。
  /// 「全部歌曲」直接数可见歌曲；自建歌单统计仍存在的非私密歌曲 id 数。
  int songCountOf(String playlist) {
    return countPlaylistSongs(
      playlist,
      songs,
      allOrder,
      playlists,
      _privatePaths,
      _favPaths,
      liveIds: _liveIds, // 网格里每张卡共用同一份，别再各建一遍
    );
  }

  Set<int>? _liveIdsCache;
  int _liveIdsRev = -1;

  /// 「仍在库中且非私密」的歌曲 id 集合，按 [revision] 缓存。
  ///
  /// ⚠️ 是**双键**：除歌自己的稳定 id，还收 `uri` 里的旧 MediaStore id ——
  /// 歌单卡片上的首数必须与 `songsOf` 列出来的列表等长，而后者也走双键
  /// （见 `library_core.songIndex`）。只收一个键会让「有歌但显示 0 首」。
  Set<int> get _liveIds {
    if (_liveIdsCache == null || _liveIdsRev != _revision) {
      final ids = <int>{};
      for (final s in songs) {
        if (_privatePaths.contains(s.filePath)) continue;
        ids.add(s.id);
        final legacy = mediaIdOfUri(s.uri);
        if (legacy != null) ids.add(legacy);
      }
      _liveIdsCache = ids;
      _liveIdsRev = _revision;
    }
    return _liveIdsCache!;
  }

  // ---- 曲库分组视图（「专辑 · 歌手」页）----
  // 与歌单列表同一套规则：私密歌不出现在分组里。
  //
  // 分组是 O(N log N) 且要给每个分组名算一次拼音键：那个页面同时监听
  // playerService.changeNotifier（切歌/播放暂停都会触发），不缓存的话
  // **每按一次暂停都要把整个曲库重分组一遍**。这里按 [revision] 缓存，
  // 只有曲库/私密名单真的变了才重算。

  /// 曲库数据版本号：任何一次 notifyListeners（歌曲、歌单、私密、收藏…）都自增。
  /// 分组的缓存键就是它 —— 数据没动，分组结果就没理由重算。
  int get revision => _revision;

  int _revision = 0;
  List<SongGroup>? _albumCache;
  int _albumCacheRev = -1;
  List<SongGroup>? _artistCache;
  int _artistCacheRev = -1;

  @override
  void notifyListeners() {
    _revision++;
    super.notifyListeners();
  }

  /// 按专辑分组（键见 library_core.albumKeyOf）。
  List<SongGroup> get songsByAlbum {
    if (_albumCache == null || _albumCacheRev != _revision) {
      _albumCache = groupByAlbum(songs, _privatePaths);
      _albumCacheRev = _revision;
    }
    return _albumCache!;
  }

  /// 按歌手分组。
  List<SongGroup> get songsByArtist {
    if (_artistCache == null || _artistCacheRev != _revision) {
      _artistCache = groupByArtist(songs, _privatePaths);
      _artistCacheRev = _revision;
    }
    return _artistCache!;
  }

  // ---- 收藏/喜欢：收藏的歌自动汇总成「喜欢」歌单 ----

  bool isFav(Song s) => _favPaths.contains(s.filePath);

  Future<void> toggleFav(Song s, {bool? value}) async {
    final set = value ?? !_favPaths.contains(s.filePath);
    if (set) {
      _favPaths.add(s.filePath);
    } else {
      _favPaths.remove(s.filePath);
    }
    await Store.saveFavs(_favPaths);
    notifyListeners();
  }

  // ---- 私密区域：私密歌曲在公共歌单隐藏，仅通过指纹/密码进入的私密区域可见 ----

  /// 当前是否为私密歌曲。
  bool isPrivate(Song s) => _privatePaths.contains(s.filePath);

  /// 私密区域里可显示的歌曲（全部私密歌）。
  List<Song> get privateSongs =>
      songs.where((s) => _privatePaths.contains(s.filePath)).toList();

  /// 私密歌曲的文件路径集合（供备份判断哪些音乐文件不该导出）。
  Set<String> get privatePathSet => Set.of(_privatePaths);

  /// 把歌曲加入/移出私密区域。
  Future<void> setPrivate(Song s, {required bool value}) async {
    if (value) {
      _privatePaths.add(s.filePath);
    } else {
      _privatePaths.remove(s.filePath);
    }
    await Store.savePrivateSongs(_privatePaths);
    notifyListeners();
  }

  String displayTitle(Song s) {
    final t = titles[s.id];
    if (t != null && t.isNotEmpty) return t;
    return s.title;
  }

  /// 文件名 basename（纯音乐名单 / 已删除黑名单都按它匹配）。
  String _base(Song s) => basenameOf(s.filePath);

  bool isInstrumental(Song s) => instrumentalNames.contains(_base(s));

  /// 标记/取消纯音乐；标记为纯音乐时清掉之前拉到的缓存歌词（错词）与导入的自定义歌词。
  Future<void> markInstrumental(Song s, {required bool value}) async {
    final base = _base(s);
    if (value) {
      instrumentalNames.add(base);
      await LyricsStore.remove(s);
      await ImportedLyricsStore.remove(s);
    } else {
      instrumentalNames.remove(base);
    }
    await Store.saveInstrumental(instrumentalNames);
    notifyListeners();
  }

  /// 删除某首歌的歌词（App 内部缓存 + 导入的自定义歌词 + 同目录 .lrc），不联网、不影响歌曲本身。
  Future<void> deleteLyrics(Song s) async {
    await LyricsStore.remove(s);
    await ImportedLyricsStore.remove(s);
    final lrcPath = s.filePath.toLowerCase().endsWith('.mp3')
        ? '${s.filePath.substring(0, s.filePath.length - 4)}.lrc'
        : '${s.filePath}.lrc';
    try {
      final f = File(lrcPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    notifyListeners();
  }

  // ---- 歌单/标题数据操作（持久化 + 通知）；UI 提示与弹窗留在页面层 ----

  /// 新建歌单；名称重复或为空返回 false。
  bool createPlaylist(String name) {
    if (name.isEmpty || playlists.containsKey(name)) return false;
    playlists[name] = [];
    _save();
    notifyListeners();
    return true;
  }

  Future<void> deletePlaylist(String name) async {
    playlists.remove(name);
    await Store.savePlaylists(playlists);
    notifyListeners();
  }

  /// 添加歌曲到歌单；已在歌单中返回 false。
  Future<bool> addToPlaylist(String name, Song song) async {
    final ids = playlists[name] ?? [];
    if (ids.contains(song.id)) return false;
    playlists[name] = [...ids, song.id];
    await Store.savePlaylists(playlists);
    notifyListeners();
    return true;
  }

  /// 批量添加歌曲到歌单；已在歌单中的自动跳过，返回实际新增数量。
  Future<int> addSongsToPlaylist(String name, List<Song> songs) async {
    final ids = playlists[name] ?? [];
    final existing = ids.toSet();
    final newIds = songs.map((s) => s.id).where((id) => !existing.contains(id)).toList();
    if (newIds.isEmpty) return 0;
    playlists[name] = [...ids, ...newIds];
    await Store.savePlaylists(playlists);
    notifyListeners();
    return newIds.length;
  }

  Future<void> removeFromPlaylist(String name, Song song) async {
    playlists[name] = (playlists[name] ?? []).where((e) => e != song.id).toList();
    await Store.savePlaylists(playlists);
    notifyListeners();
  }

  /// 批量从歌单移除歌曲（按 id）；返回实际移除数量。
  Future<int> removeSongsFromPlaylist(String name, Set<int> ids) async {
    final list = playlists[name] ?? [];
    final before = list.length;
    playlists[name] = list.where((id) => !ids.contains(id)).toList();
    final removed = before - (playlists[name] ?? []).length;
    if (removed > 0) {
      await Store.savePlaylists(playlists);
      notifyListeners();
    }
    return removed;
  }

  /// 批量移动：把歌曲从当前歌单移除并加入目标歌单（已在目标中的自动跳过）。
  /// 目标为「全部歌曲」时只从当前移除（全部歌曲本就不需要加入）。
  Future<void> moveSongsToPlaylist(String fromName, String toName, Set<int> ids) async {
    if (toName != kAllSongs) {
      final target = playlists[toName] ?? [];
      final have = target.toSet();
      final add = ids.where((id) => !have.contains(id)).toList();
      playlists[toName] = [...target, ...add];
    }
    // 只处理真实存在的自建歌单：「全部歌曲」「喜欢」是虚拟歌单，没有自己的 id
    // 列表，对它们赋值会凭空造出同名幽灵歌单（且 UI 里没有删除入口）。
    if (fromName != kAllSongs &&
        fromName != kLikes &&
        playlists.containsKey(fromName)) {
      playlists[fromName] =
          (playlists[fromName] ?? []).where((id) => !ids.contains(id)).toList();
    }
    await Store.savePlaylists(playlists);
    notifyListeners();
  }


  /// 调整自建歌单之间的顺序（「全部歌曲」固定第一，不参与排序）。
  /// 用 onReorderItem 回调：newIndex 已自动修正为移除项后的目标位置，无需再减一。
  Future<void> reorderPlaylists(int oldIndex, int newIndex) async {
    final names = playlists.keys.toList();
    if (oldIndex < 0 || oldIndex >= names.length) return;
    final reorderedNames = reorderMove<String>(names, oldIndex, newIndex);
    // 重建 LinkedHashMap 以改变遍历顺序（jsonEncode 按插入顺序写，刷新后顺序不丢）
    final reordered = <String, List<int>>{};
    for (final n in reorderedNames) {
      reordered[n] = playlists[n] ?? [];
    }
    playlists = reordered;
    notifyListeners();
    await Store.savePlaylists(playlists);
  }

  /// 按「被拖歌曲 id + 落点歌曲 id」重排歌单顺序（UI 拖拽走这条）。
  /// 页面列表过滤掉了私密歌，索引与 [playlists]/[allOrder] 里的 id 列表并不一一
  /// 对应：按索引重排（[reorderPlaylist]）会挪错歌，把用户顺序静默写坏。
  Future<void> reorderSongsById(String name, int movedId, int? beforeId) async {
    final ids = name == kAllSongs ? allOrder : (playlists[name] ?? const <int>[]);
    final from = ids.indexOf(movedId);
    if (from < 0) return; // 歌曲不在这个列表里（例如列表已刷新的竞态）
    final next = List<int>.of(ids)..removeAt(from);
    final at = beforeId == null ? next.length : next.indexOf(beforeId);
    next.insert(at < 0 ? next.length : at, movedId);
    if (name == kAllSongs) {
      allOrder = next;
      notifyListeners(); // 先刷 UI 再落盘，拖拽收尾不卡顿
      await Store.saveAllOrder(allOrder);
    } else {
      playlists[name] = next;
      notifyListeners();
      await Store.savePlaylists(playlists);
    }
  }

  Future<void> editTitle(Song song, String newTitle) async {
    await Store.saveTitleOverride(song.filePath, newTitle);
    if (newTitle.isEmpty) {
      titles.remove(song.id);
    } else {
      titles[song.id] = newTitle;
    }
    // ★ 通知栏/锁屏挂的是 mediaItem 的**快照**，改名不改歌（没有 playAt）——
    //   不在这里重推一次，通知栏就一直显示改名前的旧名。
    _publishTitlesToSession();
    notifyListeners();
  }

  void _save() => Store.savePlaylists(playlists);
}
