/// 导出文案与计数的断言。
///
/// ## 现场（真机实测，未修复版）
/// App 报「已导出 40/40 首到 Music/MuBox」，而公共目录里 41 个文件**只有 1 个是新写的**、
/// 39 个沿用旧文件（40 = 曲库 41 首 − 1 首私密歌）。
/// 根因：原生会先比对 size+sha256，内容一致就原地不动；Dart 这侧却把
/// 「成功」一律算成「已导出」⇒ 文案「N/N」与事实对不上。
///
/// ## 这里钉什么
/// * 三笔账（真写入 / 已是最新 / 失败）的计数与文案逐字对上；
/// * ⛔ 「已导出 N/N」这种形状**不许**再出现（拿 1 写 + 39 已是最新 直接证伪）；
/// * 接线：`settings_page` 必须把 `ExportResult.written` 喂进计数、并用纯函数拼文案
///   （这一段在真机 UI 线程上，离线跑不到 ⇒ 照本仓 `privacy_outbound_test.dart` /
///   `settings_page_battery_test.dart` 的老办法：**读源码当护栏**，
///   把「区分 unchanged」那一段 revert 回去这条当场红）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/export_plan.dart';

void main() {
  group('ExportTally：三笔账要加得起来', () {
    test('★1 3 首真写入 + 2 首已是最新 + 1 首失败 ⇒ 计数与文案逐字对上', () {
      final t = ExportTally()..begin(6);
      // 3 首真的写了、2 首内容已是最新（原生没重写）、1 首失败
      t.addResult(written: true);
      t.addResult(written: false);
      t.addResult(written: true);
      t.addResult(written: false);
      t.addResult(written: true);
      t.addFailure(StateError('导出失败：x.mp3\n第二行不该出现'));

      expect(t.total, 6);
      expect(t.written, 3);
      expect(t.upToDate, 2);
      expect(t.failed, 1);
      expect(t.done, 6, reason: '三笔账加起来必须等于总数');
      expect(
        exportSummary(t),
        '已导出 3/6 首到 Music/MuBox，2 首已是最新，失败 1 首（Bad state: 导出失败：x.mp3）',
      );
    });

    test('★2 负向有牙：1 写 + 39 已是最新 ⇒ 不许再出现「40/40」那种文案', () {
      final t = ExportTally()..begin(40);
      t.addResult(written: true);
      for (var i = 0; i < 39; i++) {
        t.addResult(written: false);
      }
      final msg = exportSummary(t);
      // ignore: avoid_print
      print('EXPORT: $msg');
      expect(msg, '已导出 1/40 首到 Music/MuBox，39 首已是最新，失败 0 首');
      expect(msg.contains('40/40'), isFalse,
          reason: '★ 这正是真机看到的那句假话（实际只写了 1 个）');
    });

    test('全部失败：一个「已导出」都不许报', () {
      final t = ExportTally()..begin(3);
      t.addFailure(Exception('拿不到音频焦点'));
      t.addFailure(Exception('第二条'));
      t.addFailure(Exception('第三条'));
      expect(t.written, 0);
      expect(exportSummary(t),
          '已导出 0/3 首到 Music/MuBox，0 首已是最新，失败 3 首（Exception: 拿不到音频焦点）');
      expect(t.firstError, 'Exception: 拿不到音频焦点', reason: '只留第一条原因');
    });

    test('begin 清零（上一轮的账不许漏进这一轮）', () {
      final t = ExportTally()..begin(2);
      t.addResult(written: true);
      t.addFailure(Exception('x'));
      t.begin(5);
      expect([t.total, t.written, t.upToDate, t.failed, t.done], [5, 0, 0, 0, 0]);
      expect(t.firstError, isNull);
    });

    test('零首（理论上进不来）：文案仍要能加得起来，不许吹成功', () {
      final t = ExportTally()..begin(0);
      expect(exportSummary(t), '已导出 0/0 首到 Music/MuBox，0 首已是最新，失败 0 首');
    });
  });

  group('接线（读源码）：文案必须由 ExportResult 的三态驱动', () {
    final src = File('lib/pages/settings_page.dart').readAsStringSync();

    test('把 `written` 喂进计数（revert 成一律成功 ⇒ 这条红）', () {
      expect(
        src.contains('_exportTally.addResult(written: r.written)'),
        isTrue,
        reason: '★ 导出循环必须按 `ExportResult.written` 分成「真写入 / 已是最新」两笔；'
            '一律算成功就回到「40/40 其实只写了 1 个」',
      );
      expect(src.contains('_exportTally.addFailure('), isTrue,
          reason: '失败要另记一笔（原先只在末尾拼一句 why）');
    });

    test('末尾提示由纯函数拼（不在页面里手写数字）', () {
      expect(src.contains('exportSummary(_exportTally)'), isTrue);
      expect(RegExp(r'已导出 \$_exported/').hasMatch(src), isFalse,
          reason: '★ 页面里不许再手写「已导出 N/N」——那正是对不上账的那句');
    });

    test('返回值类型变了：调用点必须接 ExportResult（不是 bool）', () {
      expect(src.contains('ExportService.exportSong('), isTrue);
      expect(
        RegExp(r'final r = await ExportService\.exportSong\(s\);').hasMatch(src),
        isTrue,
      );
    });
  });
}
