/// **`songs.json` 损坏后，只存在于 `docs/music/` 里的歌永久消失**。
///
/// ## 故障链（行号以本文件写作时的源码为准）
/// 1. `store.dart` 的 `loadSongs`：整个文件不是合法 JSON ⇒ 留一份 `songs.json.corrupt`
///    ⇒ **返回 `[]`**；
/// 2. `library_data.dart` 的 `_doInit`：空列表 = 「无缓存」⇒ 全量重扫 + 重新索要权限；
/// 3. 扫描范围（`kScanRoots`）= MediaStore + `/Music` `/Download` `/Documents`
///    ⇒ **App 私有目录 `docs/music/` 不在其中**；
/// 4. ⇒ 内部副本里那些歌（**在线下载的**、**原文件已被用户删掉的**）整批从库里消失，
///    且没有任何入口能找回 —— 文件还在磁盘上，成了孤儿。
///
/// ## 这里测什么
/// * 纯逻辑 `planOrphanRescue`（判定：谁是孤儿 / 谁不许救回来 / 身份怎么算）；
/// * **真 `Library`**走一遍启动那条路（挡掉 path_provider 与 on_audio_query 两条通道）：
///   损坏索引 + 3 个内部副本 ⇒ 库里必须重新有 3 首，且歌单 / 自定义歌名 / 私密名单
///   这些「按内部路径存」的键**自动重新对上**（身份 = 内部副本路径的散列）；
/// * 负向：索引**没坏**时这条路一个字节都不写（字节 + mtime 都不许变）。
///
/// ⚠️ 量具口径：这里读的是**真 `Library.instance.songs`** 与**真磁盘文件**，
/// 不是"看代码里有没有那一行"。假播放器只用来让 `PlayerService.init()` 跑得起来
/// （`Library._doInit` 第一句就 `await playerService!.init()`），它一次原生调用都不许发生。
library;

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

const MethodChannel _kPathProvider =
    MethodChannel('plugins.flutter.io/path_provider');
const MethodChannel _kAudioQuery =
    MethodChannel('com.lucasjosino.on_audio_query');

late Directory _docs;
late Directory _music;

/// 音乐库权限通道回什么（用例中途可翻）。缺省「已授权」。
bool _granted = true;

/// 哑播放器：只让 `PlayerService.init()` 能跑完（它挂四条流订阅 + 装位置轮询器），
/// 一步原生调用都不走。没用到的成员一律抛 —— 服务里多调一个原生成员会当场响。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub-rescue';

  @override
  Future<void> setReleaseMode(ReleaseMode releaseMode) async {}

  @override
  Future<Duration?> getCurrentPosition() async => Duration.zero;

  @override
  set positionUpdater(PositionUpdater? updater) {}

  @override
  Stream<Duration> get onPositionChanged => const Stream<Duration>.empty();

  @override
  Stream<Duration> get onDurationChanged => const Stream<Duration>.empty();

  @override
  Stream<PlayerState> get onPlayerStateChanged =>
      const Stream<PlayerState>.empty();

  @override
  Stream<void> get onPlayerComplete => const Stream<void>.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假播放器没实现 ${invocation.memberName}');
}

/// 造一个「内部副本」文件（内容无所谓，本缺陷只看文件名与存在性）。
File _orphan(String name) => File('${_music.path}/$name')..writeAsStringSync('x');

/// 走一遍**启动那条路**（`reload()` 内部就是 `init()` → `_doInit()`），
/// 失败时把当前状态打出来，免得只剩一句"期望 3 实际 0"。
Future<void> _boot() async {
  await Library.instance.reload();
  final lib = Library.instance;
  // ignore: avoid_print
  print(
    'RESCUE: songs=${lib.songs.length} '
    'loading=${lib.loading} permDenied=${lib.permDenied} '
    'files=${lib.songs.map((s) => basenameOf(s.filePath)).toList()}',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _docs = Directory.systemTemp.createTempSync('mubox_rescue_');
    _music = Directory('${_docs.path}/music')..createSync(recursive: true);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPathProvider, (call) async => _docs.path);
    // 音乐库权限走 on_audio_query 的通道：给「已授权 + 扫到 0 首」的最干净现场
    // （本缺陷关心的是**内部副本**那一路，MediaStore 有没有歌都无所谓）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kAudioQuery, (call) async {
      if (call.method == 'permissionsRequest') return _granted;
      if (call.method == 'querySongs') return <Object?>[];
      return null;
    });
    _granted = true;
    playerService = PlayerService(player: _StubPlayer());
  });

  tearDown(() async {
    playerService = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPathProvider, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kAudioQuery, null);
    await deleteTempDir(_docs);
  });

  // ───────────────────────── 纯逻辑 ─────────────────────────

  group('planOrphanRescue：谁是孤儿 / 谁不许救回来（纯函数）', () {
    List<Song> plan(
      List<String> files, {
      Set<String> known = const {},
      Set<String> deleted = const {},
    }) => planOrphanRescue(
      '/docs/music',
      fileNames: files,
      knownNames: known,
      deletedPaths: deleted,
    );

    test('N 个音频文件 ⇒ N 首歌；身份 = 内部副本路径的散列，元数据一律留空', () {
      final songs = plan(['b.mp3', 'a.flac', 'c.m4a']);
      expect(songs, hasLength(3));
      expect(
        songs.map((s) => basenameOf(s.filePath)).toList(),
        ['a.flac', 'b.mp3', 'c.m4a'],
        reason: '顺序必须确定（列目录顺序不保证）：按路径排序',
      );
      for (final s in songs) {
        expect(s.filePath, '/docs/music/${basenameOf(s.filePath)}');
        expect(s.id, stableIdOfPath(s.filePath),
            reason: '身份 = 内部副本路径的散列，歌单/私密/收藏才认得出它');
        expect(s.durationMs, 0, reason: '时长救不回来就留 0（播放后回写），不许猜');
        expect(s.uri, '');
        expect(s.albumId, isNull);
        expect(s.srcPath, '', reason: '源路径已不可知（下载进来的歌本来就是空）');
        expect(s.title.isNotEmpty, isTrue);
      }
    });

    test('歌名按既有规则从文件名推（与 songFromFilePath 逐项一致，不另发明一套）', () {
      final s = plan(['周杰伦 - 告白气球.mp3']).single;
      final ref = songFromFilePath('/docs/music/周杰伦 - 告白气球.mp3');
      expect(s.title, ref.title);
      expect(s.artist, ref.artist);
      expect(s.title, '告白气球');
      expect(s.artist, '周杰伦');
    });

    test('库里已经认识的名字一个都不加（正常路径「零副作用」的纯逻辑那一半）', () {
      expect(plan(['a.mp3', 'b.mp3'], known: {'a.mp3', 'b.mp3'}), isEmpty);
      expect(plan(['a.mp3', 'b.mp3'], known: {'a.mp3'}), hasLength(1));
    });

    test('非音频扩展名一律不当歌（.nomedia / 封面 / 临时文件 / 无扩展名）', () {
      expect(
        plan(['.nomedia', 'cover.jpg', 'x.mp3.tmp', 'noext', 'ok.mp3']),
        hasLength(1),
      );
      expect(plan(['OK.MP3']).single.filePath.endsWith('OK.MP3'), isTrue,
          reason: '扩展名大小写不敏感（大小写只在比对时降级，路径原名不改）');
    });

    test('黑名单命中的不许救回来（basename 形态 + 绝对源路径形态都认）', () {
      final songs = plan(
        ['gone.mp3', 'old.mp3', 'keep.mp3'],
        deleted: {
          'gone.mp3', // srcPath 为空时存下的形态（下载进来的歌）
          '/storage/emulated/0/Music/old.mp3', // 删歌时存下的原始源路径
        },
      );
      expect(songs.map((s) => basenameOf(s.filePath)).toList(), ['keep.mp3'],
          reason: '★ 被用户删过的歌不许被「救」回来');
    });

    test('文件名重复只算一次、空名跳过（同一目录内名字唯一，防御性去重）', () {
      expect(plan(['a.mp3', 'a.mp3', '', 'b.mp3']), hasLength(2));
    });

    test('结果与输入顺序无关（列目录顺序每次都可能不同）', () {
      final a = plan(['b.mp3', 'a.mp3', 'c.mp3']);
      final b = plan(['c.mp3', 'b.mp3', 'a.mp3']);
      expect(
        a.map((s) => s.filePath).toList(),
        b.map((s) => s.filePath).toList(),
      );
    });
  });

  // ───────────────────────── 真 Library 走一遍 ─────────────────────────

  group('真 Library：损坏的 songs.json + 内部副本还在', () {
    test('★1 正向：3 个孤儿内部副本 ⇒ 库里重新有那 3 首（改前是 0 首）', () async {
      _orphan('a.mp3');
      _orphan('b.flac');
      _orphan('c.m4a');
      // 现场：整个索引不是合法 JSON
      File('${_docs.path}/songs.json').writeAsStringSync('{ 这不是 json');

      await _boot();

      final lib = Library.instance;
      expect(lib.permDenied, isFalse);
      expect(
        lib.songs.map((s) => basenameOf(s.filePath)).toList(),
        ['a.mp3', 'b.flac', 'c.m4a'],
        reason: '★ 索引坏了就把内部副本里的歌整批丢掉 = 缺陷②',
      );
      for (final s in lib.songs) {
        expect(s.filePath, '${_music.path}/${basenameOf(s.filePath)}');
        expect(s.id, stableIdOfPath(s.filePath));
      }
      expect(lib.songsOf(kAllSongs), hasLength(3), reason: '要能在「全部歌曲」里看见');
      expect(File('${_docs.path}/songs.json.corrupt').existsSync(), isTrue,
          reason: '坏索引要按既有约定留现场');
      // 救回来的东西必须**落盘**：否则下次启动又白救一遍
      final onDisk = await Store.loadSongs();
      expect(onDisk.map((s) => basenameOf(s.filePath)).toList(),
          ['a.mp3', 'b.flac', 'c.m4a']);
    });

    test('★2 既有语义不许破坏：歌单 / 自定义歌名 / 私密名单仍然认得出这些歌', () async {
      final secret = _orphan('secret.mp3');
      final normal = _orphan('normal.mp3');
      File('${_docs.path}/songs.json').writeAsStringSync('坏了');
      // 这三份都是**按内部副本路径（或它的散列 id）存**的，正是身份约定的用处
      await Store.savePlaylists({
        '我的最爱': [stableIdOfPath(normal.path)],
      });
      await Store.saveTitleOverride(normal.path, '我改过的歌名');
      await Store.savePrivateSongs({secret.path});

      await _boot();
      final lib = Library.instance;

      expect(lib.songs, hasLength(2));
      expect(lib.songsOf('我的最爱').single.filePath, normal.path,
          reason: '★ 歌单存的是稳定 id，救回来的歌必须还是原来那条歌单条目');
      expect(
        lib.displayTitle(
          lib.songs.firstWhere((s) => s.filePath == normal.path),
        ),
        '我改过的歌名',
        reason: '★ 自定义歌名按 filePath 存，身份对上就自动回来',
      );
      expect(
        lib.isPrivate(lib.songs.firstWhere((s) => s.filePath == secret.path)),
        isTrue,
        reason: '★ 私密歌救回来还得是私密（不许漏进公共列表）',
      );
      expect(
        lib.songsOf(kAllSongs).map((s) => basenameOf(s.filePath)).toList(),
        ['normal.mp3'],
        reason: '★ 私密歌不许出现在公共歌单里',
      );
      expect(lib.privateSongs.map((s) => basenameOf(s.filePath)).toList(),
          ['secret.mp3']);
    });

    test('★3 黑名单：用户删过的歌不许被「救」回来', () async {
      _orphan('gone.mp3');
      _orphan('keep.mp3');
      File('${_docs.path}/songs.json').writeAsStringSync('坏了');
      await Store.saveDeletedPaths({'/storage/emulated/0/Music/gone.mp3'});

      await _boot();

      expect(
        Library.instance.songs.map((s) => basenameOf(s.filePath)).toList(),
        ['keep.mp3'],
        reason: '★ 删歌黑名单里的（源路径形态）不许被救回来',
      );
    });

    test('★4 负向（零副作用）：songs.json 正常时，孤儿一个都不加、且一个字节都不写', () async {
      final inLib = _orphan('inlib.mp3');
      _orphan('orphan.mp3'); // 库里没有它 —— 但这条路**不该**去救
      await Store.saveSongs([
        Song(
          id: stableIdOfPath(inLib.path),
          title: '在库歌',
          artist: '',
          durationMs: 1000,
          uri: '',
          filePath: inLib.path,
        ),
      ]);
      // 一次性 albumId 迁移标记：真机上跑过一轮的库就是 true
      // （不然 `needsAlbumId` 会让正常启动也走一次重扫，那是既有行为、与本缺陷无关）
      final sp = await SharedPreferences.getInstance();
      await sp.setBool('album_id_migrated', true);

      final json = File('${_docs.path}/songs.json');
      final before = json.readAsBytesSync();
      final beforeMtime = json.statSync().modified;

      await _boot();

      expect(Library.instance.songs, hasLength(1),
          reason: '★ 索引没坏就不许走挽救那条路（孤儿一个都不许加）');
      expect(basenameOf(Library.instance.songs.single.filePath), 'inlib.mp3');
      expect(json.readAsBytesSync(), orderedEquals(before),
          reason: '★ songs.json 一个字节都不许动');
      expect(json.statSync().modified, beforeMtime,
          reason: '★ 连「原样重写一遍」都不许 —— 字节相同也会换 mtime，这条抓的就是它');
    });

    test('★5 内部副本目录空着时：损坏索引也只扫出 0 首（挽救不是凭空造歌）', () async {
      File('${_docs.path}/songs.json').writeAsStringSync('坏了');
      await _boot();
      expect(Library.instance.songs, isEmpty);
      expect(Library.instance.permDenied, isFalse);
    });

    test('★6 索引坏了 + 先拒权限 + 随后授权 ⇒ 点「重新授权」这一趟就要救回来', () async {
      _orphan('a.mp3');
      File('${_docs.path}/songs.json').writeAsStringSync('坏了');
      _granted = false; // 权限被拒：`_scanAndSave` 在权限闸门就早退了，救不了
      await _boot();
      expect(Library.instance.permDenied, isTrue);
      expect(Library.instance.songs, isEmpty, reason: '前置：这一趟确实什么都没扫到');

      _granted = true; // 用户在系统弹窗里点了允许
      await Library.instance.retry();
      // ignore: avoid_print
      print('RESCUE retry: songs=${Library.instance.songs.length}');
      expect(Library.instance.permDenied, isFalse);
      expect(
        Library.instance.songs.map((s) => basenameOf(s.filePath)).toList(),
        ['a.mp3'],
        reason: '★ 授权那一趟就该救回来，别等下次冷启动',
      );
    });
  });
}
