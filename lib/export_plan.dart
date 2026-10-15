/// 导出的**计数与文案**（纯逻辑，零 Flutter 依赖）。
///
/// 为什么单独一个文件：`export_service.dart` 走 MethodChannel，跑不了纯单测，
/// 而这段文案必须能**对得上账**。
///
/// 一个真实踩过的坑：App 报「已导出 40/40 首到 Music/MuBox」，
/// 公共目录里 41 个文件却只有 **1 个是新写的**、其余沿用旧文件
/// （原生按 size+sha256 判定内容一致就不重写）。
/// ⇒ 文案必须把「真写入 / 已是最新 / 失败」**三笔账**分开，⛔ 不许再出现
/// 「N/N」而实际只写了 1 个。
///
/// 判定与文案都在这里，`settings_page` 只负责把结果喂进来、把这句话弹出去。
library;

/// 一轮导出里三笔账的计数。
class ExportTally {
  /// 这轮打算导出多少首。
  int total = 0;

  /// 真的写进公共目录的（原生回 `exported`）。
  int written = 0;

  /// 公共目录里已有一份**逐字节相同**的，原生没重写（回 `unchanged`）。
  int upToDate = 0;

  /// 失败的。
  int failed = 0;

  /// 第一条失败原因（只留第一条；`exportSummary` 在失败数 > 0 时带出来）。
  String? firstError;

  /// 开始新一轮：三笔账全部清零（`total` 重新给定）。
  void begin(int total) {
    this.total = total;
    written = 0;
    upToDate = 0;
    failed = 0;
    firstError = null;
  }

  /// 记一条成功。[written] = 这次**真的写了文件**（false = 内容已是最新、没动）。
  void addResult({required bool written}) {
    if (written) {
      this.written++;
    } else {
      upToDate++;
    }
  }

  /// 记一条失败。[error] 只取第一行（多行异常会把提示撑成一坨）。
  void addFailure(Object error) {
    failed++;
    firstError ??= '$error'.split('\n').first;
  }

  /// 已处理的条数（进度用：写进去的和跳过的一样都算处理过）。
  int get done => written + upToDate + failed;
}

/// 末尾那句提示。三笔账必须能对上：`written + upToDate + failed == total`。
///
/// 形状（失败为 0 时也照常写「失败 0 首」，让三笔账一眼能加得起来）：
/// `已导出 3/6 首到 Music/MuBox，2 首已是最新，失败 1 首（原因）`
String exportSummary(ExportTally t) {
  final buf = StringBuffer(
    '已导出 ${t.written}/${t.total} 首到 Music/MuBox，'
    '${t.upToDate} 首已是最新，失败 ${t.failed} 首',
  );
  final why = t.firstError;
  if (t.failed > 0 && why != null && why.isNotEmpty) buf.write('（$why）');
  return buf.toString();
}
