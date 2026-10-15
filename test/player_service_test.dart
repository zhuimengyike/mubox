/// `lib/player_service.dart` 的**行为**测试 —— 队列 2.0 那一刀真的接上去了没有。
///
/// 为什么非要有这个文件：`player_service.dart` 至今零单测，而队列 2.0 改的正是它。
/// 光测 `playback/queue.dart` 只能证明纯函数对 —— **把 player_service 里的接线整段
/// 还原成旧实现（现抽随机 + 手算下标），那 51 项纯函数用例一行都不会红**（已实测）。
/// 所以这里直接构造 `PlayerService` 实例、喂一个假播放器，走真代码路径：
///
/// 1. **切歌不碰播放器**：把 `AudioPlayer` 换成 [_FakeAudioPlayer]，
///    「下一首 / 上一首 / 删歌」就退化成纯下标算术，可以断言「当前曲是哪一首」；
/// 2. 随机模式下「下一首 → 上一首」必须回到**同一首**（既定的随机序语义）；
/// 3. 删当前曲之前的歌不许把正在听的那首换掉（下标算错就会换）；
/// 4. 真初始化 `init()` 走一遍：证明 `mode` 仍从 prefs 读、且只走「本地文件」
///    那条落盘路（顺带把 `init` 里那些订阅都过一遍）。
///
/// ⚠️ 这个文件是**故意的特例**：本仓 `testWidgets` = 0，这里也没有 widget，
/// 只是需要一个 `PlayerService` 实例。凡是能进纯函数的判定，仍旧一律进
/// `playback/queue.dart`（那边才有穷举）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

late Directory _docs;

/// 把真播放器整个换掉：任何一次「切歌 / 播放」都不碰原生层，
/// 于是「当前曲是哪一首」完全由 `playAt` 里的下标算术决定 —— 正好是要测的东西。
///
/// 只覆写 `PlayerService` 真会用到的那几个成员，其余交给 [noSuchMethod]
/// （假实现故意不完整：以后谁在服务里多调一个原生方法，这里会当场响）。
class _FakeAudioPlayer implements AudioPlayer {
  final List<Object> sources = [];

  /// 播放器身份：原生侧按它登记/查询 audio session（阶段 2b）——
  /// 服务会在每次起播时把"当前在场的是哪个播放器"推给三个引擎，所以这个成员
  /// 从"用不到"变成"真会读到"。假实现必须给出来（[noSuchMethod] 会当场响）。
  @override
  final String playerId = 'fake-A';

  @override
  Future<void> setSource(Source source) async => sources.add(source);

  @override
  Future<void> setSourceUrl(String url, {String? mimeType}) async =>
      sources.add(url);

  @override
  Future<void> stop() async {}

  @override
  Future<void> resume() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setPlaybackRate(double playbackRate) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setReleaseMode(ReleaseMode releaseMode) async {}

  @override
  Future<Duration?> getCurrentPosition() async => Duration.zero;

  @override
  set positionUpdater(PositionUpdater? updater) {}

  @override
  Stream<Duration> get onPositionChanged => const Stream.empty();

  @override
  Stream<Duration> get onDurationChanged => const Stream.empty();

  @override
  Stream<PlayerState> get onPlayerStateChanged => const Stream.empty();

  @override
  Stream<void> get onPlayerComplete => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假播放器没实现 ${invocation.memberName}');
}

/// 本文件建过的**全部**服务：tearDown 要等它们的落盘链走完再删临时目录。
///
/// 一个都不许漏，也不能只记「当前用例那一个」：服务从不 dispose，前一个用例的
/// 落盘可能晚一步才落，句柄就攥在那一次 `queue.json` 的写上
/// （根因 + 实测到的两种真实异常见 `support/temp_docs.dart`）。
final List<PlayerService> _live = <PlayerService>[];

PlayerService _service() {
  final ps = PlayerService(player: _FakeAudioPlayer());
  _live.add(ps);
  return ps;
}

/// 等这个服务的落盘链走完（落盘是 fire-and-forget，不等就只能 sleep 碰运气）。
Future<void> _settle(PlayerService ps) async {
  for (var i = 0; i < 5; i++) {
    await ps.debugFlushPersist();
  }
}

/// 把本文件所有服务的落盘链排空 —— `tearDown` 删目录之前的那一步（根因修复）。
Future<void> _drainPersists() async {
  for (final ps in _live) {
    await ps.debugFlushPersist();
  }
}

List<Song> _songs(int n) => [
  for (var i = 0; i < n; i++)
    Song(
      id: 1000 + i,
      title: '歌$i',
      artist: '',
      durationMs: 180000,
      uri: 'content://media/external/audio/media/${1000 + i}',
      filePath: '/m/$i.mp3',
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_svc_');
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
    // ★ 顺序不能反，三步各有用处：
    //   ① 排空落盘（此刻 path_provider 的 mock **还挂着** —— 迟到的写要能找到
    //      同一个目录，否则它会去碰真文档目录）。这一步才是根因修复：句柄放掉。
    //   ② 再拆 mock。③ 最后删目录（带重试兜住没挂在服务链上的迟到写）。
    //   以前是「先拆 mock → 删 → catch (_) {}」：每跑一轮全量就在 %TEMP% 里
    //   攒一个 mubox_svc_*，攒了好几轮没人发现（实测 errno 32 / 145）。
    await _drainPersists();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    await deleteTempDir(_docs);
  });

  group('顺序模式：切歌就是队列里挪一格', () {
    test('next / prev 在首尾之间绕回（列表循环）', () async {
      final ps = _service();
      await ps.playQueue(_songs(3), 0);
      expect(ps.current!.title, '歌0');
      await ps.next();
      expect(ps.current!.title, '歌1');
      await ps.next();
      await ps.next();
      expect(ps.current!.title, '歌0', reason: '走到底绕回第一首');
      await ps.prev();
      expect(ps.current!.title, '歌2', reason: '第一首再上一首 = 最后一首');
    });

    test('不参与循环的歌被跳过', () async {
      final ps = _service();
      final songs = _songs(3);
      await ps.playQueue(songs, 0);
      ps.setLoopEnabled(songs[1], false);
      await ps.next();
      expect(ps.current!.title, '歌2', reason: '歌1 被排除，直接跳到歌2');
      // 排除名单只影响顺序模式的选择，不影响当前曲
      ps.setLoopEnabled(songs[1], true);
      await ps.prev();
      expect(ps.current!.title, '歌1');
    });
  });

  group('★ 随机模式：固定种子序（计划书阶段 1 判据「拉回上一首能回到同一首」）', () {
    test('下一首 → 上一首，回到同一首（10 首队列，200 轮）', () async {
      final ps = _service();
      await ps.playQueue(_songs(10), 0);
      await ps.setMode('shuffle');
      for (var round = 0; round < 200; round++) {
        final start = ps.current!.id;
        await ps.next();
        expect(ps.current!.id, isNot(start), reason: '随机不该原地不动');
        await ps.prev();
        expect(ps.current!.id, start,
            reason: '第 $round 轮：回退漂到别处了（旧实现每次现抽，必然漂）');
      }
    });

    test('再往上退多步也对得上（前进 3 步 → 退 3 步回到原点）', () async {
      final ps = _service();
      await ps.playQueue(_songs(8), 2);
      await ps.setMode('shuffle');
      final start = ps.current!.id;
      final fwd = <int>[];
      for (var i = 0; i < 3; i++) {
        await ps.next();
        fwd.add(ps.current!.id);
      }
      for (var i = 2; i >= 0; i--) {
        await ps.prev();
        expect(ps.current!.id, i == 0 ? start : fwd[i - 1]);
      }
    });

    test('装满一圈 = 每首歌各播一次（不重复、不漏）', () async {
      final ps = _service();
      await ps.playQueue(_songs(6), 0);
      await ps.setMode('shuffle');
      final seen = <int>{ps.current!.id};
      for (var i = 0; i < 5; i++) {
        await ps.next();
        seen.add(ps.current!.id);
      }
      expect(seen.length, 6, reason: '6 首走 5 步应该一首不漏');
    });

    test('换队列会换一条新的随机序（不是把上一张歌单的序套过来）', () async {
      final ps = _service();
      // 这条用例真正要钉的**那一刀**：`playQueue` 里的
      //   `_shuffleSeed = _newShuffleSeed();`（换队列重摇种子）
      //   `_queueChanged();`（作废旧的随机排列）
      // 两刀**任一**被收起来，新队列就会套用上一张歌单的序 —— 这里必须红。
      //
      // ⚠️ 早先那版断言（`expect(order.first, isNot(a.first))`：6 首那轮的首元素 vs 12 首那轮的
      // 首元素）栽在两处，都已实测：
      //   ① **假红**：它比的是「两条随机排列的**首元素**不同」，12 首里撞上的概率约 1/12
      //      ⇒ 单独连跑 15 次红 2 次（另一组实测 12 次红 3 次）。注释里的 1/720 与
      //      1/4.8 亿是**另一个事件**（两条完整排列逐项相同）的概率，跟这行断言无关。
      //   ② **没牙**：两轮长度不同（6 vs 12），把重摇种子那刀收起来它**照样绿**
      //      —— 6 项的排列与 12 项的排列本来就是两条不同的排列，首元素大概率也对不上。
      //      实测：收刀后连跑 3 次全绿（种子被冻住 ⇒ 结果甚至是确定性的）。
      // ⇒ 所以改成：**同一批歌、同一个长度（12 对 12）**，比**整条排列**（12 项逐项）。
      //   同长度是关键 —— 长度不同时「整条不同」恒真（6 项列表 ≠ 12 项列表），
      //   等于没测；同长度下「不重摇种子/不作废旧排列」必然得出逐项相同的两条排列。
      final songs = _songs(12);

      // 走满一圈 = 读完整条排列（12 首走 11 步就绕回起点那一首）。
      Future<List<int>> walk() async {
        await ps.playQueue(songs, 0);
        final order = <int>[ps.current!.id];
        for (var i = 0; i < songs.length - 1; i++) {
          await ps.next();
          order.add(ps.current!.id);
        }
        return order;
      }

      await ps.setMode('shuffle');
      final a = await walk();
      final b = await walk();

      // 先钉死「走法本身是好的」：一轮必须正好 12 个互不相同的 id。
      // 走残/走空也会让下面的 isNot 得出莫名其妙的结果，先把它排除掉。
      expect(a.toSet(), hasLength(12), reason: '第一轮没走满一圈：先怀疑走法，不是种子');
      expect(b.toSet(), hasLength(12), reason: '第二轮没走满一圈');

      // ★ 断言 = **整条排列**不同（不是首元素不同，也不是「碰巧某个位置不同」）。
      expect(b, isNot(a),
          reason: '换队列没换序：种子没重摇（或旧排列没作废），上一张歌单的序被套到新队列上了');
    });
  });

  group('删歌：不该动正在听的那首（下标记错的经典现场）', () {
    test('删当前曲之前的歌 → 当前曲不变', () async {
      final ps = _service();
      final songs = _songs(4);
      await ps.playQueue(songs, 2);
      expect(ps.current!.title, '歌2');
      await ps.removeFromQueue(songs[0]);
      expect(ps.current!.title, '歌2', reason: '删了别的歌却把正在听的换掉了');
      expect(ps.queueList.length, 3);
    });

    test('删当前曲之后的歌 → 当前曲不变', () async {
      final ps = _service();
      final songs = _songs(4);
      await ps.playQueue(songs, 1);
      await ps.removeFromQueue(songs[3]);
      expect(ps.current!.title, '歌1');
    });

    test('删当前曲本身 → 后一首顶上', () async {
      final ps = _service();
      final songs = _songs(4);
      await ps.playQueue(songs, 1);
      await ps.removeFromQueue(songs[1]);
      expect(ps.current!.title, '歌2');
      expect(ps.queueList.length, 3);
    });

    test('删最后一首（= 当前曲）→ 落到新的最后一首，不越界', () async {
      final ps = _service();
      final songs = _songs(3);
      await ps.playQueue(songs, 2);
      await ps.removeFromQueue(songs[2]);
      expect(ps.current!.title, '歌1');
      expect(ps.queueList.length, 2);
    });
  });

  group('落盘：队列不写 prefs 了，写文档目录的 queue.json', () {
    test('★ 正向：切歌后 queue.json 里是完整的队列 + 当前下标 + 随机种子', () async {
      final ps = _service();
      await ps.playQueue(_songs(3), 1, title: '我喜欢');
      await ps.setMode('shuffle');
      await ps.next();
      await _settle(ps);

      final f = File('${_docs.path}/queue.json');
      expect(f.existsSync(), isTrue, reason: '队列要落在文档目录的 queue.json');
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      expect(m['paths'], ['/m/0.mp3', '/m/1.mp3', '/m/2.mp3']);
      expect(m['title'], '我喜欢');
      expect(m['index'], isA<int>());
      expect(m['seed'], isA<int>(), reason: '随机序的固定种子要一起存，重启才接得上');
      expect(m['cursor'], isA<int>());

      // 老键一个字节都不写（prefs 里不再有 last_session）
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('last_session'), isNull);
      // songs.json 那条路照旧没被动过
      expect(File('${_docs.path}/songs.json').existsSync(), isFalse);
    });

    test('无 .tmp 残留（走的是原子写入口）', () async {
      final ps = _service();
      await ps.playQueue(_songs(2), 0);
      await _settle(ps);
      expect(_docs.listSync().where((e) => e.path.endsWith('.tmp')), isEmpty);
    });
  });

  group('init()：真跑一遍初始化，证明 mode 仍从 prefs 读', () {
    test('prefs 里的 mode 生效，且不碰 last_session 那个老键', () async {
      SharedPreferences.setMockInitialValues({'mode': 'shuffle', 'speed': 1.25});
      final ps = _service();
      await ps.init().timeout(const Duration(seconds: 10));
      expect(ps.mode, 'shuffle');
      expect(ps.speed, 1.25);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('last_session'), isNull);
    });
  });
}
