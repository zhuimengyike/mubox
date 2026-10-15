/// **「备份忽略私密」只过滤了 `music/` 里的音频，名单照样出门**。
///
/// ## 原样（改前，`backup_service.dart`）
/// * `prefs.json` = SharedPreferences 里**除 `flutter.` 前缀外的全部键** ——
///   没排除 `private_songs`（私密名单本体），也没排除 `play_history`
///   （私密歌会进播放历史，见 `player_service.dart` 的注释）；
/// * `songs.json` 原文件直接进包：里面是**明文** `title`/`artist`/`filePath`；
/// * `lyrics/` `imported_lyrics/` `sub_lyrics/` `artwork/` 里的文件是**一歌一名**的
///   （`<内部副本主名>.lrc/.sub.json/.jpg`）—— 私密歌的音频没进包，它的歌词文件名进去了。
/// ⇒ 拿到 zip 的人能数出有几首私密歌、叫什么名字、路径是什么。
///
/// ## 这里测什么（真跑 `BackupService.createBackup()`，翻真 zip）
/// * 正向（默认 `backup_skip_private=true`）：造一份「公开歌 + 私密歌」的完整用户数据，
///   断言 zip 里**任何一处**（条目名 + 条目内容）都不出现私密歌的名字/路径，
///   而公开歌的那几份**一个都不少**、其余 prefs 键原样还在；
/// * 反向（`backup_skip_private=false`）：私密歌的**音频**必须照旧进包
///   （证明只改了「名单」那一路，没把用户的选择也砍掉）。
///
/// ⚠️ 量具口径：断言读的是**真 zip 的条目名与内容**，不是"看代码里有没有那几行"。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/backup_service.dart';
import 'package:mu_box_phone/library_core.dart';
import 'package:mu_box_phone/library_data.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

late Directory _docs;
late Directory _tmp;

const String _pubName = '公开歌名.mp3';
const String _secName = '秘密歌名.mp3';
const String _pubTitle = '公开自定义歌名';
const String _secTitle = '秘密自定义歌名';

String get _pubPath => '${_docs.path}/music/$_pubName';
String get _secPath => '${_docs.path}/music/$_secName';

/// 私密歌的身份探针：zip 里**任何一处**都不许出现它们
/// （覆盖「条目名」与「条目内容」两条通道，也包括我没枚举到的通道）。
List<String> get _needles => ['秘密', _secPath];

Song get _secretSong => Song(
  id: stableIdOfPath(_secPath),
  title: '秘密歌名',
  artist: '秘密歌手',
  durationMs: 3000,
  uri: '',
  filePath: _secPath,
);

/// 造一份带私密歌的完整现场：音频 + 歌词/译文/封面 + 索引 + prefs。
Future<void> _fixture({required bool withPrivateAudio}) async {
  void w(String rel, String body) {
    final f = File('${_docs.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(body);
  }

  w('music/$_pubName', 'pub-audio');
  if (withPrivateAudio) w('music/$_secName', 'sec-audio');
  w('lyrics/公开歌名.lrc', '[00:01.00]hello');
  w('lyrics/秘密歌名.lrc', '[00:01.00]secret');
  w('imported_lyrics/秘密歌名.lrc', '[00:01.00]secret');
  w('sub_lyrics/公开歌名.sub.json', jsonEncode(['译文']));
  w('sub_lyrics/秘密歌名.sub.json', jsonEncode(['秘密译文']));
  w('artwork/公开歌名.jpg', 'pub-art');
  w('artwork/秘密歌名.jpg', 'sec-art');
  w('wallpapers/w.jpg', 'wall');
  w('visual_presets/p.png', 'preset');

  // songs.json：两份明文的记录（私密那份必须被摘掉）
  await Store.saveSongs([
    Song(
      id: stableIdOfPath(_pubPath),
      title: '公开歌名',
      artist: '公开歌手',
      durationMs: 1000,
      uri: '',
      filePath: _pubPath,
    ),
    _secretSong,
  ]);

  final pubId = stableIdOfPath(_pubPath);
  final secId = stableIdOfPath(_secPath);
  SharedPreferences.setMockInitialValues({
    'fav_songs': jsonEncode([_pubPath, _secPath]),
    'title_overrides': jsonEncode({_pubPath: _pubTitle, _secPath: _secTitle}),
    'playlists': jsonEncode({
      '我的歌单': [pubId, secId],
    }),
    'all_order': jsonEncode([pubId, secId]),
    'deleted_names': jsonEncode(['已删公开.mp3', _secName]),
    'instrumental_names': jsonEncode([_secName]),
    'blocked_names': jsonEncode([_secName]),
    'play_history': jsonEncode([_secPath, _pubPath]),
    'private_songs_corrupt': jsonEncode([_secName]),
    'mode': 'shuffle',
    'speed': 1.25,
    'theme_index': 3,
    'wallpaper_path': '${_docs.path}/wallpapers/w.jpg',
  });
  // 私密名单走 App 自己的入口写（`Library.setPrivate` 会一并落盘 prefs），
  // 顺带把内存里的 `privatePathSet`（`createBackup` 读的就是它）设成同一份。
  await Library.instance.setPrivate(_secretSong, value: true);
}

Archive _zipOf(String path) =>
    ZipDecoder().decodeBytes(File(path).readAsBytesSync());

Map<String, dynamic> _prefsOf(Archive a) => jsonDecode(
  utf8.decode(a.files.firstWhere((f) => f.name == 'prefs.json').content),
) as Map<String, dynamic>;

/// zip 里出现 [needles] 的地方（条目名 + 条目内容都查）。
List<String> _mentions(Archive a, List<String> needles) {
  final hits = <String>[];
  for (final f in a.files) {
    for (final n in needles) {
      if (f.name.contains(n)) hits.add('条目名：${f.name}');
    }
    if (!f.isFile) continue;
    final text = utf8.decode(f.content, allowMalformed: true);
    for (final n in needles) {
      if (text.contains(n)) hits.add('条目内容：${f.name}');
    }
  }
  return hits;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_bkpriv_');
    _tmp = Directory.systemTemp.createTempSync('mubox_bkpriv_tmp_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => _docs.path,
        'getTemporaryDirectory' => _tmp.path,
        _ => null,
      };
    });
  });

  tearDown(() async {
    // 单例是全局的：把私密标记复位，别影响下一个用例 / 别的用例组
    if (Library.instance.privatePathSet.isNotEmpty) {
      await Library.instance.setPrivate(_secretSong, value: false);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    await deleteTempDir(_docs);
    await deleteTempDir(_tmp);
  });

  group('默认「备份忽略私密」：私密歌的身份一处都不许进 zip', () {
    test('★1 正向：prefs.json / songs.json / 四个目录里都找不到私密歌', () async {
      await _fixture(withPrivateAudio: true);
      final zip = _zipOf(await BackupService.createBackup());
      final names = zip.files.map((f) => f.name).toSet();

      // ① 纯名单键整键丢掉
      final prefs = _prefsOf(zip);
      expect(prefs.containsKey('private_songs'), isFalse,
          reason: '★ 私密名单本体不许进包');
      expect(prefs.containsKey('play_history'), isFalse,
          reason: '★ 私密歌会进播放历史（player_service 的注释明说）');
      expect(prefs.containsKey('private_songs_corrupt'), isFalse,
          reason: '损坏隔离现场键里也可能正是一份私密名单');

      // ② 其余键一个不少（只许摘私密条目，不许整键丢 = 丢用户数据）
      for (final k in [
        'fav_songs',
        'title_overrides',
        'playlists',
        'all_order',
        'deleted_names',
        'instrumental_names',
        'blocked_names',
        'mode',
        'speed',
        'theme_index',
        'wallpaper_path',
      ]) {
        expect(prefs.containsKey(k), isTrue, reason: '$k 整键丢了 = 用户数据少了');
      }
      final pubId = stableIdOfPath(_pubPath);
      expect(jsonDecode(prefs['fav_songs'] as String), [_pubPath],
          reason: '公开歌的收藏必须原样保留，私密那条摘掉');
      expect(jsonDecode(prefs['title_overrides'] as String), {
        _pubPath: _pubTitle,
      });
      expect(jsonDecode(prefs['playlists'] as String), {
        '我的歌单': [pubId],
      });
      expect(jsonDecode(prefs['all_order'] as String), [pubId]);
      expect(jsonDecode(prefs['deleted_names'] as String), ['已删公开.mp3']);
      expect(jsonDecode(prefs['instrumental_names'] as String), isEmpty);
      expect(prefs['mode'], 'shuffle');
      expect(prefs['speed'], 1.25);

      // ③ 索引里的私密记录摘掉，公开记录留着
      final songs = Store.decodeSongs(
        utf8.decode(zip.files.firstWhere((f) => f.name == 'songs.json').content),
      );
      expect(songs.map((s) => basenameOf(s.filePath)).toList(), [_pubName],
          reason: '★ songs.json 里是明文 title/artist/filePath');

      // ④ 一歌一名的那几个目录：私密的跳过，公开的一个不少
      expect(names.contains('music/$_secName'), isFalse);
      expect(names.contains('lyrics/秘密歌名.lrc'), isFalse);
      expect(names.contains('imported_lyrics/秘密歌名.lrc'), isFalse);
      expect(names.contains('sub_lyrics/秘密歌名.sub.json'), isFalse);
      expect(names.contains('artwork/秘密歌名.jpg'), isFalse);
      for (final n in [
        'music/$_pubName',
        'lyrics/公开歌名.lrc',
        'sub_lyrics/公开歌名.sub.json',
        'artwork/公开歌名.jpg',
        'wallpapers/w.jpg',
        'visual_presets/p.png',
      ]) {
        expect(names.contains(n), isTrue, reason: '★ 公开歌的 $n 丢了 = 砍到用户数据了');
      }

      // ⑤ 总闸：zip 里任何一处都不许出现私密歌的名字/路径
      //    （这条能抓住我没枚举到的泄漏通道 —— 有牙就靠它）
      final hits = _mentions(zip, _needles);
      // ignore: avoid_print
      print('BKUPPRIV: 提到私密歌的地方 = $hits');
      expect(hits, isEmpty, reason: '★ 签名/名字/路径在 zip 里露出来了：$hits');
    });

    test('★2 没有私密歌时：给包内容与改动前逐项相同（不误伤正常备份）', () async {
      await _fixture(withPrivateAudio: true);
      await Library.instance.setPrivate(_secretSong, value: false); // 撤销私密标记
      final zip = _zipOf(await BackupService.createBackup());
      final prefs = _prefsOf(zip);
      expect(prefs['fav_songs'], jsonEncode([_pubPath, _secPath]),
          reason: '没有私密歌 ⇒ 一个字节都不许动');
      expect(prefs['private_songs'], jsonEncode(<String>[]),
          reason: '键还在（值是空表）—— 只摘私密条目，不整键丢');
    });
  });

  group('反向：用户主动选「备份包含私密歌曲」时，音频照旧进包', () {
    test('★3 backup_skip_private=false ⇒ 私密歌的音频仍然在 zip 里', () async {
      await _fixture(withPrivateAudio: true);
      final sp = await SharedPreferences.getInstance();
      await Store.saveBackupSkipPrivate(false);
      expect(sp.getBool('backup_skip_private'), isFalse);

      final zip = _zipOf(await BackupService.createBackup());
      final names = zip.files.map((f) => f.name).toSet();
      expect(names.contains('music/$_secName'), isTrue,
          reason: '★ 用户明确要带上私密歌 ⇒ 音频必须照旧进包（不许把用户的选择一起砍掉）');
      expect(names.contains('lyrics/秘密歌名.lrc'), isTrue);
      expect(names.contains('artwork/秘密歌名.jpg'), isTrue);
      final prefs = _prefsOf(zip);
      expect(prefs.containsKey('private_songs'), isTrue,
          reason: '开关关掉 = 「这次备份可以带私密东西」：名单也照旧带上'
              '（音频条目名本身就是歌名，名单再藏也藏不住；'
              '丢掉名单反而会让恢复回来的私密歌变成公开）');
    });
  });
}
