/// LRC 歌词解析：把 `.lrc` 文本解析成按时间排序的歌词行。
///
/// 支持一行多时间戳（`[00:12.34][01:23.45]文本`）、元数据标签（`[ti:]` `[ar:]` 等）、
/// 以及网易云在开头塞的「作词/作曲/编曲…」credits 行的过滤。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 一句歌词：开始时间 + 文本。
class LyricLine {
  final Duration time;
  final String text;
  const LyricLine(this.time, this.text);
}

class Lrc {
  // 时间戳：[分:秒] 或 [分:秒.毫秒] 或 [分:秒:厘秒]
  static final RegExp _tag = RegExp(r'^\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
  // 标准元数据标签行：[ti:歌名] [ar:歌手] [offset:…] 等，非歌词
  static final RegExp _meta = RegExp(r'^\[(ti|ar|al|by|offset|re|ve|length)\s*[:：]');
  // 网易云 credits 行（作词/作曲/编曲…），非正文歌词
  static final RegExp _credit =
      RegExp(r'^(作词|作曲|编曲|混音|母带|制作|统筹|监制|出品|发行|配唱|录音|和声|吉他|钢琴|贝斯|鼓|弦乐|管弦|键盘|录音师|混音师|制作人|演唱|填词|谱曲|词曲)\s*[:：]');

  /// 解析 LRC 文本 → 按时间升序的歌词行；无时间戳的纯文本行会被忽略。
  static List<LyricLine> parse(String raw) {
    if (raw.startsWith('﻿')) raw = raw.substring(1); // 去掉 UTF-8 BOM
    final out = <LyricLine>[];
    for (final rawLine in raw.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      if (_meta.hasMatch(line)) continue; // 元数据标签
      // 收集这一行上的所有时间戳
      final times = <Duration>[];
      var rest = line;
      while (true) {
        final m = _tag.matchAsPrefix(rest);
        if (m == null) break;
        final min = int.parse(m.group(1)!);
        final sec = int.parse(m.group(2)!);
        final frac = m.group(3);
        var ms = 0;
        if (frac != null && frac.isNotEmpty) {
          // 小数位补齐到 3 位取毫秒：'.5'→500，'.50'→500，'.500'→500
          ms = int.parse(frac.padRight(3, '0').substring(0, 3));
        }
        times.add(Duration(minutes: min, seconds: sec, milliseconds: ms));
        rest = rest.substring(m.end);
      }
      final text = rest.trim();
      if (times.isEmpty || text.isEmpty) continue;
      if (_credit.hasMatch(text)) continue; // credits 行
      for (final t in times) {
        out.add(LyricLine(t, text));
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  /// 读歌曲同目录下的同名 `.lrc` 并解析；文件不存在/读取失败返回空列表。
  static Future<List<LyricLine>> loadFor(String mp3Path) async {
    final lrcPath = mp3Path.toLowerCase().endsWith('.mp3')
        ? '${mp3Path.substring(0, mp3Path.length - 4)}.lrc'
        : '$mp3Path.lrc';
    try {
      final f = File(lrcPath);
      if (!await f.exists()) return [];
      return parse(await f.readAsString());
    } catch (_) {
      return [];
    }
  }

  /// 优先读音乐同目录的 .lrc；没有则读 App 私有歌词缓存。
  /// 用户手动导入的歌词（终极方案）优先级最高，用于覆盖错误/缺失的默认词。
  /// 若导入内容是纯文本（无时间戳），则按行生成 time=0 的歌词行，时间交由分段打点重建。
  static Future<List<LyricLine>> load(Song song) async {
    final imported = await ImportedLyricsStore.load(song);
    if (imported != null && imported.isNotEmpty) {
      final parsed = parse(imported);
      if (parsed.isNotEmpty) return parsed;
      return parsePlain(imported);
    }
    final lines = await loadFor(song.filePath);
    if (lines.isNotEmpty) return lines;
    final cached = await LyricsStore.load(song);
    return cached == null ? [] : parse(cached);
  }

  /// 解析无时间戳的纯文本歌词：每行一个 LyricLine（time=0，顺序按输入）。
  /// 用于「手动手写歌词」场景——时间完全交由分段打点重建。
  static List<LyricLine> parsePlain(String raw) {
    if (raw.startsWith('\uFEFF')) raw = raw.substring(1);
    final out = <LyricLine>[];
    for (final rawLine in raw.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      out.add(LyricLine(Duration.zero, line));
    }
    return out;
  }
}

/// App 私有歌词缓存（`Documents/lyrics/<主名>.lrc`）—— 绕过 Android 分区存储
/// 不能往 `/sdcard/Music` 写文件的限制。
///
/// ## **只读**（App 不再往里写）
/// 写入者（设置页「拉取全部歌词」）已随联网那一半一起删掉。**读 / 删两条路刻意留着**：
/// * [load] —— `Lrc.load` 的兜底：盘上**已经存下的那些词**是用户自己的数据，
///   升级之后必须照常显示（⛔ 不主动清用户的盘）；
/// * [remove] —— `Library.deleteLyrics`（「删除歌词」菜单项）
///   与 `markInstrumental`（标记纯音乐时清掉之前存下的词）都还在用它。
class LyricsStore {
  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/lyrics');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 以歌曲文件名（去目录、去 .mp3）作为缓存名，同名不同目录的歌会共享缓存（可接受）。
  static String _name(Song s) {
    final base = s.filePath.split(RegExp(r'[/\\]')).last;
    final dot = base.toLowerCase().endsWith('.mp3') ? base.length - 4 : base.length;
    return '${base.substring(0, dot)}.lrc';
  }

  static Future<String?> load(Song s) async {
    try {
      final d = await _dir();
      final f = File('${d.path}/${_name(s)}');
      if (await f.exists()) return await f.readAsString();
    } catch (_) {}
    return null;
  }

  /// 删除某首歌的缓存歌词（「删除歌词」菜单项 / 标记纯音乐时清掉之前存下的错词）。
  static Future<void> remove(Song s) async {
    try {
      final d = await _dir();
      final f = File('${d.path}/${_name(s)}');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}

/// 用户手动导入的歌词缓存：存 App 私有目录，优先级高于同目录 .lrc 与 App 内的歌词缓存，
/// 用于覆盖歌词错误/缺失的情况。可查看/清除（终极校准方案）。
class ImportedLyricsStore {
  static Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/imported_lyrics');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  /// 以歌曲文件名（去目录、去 .mp3）作为缓存名，与 LyricsStore 相同约定。
  static String _file(Song s) {
    final base = s.filePath.split(RegExp(r'[/\\]')).last;
    final dot = base.toLowerCase().endsWith('.mp3') ? base.length - 4 : base.length;
    return '${base.substring(0, dot)}.lrc';
  }

  static Future<void> save(Song s, String lrcText) async {
    final d = await _dir();
    await File('${d.path}/${_file(s)}').writeAsString(lrcText);
  }

  static Future<String?> load(Song s) async {
    try {
      final d = await _dir();
      final f = File('${d.path}/${_file(s)}');
      if (await f.exists()) return await f.readAsString();
    } catch (_) {}
    return null;
  }

  /// 当前歌曲是否导入了歌词（供「终极」面板显示/清除）。
  static Future<bool> has(Song s) async {
    try {
      final d = await _dir();
      return await File('${d.path}/${_file(s)}').exists();
    } catch (_) {}
    return false;
  }

  /// 清除导入的歌词，回退到默认词（同目录 .lrc / App 内的歌词缓存）。
  static Future<void> remove(Song s) async {
    try {
      final d = await _dir();
      final f = File('${d.path}/${_file(s)}');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }
}
