/// 常驻守门测试：**开源版必须全程离线，整个 App 一条出网路径都不许有**。
///
/// 用户原话：「把联网功能全删了，一个都别留。」
///
/// ## 为什么拿测试当护栏
/// 「有没有出网」这类事**不报错、不崩溃、界面也完全看不出** —— 少删一个
/// `HttpClient(` 或者谁哪天顺手把 `INTERNET` 权限加回 manifest，
/// `flutter test` 和 `flutter analyze` 照样全绿、装到手机上照样能用。
/// 只有读源码才看得见。所以这条规则只能靠**扫源码**来守。
///
/// ## 拦什么（守的是这三种「悄悄出网」的形状）
/// 1. `lib/**/*.dart` 里出现出网 API：`HttpClient(` / `Socket(` /
///    `RawDatagramSocket` / `WebSocket` / `InternetAddress`；
/// 2. `lib/**/*.dart` 里出现 `http(s)://` 字面量
///    （★ 注释也算 —— 留着一条「从这儿拉封面」的注释，就等于把删掉的路标回来了）；
/// 3. `android/**/AndroidManifest.xml` 里的 `permission.INTERNET`
///    （`src/main` 一个都不许有；`src/debug` / `src/profile` 各只许有 Flutter
///    工具链自己要用的那一处，见 ★3）。
///
/// ## ⚠️ 仍然要守的老账
/// 设置页「拉取全部歌词 / 全部封面」曾经用的是未过滤的 `Library.instance.songs`，
/// 于是每一首私密歌的歌名 + 歌手都会被拼进发往远端的 GET 查询串 ——
/// 把歌标成「私密」的预期当场作废。
/// 联网那两半已经整份删了，但**导出 / 备份 / 诊断包**还在往外走
/// 「自己拿走的一份」，它们同样必须过私密过滤 ⇒ 下面那两条断言留着。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 出网 API 的**构造/引用**写法。
///
/// ⚠️ 几个刻意的边界：
/// * `RawDatagramSocket.bind(` / `.connect(` 必须留后缀 —— 不带后缀的话
///   光是写出类名（比如写注释里提一嘴）也会红，那是条会喊狼来了的死断言；
/// * `WebSocket` / `InternetAddress` 不带后缀：这两个名字在 `lib/` 里
///   **没有任何非出网用途**，出现即违规；
/// * `Socket` 前面不能直接跟标识符 —— 否则 `RawDatagramSocket(` 会被
///   `Socket(` 重复命中（重复报同一行，读输出时容易误判成两处）。
/// * ★ `Socket` 既可能是构造（`Socket(`）也可能是静态工厂
///   （`Socket.connect(` / `Socket.startConnect(`）⇒ 后缀两者都要收。
///   **实测教训**：第一版只写了 `Socket\s*\(`，下面那条量具自证当场把
///   `Socket.connect(host, 80);` 这条样例行判成「没抓住」——
///   漏的正是真代码里最常见的那个写法。
final List<RegExp> _outboundApis = [
  RegExp(r'HttpClient\s*\('),
  RegExp(r'(?<![A-Za-z0-9_])Socket\s*[.(]'),
  RegExp(r'RawDatagramSocket\s*\.\s*(bind|connect)\s*\('),
  RegExp(r'(?<![A-Za-z0-9_])WebSocket(?![A-Za-z0-9_])'),
  RegExp(r'(?<![A-Za-z0-9_])InternetAddress(?![A-Za-z0-9_])'),
];

/// URL 字面量（注释里的也算，见文件头的说明）。
final RegExp _urlLiteral = RegExp(r'https?://');

/// 遍历 `lib/` 下所有 .dart，对每一行跑 [hit]；返回 `文件:行号` 列表。
List<String> _scanLib(bool Function(String line) hit) {
  final out = <String>[];
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final lines = e.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (hit(lines[i])) {
        // 统一成 posix 风格的分隔符，Windows 上跑也是同一个串
        out.add('${e.path.replaceAll(r'\', '/')}:${i + 1}');
      }
    }
  }
  return out;
}

/// `lib/` 下所有 .dart 的路径（相对包根，posix 分隔符）。
List<String> _libFiles() {
  final out = <String>[];
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    out.add(e.path.replaceAll(r'\', '/'));
  }
  return out;
}

void main() {
  test('lib/ 存在（下面的扫描有赖于 cwd = 包根目录）', () {
    expect(Directory('lib').existsSync(), isTrue,
        reason: 'flutter test 的 cwd 应当是包根目录');
  });

  group('★ 零出网（用户原话：一个都别留）', () {
    test('★1 lib/ 里不许出现任何出网 API', () {
      final hits = _scanLib((l) => _outboundApis.any((re) => re.hasMatch(l)));
      expect(
        hits,
        isEmpty,
        reason: '这些地方留着出网 API：\n${hits.join('\n')}\n'
            '开源版必须全程离线。真要用网络就该是另一个仓库的事，'
            '⛔ 别把这一条判据放宽 —— 它是这条规则的核心。',
      );
    });

    test('★2 lib/ 里不许出现 http(s):// 字面量（注释也算）', () {
      // ⚠️ 为什么连注释一起卡：这条护栏的前身就是「读源码才看得见」的漏洞。
      //    留一句「// 从这拉网易云封面」等于把删掉的路标了回来，下一个人照着写就复活了。
      final hits = _scanLib((l) => _urlLiteral.hasMatch(l));
      expect(
        hits,
        isEmpty,
        reason: '这些行里还有 URL 字面量：\n${hits.join('\n')}\n'
            '（注释里的也算 —— 别只把代码那半删了）',
      );
    });

    test('★3 src/main 不许有 INTERNET 权限；全仓只允许 src/debug + src/profile 各一处', () {
      // 三份 manifest 各查各的：`src/main` 一个都不许有；`src/debug` / `src/profile`
      // 各只许有 Flutter 工具链自己要用的那一处。
      const mainManifest = 'android/app/src/main/AndroidManifest.xml';
      final manifests = <File>[
        for (final e in Directory('android').listSync(recursive: true))
          if (e is File && e.path.endsWith('AndroidManifest.xml')) e,
      ];
      // ★ 量具自证：一个都没扫到的话，下面那条 `isEmpty` 是**恒真**的死断言。
      expect(
        manifests.map((f) => f.path.replaceAll(r'\', '/')).toList()..sort(),
        containsAll(<String>[
          mainManifest,
          'android/app/src/debug/AndroidManifest.xml',
          'android/app/src/profile/AndroidManifest.xml',
        ]),
        reason: 'expected 的扫描范围与磁盘上的 manifest 对不上，'
            '这条判据就退化成空集恒真了（扫描范围变了要改这里）',
      );

      final internetHits = <String>[];
      for (final f in manifests) {
        final lines = f.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (lines[i].contains('permission.INTERNET')) {
            internetHits.add('${f.path.replaceAll(r'\', '/')}:${i + 1}');
          }
        }
      }

      // ① 硬断言：正式包只并 `src/main` 那一份 ⇒ 它一处都不许有。
      final mainHits =
          internetHits.where((h) => h.startsWith('$mainManifest:')).toList();
      expect(
        mainHits,
        isEmpty,
        reason: '`$mainManifest` 声明着 INTERNET 权限，正式包也会并上它：\n'
            '${mainHits.join('\n')}\n'
            '用户的要求是「整个 App 没有任何一条出网路径」⇒ main 一处都不许留。',
      );

      // ② 白名单断言：**写死期望值**（`src/debug` / `src/profile` 各恰好 1 处）。
      //    为什么这两份留着：Flutter 的工具链要用 —— 调试时 Dart VM service 要在
      //    App 进程里建**本地 socket**，Android 上没有 INTERNET 权限连 loopback
      //    socket 都建不了 ⇒ 删了 `flutter run` / 热重载会瞎。
      //    这两份 manifest **只在 debug/profile 构建里合并，release 包根本不合并**
      //    ⇒ 正式包依然零联网权限。
      //    ★ 写死期望值的意义：**谁往别的 manifest 加一处、或把 main 加回去、或在这
      //    两份里多加一处，条数或清单立刻对不上 ⇒ 当场红。**
      const allowed = <String>[
        'android/app/src/debug/AndroidManifest.xml:7',
        'android/app/src/profile/AndroidManifest.xml:7',
      ];
      final allowedHits = internetHits
          .where((h) =>
              h.startsWith('android/app/src/debug/AndroidManifest.xml:') ||
              h.startsWith('android/app/src/profile/AndroidManifest.xml:'))
          .toList()
        ..sort();
      final elsewhere = internetHits
          .where((h) => !allowedHits.contains(h) && !h.startsWith('$mainManifest:'))
          .toList();
      expect(
        allowedHits,
        orderedEquals(allowed),
        reason: '`permission.INTERNET` 的全仓分布变了：\n'
            '期望只有 $allowed（Flutter 调试/热重载需要，release 不合并这两份）\n'
            '实际 ${allowedHits.isEmpty ? "（一处都没有）" : allowedHits.join("、")}\n'
            '⛔ 这两处之外一律不许出现（`src/main` 由上面那条硬断言单独守）。',
      );
      expect(
        elsewhere,
        isEmpty,
        reason: '`permission.INTERNET` 出现在了白名单之外的地方：\n${elsewhere.join('\n')}\n'
            '只有 `src/debug` / `src/profile` 各允许一处。',
      );
    });
  });

  group('H5 老账：往外走的数据必须先过私密过滤', () {
    test('没有「把未过滤的歌曲列表整个交出去」的写法', () {
      // `Library.instance.songs;` = 把原始列表赋给变量。
      // 带 `.length` 的只读计数不算（那种不往外发数据）。
      // 过滤版是 `Library.instance.songsOf(kAllSongs)`，它按歌单列表同一套规则滤掉私密歌。
      final hits = _scanLib(
        (l) => RegExp(r'Library\.instance\.songs\s*;').hasMatch(l),
      );
      expect(
        hits,
        isEmpty,
        reason: '这几处直接取了未过滤的歌曲列表：$hits\n'
            '要外发（导出 / 备份 / 诊断包）就必须走 Library.instance.songsOf(kAllSongs)，'
            '否则私密歌的名字会进到用户交出去的那一份里（H5）。',
      );
    });

    test('设置页往外走的那几处都用过滤后的列表', () {
      final src = File('lib/pages/settings_page.dart').readAsStringSync();
      // 联网那两处（拉词 / 拉封面）已经删了 ⇒ 现在只剩导出这一处往外走。
      // ★ 断言写成 `>= 1` 而不是 `== 1`：这条守的是「**每一处**外发都过滤」，
      //   将来再加一处外发（比如又出一个导出入口）时它必须自己过闸，
      //   而不是把这条断言顶红。
      expect(
        RegExp(r'Library\.instance\.songsOf\(kAllSongs\)').allMatches(src).length,
        greaterThanOrEqualTo(1),
        reason: '往用户手里交东西的那条循环必须走 songsOf(kAllSongs)（H5）',
      );
    });
  });

  test('★ 量具自证：上面那套「出网 API」判据真的抓得住东西', () {
    // ★★ 没有这一条，上面三条 `isEmpty` 全都有可能是**恒真的死断言**
    //    （正则写错、全都不匹配 ⇒ 全绿，而代码里明明有 HttpClient(）。
    //    拿**已知会违规的样例行**喂给同一组正则：必须每条都命中。
    const samples = <String>[
      '  final client = HttpClient();',
      '  final s = await Socket.connect(host, 80);',
      '  final s = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);',
      '  final ws = await WebSocket.connect(url);',
      "  await HttpClient().getUrl(Uri.parse('https://example.com/'));",
    ];
    for (final line in samples) {
      final hitByApi = _outboundApis.any((re) => re.hasMatch(line));
      final hitByUrl = _urlLiteral.hasMatch(line);
      expect(hitByApi || hitByUrl, isTrue,
          reason: '这条样例行一个判据都没抓住，说明判据本身坏了：$line');
    }
    // 负向：正常的本机 IO 不许被误伤（否则断言会喊狼来了，下一个人就把它删了）
    const clean = <String>[
      "  final f = File('\${docs.path}/artwork/x.jpg');",
      '  final d = Directory(path);',
      '  await f.writeAsBytes(bytes);',
      '  // 本机文件，不出网',
    ];
    for (final line in clean) {
      expect(_outboundApis.any((re) => re.hasMatch(line)), isFalse,
          reason: '本机 IO 被误判成出网了，判据太宽：$line');
      expect(_urlLiteral.hasMatch(line), isFalse,
          reason: '本机 IO 被误判成 URL 字面量了：$line');
    }
  });

  test('★ lib/ 的文件清单不是空的（扫描真扫到东西了）', () {
    final files = _libFiles();
    // 上一条自证的是「正则抓得住」，这一条自证的是「**扫描真的在遍历文件**」。
    // 两条合起来，那三条 `isEmpty` 才不是死断言。
    expect(files.length, greaterThan(50),
        reason: '只扫到 ${files.length} 个 .dart，扫描范围明显不对');
  });
}
