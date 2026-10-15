/// 导出歌曲：把 App 内部（docs/music）的歌曲复制一份到手机公共 Music/MuBox 目录。
///
/// 走的原生 MediaStore 写入（Android 10+ 免运行时权限），原文件仍在 App 内、删除不丢，
/// 手机文件管理器能直接看到，方便拷到电脑或手动管理。失败会抛异常，由调用方提示。
///
/// 原生侧**先比对 size+sha256，内容一致就原地不动**并回一个
/// `{"status":"exported"|"unchanged","uri":…}`，Dart 这边把三态接回来
/// （真写入 / 已是最新 / 失败）—— 只认「成功/失败」的话，「已导出 40/40 首」
/// 里可能只有 1 首是新写的。计数与文案在 `export_plan.dart`。
library;

import 'package:flutter/services.dart';

import 'models.dart';

/// 一次导出的结果状态。
enum ExportStatus {
  /// 真的写了文件（新建或内容不一致时原地覆盖）。
  exported,

  /// 公共目录里已有一份**逐字节相同**的：原生没重写。
  alreadyUpToDate,
}

/// 导出单曲的结果：[status] 三态里的前两态，[uri] 是公共目录里的 uri。
/// 失败（拿不到 uri）仍然**抛异常** —— 与改动前同一条路，调用方照旧 catch。
class ExportResult {
  const ExportResult(this.status, this.uri);

  final ExportStatus status;
  final String uri;

  /// 这次真的写了文件吗（`false` = 已是最新，公共目录里那份一个字节都没动）。
  bool get written => status == ExportStatus.exported;
}

class ExportService {
  static const MethodChannel _ch = MethodChannel('com.mubox.mu_box_phone/export');

  /// 导出单曲：成功返回 [ExportResult]，失败抛异常。
  ///
  /// 带 `report: true` 请原生回「状态 + uri」的 map；**两种回法都认**：
  /// * map：`{'status': 'exported'|'unchanged', 'uri': 'content://…'}`
  ///   （`status` 认不出来时按 `exported` 处理 —— 宁可多算一笔「写进去」，
  ///   也不要把真写了的那次说成「已是最新」）；
  /// * 纯字符串：老原生的回法（只有 uri，没有状态）⇒ 按 `exported`。
  ///
  /// ⚠️ `uri` 为空 / null **仍然走原来的失败路径**（抛异常）：状态是附带信息，
  /// 「有没有落地」只认 uri。三态语义由此保持：exported / unchanged / 抛异常。
  static Future<ExportResult> exportSong(Song s) async {
    if (s.filePath.isEmpty) throw Exception('歌曲路径为空');
    final name = s.filePath.split(RegExp(r'[/\\]')).last;
    // 用 `Object?` 接：map 与纯字符串两种回法都要能收（强转 Map 会在老回法上抛
    // TypeError，那就把「老路径」弄坏了）。
    final raw = await _ch.invokeMethod<Object?>('export', {
      'src': s.filePath,
      'name': name,
      'report': true,
    });

    String? uri;
    var status = ExportStatus.exported;
    if (raw is Map) {
      final u = raw['uri'];
      if (u is String) uri = u;
      if (raw['status'] == 'unchanged') status = ExportStatus.alreadyUpToDate;
    } else if (raw is String) {
      uri = raw; // 老原生：只有 uri
    }
    if (uri == null || uri.isEmpty) throw Exception('导出失败：$name');
    return ExportResult(status, uri);
  }
}
