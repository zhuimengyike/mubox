/// `lib/export_service.dart` 的**三态**断言。
///
/// 原生侧（`MainActivity.kt`）已经把导出改成「先比对 size+sha256，内容不一致才原地真覆盖」，
/// 并回 `{"status":"exported"|"unchanged","uri":…}`。Dart 这侧要做的只有一件事：
/// **把这个状态如实接回来**，别把「已是最新（没重写）」也说成「导出成功」。
///
/// 这里挡掉 `com.mubox.mu_box_phone/export` 通道，逐条核：
/// * 请求里必须带 `report: true`（不带原生就不回状态）；
/// * map 回法两种状态都要认；
/// * **老回法（纯 uri 字符串）不许坏**，`uri` 空/null 仍走原来的失败路径（抛异常）；
/// * `status` 认不出来时按「已写入」处理（宁可多报一笔写入，也不要把真写了说成没写）。
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/export_service.dart';
import 'package:mu_box_phone/models.dart';

const MethodChannel _ch = MethodChannel('com.mubox.mu_box_phone/export');

Song _song() => Song(
  id: 1,
  title: '歌',
  artist: '',
  durationMs: 1000,
  uri: '',
  filePath: '/data/music/歌.mp3',
);

/// 装一个假的导出通道，记录每次调用的参数与请求，按 [reply] 回应。
List<MethodCall> _install(Object? Function(MethodCall call) reply) {
  final calls = <MethodCall>[];
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_ch, (call) async {
    calls.add(call);
    return reply(call);
  });
  addTearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_ch, null);
  });
  return calls;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('请求里带 report: true、src/name 照旧（不带就只能收到「成功/失败」两态）', () async {
    final calls = _install(
      (_) => {'status': 'exported', 'uri': 'content://media/external/audio/media/7'},
    );
    final r = await ExportService.exportSong(_song());

    expect(calls, hasLength(1));
    expect(calls.single.method, 'export');
    final args = calls.single.arguments as Map;
    expect(args['report'], isTrue, reason: '★ 不带 report，原生不会回状态');
    expect(args['src'], '/data/music/歌.mp3');
    expect(args['name'], '歌.mp3');
    expect(r.written, isTrue);
    expect(r.status, ExportStatus.exported);
    expect(r.uri, 'content://media/external/audio/media/7');
  });

  test('★ 三态：unchanged = 已是最新（没重写），不许算成「写了」', () async {
    _install(
      (_) => {'status': 'unchanged', 'uri': 'content://media/external/audio/media/7'},
    );
    final r = await ExportService.exportSong(_song());
    expect(r.status, ExportStatus.alreadyUpToDate);
    expect(r.written, isFalse,
        reason: '★ 文案要把这一笔单列成「已是最新」，不能再混进「已导出」');
  });

  test('status 认不出来（老原生 / 新状态值）⇒ 按「已写入」处理', () async {
    _install(
      (_) => {'status': '???', 'uri': 'content://media/external/audio/media/7'},
    );
    final r = await ExportService.exportSong(_song());
    expect(r.written, isTrue,
        reason: '宁可多报一笔「写进去」，也不要把真写了的那次说成没写');
  });

  test('老回法（纯 uri 字符串）不许坏：仍然算「已写入」', () async {
    _install((_) => 'content://media/external/audio/media/9');
    final r = await ExportService.exportSong(_song());
    expect(r.written, isTrue);
    expect(r.uri, 'content://media/external/audio/media/9');
  });

  group('失败路径与改动前一致：拿不到 uri 就抛', () {
    test('null 回应', () async {
      _install((_) => null);
      await expectLater(ExportService.exportSong(_song()), throwsException);
    });

    test('map 里 uri 为 null / 空串', () async {
      _install((_) => {'status': 'exported', 'uri': null});
      await expectLater(ExportService.exportSong(_song()), throwsException);
      _install((_) => {'status': 'exported', 'uri': ''});
      await expectLater(ExportService.exportSong(_song()), throwsException);
    });

    test('map 里根本没有 uri 键', () async {
      _install((_) => {'status': 'unchanged'});
      await expectLater(ExportService.exportSong(_song()), throwsException);
    });

    test('空 filePath：连通道都不该打', () async {
      final calls = _install((_) => 'x');
      await expectLater(
        ExportService.exportSong(
          Song(id: 1, title: 't', artist: '', durationMs: 0, uri: '', filePath: ''),
        ),
        throwsException,
      );
      expect(calls, isEmpty);
    });

    test('原生抛异常：原样往上抛（调用方照旧 catch）', () async {
      _install((_) => throw PlatformException(code: 'boom'));
      await expectLater(
        ExportService.exportSong(_song()),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}
