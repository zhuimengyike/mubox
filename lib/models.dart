/// 歌曲模型与通用格式化工具。
library;

import 'package:on_audio_query/on_audio_query.dart';

class Song {
  /// 歌曲的**稳定 id**：见 `library_core.stableIdOfPath` —— 内部副本路径散列取负。
  /// 刷新/重扫都不会变，所以歌单 /「全部歌曲」顺序 / 收藏都指着它。
  final int id;
  final String title;
  final String artist;

  /// 专辑名（MediaStore 标签里的）。手动扫描导入的歌没有标签，这里是空串，
  /// 分组时由 library_core 归到「未知专辑」——见 `albumKeyOf`。
  final String album;
  final int durationMs;
  final String uri; // content:// 备用
  final String filePath; // 绝对路径，播放走 DeviceFileSource（content:// 在 Android 上无法直接播）
  final int? albumId; // 专辑 id，用于通知栏专辑封面大图（MediaStore albumart）

  /// 手机上的**原始源路径**（MediaStore 的 `_data`，或文件系统补扫到的路径）。
  /// 手动放进/下载进内部目录的歌没有源路径，这里是空串。
  /// 用途：内部副本撞名判定、防改名认领、删歌黑名单（见 `planInternalNames`）。
  ///
  /// ⚠️ **身份不是它** —— 身份是 [filePath]（内部副本路径），见 `stableIdOfPath`。
  final String srcPath;

  Song({
    required this.id,
    required this.title,
    required this.artist,
    // 可选带默认值：老的构造点（如 songFromFilePath）不必改，也不会因为漏传而报错
    this.album = '',
    required this.durationMs,
    required this.uri,
    required this.filePath,
    this.albumId,
    // 同理：老索引里没这个键，向后兼容读见 `Store.decodeSongs`
    this.srcPath = '',
  });

  factory Song.fromModel(SongModel m) {
    final t = m.title.trim();
    return Song(
      id: m.id,
      title: t.isEmpty ? '未知歌曲' : t,
      artist: m.artist ?? '',
      album: (m.album ?? '').trim(),
      durationMs: m.duration ?? 0,
      uri: 'content://media/external/audio/media/${m.id}',
      filePath: m.data,
      albumId: m.albumId,
      srcPath: m.data,
    );
  }

  /// 复制并覆盖若干字段（播放后回写真实时长；备份恢复后改写内部副本路径）。
  /// ⚠️ 换 [filePath] 时**必须同时给出新的 [id]**（用 `library_core.withStableId`），
  /// 否则 id 与内部副本路径对不上，歌单里指向这首歌的条目会失联。
  Song copyWith({int? id, int? durationMs, String? filePath, String? srcPath}) =>
      Song(
        id: id ?? this.id,
        title: title,
        artist: artist,
        album: album,
        durationMs: durationMs ?? this.durationMs,
        uri: uri,
        filePath: filePath ?? this.filePath,
        albumId: albumId,
        srcPath: srcPath ?? this.srcPath,
      );

  String get durationText => fmtMs(durationMs);
}

/// 毫秒 → "m:ss" 文本
String fmtMs(int ms) {
  final s = (ms / 1000).floor();
  final m = (s ~/ 60).toString();
  final ss = (s % 60).toString().padLeft(2, '0');
  return '$m:$ss';
}

/// 单个歌词校准点：timeMs = 打点处的歌曲播放时间（毫秒），offsetMs = 该点的偏移。
/// 偏移语义与单点一致：正 = 歌词延后显示，负 = 歌词提前显示。
class CalibrationPoint {
  final int timeMs;
  final int offsetMs;
  const CalibrationPoint(this.timeMs, this.offsetMs);

  /// 序列化成 [timeMs, offsetMs] 二元数组，紧凑且稳定。
  List<int> toJson() => [timeMs, offsetMs];

  factory CalibrationPoint.fromJson(List<dynamic> a) =>
      CalibrationPoint((a[0] as num).toInt(), (a[1] as num).toInt());
}

/// 计算某首歌在播放时间 [songTimeMs] 处的校准偏移（毫秒，可为小数）。
/// 按 (timeMs, offsetMs) 点做分段线性插值：
/// - 无点：恒为 0；
/// - 单点：全曲恒定该偏移（等价于「校准·基础」的整曲统一微调）；
/// - 多点：早于首点取首点值、晚于末点取末点值（两端取端点，不外推），中间线性过渡。
double calibrationOffsetAt(List<CalibrationPoint> pts, int songTimeMs) {
  if (pts.isEmpty) return 0;
  if (pts.length == 1) return pts[0].offsetMs.toDouble();
  if (songTimeMs <= pts.first.timeMs) return pts.first.offsetMs.toDouble();
  if (songTimeMs >= pts.last.timeMs) return pts.last.offsetMs.toDouble();
  for (var i = 0; i < pts.length - 1; i++) {
    final a = pts[i];
    final b = pts[i + 1];
    if (songTimeMs >= a.timeMs && songTimeMs <= b.timeMs) {
      final tt = b.timeMs == a.timeMs
          ? 0.0
          : (songTimeMs - a.timeMs) / (b.timeMs - a.timeMs);
      return a.offsetMs + (b.offsetMs - a.offsetMs) * tt;
    }
  }
  return pts.last.offsetMs.toDouble();
}

/// 歌词分段校准：一段连续歌词行（[startIdx]..[endIdx]）的实际演唱时间区间
/// [startMs]..[endMs]。段内歌词行的时间按这段起止在此区间内重新铺开（先按原始
/// 相对间距等比缩放），用于纠正这一段在整首歌里的漂移；未标注的行保留原始时间戳。
/// 字段对标用户"长绳截取几段染色"：startIdx/endIdx = 这段的起止歌词行，startMs/endMs =
/// 这段开始唱/唱完的精确音频时间。旋律段（无词）时，endMs 常打在下一句歌词开始处。
class LyricSegment {
  final int startIdx;
  final int endIdx;
  final int startMs;
  final int endMs;
  const LyricSegment(this.startIdx, this.endIdx, this.startMs, this.endMs);

  bool contains(int idx) => idx >= startIdx && idx <= endIdx;

  /// 序列化成 [startIdx, endIdx, startMs, endMs] 四元数组。
  List<int> toJson() => [startIdx, endIdx, startMs, endMs];

  factory LyricSegment.fromJson(List<dynamic> a) => LyricSegment(
        (a[0] as num).toInt(),
        (a[1] as num).toInt(),
        (a[2] as num).toInt(),
        (a[3] as num).toInt(),
      );
}

/// 计算整首歌每行歌词的显示时间：**全局连续时间轴**。
///
/// ── 踩坑备注（务必保留）──
/// 问题：旧实现是「段内覆盖 + 段外保持原始时间」，打了一段后段末与下一行之间出现断层。
/// 例：把前 30 秒的歌词映射成 0~30s 后，段外下一行仍是它的原始时间（可能 48s），
/// 播放到 30s 时高亮会「刷」地一下跳到 48s 那句（用户：改前 30 秒，歌词一下跑到 48 秒）。
/// 解决：改为「锚点分段线性插值 + 首尾平移」的全局映射，让整首歌时间轴单调连续：
///   1. 每段 起始行→seg.startMs、结束行→seg.endMs 作为锚点；
///   2. 任意两相邻锚点之间的行，按原始时间在此区间内等比插值（连续、单调、无断层）；
///   3. 第一个锚点之前的行、最后一个锚点之后的行，按各自锚点做整体平移，保证首尾连贯。
/// 这样调整一段不会让相邻区域跳变；未标段时返回原始时间轴。
List<int> computeLineTimes(List<int> originalTimes, List<LyricSegment> segs) {
  final n = originalTimes.length;
  if (n == 0) return const [];
  if (segs.isEmpty) return List.of(originalTimes);

  // 收集锚点：行索引 -> 该行锚定目标时间
  final anchor = <int, int>{};
  for (final s in segs) {
    if (s.startIdx >= 0 && s.startIdx < n) anchor[s.startIdx] = s.startMs;
    if (s.endIdx >= 0 && s.endIdx < n) anchor[s.endIdx] = s.endMs;
  }
  final anchorIdx = anchor.keys.toList()..sort();

  final times = List<int>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final a = anchor[i];
    if (a != null) {
      times[i] = a;
      continue;
    }
    int? li, ri;
    for (final k in anchorIdx) {
      if (k < i) li = k;
      if (k > i) {
        ri = k;
        break;
      }
    }
    if (li != null && ri != null) {
      // 两相邻锚点之间：按原始时间等比插值
      times[i] = _lerpTime(
        originalTimes[i],
        originalTimes[li],
        originalTimes[ri],
        anchor[li]!,
        anchor[ri]!,
      );
    } else if (li == null && ri != null) {
      // 第一个锚点之前：整体平移，使 ri 行处对齐
      times[i] = originalTimes[i] + (anchor[ri]! - originalTimes[ri]);
    } else if (li != null && ri == null) {
      // 最后一个锚点之后：整体平移，使 li 行处对齐
      times[i] = originalTimes[i] + (anchor[li]! - originalTimes[li]);
    } else {
      times[i] = originalTimes[i];
    }
    if (times[i] < 0) times[i] = 0;
  }
  return times;
}

/// 在 [xa, xb] 之间按 x 位置线性插值出 [ya, yb] 的对应值。
int _lerpTime(int x, int xa, int xb, int ya, int yb) {
  final span = xb - xa;
  final t = span <= 0 ? 0.0 : (x - xa) / span;
  return (ya + t * (yb - ya)).round();
}
