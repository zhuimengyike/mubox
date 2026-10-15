/// **通知栏/锁屏歌名 = `PlayerService.mediaItem` 的一份快照**。
///
/// 症状：**修改歌名之后，通知栏里的歌名并不是改过的那个，而是原本的歌名**。
///
/// ## 保真度锚点 —— 真实现走哪条路（Dart → 插件 → 原生，本机逐行核过）
///
/// 1. 通知栏标题的**唯一来源**是 `mediaItem` 这条 `BehaviorSubject`
///    （`lib/player_service.dart:724-736` 造，`:704` / `:784` 推）；
/// 2. audio_service Dart 侧订阅它并转给原生：
///    `audio_service-0.18.19/lib/audio_service.dart`
///    **`:1031`** `_handler.mediaItem.listen(...)` → **`:1040`** / **`:1054`**
///    `_platform.setMediaItem(SetMediaItemRequest(mediaItem: …))`；
/// 3. 原生侧同版本插件：
///    `…\audio_service-0.18.19\android\src\main\java\com\ryanheise\audioservice\AudioServicePlugin.java`
///    **`:837`** `case "setMediaItem"` → **`:841`** `createMediaMetadata(rawMediaItem)`
///    → **`:842`** `AudioService.instance.setMetadata(mediaMetadata)`；
///    `…\AudioService.java` **`:786-804`** `setMetadata()` → `:803` 存字段、`:804`
///    `mediaSession.setMetadata(mediaMetadata)` ⇒ 通知栏/锁屏/车机的 MediaMetadata 刷新。
/// 4. ⚠️ **`queue` 那条路刷不动标题**：`AudioService.java:765-767` 的 `setQueue()`
///    只做 `mediaSession.setQueue(queue)`，**不碰当前 metadata** ⇒
///    修「通知栏歌名」只需重推 `mediaItem`，不必连带重推整个队列。
///
/// ⇒ 「通知栏歌名变没变」**等价于**「`ps.mediaItem.value!.title` 变没变」。
/// 本文件断言的**就是后者**（❌ 不是 `Library.displayTitle()` 的返回值 ——
/// 那个在改名那一刻就已经是新名了，它绿着也证明不了通知栏会变）。
///
/// ## 为什么会漏
/// `mediaItem` 只在「换歌」的几处推：`playQueue` / `restoreSession` / `playAt`。
/// **改名不改歌** —— 一次 `playAt` 都不会发生。
///
/// ⚠️ 用**真 `PlayerService`** + 假播放器（与 `player_service_test.dart` /
/// `player_service_crossfade_test.dart` 同一套路），不是把逻辑抄一份进测试里。
library;

import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/library_core.dart';
import 'package:mu_box_phone/library_data.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:mu_box_phone/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

late Directory _docs;

/// 假播放器：只实现 `PlayerService` 真会用到的那几个成员，其余交给 [noSuchMethod]
/// 当场响 —— 以后谁在服务里多调一个原生方法，这里会立刻炸出来。
class _FakePlayer implements AudioPlayer {
  @override
  final String playerId = 'fake-A';

  @override
  Future<void> setSource(Source source) async {}

  @override
  Future<void> setSourceUrl(String url, {String? mimeType}) async {}

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

/// 本文件建过的**全部**服务：tearDown 要等它们的落盘链走完再删临时目录
/// （根因与两种真实异常见 `support/temp_docs.dart`）。
final List<PlayerService> _live = <PlayerService>[];

PlayerService _service() {
  final ps = PlayerService(player: _FakePlayer());
  // ★ 与应用入口**同一套接线**：`main.dart:26-30` 的 `AudioService.init` builder 里
  //   `playerService = PlayerService();`（曲库侧就是通过这个全局找到播放服务的 ——
  //   `library_data.dart` 的 `playerService?.refreshMediaItem()` 与既有的
  //   `playerService?.pruneHistory(ids)` 同一条线）。不接这一步，
  //   `Library.instance.editTitle()` 找不到任何服务，测的就不是真实现的路径。
  playerService = ps;
  _live.add(ps);
  return ps;
}

Future<void> _drainPersists() async {
  for (final ps in _live) {
    await ps.debugFlushPersist();
  }
}

/// 三首歌。`filePath` 一律按**内部副本**的形状给（身份 = 内部副本路径的散列）。
List<Song> _songs() => [
  for (var i = 0; i < 3; i++)
    Song(
      id: stableIdOfPath('/docs/music/$i.mp3'),
      title: '歌$i',
      artist: '',
      durationMs: 180000,
      uri: 'content://media/external/audio/media/${1000 + i}',
      filePath: '/docs/music/$i.mp3',
      srcPath: '/storage/emulated/0/Music/$i.mp3',
    ),
];

/// 当前通知栏上挂着的那一份（`null` = 还没推过）。
String? _notifyTitle(PlayerService ps) => ps.mediaItem.value?.title;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_mtitle_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => _docs.path,
        'getTemporaryDirectory' => _docs.path,
        _ => null,
      };
    });
    SharedPreferences.setMockInitialValues({});
    // 曲库是单例：每个用例都从干净状态起步（上一个用例的 songs/titles 不许漏进来）
    Library.instance.songs = [];
    Library.instance.titles = {};
    Library.instance.playlists = {};
    Library.instance.allOrder = [];
  });

  tearDown(() async {
    playerService = null; // 全局接线不许漏到下一个用例
    await _drainPersists();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    await deleteTempDir(_docs);
  });

  group('★ 核心判据：当前播放的歌被改名 ⇒ 通知栏的 MediaItem 必须跟着变', () {
    test('★1 正/负向：改名后 mediaItem.title 必须是新名（基线行为 = 还挂着旧名）', () async {
      final songs = _songs();
      Library.instance.songs = songs;
      final ps = _service();
      await ps.playQueue(songs, 0);

      expect(_notifyTitle(ps), '歌0', reason: '起播时通知栏推的是原名');

      await Library.instance.editTitle(songs[0], '我改过的名字');

      // ★ 这一行就是这次修复的断言点 —— 断言在 MediaItem 上，不在 displayTitle 上。
      expect(
        _notifyTitle(ps),
        '我改过的名字',
        reason: '改名只改了曲库里的值，没人重推 mediaItem：'
            '通知栏还挂着改名前的那个快照（旧名），而 App 内已经显示新名',
      );
      // 顺带钉住「值本身确实是新的」——把两种失败分开：
      // 若这条红而上面那条也红，是取错了歌；若这条绿而上面红，就是没人重推。
      expect(Library.instance.displayTitle(songs[0]), '我改过的名字');
    });

    test('★2 清掉自定义歌名（空串）⇒ 通知栏回到歌自己的原名', () async {
      final songs = _songs();
      Library.instance.songs = songs;
      final ps = _service();
      await ps.playQueue(songs, 0);

      await Library.instance.editTitle(songs[0], '临时名');
      // ⚠️ 这一步**不能省**：只断言最后那句「清掉之后是原名」的话，
      // 基线（没人重推 mediaItem）下通知栏**从头到尾一直挂着原名**，末句照样绿
      // —— 那是一条死断言（实测：本文件第一版就是这样，基线 4 绿 1 红）。
      expect(_notifyTitle(ps), '临时名', reason: '改名后通知栏必须是「临时名」');

      await Library.instance.editTitle(songs[0], ''); // editTitle 的空串分支 = 删除覆盖
      expect(Library.instance.displayTitle(songs[0]), '歌0', reason: '覆盖已删，回落原名');
      expect(_notifyTitle(ps), '歌0', reason: '通知栏也要从「临时名」回落成原名');
    });
  });

  group('其它情形：非当前曲 / 切歌 / 重启', () {
    test('★3 改的是**非当前播放**的歌 ⇒ 通知栏不许被改掉，切过去才变', () async {
      final songs = _songs();
      Library.instance.songs = songs;
      final ps = _service();
      await ps.playQueue(songs, 0);

      await Library.instance.editTitle(songs[1], '第二首的新名');

      expect(
        _notifyTitle(ps),
        '歌0',
        reason: '改的是别的歌，通知栏（当前曲 = 歌0）一个字节都不许动',
      );

      await ps.next(); // 切到被改过名的那一首
      expect(_notifyTitle(ps), '第二首的新名', reason: '切歌这条路本来就重推 mediaItem');
    });

    test('★4 改名后再切走再切回 ⇒ 通知栏仍是新名', () async {
      final songs = _songs();
      Library.instance.songs = songs;
      final ps = _service();
      await ps.playQueue(songs, 0);
      await Library.instance.editTitle(songs[0], '我改过的名字');

      await ps.next();
      expect(_notifyTitle(ps), '歌1');
      await ps.prev();
      expect(_notifyTitle(ps), '我改过的名字', reason: '切回来时重推的那一份必须取到覆盖值');
    });

    test('★5 重启 App：覆盖按 filePath 落盘、按 filePath 读回（键不匹配的探针）', () async {
      final songs = _songs();
      Library.instance.songs = songs;
      final ps = _service();
      await ps.playQueue(songs, 0);
      await Library.instance.editTitle(songs[0], '重启后还要在');

      // ① 落盘用的键 = **内部副本的 filePath**（不是歌名、不是 MediaStore id）
      final sp = await SharedPreferences.getInstance();
      final raw = jsonDecode(sp.getString('title_overrides')!) as Map<String, dynamic>;
      expect(raw[songs[0].filePath], '重启后还要在');
      expect(raw.length, 1, reason: '只该有一条覆盖');

      // ② 「重启」= 重新走 loadTitleOverrides → mapTitleOverrides（`_doInit` 那条路，
      //    见 `library_data.dart:147` 的 `titles = await _loadAllTitles(songs)`）
      final reloaded = mapTitleOverrides(songs, await Store.loadTitleOverrides());
      expect(
        reloaded[songs[0].id],
        '重启后还要在',
        reason: '写进去的键与 displayTitle 查表用的键对不上（内部副本路径变了 / 存的是源路径）',
      );
    });
  });
}
