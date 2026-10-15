/// 两件事的**纯逻辑**（零 Flutter 依赖）：诊断包的内容清单，与「耗时循环能不能被叫停」。
///
/// 为什么单独一个文件（照 `backup_plan.dart` / `export_plan.dart` 的同一套理由）：
/// 清单错了会**少带一份用户数据**（那是丢数据），取消判定错了会**让用户白等**
/// —— 两条都该在单测里钉死，而它们的调用点（`backup_service` / `library_data`）
/// 全都依赖 SharedPreferences / path_provider / MethodChannel，跑不了纯单测。
///
/// 本文件只许 import `dart:convert`（`CancellationException` 自己实现
/// `Exception`，不依赖任何异常库），⛔ 不许 import Flutter / 任何插件。
library;

import 'dart:convert';

// ═══════════════════════════════════════════════════════════════════════════
// 一、诊断包（给用户自己排查用的一份 zip）
// ═══════════════════════════════════════════════════════════════════════════

/// 诊断包 zip 的文件名前缀（`diagnostic_<毫秒时间戳>.zip`）。
const String kDiagnosticPrefix = 'diagnostic_';

/// 诊断包落在公共存储里的子目录（原生侧收 `subdir` 参数）。
///
/// 与备份共用同一个目录：`内部存储/Documents/MuBox/`。人类可读路径由
/// [documentsDisplayPath] 在 Dart 侧拼（**原生不回路径**，这是订好的契约）。
const String kDocumentsSubdir = 'MuBox';

/// 诊断包里那份人读的说明文件（**不带时间戳**，免得每份诊断包的名字都不一样）。
const String kDiagnosticInfoName = 'info.txt';

/// 期望在诊断包里见到的**固定**条目（除 [kDiagnosticInfoName]）。
///
/// * `songs.json` —— 曲库索引原文（⚠️ **做私密过滤**：它会被交到用户手上，
///   而过滤规则全仓只有一份，在 `backup_service._addSongsJson`）；
/// * `prefs.json` —— SharedPreferences 全量。
///
/// ⚠️ 这是**唯一**的内容清单：判定「这份诊断包该有什么」走 [diagnosticHasEntry]，
/// 预览 / 测试都不许另写一份。
const List<String> kDiagnosticEntries = ['songs.json', 'prefs.json'];

/// 诊断包里的曲库索引条目名（与 `backup_service` 的 `_songsJsonName` 同一个名字）。
const String kDiagnosticSongsName = 'songs.json';

/// 诊断包里的设置条目名（与备份包的标记文件同一个名字）。
const String kDiagnosticPrefsName = 'prefs.json';

/// 诊断包 → `subdir` 下要写的文件名，用备份 zip 内的**毫秒时间戳**。
///
/// ⚠️ [stamp] 必须取自备份包内那个时间戳（`createBackup` 的入参），
/// **不许在这里另取一次 `DateTime.now()`** —— 两次取时钟会跨毫秒，
/// 于是 zip 里的 `info.txt` 写的时间与实际文件名对不上（实测差 1ms）。
String diagnosticZipName(int stamp) => '$kDiagnosticPrefix$stamp.zip';

/// 诊断包（曲库索引 + 设置 + 说明）里那个 `zip/<名>` 是不是该有的条目。
///
/// 纯函数，给「清单不完整」这类退化当闸门：该有的条目 = `kDiagnosticEntries`
/// 加上那份说明文件。清单里少一份 ⇒ 这里当场 false。
bool diagnosticHasEntry(String name) =>
    kDiagnosticEntries.contains(name) || name == kDiagnosticInfoName;

/// `info.txt` 的内容（纯函数，同样的输入 ⇒ 逐字节同样的输出）。
///
/// ⚠️ **只写真的量得到的东西**，量不到的（设备型号 / ROM 版本 / 崩溃栈）
/// 一律不写 —— 编出来的诊断信息比没有更坏。四个字段正好对上 UI 上那句说明。
String buildDiagnosticInfo({
  required String appVersion,
  required String buildNumber,
  required DateTime exportedAt,
  required int songCount,
  required int musicFileCount,
}) {
  final buf = StringBuffer()
    ..writeln('Mu Box 手机版 · 诊断包（用户自排查用）')
    ..writeln('App 版本：$appVersion+$buildNumber')
    ..writeln('导出时间：${_fmtLocal(exportedAt)}')
    // 「曲库条数」= 索引里的**全部**歌（含私密歌）—— 诊断要能看出「库里到底几条」，
    // 少报会让用户以为歌丢了。所以这里刻意不用过滤私密后的列表。
    ..writeln('曲库条数：$songCount')
    ..writeln('内部副本目录文件数：$musicFileCount')
    ..writeln('')
    ..writeln('提示：这份 zip 里有完整的设置与曲库索引，可能含私密歌信息（歌名等），')
    ..writeln('      只给自己看，别发给别人。要发给别人请用「备份（导出 zip）」。');
  return buf.toString();
}

/// 本地时间的人读格式 `YYYY-MM-DD HH:MM:SS`（不带时区后缀，用户看的就是本机时间）。
String _fmtLocal(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
}

/// 从 `Platform.resolvedExecutable` 里取「版本名 + 版本号」（Android 上是
/// `…/base.apk!/assets/flutter_assets/kernel_blob.bin` 这种串）。
///
/// 为什么要这么绕：本项目**没有** `package_info_plus` 依赖，而 Android 侧唯一
/// 能读到 `versionName`/`versionCode` 的地方就是这个 APK 路径 ——
/// 装出来的那份形状是
/// `…/com.mubox.mu_box_phone-<base64 签名摘要>/base.apk!/assets/…`。
///
/// ⚠️ **数字取不出来时如实返回 `('未知', '未知')`，⛔ 不编一个**：本机跑单测的
/// 宿主是 `flutter_tester`（路径里根本没有 `base.apk`），解不出来是**常态**，
/// 不是错误。诊断包宁可少一项，也不能写一个假的版本号。
///
/// ⚠️ 实测：`flutter build apk --release` 产出的是 `app-release.apk`
/// （路径里**不带** `+build`）⇒ 非 base64 的目录名一律回「未知」。
/// 这条只是保险，不改变上面那条事实。
({String version, String build}) parseAppVersion(String execPath) {
  // APK 归一到 `/`，Windows / POSIX 两条都认
  final norm = execPath.replaceAll('\\', '/');
  final i = norm.indexOf('/base.apk!/');
  if (i <= 0) return (version: '未知', build: '未知');
  final dir = norm.substring(0, i).split('/').last; // com.mubox.mu_box_phone-<摘要>
  final dash = dir.lastIndexOf('-');
  if (dash < 0) return (version: '未知', build: '未知');
  final digest = dir.substring(dash + 1);
  if (digest.isEmpty ||
      digest.length % 4 != 0 ||
      !RegExp(r'^[A-Za-z0-9+/]+={0,2}$').hasMatch(digest)) {
    return (version: '未知', build: '未知');
  }
  final dec = _b64(digest);
  if (dec.length < 4) return (version: '未知', build: '未知');
  return (version: '${dec[2]}.${dec[3]}', build: '${dec[4]}');
}

/// 标准 base64 解码（`dart:convert` 自带，这里只是给上面那个函数一个短名字）。
List<int> _b64(String s) => base64.decode(s);

/// 公共目录里的**人类可读路径**，给 SnackBar 用（原生不回路径，只能这边拼）。
///
/// 例：`内部存储/Documents/MuBox/mubox_backup_1759800000000.zip`
String documentsDisplayPath(String subdir, String name) {
  final cleanSub = subdir.replaceAll(RegExp(r'[/\\]+$'), '');
  if (cleanSub.isEmpty) return '内部存储/Documents/$name';
  return '内部存储/Documents/$cleanSub/$name';
}

/// `saveToDocuments` 的两种**正确**结果。
enum SaveStatus {
  /// 真的写进去了（新建，或内容不一致时原地覆写）。
  exported,

  /// 公共目录里已有一份**逐字节相同**的，原生没重写。
  ///
  /// ⚠️ 这是**正确**结果，不是失败：上次导出的那份还在、内容一模一样。
  /// 文案写成「失败」就是骗人（`saveResultText` 负责把两种说法分开）。
  unchanged,
}

/// 一次「保存到公共目录」的结果。
class SaveOutcome {
  const SaveOutcome({
    required this.status,
    required this.uri,
    required this.displayPath,
    required this.name,
  });

  final SaveStatus status;

  /// 公共目录里那份的 uri（`content://…`）。
  final String uri;

  /// 给人看的落地路径（`内部存储/Documents/MuBox/<name>`）。
  final String displayPath;

  /// 文件名。
  final String name;

  /// 这次真的写了文件吗（`false` = 内容已是最新，一个字节都没动）。
  bool get written => status == SaveStatus.exported;
}

/// 保存成功后 SnackBar 里那句话 —— **必须带人能看懂的路径**，且
/// `unchanged` 不许写成失败（`test/diagnostic_pack_test.dart` 钉着）。
String saveResultText(SaveOutcome r) => r.written
    ? '已保存到 ${r.displayPath}'
    : '已是最新（内容与上次相同）：${r.displayPath}';


// ═══════════════════════════════════════════════════════════════════════════
// 二、取消：一个「点了真的停」的标志位，配套一条专用异常
// ═══════════════════════════════════════════════════════════════════════════

/// 「中止」异常：只有发起那次任务自己的 `catch` 认它，用完就吞（⛔ 不许让它冒到 UI）。
///
/// 为什么用异常而不是全靠返回值：备份打包 / 单曲导出这些**单个 await 很长**的
/// 循环里，只有抛出去才能在「正在 await 的那一刻」就停下来；纯标志位要等
/// 这一次 await 自己结束 —— 一个 250MB 的 zip 条目就是好几秒。
///
/// ⚠️ 只 `implements Exception`，**不 extends 任何库里的异常**：
/// `dart:async` 的 `TimeoutException` 是 `implements Exception` 的**类**、
/// 没法拿来当父类继承（`dart:isolate` 里那个只是它的再导出）；
/// 而本文件刻意不 import `dart:async` —— 一个异常类不值得把整个 async 库拉进来。
class CancellationException implements Exception {
  const CancellationException([this.message = '已取消']);

  final String message;

  @override
  String toString() => 'CancellationException: $message';
}

/// 取消标志位。**一个任务一个 token**，点了「取消」写进去，循环自己看。
///
/// 语义：
/// * [begin] 开一轮新任务 —— 令牌换新（**旧 token 就此永久失效**，见 [generation]）；
/// * [cancel] 叫停当前这一轮；
/// * [isCancelled] 循环每步读它（读的是**这一轮**那个号码的状态）。
///
/// ⚠️ **为什么令牌里要带号码**：光一个 bool 的话，「上一轮点了取消、下一轮又
/// 开始」时 bool 还是 true —— 新任务第一步就自杀。带号码之后每轮各看各的，
/// 这条只能靠单测钉住（症状：「第一次点取消之后就再也跑不动」）。
class CancelToken {
  int _generation = 0;
  int _cancelledAt = -1;

  /// 当前轮次号码（第一次 [begin] 之前是 0）。
  int get generation => _generation;

  /// 这一轮的取消令牌：传给异步子任务，让它们看的是**同一个号码**。
  ///
  /// ⚠️ 长循环里必须先把 `final t = cancel.token;` 取出来再进循环体：
  /// 每步读 `cancel.token` 的话，中途有人 [begin] 开新轮就会读到新令牌，
  /// 那一轮就再也停不下来了。
  CancelTokenHandle get token => CancelTokenHandle(this, _generation);

  /// 开一轮新任务：令牌换新（上一轮的取消状态不影响这一轮）。
  void begin() => _generation++;

  /// 叫停**当前这一轮**。同轮重复调用无副作用。
  void cancel() => _cancelledAt = _generation;

  /// 当前这一轮被叫停了吗。
  bool get isCancelled => _cancelledAt == _generation;

  /// 当前这一轮被叫停就抛 [CancellationException]（长循环里当断言用）。
  void throwIfCancelled() {
    if (isCancelled) throw const CancellationException();
  }
}

/// [CancelToken] 的**某一轮**的句柄（见 `CancelToken.token` 的理由）。
class CancelTokenHandle {
  const CancelTokenHandle(this._owner, this.generation);

  final CancelToken _owner;

  /// 句柄对应的轮次号码。
  final int generation;

  /// 这一轮被叫停了吗。
  bool get isCancelled => _owner._cancelledAt == generation;

  /// 这一轮被叫停就抛 [CancellationException]。
  void throwIfCancelled() {
    if (isCancelled) throw const CancellationException();
  }
}

// ═══════════════════════════════════════════════════════════════════════════
// 三、临时目录里「上一个备份 zip」的清理（不清理会攒到 250MB）
// ═══════════════════════════════════════════════════════════════════════════

/// 备份 zip 的文件名前缀（`mubox_backup_<毫秒时间戳>.zip`）。
const String kBackupTempPrefix = 'mubox_backup_';

/// 备份用的临时 prefs 文件名（**不是**要清理的 zip，清理时要放过它）。
const String kBackupPrefsTempName = 'mubox_prefs.json';

/// 从 [names] 里挑出**该删的旧备份 zip**（纯函数，只挑名字，不碰磁盘）。
///
/// ⚠️ **这是"只删自己建的"这条铁律的落点**：只删自己这个前缀、**且时间戳解析得出来**
/// 的 `.zip`，**一次一个精确路径**，绝不按通配删临时目录里别的东西。三道条件：
/// 前缀 = [kBackupTempPrefix]、后缀 = `.zip`、中间那截是**纯数字**（本函数自己
/// 拼得出来的名字）。少任何一道，就可能把 `mubox_prefs.json`、别的任务的临时文件、
/// 或者一个**看着像但其实不是我们建的**名字算进来 —— 认不出来的一律**不动**。
///
/// 规则：
/// * [keep]（= 本次刚建出来的那份）**永远不删**，哪怕它也在 [names] 里；
/// * 其余按名字里嵌的毫秒时间戳**从新到旧**排，只删最前面的 [keepLatest] 个之外的部分
///   （所以 `keepLatest: 0` ⇒ 上一份也删；`keepLatest: 1` ⇒ 留着上一份）。
///
/// ⚠️ 调用点（`backup_service._cleanupOldTempZips`）给的是 **0**：分享面板此刻拿的是
/// **本次这份**（用户刚点的备份），上一份没有任何人在用 —— 留着就是僵尸。
/// ⚠️ **别把「上一份」当成 `keepLatest: 1` 的目的**：那个位置指的是
/// 「比 keep 更新的那几份」，而不是「keep 自己的上一代」。
List<String> planTempZipCleanup(
  Iterable<String> names, {
  required String keep,
  int keepLatest = 0,
}) {
  final re = RegExp('^$kBackupTempPrefix(\\d+)\\.zip\$');
  final olds = <({String name, String stamp})>[
    for (final n in names)
      if (n != keep && re.hasMatch(n))
        (name: n, stamp: n.substring(kBackupTempPrefix.length, n.length - 4)),
  ]..sort((a, b) {
    final x = a.stamp.padLeft(20, '0');
    final y = b.stamp.padLeft(20, '0');
    final byStamp = y.compareTo(x); // 新的在前
    return byStamp != 0 ? byStamp : b.name.compareTo(a.name);
  });
  if (olds.length <= keepLatest) return const [];
  return [for (final e in olds.sublist(keepLatest)) e.name];
}

// ═══════════════════════════════════════════════════════════════════════════
// 四、可取消的导入循环（扫描 → 复制进内部副本）
// ═══════════════════════════════════════════════════════════════════════════

/// 复制一首歌的实际动作：给定目标文件名，返回**建好的那一条**，失败返回 null。
///
/// 泛型 `T` 是调用方自己的记录类型（`library_data` 传的是 `Song`）。
/// 真正的 IO 与「怎么建记录」都在调用方 —— 本文件只负责「循环 + 取消」，
/// 零依赖（不许 import `models.dart`）。
typedef ImportCopy<T> = Future<T?> Function(
  ImportPlanItem item,
  String targetName,
);

/// 导入循环的一条输入。
///
/// * [src] 源文件绝对路径（撞名判定的键、黑名单比的就是它）；
/// * [base] 源文件 basename（黑名单的老记录按它比）；
/// * [targetName] `planInternalNames` 规划出来的内部副本名（纯函数，别在这儿另算）；
/// * [extra] 调用方想随条带过去的任何东西（`library_data` 用不到，留作扩展位）。
class ImportPlanItem {
  const ImportPlanItem({
    required this.src,
    required this.base,
    required this.targetName,
    this.extra,
  });

  final String src;
  final String base;
  final String targetName;
  final Object? extra;
}

/// 导入循环的结果。
///
/// ⚠️ **[completed] 与 [imported].length 是两笔账，必须分别如实报**：
/// 前者 = 「真的走完了整个列表」，后者 = 「真的复制成功的」。取消时
/// `completed=false` 而 `imported` 里已经有若干首 —— 已入库的歌照旧留着
/// （那是完整文件，不是半成品），界面按 `imported.length/total` 报「已取消：完成 X/Y」。
class ImportLoopResult<T> {
  const ImportLoopResult({
    required this.imported,
    required this.completed,
    required this.total,
  });

  /// 成功复制进内部的（按原顺序）。
  final List<T> imported;

  /// 整个列表走完了吗（false = 被叫停过）。
  final bool completed;

  /// 这一轮一共打算处理几首。
  final int total;

  /// 已处理的条数（= 真的复制成功的条数）。
  int get done => imported.length;
}

/// 把 [items] 逐条复制进内部目录，**每一步之间看一次取消标志**。
///
/// 取消语义：**在每首歌之间检查标志位就退出，不许留下半写状态**。
/// 两条保证：
/// 1. 取消检查在**循环体最开头** ⇒ 被叫停时那一首**一个字节都还没复制**，
///    不存在「复制到一半的 mp3」；已经复制完的整首留在盘上（下次扫描会用
///    `_importIfNeeded` 的「同名同大小直接用」认回来，**已入库的照旧保留**）；
/// 2. 取消**不抛异常**，靠 [ImportLoopResult.completed] 报出去 —— 调用方要据此
///    **跳过落盘**（别把只导入了一半的列表写进 songs.json）。
///
/// ⚠️ 循环用下标推进（不是 `for (final x in items)`）：`copy` 返回 null 的条目
/// 不占名额，否则一条复制失败的歌会把后面全部跳掉。
Future<ImportLoopResult<T>> runImportLoop<T>(
  Iterable<ImportPlanItem> items, {
  required ImportCopy<T> copy,
  CancelTokenHandle? cancel,
  void Function(int done, int total)? onProgress,
}) async {
  final list = items.toList();
  final imported = <T>[];
  var index = 0;
  while (index < list.length) {
    if (cancel != null && cancel.isCancelled) break;
    final item = list[index];
    index++;
    final made = await copy(item, item.targetName);
    if (made != null) imported.add(made);
    onProgress?.call(index, list.length);
  }
  return ImportLoopResult<T>(
    imported: imported,
    completed: index >= list.length && !(cancel?.isCancelled ?? false),
    total: list.length,
  );
}

// ═══════════════════════════════════════════════════════════════════════════
// 五、诊断包的内容清单 / 落盘计划
// ═══════════════════════════════════════════════════════════════════════════

/// 诊断包里一条要写的文件：[name] = zip 内条目名，[content] = 这份文件的内容。
///
/// ⚠️ 这是个**清单**，不是「能写多少算多少」的集合：少了任何一条都该被
/// [diagnosticMissing] 判出来（诊断包缺文件 = 用户以为拿到了全部信息）。
class DiagnosticFile {
  const DiagnosticFile(this.name, this.content);

  final String name;
  final String content;
}

/// 拼出诊断包的完整内容清单（纯函数，不碰 IO）。
///
/// [songsJson] / [prefsJson] 都必须是调用方**已经算好**的文本
/// （曲库索引要过私密过滤、prefs 要过 `sanitizeBackupPrefs`）——
/// 本文件零依赖，拿不到 `Store` / `Library`，也不该拿。
List<DiagnosticFile> buildDiagnosticFiles({
  required String songsJson,
  required String prefsJson,
  required String infoText,
}) => [
  DiagnosticFile(kDiagnosticSongsName, songsJson),
  DiagnosticFile(kDiagnosticPrefsName, prefsJson),
  DiagnosticFile(kDiagnosticInfoName, infoText),
];

/// [files] 里少了哪些「该有的条目」（按 [kDiagnosticEntries] 判 + 说明文件）。
///
/// 返回空列表 = 齐全。**排序过**，所以判定与报错都稳定。
List<String> diagnosticMissing(
  Iterable<String> files, {
  bool requireInfo = true,
}) {
  final have = files.toSet();
  final want = <String>[
    ...kDiagnosticEntries,
    if (requireInfo) kDiagnosticInfoName,
  ];
  final missing = [for (final n in want) if (!have.contains(n)) n]..sort();
  return missing;
}

/// 写 prefs.json 用的文本：**原样** `jsonEncode`，⛔ 不做私密过滤。
///
/// ⚠️ 与备份那条线**故意不同**，不是漏了：诊断包是给用户自己排查的，
/// 要的就是「设置里到底存了什么」；过滤掉就查不出问题了。
/// 代价是包里可能含私密歌信息 ⇒ UI 必须写明「只给自己看」（见 `info.txt`）。
String encodeDiagnosticPrefs(Map<String, Object?> prefs) => jsonEncode(prefs);
