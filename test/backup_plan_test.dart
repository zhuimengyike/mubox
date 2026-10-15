/// `lib/backup_plan.dart` 的单测 —— 备份清单与「恢复被打断」的判定。
///
/// 这两条规则的共同点是：**错了不会当场报错，只会在很久以后以「数据没了」的形式
/// 出现**。译文目录漏出清单（H4）要等到换手机才发现；恢复没有落盘回滚点（H7）
/// 要等到恢复时被杀进程才发现。所以在这儿钉死。
///
/// 第三组：**私密歌身份过滤** —— 它错了同样不报错，
/// 只是把藏起来的歌名悄悄塞进 zip（见 `test/backup_private_test.dart` 的端到端断言）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/backup_plan.dart';

/// 一份「公开歌 + 私密歌」的身份指纹（值不重要，形态要对）。
PrivateMarks _marks() => (
  paths: {'/d/music/秘密.mp3', '/d/music/别的.mp3'},
  names: {'秘密.mp3', '别的.mp3'},
  stems: {'秘密', '别的'},
  ids: {111, 222},
);

void main() {
  group('H4：备份目录清单必须覆盖所有用户数据目录', () {
    test('译文目录 sub_lyrics 在清单里（这条就是 H4 的回归）', () {
      expect(kBackupDirs, contains('sub_lyrics'));
    });

    test('其余已知的用户数据目录也都在清单里', () {
      for (final d in [
        'music',
        'wallpapers',
        'artwork',
        'lyrics',
        'imported_lyrics',
        'visual_presets',
      ]) {
        expect(kBackupDirs, contains(d), reason: '$d 丢了 = 换机后这份数据没了');
      }
    });

    test('清单里没有重复项（重复只会让 zip 多写一遍）', () {
      expect(kBackupDirs.toSet().length, kBackupDirs.length);
    });
  });

  group('H7：恢复被打断的判定', () {
    test('没有快照 → 不动任何东西', () {
      expect(restoreRecoveryOf(null), RestoreRecovery.none);
    });

    test('快照是 pending → 回滚（上次恢复没写完就死了）', () {
      final raw = buildRollbackSnapshot({'a': 1}, state: kRestoreStatePending);
      expect(restoreRecoveryOf(raw), RestoreRecovery.rollback);
    });

    test('快照是 committed → 只删文件，别回滚（新设置已经写完了）', () {
      final raw = buildRollbackSnapshot(const {}, state: kRestoreStateCommitted);
      expect(restoreRecoveryOf(raw), RestoreRecovery.discard);
    });

    test('快照坏了 / 不是 JSON / 不是 Map / 状态不认识 → 一律不动', () {
      expect(restoreRecoveryOf(''), RestoreRecovery.none);
      expect(restoreRecoveryOf('不是 json'), RestoreRecovery.none);
      expect(restoreRecoveryOf('[1,2,3]'), RestoreRecovery.none);
      expect(restoreRecoveryOf('{"state":"???","prefs":{}}'),
          RestoreRecovery.none);
      expect(restoreRecoveryOf('{"prefs":{}}'), RestoreRecovery.none);
    });
  });

  group('H7：旧设置的落盘 / 读回', () {
    test('五种 prefs 值类型都能原样往返（写回时不会因类型不对而抛）', () {
      final prefs = <String, Object>{
        'b': true,
        'i': 42,
        'd': 1.25,
        's': '中文 also ascii',
        'l': <String>['a', 'b', ''],
      };
      final back = parseRollbackSnapshot(
        buildRollbackSnapshot(prefs, state: kRestoreStatePending),
      );
      expect(back, isNotNull);
      expect(back!['b'], true);
      expect(back['i'], 42);
      expect(back['d'], 1.25);
      expect(back['s'], '中文 also ascii');
      // ⚠️ 关键：必须是 List<String>，不能是 JSON 解出来的 List<dynamic>
      // —— 否则 sp.setStringList 会在回滚那一刻抛，回滚就白做了
      expect(back['l'], isA<List<String>>());
      expect(back['l'], <String>['a', 'b', '']);
    });

    test('坏文本 / 缺 prefs → null，调用方据此放弃回滚而不是写坏设置', () {
      expect(parseRollbackSnapshot('不是 json'), isNull);
      expect(parseRollbackSnapshot('[]'), isNull);
      expect(parseRollbackSnapshot('{"state":"pending"}'), isNull);
    });

    test('不认识的值类型被丢掉，其余照常保留', () {
      final back = parseRollbackSnapshot(
        '{"state":"pending","prefs":{"ok":1,"bad":null,"nested":{"x":1}}}',
      );
      expect(back, {'ok': 1});
    });

    test('快照文件名固定（改名 = 旧残留文件认不出来，回滚静默失效）', () {
      expect(kRestoreRollbackFile, 'restore_rollback.json');
    });
  });

  // ─────────────── 缺陷③：私密歌的身份过滤（纯逻辑） ───────────────

  group('sanitizeBackupPrefs：私密歌的身份不许进 prefs.json', () {
    /// 一份尽量全的 prefs（键名与 `store.dart` / `app_config.dart` 里的实际用键一致）。
    Map<String, Object?> fullPrefs() => {
      // 纯名单键（整键丢）
      'private_songs': jsonEncode(['/d/music/秘密.mp3']),
      'play_history': jsonEncode(['/d/music/秘密.mp3', '/d/music/公开.mp3']),
      'last_session': jsonEncode({'paths': ['/d/music/秘密.mp3'], 'index': 0}),
      'private_songs_corrupt': jsonEncode(['/d/music/秘密.mp3']),
      // 按歌曲身份存的键（只摘私密那几条）
      'fav_songs': jsonEncode(['/d/music/公开.mp3', '/d/music/秘密.mp3']),
      'deleted_names': jsonEncode(['公开.mp3', '秘密.mp3']),
      'instrumental_names': jsonEncode(['秘密.mp3']),
      'blocked_names': jsonEncode(['秘密.mp3']),
      'title_overrides': jsonEncode({
        '/d/music/公开.mp3': '公开自定义',
        '/d/music/秘密.mp3': '秘密自定义',
      }),
      'lyric_offsets': jsonEncode({'/d/music/秘密.mp3': 500}),
      'lyric_calibration': jsonEncode({
        '/d/music/公开.mp3': [
          [0, 100],
        ],
      }),
      'lyric_segments': jsonEncode({
        '/d/music/秘密.mp3': [
          [0, 1, 0, 1000],
        ],
      }),
      'all_order': jsonEncode([9, 111, 222]),
      'playlists': jsonEncode({
        '我的歌单': [9, 111],
        '别的歌单': [222, 8],
      }),
      // 与歌曲身份无关的（一个字节都不许动）
      'mode': 'shuffle',
      'speed': 1.25,
      'theme_index': 3,
      'fx_params': jsonEncode({'v0.size': 1.2}),
      'playlist_columns': 1,
      'wallpaper_path': '/d/wallpapers/w.jpg',
      'eq_presets': jsonEncode([
        {'name': '我的预设', 'levels': [1, 2]},
      ]),
    };

    test('空指纹 ⇒ 原样返回（开关关掉 / 本来就没私密歌时，既有备份逐字节不变）', () {
      final prefs = fullPrefs();
      final out = sanitizeBackupPrefs(prefs, kNoPrivateMarks);
      expect(identical(out, prefs), isTrue, reason: '连复制都不做，直接原样返回');
      expect(out['private_songs'], prefs['private_songs']);
    });

    test('纯名单键 + 损坏隔离现场键：整键丢掉', () {
      final out = sanitizeBackupPrefs(fullPrefs(), _marks());
      expect(out.containsKey('private_songs'), isFalse, reason: '私密名单本体');
      expect(out.containsKey('play_history'), isFalse, reason: '私密歌会进播放历史');
      expect(out.containsKey('last_session'), isFalse, reason: '旧队列键 = 又一份路径名单');
      expect(out.containsKey('private_songs_corrupt'), isFalse,
          reason: '损坏现场键里可能正是一份私密名单原文');
    });

    test('其余键一个都不少（整键丢 = 丢用户数据，只许摘条目）', () {
      final prefs = fullPrefs();
      final out = sanitizeBackupPrefs(prefs, _marks());
      for (final k in prefs.keys) {
        if (kBackupPrefsDropped.contains(k) || k.endsWith(kBackupCorruptSuffix)) {
          continue;
        }
        expect(out.containsKey(k), isTrue, reason: '$k 丢了');
      }
    });

    test('路径名单 / 文件名名单：私密那条摘掉，公开的原样', () {
      final out = sanitizeBackupPrefs(fullPrefs(), _marks());
      expect(jsonDecode(out['fav_songs']! as String), ['/d/music/公开.mp3']);
      expect(jsonDecode(out['deleted_names']! as String), ['公开.mp3']);
      expect(jsonDecode(out['instrumental_names']! as String), isEmpty);
      expect(jsonDecode(out['blocked_names']! as String), isEmpty);
    });

    test('路径键映射：私密路径做键的那几条摘掉，公开的连值一起留', () {
      final out = sanitizeBackupPrefs(fullPrefs(), _marks());
      expect(jsonDecode(out['title_overrides']! as String), {
        '/d/music/公开.mp3': '公开自定义',
      });
      expect(jsonDecode(out['lyric_offsets']! as String), isEmpty);
      expect(jsonDecode(out['lyric_segments']! as String), isEmpty);
      expect(jsonDecode(out['lyric_calibration']! as String), {
        '/d/music/公开.mp3': [
          [0, 100],
        ],
      });
    });

    test('稳定 id 名单 / 歌单：私密歌的 id 摘掉，别的一律不动', () {
      final out = sanitizeBackupPrefs(fullPrefs(), _marks());
      expect(jsonDecode(out['all_order']! as String), [9],
          reason: '111 / 222 是私密歌的稳定 id');
      expect(jsonDecode(out['playlists']! as String), {
        '我的歌单': [9],
        '别的歌单': [8],
      }, reason: '歌单结构与名字都要留着（那是用户数据）');
    });

    test('与歌曲身份无关的键：值逐项不变', () {
      final prefs = fullPrefs();
      final out = sanitizeBackupPrefs(prefs, _marks());
      for (final k in [
        'mode',
        'speed',
        'theme_index',
        'fx_params',
        'playlist_columns',
        'wallpaper_path',
        'eq_presets',
      ]) {
        expect(out[k], prefs[k], reason: '$k 被动了');
      }
    });

    test('身份键的值解析不了 ⇒ 整键丢（坏值在 App 眼里本来就等于空，留着却可能带私密原文）', () {
      final out = sanitizeBackupPrefs({
        'fav_songs': '这不是 json',
        'all_order': '[1,2',
        'title_overrides': '{"a":1}',
      }, _marks());
      expect(out.containsKey('fav_songs'), isFalse);
      expect(out.containsKey('all_order'), isFalse);
      expect(out['title_overrides'], '{"a":1}',
          reason: '能解析的照常过滤（公开键留下）');
    });

    test('键名表覆盖了 `store.dart` 里全部「按歌曲身份存」的名单键', () {
      for (final k in [
        'fav_songs',
        'deleted_names',
        'instrumental_names',
        'blocked_names',
        'title_overrides',
        'lyric_offsets',
        'lyric_calibration',
        'lyric_segments',
        'all_order',
        'playlists',
      ]) {
        expect(kBackupSongKeyShapes.containsKey(k), isTrue,
            reason: '$k 带歌曲身份却没进过滤表 ⇒ 私密歌的条目会跟着出门');
      }
      for (final k in ['private_songs', 'play_history', 'last_session']) {
        expect(kBackupPrefsDropped, contains(k));
      }
    });
  });

  group('isPrivateBackupArtifact：一歌一名的目录里，私密歌的文件名也不许进包', () {
    final stems = {'秘密', '别的歌'};

    test('四个目录各自的命名后缀都能命中', () {
      expect(isPrivateBackupArtifact('lyrics', '秘密.lrc', stems), isTrue);
      expect(isPrivateBackupArtifact('imported_lyrics', '秘密.lrc', stems), isTrue);
      expect(isPrivateBackupArtifact('sub_lyrics', '秘密.sub.json', stems), isTrue);
      expect(isPrivateBackupArtifact('artwork', '秘密.jpg', stems), isTrue);
    });

    test('公开歌 / 后缀不匹配 / 不在清单里的目录：一律 false（不许误伤）', () {
      expect(isPrivateBackupArtifact('lyrics', '公开.lrc', stems), isFalse);
      expect(isPrivateBackupArtifact('lyrics', '秘密.lrc.bak', stems), isFalse);
      expect(isPrivateBackupArtifact('lyrics', '秘密', stems), isFalse);
      expect(isPrivateBackupArtifact('music', '秘密.mp3', stems), isFalse,
          reason: 'music/ 按完整路径另行判定');
      expect(isPrivateBackupArtifact('wallpapers', '秘密.jpg', stems), isFalse,
          reason: '壁纸与歌曲身份无关');
      expect(isPrivateBackupArtifact('lyrics', '秘密.lrc', const {}), isFalse,
          reason: '空集 ⇒ 整套过滤是 no-op');
    });

    test('命名后缀表与四个目录的实际命名一一对应（改名要三处一起改）', () {
      expect(kBackupSongNamedSuffix.keys.toSet(), {
        'lyrics',
        'imported_lyrics',
        'sub_lyrics',
        'artwork',
      });
      expect(kBackupSongNamedSuffix['sub_lyrics'], '.sub.json',
          reason: '唯一的双后缀：`.sub.json`，按 `.json` 剥会漏');
    });
  });
}
