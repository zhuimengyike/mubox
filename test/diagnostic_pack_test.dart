/// `lib/diagnostic_pack.dart` 的断言：诊断包清单 / 命名单 / 内容判定 / 落盘 /
/// 旧临时 zip 清理 / 可取消循环。
///
/// ## 这里测什么（真跑 IO，不是只读常量）
///
/// 1. **诊断包**：`songs.json` + `prefs.json` + `info.txt` 三份都在，
///    且 `info.txt` 里写的是**真的量到的**四个字段；
/// 2. **旧临时 zip 清理**：真在临时目录里摆现场（一个旧备份 + 一个非本前缀的文件 +
///    一个同前缀但非 zip 的文件），跑 `BackupService.createBackup()`，核对
///    「旧备份被删、别人的文件一个没动、本次那份还在」；
/// 3. **取消**：`runImportLoop` 置位后**在 N 步内退出**，且返回的计数与
///    真的处理过的条数一致；配套两条负向（不看标志 ⇒ 红、`begin()` 之后
///    旧取消不许复发）。
///
/// ## 每条正向断言的负向对照（把修复收起来就红）
/// 收起来的方式写在每条用例的 doc 里，**实测过红**。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/backup_service.dart';
import 'package:mu_box_phone/diagnostic_pack.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// 导出 / 保存到公共目录走的那条通道（`export_service` 与 `backup_service` 共用）。
const MethodChannel _exportChannel =
    MethodChannel('com.mubox.mu_box_phone/export');

late Directory _docs;
late Directory _tmp;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_diag_docs_');
    _tmp = Directory.systemTemp.createTempSync('mubox_diag_tmp_');
    // path_provider 的通道挡掉，指到真临时目录（与 backup_service_test 同一套）
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
    await deleteTempDir(_docs);
    await deleteTempDir(_tmp);
  });

  // ═════════════════════════════════════════════════════════════════════════
  // 一、诊断包：清单 / 命名 / 内容判定
  // ═════════════════════════════════════════════════════════════════════════
  group('★1 诊断包：清单 / 命名 / 内容', () {
    test('命名单：diagnostic_<时间戳>.zip，落在 MuBox 子目录下', () {
      expect(diagnosticZipName(1759800000000), 'diagnostic_1759800000000.zip');
      expect(kDiagnosticEntries, ['songs.json', 'prefs.json']);
      expect(
        documentsDisplayPath(kDocumentsSubdir, diagnosticZipName(1)),
        '内部存储/Documents/MuBox/diagnostic_1.zip',
      );
    });

    // ⚠️ 负向对照：把 `diagnosticZipName` 改成不带时间戳（两份诊断包撞名 ⇒
    //    后一份把前一份覆盖掉，用户以为拿到的还是旧的）⇒ 这条红。
    test('每份诊断包的 zip 名都带自己的时间戳，不会撞名', () {
      expect(diagnosticZipName(1759800000000), 'diagnostic_1759800000000.zip');
      expect(diagnosticZipName(1) == diagnosticZipName(2), isFalse);
      // ⛔ 临时文件只删**自己这一个精确路径**（项目铁律）：接线处用的是
      //    「同一个 stamp → 同一个名字」（见 `settings_page._exportDiagnostic`），
      //    所以时间戳必须能从名字里原样读回来 —— 这条钉住这个约定。
      final name = diagnosticZipName(1759800000000);
      expect(name.substring(kDiagnosticPrefix.length, name.length - 4),
          '1759800000000');
    });

    test('清单齐全时 diagnosticMissing 为空，少一份就点名', () {
      expect(diagnosticMissing(const ['songs.json', 'prefs.json', 'info.txt']),
          isEmpty);
      expect(diagnosticMissing(const ['songs.json', 'prefs.json']), ['info.txt'],
          reason: 'info.txt 是给人看的那份，不许跟 songs/prefs 一起漏');
    });

    // ⚠️ 负向对照：把 `kDiagnosticEntries` 里的 'songs.json' 去掉 ⇒ 上面这条
    //    与这条同时红（清单少一份 = 诊断包缺文件，用户以为拿到了全部信息）。
    test('清单里少一份 ⇒ hasEntry 当场 false（判定只有一处）', () {
      for (final n in kDiagnosticEntries) {
        expect(diagnosticHasEntry(n), isTrue, reason: '$n 该在清单里');
      }
      expect(diagnosticHasEntry(kDiagnosticInfoName), isTrue);
      expect(diagnosticHasEntry('wallpapers/1.png'), isFalse,
          reason: '诊断包不带壁纸/音频，只带索引 + 设置 + 说明');
    });

    test('info.txt：四个字段都是真量到的值，且写明「只给自己看」', () {
      final info = buildDiagnosticInfo(
        appVersion: '1.6.6',
        buildNumber: '19',
        exportedAt: DateTime(2026, 10, 6, 9, 8, 7),
        songCount: 56,
        musicFileCount: 61,
      );
      expect(info, contains('1.6.6+19'));
      expect(info, contains('2026-10-06 09:08:07'));
      expect(info, contains('曲库条数：56'));
      expect(info, contains('内部副本目录文件数：61'));
      expect(info, contains('只给自己看'));
      // ⛔ 量不到的别编：设备型号 / ROM 版本一律不写
      expect(info, isNot(contains('机型')));
      expect(info, isNot(contains('ROM')));
    });

    // ⚠️ 负向对照：把 `musicFileCount` 那一行从 `buildDiagnosticInfo` 去掉 ⇒ 红。
    test('info.txt 少了任何一项都算缺（逐项点名）', () {
      final info = buildDiagnosticInfo(
        appVersion: 'v',
        buildNumber: 'b',
        exportedAt: DateTime(2026),
        songCount: 3,
        musicFileCount: 4,
      );
      for (final needle in const ['App 版本', '导出时间', '曲库条数', '内部副本目录文件数']) {
        expect(info, contains(needle), reason: 'info.txt 缺「$needle」');
      }
    });
  });

  // ═════════════════════════════════════════════════════════════════════════
  // 二、诊断包真的写成 zip（真跑 IO）
  // ═════════════════════════════════════════════════════════════════════════
  group('★2 诊断包真的打成 zip', () {
    test('zip 里三份都在，且内容逐字节等于喂进去的那份', () async {
      final files = buildDiagnosticFiles(
        songsJson: '{"songs":[{"id":-1,"title":"歌"}]}',
        prefsJson: encodeDiagnosticPrefs({'mode': 'shuffle', 'vol': 0.8}),
        infoText: buildDiagnosticInfo(
          appVersion: '1.6.6',
          buildNumber: '19',
          exportedAt: DateTime(2026, 10, 6, 1, 2, 3),
          songCount: 1,
          musicFileCount: 1,
        ),
      );
      final path = await BackupService.writeZip(
        dir: _tmp,
        fileName: diagnosticZipName(20261006),
        files: files,
      );
      expect(File(path).existsSync(), isTrue);

      final archive = ZipDecoder().decodeBytes(await File(path).readAsBytes());
      final names = archive.files.where((f) => f.isFile).map((f) => f.name).toList();
      for (final f in files) {
        expect(names, contains(f.name), reason: '${f.name} 没进 zip');
        final entry = archive.files.firstWhere((e) => e.name == f.name);
        expect(utf8.decode(entry.content as List<int>), f.content,
            reason: '${f.name} 的内容对不上');
      }
      // 诊断包不带别的东西（临时文件不许被顺手打进去）
      expect(names.length, files.length);
      expect(names.any((n) => n.startsWith('mubox_diag_')), isFalse,
          reason: '写 zip 用的临时文件不许留在包里，也不许留在临时目录');
      final leftovers = _tmp
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split(RegExp(r'[/\\]')).last)
          .where((n) => n.startsWith('mubox_diag_'))
          .toList();
      expect(leftovers, isEmpty, reason: '临时文件用完必须删：$leftovers');
    });

    // ⚠️ 负向对照：把 `writeZip` 里的 `diagnosticMissing` 自检删掉 ⇒ 这条红
    //    （少了 songs.json 也照样「成功」，用户以为拿到了全部信息）。
    test('清单不全 ⇒ writeZip 当场抛，不许产出「看着成功」的包', () async {
      await expectLater(
        BackupService.writeZip(
          dir: _tmp,
          fileName: diagnosticZipName(1),
          files: buildDiagnosticFiles(
            songsJson: '{}',
            prefsJson: '{}',
            infoText: 'x',
          ).where((f) => f.name != kDiagnosticSongsName).toList(),
        ),
        throwsA(isA<StateError>()),
      );
    });
  });

  // ═════════════════════════════════════════════════════════════════════════
  // 三、临时目录里的旧备份 zip（用户踩到的 250MB 僵尸）
  // ═════════════════════════════════════════════════════════════════════════
  group('★3 建新备份前清掉上一份临时 zip', () {
    String nameAt(int ms) => '$kBackupTempPrefix$ms.zip';

    test('选择规则：只认前缀 + .zip + 纯数字时间戳，本次那份永不删', () {
      final doomed = planTempZipCleanup(
        [
          nameAt(100), // 更早的
          nameAt(300), // 本次
          nameAt(200), // 上一份（用户点这次备份之前那一份）
          kBackupPrefsTempName, // 不是 zip：必须放过
          'mubox_backup_50.zip.bak', // 同前缀但非 .zip：必须放过
          'someone_else.tmp', // 别人的文件：必须放过
          'mubox_backup_abc.zip', // 时间戳不是数字：**认不出来就不许删**
          'mubox_backup_.zip', // 空时间戳：同上
        ],
        keep: nameAt(300),
      );
      expect(doomed, [nameAt(200), nameAt(100)],
          reason: '除了本次那份，别的 mubox_backup_*.zip（含上一份）都要清掉');
      for (final untouched in const [
        kBackupPrefsTempName,
        'someone_else.tmp',
        'mubox_backup_50.zip.bak',
        'mubox_backup_abc.zip',
        'mubox_backup_.zip',
      ]) {
        expect(doomed, isNot(contains(untouched)),
            reason: '⛔ $untouched 不归我们管，绝不能被删');
      }
    });

    test('keepLatest=1 ⇒ 除本次外留最新那一份（位置语义，别当成「上一代」）', () {
      expect(
        planTempZipCleanup(
          [nameAt(100), nameAt(400), nameAt(300)],
          keep: nameAt(300),
          keepLatest: 1,
        ),
        [nameAt(100)],
        reason: 'keepLatest 数的是「除本次外还留几份最新的」；调用点给的是 0',
      );
    });

    /// ⚠️ 负向对照（实测红）：把 `createBackup()` 里那句
    /// `await _cleanupOldTempZips(tmp, keep: zipPath);` 注释掉 ⇒ 旧的
    /// `mubox_backup_1000.zip` 还在（`Expected: empty / Actual: WhereIterable<String>:
    /// ['mubox_backup_1000.zip']`）。
    test('真跑 createBackup：旧 zip 一个不剩，别人的文件一个没动', () async {
      // 现场：一个更早的旧备份 + 一个非本前缀的文件 + 一个同前缀但非 zip 的文件
      File('${_tmp.path}/${nameAt(1000)}').writeAsStringSync('old zip bytes');
      File('${_tmp.path}/someone_else.tmp').writeAsStringSync('别动我');
      File('${_tmp.path}/mubox_backup_1000.zip.bak').writeAsStringSync('别动我');

      final zipPath = await BackupService.createBackup();
      final nowName = zipPath.split(RegExp(r'[/\\]')).last;
      expect(nowName, startsWith(kBackupTempPrefix));
      expect(File(zipPath).existsSync(), isTrue, reason: '本次那份必须建出来');

      final left = _tmp
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split(RegExp(r'[/\\]')).last)
          .toList();
      expect(
        left.where((n) =>
            n.startsWith(kBackupTempPrefix) && n.endsWith('.zip') && n != nowName),
        isEmpty,
        reason: '建新备份之前必须把上一个 mubox_backup_*.zip 删掉（250MB 僵尸的来源）',
      );
      // ⛔ 铁律：只删自己这个前缀的 zip，别人的文件一个都不许动
      expect(File('${_tmp.path}/someone_else.tmp').existsSync(), isTrue,
          reason: '非本前缀的文件绝不能被删');
      expect(File('${_tmp.path}/mubox_backup_1000.zip.bak').existsSync(), isTrue,
          reason: '同前缀但非 .zip 的也不许删（判据两道：前缀 + .zip）');
      // 临时 prefs 也不许留在 cache 里
      expect(File('${_tmp.path}/$kBackupPrefsTempName').existsSync(), isFalse,
          reason: '临时 prefs.json 用完必须删（否则又是一份僵尸）');
    });

    test('连做两次备份：临时目录里始终只有一份备份 zip', () async {
      await BackupService.createBackup();
      final second = await BackupService.createBackup();
      final zips = _tmp
          .listSync()
          .whereType<File>()
          .map((f) => f.path.split(RegExp(r'[/\\]')).last)
          .where((n) => n.startsWith(kBackupTempPrefix) && n.endsWith('.zip'))
          .toList();
      expect(zips, [second.split(RegExp(r'[/\\]')).last],
          reason: '第二次备份前要清掉第一次那份');
    });
  });

  // ═════════════════════════════════════════════════════════════════════════
  // 四、可取消的导入循环
  // ═════════════════════════════════════════════════════════════════════════
  group('★4 导入循环可取消（置位后 N 步内退出、计数与实际处理数一致）', () {
    /// 造 10 条；`cancelAfter` 条**做完之后**把令牌置位（模拟用户中途点取消）。
    ///
    /// ⚠️ 置位放在 `copy` **内部**（await 之间）是刻意的：这样「取消检查在
    /// 循环体最开头」这句话才可证 —— 检查在开头 ⇒ 第 `cancelAfter` 条做完就退出，
    /// `calls == cancelAfter`；检查挪到 `copy` 之后 ⇒ 会多做一条（`cancelAfter + 1`），
    /// 断言当场红。
    Future<({ImportLoopResult<String> r, int calls})> run({
      required int? cancelAfter,
    }) async {
      final cancel = CancelToken();
      cancel.begin();
      var calls = 0;
      final items = [
        for (var i = 0; i < 10; i++)
          ImportPlanItem(src: '/m/$i.mp3', base: '$i.mp3', targetName: '$i.mp3'),
      ];
      final r = await runImportLoop<String>(
        items,
        cancel: cancel.token,
        copy: (item, targetName) async {
          calls++;
          if (cancelAfter != null && calls == cancelAfter) cancel.cancel();
          return targetName;
        },
      );
      return (r: r, calls: calls);
    }

    test('第 4 条做完点取消 ⇒ calls 正好 4、imported 4、completed false', () async {
      final out = await run(cancelAfter: 4);
      expect(out.calls, 4,
          reason: '取消检查必须在循环体最开头：被叫停的那一条一个字节都还没复制');
      expect(out.r.imported.length, 4);
      expect(out.r.done, 4);
      expect(out.r.total, 10);
      expect(out.r.completed, isFalse, reason: '取消 ⇒ 调用方据此跳过落盘');
    });

    // ⚠️ 负向对照（实测红，原文见交付报告）：去掉 `runImportLoop` 里那句
    //    `if (cancel != null && cancel.isCancelled) break;` ⇒
    //    calls 变成 10、done 变成 10、completed 变成 true ⇒ 这条红。
    test('★ 负向：取消一旦置位就绝不能跑满（不看标志 = 红）', () async {
      final out = await run(cancelAfter: 4);
      expect(out.calls, lessThan(10), reason: '不看标志的话这里就是 10');
      expect(out.r.done, lessThan(out.r.total));
      expect(out.r.completed, isFalse);
    });

    test('取消一次不会让下一轮永远跑不动（begin 换号）', () async {
      final cancel = CancelToken();
      cancel.begin();
      cancel.cancel();
      expect(cancel.token.isCancelled, isTrue);
      cancel.begin(); // 新一轮
      expect(cancel.token.isCancelled, isFalse,
          reason: '光一个 bool 的话这里还是 true ⇒ 每次刷新第一步就自杀');
      final r = await runImportLoop<String>(
        [
          for (var i = 0; i < 3; i++)
            ImportPlanItem(src: '/m/$i.mp3', base: '$i.mp3', targetName: '$i.mp3'),
        ],
        cancel: cancel.token,
        copy: (item, targetName) async => targetName,
      );
      expect(r.completed, isTrue);
      expect(r.done, 3);
      expect(cancel.isCancelled, isFalse);
    });

    test('复制失败的条目不占名额，也不会把后面的全跳掉', () async {
      final items = [
        for (var i = 0; i < 5; i++)
          ImportPlanItem(src: '/m/$i.mp3', base: '$i.mp3', targetName: '$i.mp3'),
      ];
      var calls = 0;
      final progress = <String>[];
      final r = await runImportLoop<String>(
        items,
        copy: (item, targetName) async {
          calls++;
          return calls == 2 ? null : targetName; // 第 2 条复制失败
        },
        onProgress: (done, total) => progress.add('$done/$total'),
      );
      expect(calls, 5, reason: '失败一条不该跳过后面的');
      expect(r.done, 4);
      expect(r.total, 5);
      expect(r.completed, isTrue);
      expect(progress.last, '5/5');
    });

    test('取消时的计数与「真的处理过多少」一致（进度条不会虚报）', () async {
      final cancel = CancelToken();
      cancel.begin();
      var calls = 0;
      final progress = <int>[];
      final r = await runImportLoop<String>(
        [
          for (var i = 0; i < 6; i++)
            ImportPlanItem(src: '/m/$i.mp3', base: '$i.mp3', targetName: '$i.mp3'),
        ],
        cancel: cancel.token,
        copy: (item, targetName) async {
          calls++;
          if (calls == 2) cancel.cancel();
          return targetName;
        },
        onProgress: (done, total) => progress.add(done),
      );
      expect(r.done, 2);
      expect(progress.last, 2, reason: '界面报的「完成 X」必须等于真的处理过的条数');
      expect(r.completed, isFalse);
    });
  });

  // ═════════════════════════════════════════════════════════════════════════
  // 五、保存到公共目录：两种**正确**结果都不许写成失败
  // ═════════════════════════════════════════════════════════════════════════
  group('★5 保存结果文案', () {
    test('exported ⇒ 明确写出人能看懂的路径', () {
      const r = SaveOutcome(
        status: SaveStatus.exported,
        uri: 'content://media/external/file/1',
        displayPath: '内部存储/Documents/MuBox/mubox_backup_1.zip',
        name: 'mubox_backup_1.zip',
      );
      expect(r.written, isTrue);
      expect(saveResultText(r), '已保存到 内部存储/Documents/MuBox/mubox_backup_1.zip');
    });

    // ⚠️ 负向对照：把 `saveResultText` 里 unchanged 那条改写成「失败」⇒ 红
    //    （内容是逐字节相同的，本来就没必要重写 —— 说失败是骗人）。
    test('unchanged 是正确结果：文案不许出现「失败」两个字', () {
      const r = SaveOutcome(
        status: SaveStatus.unchanged,
        uri: 'content://media/external/file/1',
        displayPath: '内部存储/Documents/MuBox/mubox_backup_1.zip',
        name: 'mubox_backup_1.zip',
      );
      expect(r.written, isFalse);
      expect(saveResultText(r), contains('已是最新'));
      expect(saveResultText(r), contains('内部存储/Documents/MuBox'));
      expect(saveResultText(r), isNot(contains('失败')));
    });
  });

  // ═════════════════════════════════════════════════════════════════════════
  // 六、版本号解析（info.txt 里的 App 版本）
  // ═════════════════════════════════════════════════════════════════════════
  group('★6 info.txt 的版本号', () {
    // Flutter 在 Android 上真实的 resolvedExecutable 形状（现装那版实测）：
    //   …/com.mubox.mu_box_phone-<base64>/base.apk!/assets/flutter_assets/kernel_blob.bin
    // 目录名里那截 base64 的前 5 个字节 = 01 02 <major> <minor> <patch>
    // （本用例 = 01 02 06 00 13 ⇒ 版本名 6.0、版本号 19）。编码串用 python 现算：
    //   base64.b64encode(bytes([1,2,6,0,19,9,9,9])) = 'AQIGABMJCQk='
    const realPath = '/data/app/~~x==/com.mubox.mu_box_phone-AQIGABMJCQk=/'
        'base.apk!/assets/flutter_assets/kernel_blob.bin';

    test('从真机形状的 APK 路径里解出 版本名 6.0 / 版本号 19', () {
      final r = parseAppVersion(realPath);
      expect(r.version, '6.0');
      expect(r.build, '19');
    });

    test('Windows 分隔符也认（同一串换成反斜杠）', () {
      final r = parseAppVersion(realPath.replaceAll('/', r'\'));
      expect(r.version, '6.0');
      expect(r.build, '19');
    });

    // ⚠️ 负向对照：把「解不出来就回未知」改成「回一个写死的旧版本号」⇒ 这两条红。
    test('不是 base64 的目录名 ⇒ 如实「未知」，⛔ 不编一个假版本号', () {
      expect(parseAppVersion('/data/app/base.apk!/x').version, '未知');
      expect(parseAppVersion('/data/app/base.apk!/x').build, '未知');
      expect(
        parseAppVersion('/data/app/com.mubox.mu_box_phone-x/base.apk!/x').version,
        '未知',
      );
    });

    test('host 上没有 APK（flutter_tester 跑单测）⇒ 两个都「未知」', () {
      final r = parseAppVersion(r'C:\tools\flutter\bin\cache\artifacts\flutter_tester.exe');
      expect(r.version, '未知');
      expect(r.build, '未知');
    });
  });

  // ═════════════════════════════════════════════════════════════════════════
  // 七、`saveToDocuments` 的 Dart 侧接线（参数名契约 + 三种回法）
  // ═════════════════════════════════════════════════════════════════════════
  group('★7 saveToDocuments 接线（参数名不许改）', () {
    /// 装一个假的导出通道，记录每次调用，按 [reply] 回应。
    List<MethodCall> install(Object? Function(MethodCall call) reply) {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_exportChannel, (call) async {
        calls.add(call);
        return reply(call);
      });
      addTearDown(() {
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(_exportChannel, null);
      });
      return calls;
    }

    // ⚠️ 负向对照：把 Dart 侧 `'subdir'` 写成别的名字（或漏掉）⇒ 这条红，
    //    而原生侧 `argument<String>("subdir")` 会拿到 null ⇒ 落错目录。
    test('请求带 src / name / subdir / report 四个参数，方法名不变', () async {
      final calls = install(
        (_) => {'status': 'exported', 'uri': 'content://media/external/file/9'},
      );
      final r = await BackupService.saveToDocuments(
        src: '/data/user/0/com.mubox.mu_box_phone/cache/mubox_backup_7.zip',
        name: 'mubox_backup_7.zip',
      );
      expect(calls, hasLength(1));
      expect(calls.single.method, 'saveToDocuments',
          reason: '方法名是订好的契约（判据 tool/check_save_to_documents.py 的 P11）');
      final args = calls.single.arguments as Map;
      expect(args['src'], endsWith('mubox_backup_7.zip'));
      expect(args['name'], 'mubox_backup_7.zip');
      expect(args['subdir'], 'MuBox');
      expect(args['report'], isTrue, reason: '不带 report 原生就不回 status');
      expect(r.status, SaveStatus.exported);
      expect(r.written, isTrue);
    });

    test('map 回法：status=unchanged 认成「已是最新」，不是失败', () async {
      install((_) => {'status': 'unchanged', 'uri': 'content://media/external/file/9'});
      final r = await BackupService.saveToDocuments(src: '/x/y.zip', name: 'y.zip');
      expect(r.status, SaveStatus.unchanged);
      expect(r.written, isFalse);
    });

    test('status 认不出来 ⇒ 按「真写了」处理（宁可多算一笔写入）', () async {
      install((_) => {'status': '???', 'uri': 'content://media/external/file/9'});
      final r = await BackupService.saveToDocuments(src: '/x/y.zip', name: 'y.zip');
      expect(r.written, isTrue);
    });

    // ⚠️ 这条是**老回法不许坏**：不带 report 时原生仍回纯 uri 字符串。
    test('老回法（纯 uri 字符串）仍然认，按 exported', () async {
      install((_) => 'content://media/external/file/9');
      final r = await BackupService.saveToDocuments(src: '/x/y.zip', name: 'y.zip');
      expect(r.status, SaveStatus.exported);
      expect(r.uri, 'content://media/external/file/9');
    });

    // ⚠️ 负向对照：把 `if (uri == null || uri.isEmpty) throw` 删掉 ⇒ 这两条红
    //    （源文件不存在 / 名字非法时原生回 null，Dart 侧当成功就是骗人）。
    test('原生回 null ⇒ 必须抛异常，⛔ 绝不当成功', () async {
      install((_) => null);
      await expectLater(
        BackupService.saveToDocuments(src: '/x/y.zip', name: 'y.zip'),
        throwsException,
      );
    });

    test('回空 uri 也抛；文件名空则在本地就拦下（不发请求）', () async {
      final calls = install((_) => '');
      await expectLater(
        BackupService.saveToDocuments(src: '/x/y.zip', name: 'y.zip'),
        throwsException,
      );
      await expectLater(
        BackupService.saveToDocuments(src: '/x/y.zip', name: ''),
        throwsException,
      );
      expect(calls, hasLength(1), reason: '空文件名不该白跑一趟通道');
    });
  });
}
