/// **通知栏大图是 `PlayerService.mediaItem` 的一份快照** —— 换/删歌曲图标之后
/// 必须重推，否则通知栏继续显示旧图（E2 发现的同族 bug，与「改名不刷新」同一个病）。
///
/// 症状：给**正在播放**的那首歌换图标（歌曲行 ⋮ →「设置歌曲图标」），通知栏大图不刷新。
///
/// ## 保真度锚点 —— 真实现走哪条路（本机逐行核过）
///
/// 1. 通知栏大图的**唯一来源**是 `mediaItem` 这条流里的 `artUri`
///    （`lib/player_service.dart:724-736` 的 `_mediaItem()` 造，
///    `:753` 的 `refreshMediaItem()` / `:704` / `:784` 推）；
///    `:732` 的 `ArtworkStore.uriFor(s)` 就是「有没有本地图标」那一档。
/// 2. audio_service 侧订阅它并转给原生：
///    `audio_service-0.18.19\lib\audio_service.dart:1031`
///    `_handler.mediaItem.listen(...)` → `:1040`/`:1054`
///    `_platform.setMediaItem(...)` → 原生 `setMetadata()` → 通知栏刷新
///    （整条链的锚点见 `player_service_media_title_test.dart` 文件头，同一套）。
/// 3. ★ **修复点在页面**：
///    `lib/pages/playlists_page.dart` 的模块级 `saveArtwork()` /
///    `refreshArtworkIfCurrent()` —— `PlaylistsPage._setArtwork()` 与
///    `_deleteArtwork()` 都走它们（`:1139` / `:1120` 一带）。
///    本文件**直接驱动这两个函数**，不另抄一份逻辑。
///    ⛔ 为什么不用 `testWidgets` 驱动整页：那要过相册选图
///    （`ImagePicker.pickImage`）+ 裁剪页 `Navigator.push`，本机起不来。
///    这是**既有的**结构性限制，不是图省事（同一条限制的记录见
///    `test/player_bar_colors_test.dart:513-526`）。
///
/// ⇒ 「通知栏大图变没变」**等价于**「`ps.mediaItem.value!.artUri` 变没变」。
/// 本文件断言的**就是后者**（❌ 不是 `ArtworkStore.uriFor()` 的返回值 ——
/// 那个在写完文件那一刻就已经是新的了，它绿着也证明不了通知栏会变）。
///
/// ## 负向（把修复收起来必须红）
/// 把 `saveArtwork` 里那句 `refreshArtworkIfCurrent(...)` 收掉，
/// **★1 / ★2 两条立刻红**（通知栏还挂着推之前的那一份）。
library;

import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/artwork.dart';
import 'package:mu_box_phone/library_core.dart';
import 'package:mu_box_phone/library_data.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/pages/playlists_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

late Directory _docs;

/// 假播放器：只实现 `PlayerService` 真会用到的那几个成员，其余交给 [noSuchMethod]
/// 当场响 —— 以后谁在服务里多调一个原生方法，这里会立刻炸出来。
/// （与 `player_service_media_title_test.dart` 同一副牌。）
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

/// 本文件建过的**全部**服务：tearDown 要等它们的落盘链走完再删临时目录。
final List<PlayerService> _live = <PlayerService>[];

PlayerService _service() {
  final ps = PlayerService(player: _FakePlayer());
  // ★ 与应用入口**同一套接线**：`main.dart:28` 的 `AudioService.init` builder 里
  //   `playerService = PlayerService();`。页面里的 `_player` 取的就是这个全局。
  playerService = ps;
  _live.add(ps);
  return ps;
}

/// 三首歌。`filePath` 一律按**内部副本**的形状给（身份 = 内部副本路径的散列）。
List<Song> _songs(String tag) => [
  for (var i = 0; i < 3; i++)
    Song(
      id: stableIdOfPath('/docs/$tag/music/$i.mp3'),
      title: '歌$i',
      artist: '',
      durationMs: 180000,
      uri: 'content://media/external/audio/media/${1000 + i}',
      filePath: '/docs/$tag/music/$i.mp3',
      srcPath: '/storage/emulated/0/Music/$i.mp3',
    ),
];

/// 当前通知栏上挂着的那一份的 artUri（`null` = 还没推过 / 没有图）。
Uri? _notifyArtUri(PlayerService ps) => ps.mediaItem.value?.artUri;

/// 伪造「通知栏还挂着修复前那一份」的状态。
///
/// ⚠️ 这一步**不能省**：只断言最后那句「之后是新的」的话，基线（没人重推）
/// 下 `mediaItem` **从头到尾一直是 null**，末句「新 artUri 非 null」照样红、
/// 但「删掉之后回到 null」那条会**假绿**。先塞一个哨兵值，两条才有牙。
/// （与 `player_service_media_title_test.dart:207-211` 同一个手法。）
void _staleNotification(PlayerService ps) {
  ps.mediaItem.add(const MediaItem(id: 'stale', title: '旧的一份'));
  expect(_notifyArtUri(ps), isNull, reason: '哨兵已就位：通知栏挂的是「没有大图」');
}

final Uint8List _iconBytes = Uint8List.fromList(List<int>.generate(8, (i) => i));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    // ★ 全部用例共用**一个**临时目录：`ArtworkStore._dirPath` 是**静态**且
    //   `ensureInit()` 一旦成功就早退（`artwork.dart:38-39`），每个用例换新目录
    //   也换不掉它。共用 + 文件名互不重复（`_songs('用例名')`）才是干净的做法。
    _docs = Directory.systemTemp.createTempSync('mubox_artnotify_');
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => _docs.path,
        'getTemporaryDirectory' => _docs.path,
        _ => null,
      };
    });
    SharedPreferences.setMockInitialValues({});
    // 曲库是单例：每个用例都从干净状态起步
    Library.instance.songs = [];
    Library.instance.titles = {};
    Library.instance.playlists = {};
    Library.instance.allOrder = [];
  });

  tearDown(() async {
    playerService = null; // 全局接线不许漏到下一个用例
    for (final ps in _live) {
      await ps.debugFlushPersist();
    }
    _live.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
  });

  tearDownAll(() async {
    await deleteTempDir(_docs);
  });

  group('★ 核心判据：给当前播放的歌换/删图标 ⇒ 通知栏的 artUri 必须跟着变', () {
    test('★1 存图标：mediaItem.artUri 必须变成新图标的 file:// URI', () async {
      final songs = _songs('set');
      Library.instance.songs = songs;
      await ArtworkStore.ensureInit(); // App 里由 Library._doInit 调（library_data:106）
      final ps = _service();
      await ps.playQueue(songs, 0);

      expect(_notifyArtUri(ps), isNull, reason: '起播时这首歌还没有图标');

      // 哨兵：模拟「通知栏还挂着修复前推的那一份」
      _staleNotification(ps);

      // ★ 这一行就是这次修复的入口（`PlaylistsPage._setArtwork` 走的就是它）
      await saveArtwork(songs[0], _iconBytes, ps);

      final after = _notifyArtUri(ps);
      expect(
        after,
        isNotNull,
        reason: '图标存进缓存了，可没人重推 mediaItem ⇒ 通知栏还挂着旧的那一份。'
            '`ArtworkStore.revision` 只让**界面**重画，它跟通知栏是两条路',
      );
      // ⚠️ 别拿 `Directory.path`（在 Windows 上是反斜杠）去 contains
      //    `Uri.path`（是正斜杠）—— 两边分隔符与盘符写法都不一样。
      //    统一成正斜杠再比（实测：第一版就是这么红的）。
      final dirPosix =
          '${_docs.path}/artwork/'.replaceAll(r'\', '/');
      expect(after!.path.replaceAll(r'\', '/'), contains(dirPosix),
          reason: '推上去的得是缓存目录里的那份图');
      expect(after.path, endsWith('0.jpg'));
      expect(ArtworkStore.has(songs[0]), isTrue, reason: '字节确实落盘了');
    });

    test('★2 删图标：mediaItem.artUri 必须回到 null（不许继续显示已删的图）', () async {
      final songs = _songs('del');
      Library.instance.songs = songs;
      await ArtworkStore.ensureInit();
      final ps = _service();
      await ps.playQueue(songs, 0);

      await saveArtwork(songs[0], _iconBytes, ps);
      final live = _notifyArtUri(ps);
      expect(live, isNotNull, reason: '先存一张，通知栏才有图可删');

      // ★ 哨兵必须是一个**非 null 的**旧 artUri，不能是 null。
      //   第一版这里塞的是 artUri: null —— 于是「删完还是 null」在**基线**
      //   （没人重推）下也照样绿 ⇒ 那是一条**死断言**，量不出这个 bug
      //   （实测：把修复收起来跑负向，★2 照样绿，是★1/★4 红才暴露的）。
      //   `file:///stale/old.jpg` 这个路径**不存在**：重推之后它必须消失，
      //   因为 `ArtworkStore.uriFor()` 查的是内存索引 + 文件存在性。
      ps.mediaItem.add(MediaItem(
        id: 'del',
        title: '旧的一份',
        artUri: Uri.parse('file:///stale/old.jpg'),
      ));
      expect(_notifyArtUri(ps)!.path, '/stale/old.jpg', reason: '哨兵已就位：挂的是那张已删的旧图');

      // ★ 真入口：`PlaylistsPage._deleteArtwork` 走的就是这两句
      await ArtworkStore.remove(songs[0]);
      refreshArtworkIfCurrent(songs[0], ps);

      expect(
        _notifyArtUri(ps),
        isNull,
        reason: '图删了，通知栏却还挂着 —— 不重推的话大图会一直显示已删掉的那张',
      );
      expect(ArtworkStore.has(songs[0]), isFalse);
      expect(ArtworkStore.uriFor(songs[0]), isNull);
    });
  });

  group('负向 / 边界：改的不是当前曲时不许动通知栏', () {
    test('★3 给**非当前播放**的歌存图标 ⇒ 通知栏一个字节都不许动', () async {
      final songs = _songs('other');
      Library.instance.songs = songs;
      await ArtworkStore.ensureInit();
      final ps = _service();
      await ps.playQueue(songs, 0);

      _staleNotification(ps);

      // 改的是第 2 首，当前播放的是第 1 首
      await saveArtwork(songs[1], _iconBytes, ps);

      expect(
        _notifyArtUri(ps),
        isNull,
        reason: '通知栏挂的是当前曲（歌0）；拿歌1 的图去覆盖它 = 显示错歌的大图'
            '（与「改名不许动非当前曲的通知栏」同一条规矩）',
      );
      expect(ArtworkStore.has(songs[1]), isTrue, reason: '图该存还是要存');

      // 切过去才该拿到那张图 —— 切歌这条路本来就重推 mediaItem
      await ps.next();
      expect(_notifyArtUri(ps), isNotNull, reason: '切到歌1 时才把它的图推上去');
      expect(_notifyArtUri(ps)!.path, endsWith('1.jpg'));
    });

    test('★4 换第二张图标（同一首歌）⇒ 通知栏必须换成新的那份缓存文件', () async {
      final songs = _songs('swap');
      Library.instance.songs = songs;
      await ArtworkStore.ensureInit();
      final ps = _service();
      await ps.playQueue(songs, 0);

      await saveArtwork(songs[0], _iconBytes, ps);
      final first = _notifyArtUri(ps);
      expect(first, isNotNull);

      // 同一首歌换图标：**文件名不变、内容变了**（见 artwork.dart 的 save 注释）
      await saveArtwork(songs[0], Uint8List.fromList([9, 9, 9]), ps);

      expect(
        _notifyArtUri(ps),
        isNotNull,
        reason: '换图标之后通知栏也得重推一次（推的是同一路径的新内容）',
      );
      expect(_notifyArtUri(ps)!.path, first!.path,
          reason: '同一首歌的缓存路径不变，靠 evict + 重推让两边都换新图');
      expect(ArtworkStore.has(songs[0]), isTrue);
    });

    test('★5 没有当前曲（还没播过）⇒ saveArtwork 不许炸', () async {
      final songs = _songs('idle');
      Library.instance.songs = songs;
      await ArtworkStore.ensureInit();
      final ps = _service(); // 没调 playQueue ⇒ ps.current == null

      await saveArtwork(songs[0], _iconBytes, ps);

      expect(ArtworkStore.has(songs[0]), isTrue, reason: '图照样该存进去');
      expect(ps.mediaItem.value, isNull, reason: '没有当前曲，什么都不该推');
    });
  });
}
