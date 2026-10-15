/// 子歌词（译文）存储：每行主歌词可以挂一行子歌词 —— 中文配英文、英文配中文，
/// 或者随便你写什么都行（App 不做翻译，只负责存和显示）。
///
/// 为什么不塞进 `.lrc`：LRC 没有「附属行」的概念，硬塞会被当成普通歌词行解析；
/// 而且子歌词得能跟主歌词**分开**清掉 —— 你重拉一次在线歌词，不该带走手写的译文。
/// 所以按歌曲名单独存一份 JSON：`[ "第一行的子歌词", "", "第三行的子歌词", ... ]`，
/// 空串表示该行没有子歌词，长度不必等于歌词行数（越界即视为没有）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

class SubLyricsStore {
  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/sub_lyrics');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 与 LyricsStore / ImportedLyricsStore 同样的命名约定：歌曲文件名去目录、去扩展名
  static String _file(Song s) {
    final base = s.filePath.split(RegExp(r'[/\\]')).last;
    final dot = base.lastIndexOf('.');
    return '${dot > 0 ? base.substring(0, dot) : base}.sub.json';
  }

  /// 读某首歌的子歌词；没有/读失败返回空列表
  static Future<List<String>> load(Song s) async {
    try {
      final f = File('${(await _dir()).path}/${_file(s)}');
      if (!await f.exists()) return const [];
      final raw = jsonDecode(await f.readAsString());
      if (raw is! List) return const [];
      return [for (final e in raw) e is String ? e : ''];
    } catch (_) {
      return const [];
    }
  }

  /// 保存子歌词；全空就删文件（不留空壳）
  static Future<void> save(Song s, List<String> subs) async {
    try {
      final f = File('${(await _dir()).path}/${_file(s)}');
      if (subs.every((e) => e.trim().isEmpty)) {
        if (await f.exists()) await f.delete();
        return;
      }
      await f.writeAsString(jsonEncode(subs));
    } catch (_) {}
  }

  static Future<void> remove(Song s) async {
    try {
      final f = File('${(await _dir()).path}/${_file(s)}');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
