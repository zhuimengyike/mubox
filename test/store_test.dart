/// `lib/store.dart` 的持久化单测。
///
/// 这个文件原先零覆盖，而它踩的坑全是「静默」的：JSON 读坏了按空处理，
/// 下一次任何写操作就把空值固化回磁盘 —— 歌单没了、私密名单没了（私密歌
/// 直接变公开），而且全程不报错。下面这几条把「读坏了要留现场」钉住。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('损坏隔离：读坏了不许静默变成空', () {
    test('私密名单坏掉时把原始串留到 private_songs_corrupt', () async {
      SharedPreferences.setMockInitialValues({'private_songs': '{"不是数组"'});
      expect(await Store.loadPrivateSongs(), isEmpty);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('private_songs_corrupt'), '{"不是数组"');
    });

    test('歌单 / 全部歌曲顺序 / 收藏 同样留现场', () async {
      SharedPreferences.setMockInitialValues({
        'playlists': '坏',
        'all_order': '[1,2,',
        'fav_songs': 'nope',
      });
      expect(await Store.loadPlaylists(), isEmpty);
      expect(await Store.loadAllOrder(), isEmpty);
      expect(await Store.loadFavs(), isEmpty);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('playlists_corrupt'), '坏');
      expect(sp.getString('all_order_corrupt'), '[1,2,');
      expect(sp.getString('fav_songs_corrupt'), 'nope');
    });

    test('类型不对（数组里混了字符串）也算坏，不能抛到调用方', () async {
      SharedPreferences.setMockInitialValues({
        'private_songs': '["/a.mp3", 123]',
      });
      expect(await Store.loadPrivateSongs(), isEmpty);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('private_songs_corrupt'), '["/a.mp3", 123]');
    });

    test('已经有一份现场时不覆盖（留最早那次）', () async {
      SharedPreferences.setMockInitialValues({
        'fav_songs': '第一次坏',
        'fav_songs_corrupt': '更早的现场',
      });
      expect(await Store.loadFavs(), isEmpty);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('fav_songs_corrupt'), '更早的现场');
    });

    test('没存过 ≠ 坏了：不写现场键', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await Store.loadPlaylists(), isEmpty);
      final sp = await SharedPreferences.getInstance();
      expect(sp.containsKey('playlists_corrupt'), isFalse);
    });

    test('正常数据照常读出来（隔离层不影响好数据）', () async {
      SharedPreferences.setMockInitialValues({
        'private_songs': jsonEncode(['/a.mp3']),
        'playlists': jsonEncode({
          '我': [1, 2],
        }),
      });
      expect(await Store.loadPrivateSongs(), {'/a.mp3'});
      expect(await Store.loadPlaylists(), {
        '我': [1, 2],
      });
    });
  });

  group('歌词校准的旧数据迁移', () {
    test('没有新键时才把旧的单点偏移迁过来', () async {
      SharedPreferences.setMockInitialValues({
        'lyric_offsets': jsonEncode({'/a.mp3': 500}),
      });
      final m = await Store.loadCalibration();
      expect(m['/a.mp3']!.single.offsetMs, 500);
      expect(m['/a.mp3']!.single.timeMs, 0);
    });

    test('新键坏掉时**不**走迁移，免得把现场盖掉', () async {
      SharedPreferences.setMockInitialValues({
        'lyric_calibration': '不是 JSON',
        'lyric_offsets': jsonEncode({'/a.mp3': 500}),
      });
      expect(await Store.loadCalibration(), isEmpty);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('lyric_calibration_corrupt'), '不是 JSON');
      // 关键：坏掉的原值必须原封不动留着，没被迁移结果覆盖
      expect(sp.getString('lyric_calibration'), '不是 JSON');
    });
  });

  group('播放历史', () {
    test('按 filePath 往返', () async {
      SharedPreferences.setMockInitialValues({});
      await Store.saveHistory(['/m/1.mp3', '/m/2.mp3']);
      expect(await Store.loadHistory(), ['/m/1.mp3', '/m/2.mp3']);
    });

    test('无记录返回空列表', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await Store.loadHistory(), isEmpty);
    });

    test('坏数据返回空列表并留现场', () async {
      SharedPreferences.setMockInitialValues({'play_history': '[1,2]'});
      expect(await Store.loadHistory(), isEmpty);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('play_history_corrupt'), '[1,2]');
    });
  });

  group('备份忽略私密歌的开关', () {
    test('默认开启（防私密歌被备份带走）', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await Store.loadBackupSkipPrivate(), isTrue);
    });

    test('关掉之后记得住', () async {
      SharedPreferences.setMockInitialValues({});
      await Store.saveBackupSkipPrivate(false);
      expect(await Store.loadBackupSkipPrivate(), isFalse);
    });
  });
}
