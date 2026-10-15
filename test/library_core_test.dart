import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/library_core.dart';
import 'package:mu_box_phone/models.dart';

Song s(
  int id,
  String filePath, {
  String title = 't',
  String artist = 'a',
  String album = '',
}) => Song(
  id: id,
  title: title,
  artist: artist,
  album: album,
  durationMs: 0,
  uri: '',
  filePath: filePath,
);

void main() {
  group('basenameOf', () {
    test('兼容 /', () => expect(basenameOf('/storage/emulated/0/Music/x.mp3'), 'x.mp3'));
    test('兼容 \\', () => expect(basenameOf(r'C:\Music\x.mp3'), 'x.mp3'));
  });

  group('scannedId', () {
    test('同一路径稳定、恒为负', () {
      final a = scannedId('/a/b.mp3');
      expect(a, lessThan(0));
      expect(scannedId('/a/b.mp3'), a);
    });
    test('不同路径 id 不同', () {
      expect(scannedId('/a/b.mp3'), isNot(scannedId('/a/c.mp3')));
    });
  });

  group('isMuBoxCopyPath', () {
    test('Music/MuBox 副本 → true', () {
      expect(isMuBoxCopyPath('/storage/emulated/0/Music/MuBox/x.mp3'), true);
    });
    test('普通路径 → false', () {
      expect(isMuBoxCopyPath('/storage/emulated/0/Music/x.mp3'), false);
    });
    test('大小写不敏感', () {
      expect(isMuBoxCopyPath('/abc/music/mubox/x.MP3'), true);
    });
  });

  group('parseSongName', () {
    test('歌手 - 歌名', () {
      final n = parseSongName('/d/周杰伦 - 七里香.mp3');
      expect(n.artist, '周杰伦');
      expect(n.title, '七里香');
    });
    test('无分隔符整段为歌名', () {
      final n = parseSongName('/d/song.mp3');
      expect(n.artist, '');
      expect(n.title, 'song');
    });
    test('空歌名兜底未知歌曲', () {
      final n = parseSongName('/d/Artist -   .mp3');
      expect(n.title, '未知歌曲');
    });
  });

  group('songFromFilePath', () {
    test('构造无元数据 Song', () {
      final song = songFromFilePath('/d/Artist - Title.flac');
      expect(song.title, 'Title');
      expect(song.artist, 'Artist');
      expect(song.durationMs, 0);
      expect(song.uri, '');
      expect(song.albumId, null);
      expect(song.id, scannedId('/d/Artist - Title.flac'));
    });
  });

  group('mapTitleOverrides', () {
    test('按 filePath 映射到 id，空标题跳过', () {
      final songs = [s(1, '/p/a.mp3'), s(2, '/p/b.mp3')];
      final map = mapTitleOverrides(songs, {'/p/a.mp3': '改名A', '/p/b.mp3': ''});
      expect(map, {1: '改名A'});
    });
  });

  group('reorderMove', () {
    test('向前移动并 clamp', () {
      expect(reorderMove([0, 1, 2, 3], 3, 0), [3, 0, 1, 2]);
    });
    test('向后移动', () {
      expect(reorderMove([0, 1, 2, 3], 0, 3), [1, 2, 3, 0]);
    });
    test('非法 oldIndex 不变', () {
      expect(reorderMove([0, 1], 5, 0), [0, 1]);
    });
    test('newIndex 越界被 clamp', () {
      expect(reorderMove([0, 1, 2], 0, 99), [1, 2, 0]);
    });
  });

  group('allSongsOrdered', () {
    final songs = [s(1, '/a'), s(2, '/b'), s(3, '/c'), s(4, '/p')];
    test('按 allOrder 排序 + 缺失兜底 + 过滤私密', () {
      final out = allSongsOrdered(songs, [2, 1], {'/p'});
      expect(out.map((x) => x.id).toList(), [2, 1, 3]);
    });
  });

  group('playlistSongsOrdered', () {
    test('按 id 顺序排列并过滤私密', () {
      final songs = [s(1, '/a'), s(2, '/b'), s(3, '/c')];
      final out = playlistSongsOrdered(songs, [3, 2, 1], {'/b'});
      expect(out.map((x) => x.id).toList(), [3, 1]);
    });
  });

  group('likesSongs', () {
    test('收藏且非私密', () {
      final songs = [s(1, '/a'), s(2, '/b'), s(3, '/c')];
      final out = likesSongs(songs, {'/a', '/b', '/c'}, {'/b'});
      expect(out.map((x) => x.id).toList(), [1, 3]);
    });
  });

  group('countPlaylistSongs', () {
    final songs = [s(1, '/a'), s(2, '/b'), s(3, '/c'), s(4, '/d')];
    final Map<String, List<int>> playlists = {'我': [1, 2, 99], '空': []}; // 99 不存在于库中
    test('全部歌曲 = 可见数', () {
      expect(countPlaylistSongs(kAllSongs, songs, [1, 2], playlists, {'/b'}, {}), 3);
    });
    test('喜欢 = 收藏且非私密', () {
      expect(countPlaylistSongs(kLikes, songs, [], playlists, {}, {'/a', '/b'}), 2);
    });
    test('自建歌单只数仍在库中且非私密', () {
      expect(countPlaylistSongs('我', songs, [], playlists, {'/c'}, {}), 2);
      expect(countPlaylistSongs('空', songs, [], playlists, {}, {}), 0);
    });
  });

  // ---- 曲库分组（专辑 / 歌手）----
  // 「专辑 · 歌手」页（lib/pages/library_group_page.dart）唯一的取数逻辑就是这几个函数，
  // 所以它们值得被锁住：分组顺序错、私密歌漏出来，都是用户一眼能看出的问题。

  group('albumKeyOf', () {
    test('有专辑标签时用标签', () {
      expect(albumKeyOf(s(1, '/m/x.mp3', album: '范特西')), '范特西');
    });
    test('标签只有空白也当没有', () {
      expect(albumKeyOf(s(1, '/m/x.mp3', album: '   ')), kUnknownAlbum);
    });
    // 回归：这里**曾经**回退到「所在文件夹名」，但 Song.filePath 存的是 App 内部副本
    // （docs/music/<文件名>），于是每首歌都算成同一个文件夹名 —— 无标签的歌会被塞进
    // 一个名叫 music 的假专辑。现在一律归「未知专辑」。
    test('没有标签归未知专辑（内部副本路径不能拿来推断来源文件夹）', () {
      expect(albumKeyOf(s(1, '/Music/周杰伦/1.mp3')), kUnknownAlbum);
      expect(
        albumKeyOf(s(1, '/data/user/0/com.mubox.mu_box_phone/app_flutter/docs/music/1.mp3')),
        kUnknownAlbum,
      );
    });
    test('路径也取不到时同样归未知专辑', () {
      expect(albumKeyOf(s(1, '1.mp3')), kUnknownAlbum);
      expect(albumKeyOf(s(1, '')), kUnknownAlbum);
    });
  });

  group('artistKeyOf', () {
    test('正常歌手名去空白后返回', () {
      expect(artistKeyOf(s(1, '/a', artist: ' 周杰伦 ')), '周杰伦');
    });
    test('空与 MediaStore 的 <unknown> 占位都归到未知歌手', () {
      expect(artistKeyOf(s(1, '/a', artist: '')), kUnknownArtist);
      expect(artistKeyOf(s(1, '/a', artist: '   ')), kUnknownArtist);
      expect(artistKeyOf(s(1, '/a', artist: '<unknown>')), kUnknownArtist);
      expect(artistKeyOf(s(1, '/a', artist: '<UNKNOWN>')), kUnknownArtist);
    });
  });

  group('groupByAlbum / groupByArtist', () {
    final songs = [
      s(1, '/m/B/1.mp3', album: 'B'),
      s(2, '/m/A/2.mp3', album: 'A'),
      s(3, '3.mp3'), // 无专辑标签 → 未知专辑
      s(4, '/m/B/4.mp3', album: 'B'),
      s(5, '/m/A/5.mp3', album: 'A'), // 私密
    ];

    test('组间按名称升序，「未知」恒排最后', () {
      expect(
        groupByAlbum(songs, {'/m/A/5.mp3'}).map((g) => g.name).toList(),
        ['A', 'B', kUnknownAlbum],
      );
    });
    test('组内保持传入顺序（不打乱播放顺序）', () {
      final b = groupByAlbum(songs, const {}).firstWhere((g) => g.name == 'B');
      expect(b.songs.map((x) => x.id).toList(), [1, 4]);
    });
    test('私密歌不出现在任何分组里', () {
      final groups = groupByAlbum(songs, {'/m/A/5.mp3'});
      expect(groups.expand((g) => g.songs).any((x) => x.id == 5), isFalse);
      expect(
        groups.firstWhere((g) => g.name == 'A').songs.map((x) => x.id).toList(),
        [2],
      );
    });
    test('按歌手分组：过滤私密 + 空歌手归到未知', () {
      final list = [
        s(1, '/m/1.mp3', artist: '乙'),
        s(2, '/m/2.mp3', artist: '甲'),
        s(3, '/m/3.mp3', artist: ''),
        s(4, '/m/4.mp3', artist: '甲'), // 私密
      ];
      final groups = groupByArtist(list, {'/m/4.mp3'});
      // 按拼音序：'甲' jiǎ → J、'乙' yǐ → Y，所以甲在前 —— 这才是用户预期的顺序。
      expect(groups.map((g) => g.name).toList(), ['甲', '乙', kUnknownArtist]);
      expect(
        groups.firstWhere((g) => g.name == '甲').songs.map((x) => x.id).toList(),
        [2],
      );
    });
    test('空曲库返回空分组（页面据此显示空状态）', () {
      expect(groupByAlbum(const [], const {}), isEmpty);
      expect(groupByArtist(const [], const {}), isEmpty);
    });
  });
}
