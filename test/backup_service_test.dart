/// `lib/backup_service.dart` 的**端到端**回归：真跑一遍备份打包 / 恢复回滚。
///
/// 光测 `backup_plan.dart` 的纯函数只能证明「清单里有 sub_lyrics」，
/// 证明不了「它真的进了 zip」。所以这里把 path_provider 的通道挡住，
/// 把 App 文档目录指到一个真临时目录，然后：
///   - H4：造一份 `docs/sub_lyrics/*.sub.json`，跑 createBackup()，翻 zip 条目
///   - H7：造一份「恢复中途被杀」的现场（pending 快照 + 设置已清空），
///         跑 recoverInterruptedRestore()，看设置有没有回来
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/backup_plan.dart';
import 'package:mu_box_phone/backup_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

late Directory _docs;
late Directory _tmp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_docs_');
    _tmp = Directory.systemTemp.createTempSync('mubox_tmp_');
    // 把 path_provider 的 MethodChannel 挡掉，指到真临时目录
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => _docs.path,
        'getTemporaryDirectory' => _tmp.path,
        _ => null,
      };
    });
    SharedPreferences.setMockInitialValues({});
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    // 同一个「删临时目录」的纪律：带重试，删不掉就抛（别退回 catch (_) {}，
    // 那是每跑一轮往 %TEMP% 里攒垃圾的来源 —— 见 support/temp_docs.dart）。
    await deleteTempDir(_docs);
    await deleteTempDir(_tmp);
  });

  group('H4：译文目录真的进了备份 zip', () {
    test('createBackup() 打出的包里能见到 sub_lyrics/*.sub.json', () async {
      // 造用户数据：一份译文 + 一份导入的歌词（对照组）
      Directory('${_docs.path}/sub_lyrics').createSync(recursive: true);
      File('${_docs.path}/sub_lyrics/歌.sub.json')
          .writeAsStringSync(jsonEncode(['line1', '', 'line3']));
      Directory('${_docs.path}/imported_lyrics').createSync(recursive: true);
      File('${_docs.path}/imported_lyrics/歌.lrc')
          .writeAsStringSync('[00:01.00]hello');

      final zipPath = await BackupService.createBackup();
      final archive =
          ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync());
      final names = archive.files.map((f) => f.name).toList();

      expect(names, contains('sub_lyrics/歌.sub.json'),
          reason: 'H4：译文不在备份里 = 换机必丢');
      expect(names, contains('imported_lyrics/歌.lrc'));
      expect(names, contains(kBackupMarker));
    });

    test('备份里带上了清单里的每一个目录（清单 = kBackupDirs）', () async {
      for (final d in kBackupDirs) {
        Directory('${_docs.path}/$d').createSync(recursive: true);
        File('${_docs.path}/$d/probe.bin').writeAsStringSync('x');
      }
      final zipPath = await BackupService.createBackup();
      final names =
          ZipDecoder().decodeBytes(File(zipPath).readAsBytesSync())
              .files
              .map((f) => f.name)
              .toSet();
      for (final d in kBackupDirs) {
        expect(names, contains('$d/probe.bin'), reason: '$d 没被打进包');
      }
    });
  });

  group('H7：恢复中途被杀 → 启动时自己回滚', () {
    /// 造现场：旧设置有值 → 写了 pending 快照 → 设置被 clear（模拟恢复被中断）
    Future<File> stagedInterruptedRestore() async {
      final old = <String, Object>{
        'playlists': '{"最爱":[1,2]}',
        'title_overrides': '{}',
        'private_songs': '["/docs/music/secret.mp3"]',
        'speed': 1.25,
        'mode': 'shuffle',
        'some_flags': ['a', 'b'],
      };
      final sp = await SharedPreferences.getInstance();
      await sp.clear();
      for (final e in old.entries) {
        final v = e.value;
        if (v is String) await sp.setString(e.key, v);
        if (v is double) await sp.setDouble(e.key, v);
      }
      final f = File('${_docs.path}/$kRestoreRollbackFile');
      await f.writeAsString(
        buildRollbackSnapshot(old, state: kRestoreStatePending),
        flush: true,
      );
      // 模拟「clear 完了、还没写回就被杀」
      await sp.clear();
      return f;
    }

    test('pending 快照 → 旧设置被写回来，快照被删', () async {
      final f = await stagedInterruptedRestore();
      final rolledBack = await BackupService.recoverInterruptedRestore();
      expect(rolledBack, isTrue);

      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('playlists'), '{"最爱":[1,2]}');
      expect(sp.getString('private_songs'), '["/docs/music/secret.mp3"]',
          reason: '私密名单丢了 = 私密歌全部变回公开');
      expect(sp.getDouble('speed'), 1.25);
      expect(sp.getString('mode'), 'shuffle');
      expect(sp.getStringList('some_flags'), ['a', 'b'],
          reason: 'List 值必须能写回（JSON 解出来是 List<dynamic>，不收窄会抛）');
      expect(f.existsSync(), isFalse, reason: '回滚完要清掉现场，否则每次启动都回滚');
    });

    test('committed 快照 → 只删文件，绝不回滚刚恢复好的设置', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('mode', '新恢复进来的值');
      final f = File('${_docs.path}/$kRestoreRollbackFile');
      await f.writeAsString(
        buildRollbackSnapshot({'mode': '旧值'}, state: kRestoreStateCommitted),
      );

      expect(await BackupService.recoverInterruptedRestore(), isFalse);
      expect(sp.getString('mode'), '新恢复进来的值');
      expect(f.existsSync(), isFalse);
    });

    test('没有快照 → 什么都不做（正常启动的那条路）', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('mode', 'list');
      expect(await BackupService.recoverInterruptedRestore(), isFalse);
      expect(sp.getString('mode'), 'list');
    });

    test('快照坏了 → 不动设置，也不删现场（留给人看）', () async {
      final sp = await SharedPreferences.getInstance();
      await sp.setString('mode', 'list');
      final f = File('${_docs.path}/$kRestoreRollbackFile');
      await f.writeAsString('这不是 json');

      expect(await BackupService.recoverInterruptedRestore(), isFalse);
      expect(sp.getString('mode'), 'list');
      expect(f.existsSync(), isTrue);
    });
  });
}
