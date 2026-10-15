/// 本地歌曲图标 + 封面缓存。
///
/// 本文件只有**本地**这一半：`ArtworkStore` 缓存用户从相册挑的图标 / 封面。
/// App 全程离线，**不做任何联网取图**。
///
/// ⚠️ `ArtworkStore` 被 12 个文件用着（`library_data` / `player_service` /
/// `player_bar` / `song_artwork` / `playlists_page` / `root_page` /
/// `artwork_crop_page` / `backup_plan` …）—— 它是**本地**功能，别当成
/// 「联网封面」删掉。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// App 私有封面缓存：存用户的**本地**歌曲图标（相册选图裁剪后的字节），
/// 供通知栏大图与列表项用。
/// 目录路径首次初始化后缓存到内存，`uriFor` 同步返回（player_service 构造 MediaItem 用）。
class ArtworkStore {
  static String? _dirPath;
  static final Set<String> _names = {}; // 已缓存封面文件名（内存索引，见 ensureInit）

  /// 封面内容的版本号：`save` / `remove` 成功后自增，列表项与播放栏据此重画。
  ///
  /// 刻意**不用 `Library.notifyListeners()`**：那个通知会连带把曲库分组缓存、
  /// 歌单计数全部重算一遍（见 library_data.dart 的 `songsByAlbum`），换一张小图
  /// 不值得。这里只通知「图变了」这一件事。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 初始化缓存目录路径（须在首次构造 MediaItem 前调用）。
  /// 同时建立内存索引：构建通知栏队列时每首歌都要问一次「有没有封面」，原实现
  /// 每次都同步 existsSync（大库切歌时是明显的 UI 卡顿源），改为启动时 listSync 一次。
  static Future<void> ensureInit() async {
    if (_dirPath != null) return;
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/artwork');
    if (!await d.exists()) await d.create(recursive: true);
    _dirPath = d.path;
    try {
      for (final e in d.listSync()) {
        if (e is File) _names.add(e.path.split(RegExp(r'[/\\]')).last);
      }
    } catch (_) {
      // 目录不可读：退化为「无缓存」（has() 返回 false），不影响播放
    }
  }

  /// 以歌曲文件名（去目录、去扩展名）作为缓存名，同名不同目录的歌共享缓存（可接受）。
  static String _name(Song s) {
    final base = s.filePath.split(RegExp(r'[/\\]')).last;
    final dot = base.lastIndexOf('.');
    final stem = dot > 0 ? base.substring(0, dot) : base;
    return '$stem.jpg';
  }

  /// 缓存文件是否已存在（同步，查内存索引，不做文件 IO）。
  static bool has(Song s) => _dirPath != null && _names.contains(_name(s));

  /// 该歌的封面 file:// URI（同步，供 MediaItem.artUri 用）；无缓存返回 null。
  static Uri? uriFor(Song s) {
    final dir = _dirPath;
    if (dir == null || !has(s)) return null;
    return Uri.file('$dir/${_name(s)}');
  }

  /// 该歌封面文件（同步，供界面加载用）；无缓存返回 null。
  ///
  /// 界面**必须**走这里拿文件，别自己拿 [uriFor] 再 `toFilePath()`：解码缓存的键
  /// 是文件路径字符串（`FileImage` 只比 `file.path`），而 [save]/[remove] 的 evict
  /// 用的是本方法这一串路径。两边字符串必须逐字符相同，evict 才踢得中
  /// —— `Uri.file()` 在非 POSIX 平台上会把分隔符规整掉，往返一次就不再相等。
  static File? fileFor(Song s) {
    final dir = _dirPath;
    if (dir == null || !has(s)) return null;
    return File('$dir/${_name(s)}');
  }

  /// 把封面字节写到缓存文件。
  ///
  /// ⚠️ **同一首歌换图标时文件名不变、内容变了**，而 Flutter 的 `ImageCache` 以
  /// 文件路径（`FileImage` 的相等性）为键 —— 不 evict 的话重画时会命中旧图，
  /// 用户看到的是「换了图标但列表没变」。所以写完必须把这张图的解码缓存踢掉，
  /// 再自增 [revision] 让界面重建（缺一样都还是旧图，见 `SongArtwork` 的 key）。
  ///
  /// 另外：手动裁剪的图标是 **PNG 字节存进 `.jpg` 名**（`dart:ui` 只能编码 png /
  /// rawRgba，为它引 `package:image` 不划算）。后缀名不参与解码 —— Flutter 的
  /// `Image` 与安卓通知栏的 `BitmapFactory` 都按内容嗅探，所以这是安全的，
  /// **别当 bug 改**（改名会让已有的本地封面缓存全部失效）。
  static Future<void> save(Song s, Uint8List bytes) async {
    final dir = _dirPath;
    if (dir == null) return;
    final name = _name(s);
    await File('$dir/$name').writeAsBytes(bytes);
    _names.add(name);
    await _evict(name);
    revision.value++;
  }

  /// 踢掉某首歌封面的解码缓存（顺序：先写文件、再 evict、最后通知）。
  static Future<void> _evict(String name) async {
    final dir = _dirPath;
    if (dir == null) return;
    try {
      await FileImage(File('$dir/$name')).evict();
    } catch (_) {
      // 缓存里本来就没有这张图（首次保存）：无事可做
    }
  }

  /// 读缓存封面字节；不存在返回 null。
  static Future<Uint8List?> load(Song s) async {
    try {
      final dir = _dirPath;
      if (dir == null) return null;
      final f = File('$dir/${_name(s)}');
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {}
    return null;
  }

  /// 删除某首歌的封面缓存（歌单菜单「删除歌曲图标」用）。
  static Future<void> remove(Song s) async {
    try {
      final dir = _dirPath;
      if (dir == null) return;
      final name = _name(s);
      final f = File('$dir/$name');
      if (await f.exists()) await f.delete();
      _names.remove(name);
      await _evict(name); // 同上：不踢缓存的话界面会继续显示已删掉的图
      revision.value++;
    } catch (_) {}
  }
}
