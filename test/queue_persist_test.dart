/// 队列**落盘 / 读回**的单测（阶段 1「队列 2.0」的「重启后队列还在」）。
/// 两层：
/// 1. [QueueCodec]（`lib/playback/queue.dart` 的纯函数）—— 编解码逐项等价、
///    老文件 / 坏文件怎么读；
/// 2. `Store.saveLastSession` / `Store.loadLastSession`（把 path_provider 与
///    SharedPreferences 挡掉，指向真临时目录）—— 真的写到 `queue.json`、
///    真的读得回来、坏了**绝不写空值盖现场**。
///
/// 为什么第二层非测不可：这层原先零覆盖，而它的坑全是「静默」的 —— 读坏了当空，
/// 下一次写盘把空值固化，用户看到的是「队列没了 / 上次那首没了」，全程不报错。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/playback/queue.dart';
import 'package:mu_box_phone/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

late Directory _docs;

Future<File> _queueFile() async => File('${_docs.path}/${Store.kQueueFile}');

/// 落盘用的 Map → 再「过一遍 JSON 文本」→ 解回来。
/// 必须过文本这一步：`jsonEncode` / `jsonDecode` 会把类型洗一遍
/// （int 还是 int、`List<String>` 变成 `List<dynamic>`），只比内存里的 Map 是自欺欺人。
Object? _throughJson(Object? v) => jsonDecode(jsonEncode(v));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_queue_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => _docs.path,
        'getTemporaryDirectory' => _docs.path,
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
  });

  // ════════════════════════════════════════════════════════════════════════
  group('QueueCodec：编解码（纯函数）', () {
    test('往返逐项等价：队列 / 下标 / 来源名 / 模式 / 种子 / 游标', () {
      final q = QueueState(
        refs: const ['/m/1.mp3', '/m/2.mp3', '/m/3.mp3'],
        index: 2,
        sourceName: '我喜欢',
      );
      final raw = _throughJson(
        QueueCodec.encode(q, mode: 'shuffle', seed: 12345, cursor: 1),
      );
      final back = QueueCodec.decode(raw);
      expect(back, isNotNull);
      expect(back!.refs, q.refs);
      expect(back.index, 2);
      expect(back.sourceName, '我喜欢');
      expect(back.current, '/m/3.mp3');
      expect(QueueCodec.modeOf(raw), 'shuffle');
      expect(QueueCodec.seedOf(raw), 12345);
      expect(QueueCodec.cursorOf(raw), 1);
    });

    test('空队列 / 没有当前曲也往返得回来（index = -1）', () {
      final raw = _throughJson(QueueCodec.encode(QueueState.empty));
      final back = QueueCodec.decode(raw);
      expect(back!.refs, isEmpty);
      expect(back.index, -1);
      expect(back.sourceName, '');
    });

    test('没传的字段不写进 JSON（别把 null 塞进去，读侧要多一层判断）', () {
      final raw = QueueCodec.encode(QueueState.empty);
      expect(raw.containsKey(QueueCodec.kMode), isFalse);
      expect(raw.containsKey(QueueCodec.kSeed), isFalse);
      expect(raw.containsKey(QueueCodec.kCursor), isFalse);
    });

    test('★ 老版本的文件（只有 paths/index/title）照读，新字段全是 null', () {
      // 「老数据可读」是这条 bullet 的硬要求：阶段 1 之前存下来的队列不能被判成坏的
      final raw = _throughJson(const {
        'paths': ['/m/a.mp3', '/m/b.mp3'],
        'index': 1,
        'title': '全部歌曲',
      });
      final back = QueueCodec.decode(raw);
      expect(back!.refs, ['/m/a.mp3', '/m/b.mp3']);
      expect(back.index, 1);
      expect(back.sourceName, '全部歌曲');
      expect(QueueCodec.modeOf(raw), isNull);
      expect(QueueCodec.seedOf(raw), isNull);
      expect(QueueCodec.cursorOf(raw), isNull);
    });

    test('★ 缺 index → -1（没有当前曲），**不是** null：队列本身还要留住', () {
      final back = QueueCodec.decode(_throughJson(const {
        'paths': ['/m/a.mp3'],
      }));
      expect(back, isNotNull);
      expect(back!.refs, ['/m/a.mp3']);
      expect(back.index, -1);
      expect(back.sourceName, '');
    });

    test('★ 缺 paths / 类型不对 → null（调用方据此保留磁盘上的原值）', () {
      expect(QueueCodec.decode(null), isNull);
      expect(QueueCodec.decode('不是 map'), isNull);
      expect(QueueCodec.decode(_throughJson(const {'index': 0})), isNull);
      expect(
        QueueCodec.decode(_throughJson(const {'paths': '不是数组'})),
        isNull,
      );
    });

    test('paths 里混进非字符串 → 逐项跳过（不许拖垮整条队列）', () {
      final back = QueueCodec.decode(_throughJson(const {
        'paths': ['/m/a.mp3', 123, null, '/m/b.mp3'],
        'index': 1,
      }));
      expect(back!.refs, ['/m/a.mp3', '/m/b.mp3']);
      expect(back.index, 1);
      expect(back.current, '/m/b.mp3');
    });

    test('index 越界 / 类型不对被夹住，不抛', () {
      final back = QueueCodec.decode(_throughJson(const {
        'paths': ['/m/a.mp3', '/m/b.mp3'],
        'index': 99,
      }));
      expect(back!.index, 1);
      expect(
        QueueCodec.decode(_throughJson(const {
          'paths': ['/m/a.mp3'],
          'index': 'x',
        }))!.index,
        -1,
      );
    });

    test('mode / seed / cursor 类型不对 → null，不抛', () {
      final raw = _throughJson(const {'paths': [], 'mode': 7, 'seed': 'x', 'cursor': 1.5});
      expect(QueueCodec.modeOf(raw), isNull);
      expect(QueueCodec.seedOf(raw), isNull);
      expect(QueueCodec.cursorOf(raw), isNull);
      expect(QueueCodec.modeOf('不是 map'), isNull);
    });

    test('中文来源名 / 含引号的路径往返不乱码', () {
      final q = QueueState(refs: const ['/m/带"引号".mp3'], index: 0, sourceName: '用户 "喜欢"');
      final back = QueueCodec.decode(_throughJson(QueueCodec.encode(q)));
      expect(back!.refs, ['/m/带"引号".mp3']);
      expect(back.sourceName, '用户 "喜欢"');
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('Store：真的写到 queue.json、真的读得回来', () {
    test('★ 正向：存下去的队列原样读回来（含随机种子与游标）', () async {
      await Store.saveLastSession(
        ['/m/1.mp3', '/m/2.mp3', '/m/3.mp3'],
        2,
        45000,
        '我喜欢',
        seed: 777,
        cursor: 1,
      );
      expect(await _queueFile().then((f) => f.exists()), isTrue,
          reason: '队列落在文档目录的 queue.json（不再写 prefs 的 last_session）');

      final s = await Store.loadLastSession();
      expect(s, isNotNull);
      expect(s!['paths'], ['/m/1.mp3', '/m/2.mp3', '/m/3.mp3']);
      expect(s['index'], 2);
      expect(s['posMs'], 45000);
      expect(s['title'], '我喜欢');
      expect(s['seed'], 777);
      expect(s['cursor'], 1);
    });

    test('★ 没有 queue.json 也没有老键 → null（= 全新安装，没有队列要恢复）', () async {
      expect(await Store.loadLastSession(), isNull);
    });

    test('★ 负向：queue.json 坏了 → 返回 null，而且**绝不改写它**', () async {
      final f = await _queueFile();
      await f.writeAsString('{"paths":["/m/1.mp3"], "index"');
      expect(await Store.loadLastSession(), isNull,
          reason: '坏的当没有，不能抛到启动流程里');
      expect(await f.readAsString(), '{"paths":["/m/1.mp3"], "index"',
          reason: '坏文件必须原封不动留着（写成空队列 = 把现场盖掉，用户数据就真没了）');
      expect(await f.readAsString(), isNot('{}'));
    });

    test('★ 负向：queue.json 是个数组（不是对象）→ null，且不改写', () async {
      final f = await _queueFile();
      await f.writeAsString('[1,2,3]');
      expect(await Store.loadLastSession(), isNull);
      expect(await f.readAsString(), '[1,2,3]');
    });

    test('★ 老数据（prefs 里的 last_session）照读，只读不迁', () async {
      SharedPreferences.setMockInitialValues({
        'last_session': jsonEncode({
          'paths': ['/m/old1.mp3', '/m/old2.mp3'],
          'index': 1,
          'posMs': 3000,
          'title': '老队列',
        }),
      });
      final s = await Store.loadLastSession();
      expect(s!['paths'], ['/m/old1.mp3', '/m/old2.mp3']);
      expect(s['index'], 1);
      expect(s['posMs'], 3000);
      expect(s['title'], '老队列');
      expect(s['seed'], isNull);
      expect(s['cursor'], isNull);
      // ⚠️ 不许迁到新文件：那会在「queue.json 被人为删掉」时把老队列又翻出来
      expect(await _queueFile().then((f) => f.exists()), isFalse);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('last_session'), isNotNull, reason: '老键也不许清');
    });

    test('老键缺 posMs / title / paths 里的脏元素：宽松读，不抛', () async {
      SharedPreferences.setMockInitialValues({
        'last_session': jsonEncode({
          'paths': ['/m/a.mp3', 5],
          'index': 0,
        }),
      });
      final s = await Store.loadLastSession();
      expect(s!['paths'], ['/m/a.mp3']);
      expect(s['posMs'], 0);
      expect(s['title'], '');
    });

    test('老键也坏了 → null', () async {
      SharedPreferences.setMockInitialValues({'last_session': '{坏'});
      expect(await Store.loadLastSession(), isNull);
    });

    test('空队列也写盘（清空队列后重启不许把上次那首翻出来）', () async {
      await Store.saveLastSession(const [], -1, 0, '');
      final s = await Store.loadLastSession();
      expect(s, isNotNull);
      expect(s!['paths'], isEmpty);
      expect(s['index'], -1);
    });

    test('连写两次：后一次赢，且不留 .tmp 残留', () async {
      await Store.saveLastSession(['/m/1.mp3'], 0, 1, 'A');
      await Store.saveLastSession(['/m/2.mp3'], 0, 2, 'B');
      final s = await Store.loadLastSession();
      expect(s!['paths'], ['/m/2.mp3']);
      expect(s['title'], 'B');
      final leftovers = _docs
          .listSync()
          .where((e) => e.path.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty, reason: '原子写必须自己收尾，别留 .tmp');
    });

    test('并发写（排队）：两个都不炸，最终是新值', () async {
      await Future.wait([
        Store.saveLastSession(['/m/a.mp3'], 0, 1, 'A'),
        Store.saveLastSession(['/m/b.mp3'], 0, 2, 'B'),
      ]);
      final s = await Store.loadLastSession();
      expect(s!['paths'], ['/m/b.mp3']);
      expect(
        _docs.listSync().where((e) => e.path.endsWith('.tmp')),
        isEmpty,
      );
    });

    test('路径带中文 / 空格 / 引号也能原样回来', () async {
      const paths = ['/m/我 的/歌"1".flac', '/m/日本語.mp3'];
      await Store.saveLastSession(paths, 1, 999, '带 "引号" 的歌单');
      final s = await Store.loadLastSession();
      expect(s!['paths'], paths);
      expect(s['title'], '带 "引号" 的歌单');
    });

    test('文件名常量固定（改名 = 老队列全丢）', () {
      expect(Store.kQueueFile, 'queue.json');
      expect(Store.kQueuePosMs, 'posMs');
    });
  });

  // ════════════════════════════════════════════════════════════════════════
  group('源码围栏：真身确实接了这套队列（别把纯函数测成死代码）', () {
    // 为什么要围栏：`player_service.dart` 至今零单测，而阶段 1 改的正是它。
    // 实测过——**把 `_step` 里的固定随机序整段还原成旧的现抽实现，51 项纯函数用例
    // 一行都不会红**。行为用例（`test/player_service_test.dart`）能接住大部分，
    // 但「接了没用对」的写法仍可能漏网（比如把 seed/cursor 存了却从不读回来）。
    // 这几条拿源码钉住「调用点还在、且老随机序没有复活」。
    final src = File('lib/player_service.dart').readAsStringSync();

    /// 取某个方法体（从签名到下一个同缩进的 `}` 为止）。
    String bodyOf(String signature) {
      final i = src.indexOf(signature);
      expect(i, greaterThanOrEqualTo(0), reason: '找不到「$signature」—— 是不是改名了？'
          '改名本身没问题，但改完要把这条围栏一起更新，别让它静默失效。');
      final end = src.indexOf('\n  }', i);
      expect(end, greaterThan(i), reason: '「$signature」的方法体没找到收尾');
      return src.substring(i, end);
    }

    test('老随机序（`_randomIndexOtherThan` 现抽）没有复活', () {
      expect(src.contains('_randomIndexOtherThan'), isFalse,
          reason: '旧的「每次现抽一个随机下标」实现回来了 —— 那样「下一首 → 上一首」'
              '必然漂到别处（阶段 1 的验收判据当场作废）');
    });

    test('`_rng.nextInt` 只许出现在摇种子的那个函数里', () {
      // 围栏的写法：先认「谁可以调」，再查「还有没有别人调」。
      // 旧实现正是靠 `_rng.nextInt(候选.length)` 现抽的 —— 只要这个调用出现在
      // 别的函数里，就说明随机序又绕开了 [ShuffleOrder]。
      for (final fn in ['_step(', '_nextIndex(', 'removeFromQueue(']) {
        expect(bodyOf(fn).contains('_rng.nextInt'), isFalse,
            reason: '$fn 里出现了 _rng.nextInt：随机序必须走 playback/queue.dart '
                '的 ShuffleOrder（固定种子、可复现），不能在播放服务里现抽');
      }
      expect(bodyOf('int _newShuffleSeed(').contains('_rng.nextInt'), isTrue,
          reason: '摇种子那处是 _rng.nextInt 唯一该在的地方');
    });

    test('固定随机序的三个调用点都还在：建/清游标 + 走一格 + 换队列重摇种子', () {
      expect(bodyOf('Future<void> _step(').contains('.step('), isTrue,
          reason: '_step 必须走 ShuffleOrder.step（正负方向同一条排列）');
      expect(src.contains('void _syncShuffleCursor()'), isTrue);
      expect(bodyOf('Future<void> playAt(').contains('_syncShuffleCursor()'),
          isTrue,
          reason: '切歌后要对齐随机游标，否则「上一首」是从旧位置走的');
      expect(bodyOf('Future<void> playQueue(').contains('_newShuffleSeed()'),
          isTrue,
          reason: '换整张歌单要重摇种子，否则上一张的随机序会被套到新歌单上');
    });

    test('种子与游标真的落盘了、也真的读回来了', () {
      // 写侧在 player_service 的 _persistNow（它调 Store.saveLastSession）
      expect(src.contains('seed: _shuffleSeed'), isTrue,
          reason: '种子没落盘 → 重启后随机序接不上，「上一首」回不到同一首');
      expect(src.contains('cursor: _shuffle?.cursor ?? -1'), isTrue);
      // 读侧在 library_data 的 _restoreLastSession（它把 session 交给 restoreSession）
      final data = File('lib/library_data.dart').readAsStringSync();
      expect(data.contains("session['seed']"), isTrue,
          reason: '种子存了却不读回来，等于没存');
      expect(data.contains("session['cursor']"), isTrue);
      expect(data.contains('seed: seed is int ? seed : null'), isTrue);
      expect(data.contains('cursor: cursor is int ? cursor : null'), isTrue);
    });

    test('队列落盘仍是「先写 .tmp 再原子改名」（别退回直接覆盖）', () {
      final store = File('lib/store.dart').readAsStringSync();
      final i = store.indexOf('static Future<void> _writeJsonAtomic(');
      expect(i, greaterThanOrEqualTo(0));
      final body = store.substring(i, store.indexOf('\n  }', i));
      expect(body.contains('.tmp'), isTrue);
      expect(body.contains('rename('), isTrue);
      expect(store.contains("_writeJsonAtomic(kQueueFile"), isTrue,
          reason: 'queue.json 必须走那个原子写入口，别自己 writeAsString');
    });
  });
}
