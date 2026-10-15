/// 临时文档目录的**收尾纪律** —— 给「用例用 `Directory.systemTemp` 造一个假文档目录、
/// 跑完删掉」这一族测试共用。
///
/// ⚠️ 为什么不能是 `try { dir.deleteSync(recursive: true); } catch (_) {}`：
/// 本仓的落盘是 **fire-and-forget 串行链**（`PlayerService._saveSessionQuietly` →
/// `_persist = _persist.then(_persistNow)` → `Store.saveLastSession` →
/// `Store._writeJsonAtomic`：先写 `queue.json.<n>.tmp` 再 rename）。用例体跑完那一刻，
/// 这一串**很可能还在飞**，`queue.json*` 的句柄还开着 —— Windows 上就是这两种错：
///
/// - `PathAccessException: Deletion failed, path = '...' (OS Error: 另一个程序正在使用此文件，
///   进程无法访问。, errno = 32)` —— 边写边删，共享冲突；
/// - `FileSystemException: Deletion failed, path = '...' (OS Error: 目录不是空的。, errno = 145)`
///   —— 递归删已经把目录内容列完了，那个迟到的 `queue.json` 才落进去。
///
/// 两种都被 `catch (_) {}` 咽掉 ⇒ **目录 + queue.json 永远留在 `%TEMP%`**（实测每跑
/// 一轮全量攒 5 个 `mubox_svc_*` / `mubox_xfade_*`，攒了好几轮没人发现）。
///
/// 所以收尾是两步，顺序不能反：
/// 1. **先在 mock 还挂着的时候把还在飞的落盘排空**（用例自己 `await debugFlushPersist()`）
///    —— 这一步才是根因修复：句柄放掉了，删除才有得谈；
/// 2. 再调本文件的 [deleteTempDir] 删，它带**有界小退避重试**兜住没挂在服务链上、
///    晚一步才落的写；重试用完还在就**抛** —— 那时是真的有东西攥着句柄，
///    再咽一次就等于把这个坑重新埋回去（这次就是咽出来的）。
library;

import 'dart:io';

/// 重试的退避节奏（毫秒）。首项 0 = 先原地删一次（常态下一次就过）。
///
/// 合计约 1.67 秒：一次 `writeAsString(flush: true)` + `rename` 是毫秒级的，
/// 这个窗口宽到不可能靠运气 —— **重试不是碰运气，是等那一趟写把句柄放掉**。
const List<int> _kBackoffMs = <int>[0, 10, 20, 40, 80, 120, 200, 300, 400, 500];

/// 删掉用例的临时目录；**目录本来就不存在也算成功**（用例自己删过 / 上一轮重试删掉了）。
///
/// 重试用完还删不掉就抛 [StateError]（附最后一次的真实异常）——
/// 泄漏必须是**红灯**，不许再退回 `catch (_) {}`。
Future<void> deleteTempDir(Directory dir) async {
  Object? last;
  for (final ms in _kBackoffMs) {
    if (ms > 0) await Future<void>.delayed(Duration(milliseconds: ms));
    if (!dir.existsSync()) return;
    try {
      dir.deleteSync(recursive: true);
    } catch (e) {
      last = e;
    }
    if (!dir.existsSync()) return;
  }
  throw StateError(
    '临时目录收尾失败：${dir.path}\n'
    '最后一次异常：${last ?? '（删除没抛，但目录仍然存在：有东西在删完之后又落了文件）'}\n'
    '→ 落盘句柄没放掉，或者有迟到的写。别把调用点改回 `catch (_) {}`：'
    '那正是每跑一轮就在 %TEMP% 里攒垃圾的原因。',
  );
}
