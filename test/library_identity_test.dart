/// 「曲库地基」：**歌的身份**（稳定 id / 双键读 / 迁移）与
/// **内部副本命名**（撞名才加哈希、存量永不改名）。
///
/// 这一组全是纯函数，能直接测；而它们一旦错了就是**静默丢数据**：
/// - 命名错 → 两个同名文件写同一个内部副本，其中一首整条消失（H1）
/// - 身份错 → 歌单/「全部歌曲」顺序刷新后指不到歌（H2）
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/library_core.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/store.dart';

const String kInner = '/data/user/0/com.mubox.mu_box_phone/app_flutter/music';

Song mk(
  int id,
  String filePath, {
  String title = 't',
  String uri = '',
  String srcPath = '',
}) => Song(
  id: id,
  title: title,
  artist: 'a',
  durationMs: 1,
  uri: uri,
  filePath: filePath,
  srcPath: srcPath,
);

/// 内部副本路径 + MediaStore 旧 id + uri 三件套（真机 songs.json 的形状）。
Song media(String base, int mediaId) => mk(
  mediaId,
  '$kInner/$base',
  title: base,
  uri: 'content://media/external/audio/media/$mediaId',
  srcPath: '/storage/emulated/0/个人资料/$base',
);

void main() {
  group('planInternalNames：不撞名的逐字符不变（老库零影响）', () {
    test('单一 basename 原样保留', () {
      final p = planInternalNames(['/storage/emulated/0/Music/周杰伦 - 七里香.mp3']);
      expect(p['/storage/emulated/0/Music/周杰伦 - 七里香.mp3'], '周杰伦 - 七里香.mp3');
    });

    test('同名不同目录：两个都加短哈希，且互不相同', () {
      const a = '/storage/emulated/0/Music/A/01.mp3';
      const b = '/storage/emulated/0/Music/B/01.mp3';
      final p = planInternalNames([a, b]);
      expect(p[a], isNot(p[b]));
      expect(p[a], isNot('01.mp3'));
      expect(p[b], isNot('01.mp3'));
      // 后缀加在扩展名之前，且主名不变
      expect(p[a], startsWith('01-'));
      expect(p[a], endsWith('.mp3'));
    });

    test('后缀只由源路径决定：同组里换掉别人，我的名字不变', () {
      const a = '/m/A/01.mp3';
      const b = '/m/B/01.mp3';
      const c = '/m/C/01.mp3';
      final only2 = planInternalNames([a, b]);
      final three = planInternalNames([a, b, c]);
      expect(three[a], only2[a]);
      expect(three[b], only2[b]);
    });

    test('已在库的歌永不改名（keep 优先，即使它在撞名组里）', () {
      const a = '/m/A/01.mp3';
      const b = '/m/B/01.mp3';
      final p = planInternalNames([a, b], keep: {a: '01.mp3'});
      expect(p[a], '01.mp3'); // 老库那首逐字符不动
      expect(p[b], isNot('01.mp3')); // 新来的让路
    });

    // 回归：真机数据实测踩到的那个坑 ——
    // 调用方传的 `occupied` 是「库里所有内部文件名」，**天然包含 keep 的名字**；
    // 要是拿 occupied 去拦 keep，每一首老歌都会被判成「名字被占」而加哈希，
    // 存量文件名全变（干跑 0 改名 → 落盘 16 改名）。
    test('keep 的名字同时出现在 occupied 里时，keep 仍然赢', () {
      const a = '/m/A/01.mp3';
      const other = '/m/C/老歌.mp3';
      final p = planInternalNames(
        [a],
        keep: {a: '01.mp3'},
        occupied: {'01.mp3', basenameOf(other)},
      );
      expect(p[a], '01.mp3');
    });

    test('老歌给出的名字本身重复时（不该发生）只让后来者让路，前者照留', () {
      const a = '/m/A/01.mp3';
      const b = '/m/B/01.mp3';
      final p = planInternalNames([a, b], keep: {a: '01.mp3', b: '01.mp3'});
      expect(p.values.toSet().length, 2);
      expect(p.values, contains('01.mp3'));
    });

    test('名字被占（库里已有同名老歌、srcPath 查不出来）→ 新导入让路，不覆盖', () {
      const a = '/m/A/01.mp3';
      final p = planInternalNames([a], occupied: {'01.mp3'});
      expect(p[a], isNot('01.mp3'));
      expect(p[a], endsWith('.mp3'));
    });

    test('同一源路径被两条通道扫到两次，只算一次（不当成撞名）', () {
      const a = '/Download/WeiXin/x.m4a';
      final p = planInternalNames([a, a]);
      expect(p[a], 'x.m4a'); // 若按条目数算会误判成撞名
      expect(p.length, 1);
    });

    test('结果与输入顺序无关', () {
      const a = '/m/A/01.mp3';
      const b = '/m/B/01.mp3';
      const c = '/m/z.mp3';
      final p1 = planInternalNames([a, b, c]);
      final p2 = planInternalNames([c, b, a]);
      expect(p1, p2);
    });

    test('无扩展名 / 多扩展名 / 空名字', () {
      final p = planInternalNames(['/m/A/x', '/m/B/x', '/m/A/a.tar.gz', '']);
      expect(p['/m/A/x'], startsWith('x-'));
      expect(p['/m/A/x'], isNot(contains('.')));
      expect(p['/m/B/x'], isNot(p['/m/A/x']));
      expect(p['/m/A/a.tar.gz'], 'a.tar.gz'); // 唯一：原样
      expect(p.containsKey(''), isFalse);
    });

    test('真实形状：16 个源路径不撞名 → 16 个目标名都与 basename 逐字符相同', () {
      final srcs = [
        '/storage/emulated/0/Download/WeiXin/2026年01月09日 11点37分.m4a',
        for (var i = 0; i < 15; i++) '/storage/emulated/0/个人资料/纯中文-音色$i.wav',
      ];
      final p = planInternalNames(srcs);
      expect(p.length, 16);
      for (final s in srcs) {
        expect(p[s], basenameOf(s));
      }
    });
  });

  group('负向对照：老规则（basename 直用）会把两首歌写到同一个文件', () {
    // 这就是 H1 的机理，改动前的写法：`'${dir.path}/$base'`。写在这儿是为了
    // **让「为什么必须加哈希」可执行地钉住**，而不是只写在注释里。
    String oldRule(String srcPath) => basenameOf(srcPath);

    test('老规则：两个不同源路径 → 同一个目标名（互相覆盖）', () {
      const a = '/storage/emulated/0/Music/A/01.mp3';
      const b = '/storage/emulated/0/Music/B/01.mp3';
      expect(oldRule(a), oldRule(b)); // ← 覆盖发生在这里
      final p = planInternalNames([a, b]);
      expect(p[a], isNot(p[b])); // ← 新规则不让它发生
    });

    test('老规则：新来的会盖掉库里已有的同名歌', () {
      const existing = '/m/old/同名曲.mp3';
      const newcomer = '/m/new/同名曲.mp3';
      expect(oldRule(newcomer), basenameOf(existing)); // ← 老库那首被盖
      final p = planInternalNames([newcomer], keep: {existing: '同名曲.mp3'});
      expect(p[newcomer], isNot('同名曲.mp3'));
    });
  });

  group('稳定 id 与身份升级', () {
    test('stableIdOfPath 恒为负，且同一路径稳定', () {
      final id = stableIdOfPath('$kInner/a.mp3');
      expect(id, lessThan(0));
      expect(stableIdOfPath('$kInner/a.mp3'), id);
      expect(stableIdOfPath('$kInner/a.mp3'), scannedId('$kInner/a.mp3'));
    });

    test('withStableId 让 id 跟着内部副本路径走', () {
      final s = mk(1000044312, '$kInner/a.mp3');
      final up = withStableId(s);
      expect(up.id, stableIdOfPath('$kInner/a.mp3'));
      expect(up.filePath, s.filePath);
      expect(up.title, s.title);
    });

    test('withStableId 已对齐时是幂等的（同一对象，不再复制）', () {
      final s = mk(stableIdOfPath('$kInner/a.mp3'), '$kInner/a.mp3');
      expect(identical(withStableId(s), s), isTrue);
    });

    test('mediaIdOfUri 只认 /media/<数字> 结尾', () {
      expect(
        mediaIdOfUri('content://media/external/audio/media/1000044312'),
        1000044312,
      );
      expect(mediaIdOfUri(''), isNull);
      expect(mediaIdOfUri('https://x/y.mp3'), isNull);
    });

    test('stableIdMapOf 两条通道：歌现挂的 id + uri 里的 MediaStore id', () {
      final songs = [media('采.wav', 1000044312)];
      final up = withStableId(songs.single);
      final m = stableIdMapOf([up]); // 已经升级过的歌：uri 通道仍要能认出旧 id
      expect(m[1000044312], up.id);
      expect(m[up.id], up.id);
    });

    test('translateLegacyIds：翻不动的原样保留（用户数据不许顺手清理）', () {
      final out = translateLegacyIds([1, 2, -1786900497794, 3], {1: -9, 2: -8});
      expect(out, [-9, -8, -1786900497794, 3]);
    });

    test('翻译是幂等的：再翻一次逐项不变', () {
      final songs = [mk(-7, '$kInner/a.mp3')];
      final m = stableIdMapOf(songs);
      final once = translateLegacyIds([-7, 12345], m);
      expect(translateLegacyIds(once, m), once);
    });
  });

  group('双键读：条目是旧 MediaStore id 也认得出歌', () {
    final songs = [
      media('A.wav', 1000044312),
      media('B.wav', 1000044316),
    ];
    final upgraded = songs.map(withStableId).toList();

    test('歌单：旧 id 命中（改动前这里是空列表）', () {
      final out = playlistSongsOrdered(upgraded, [1000044316, 1000044312], const {});
      expect(out.map((s) => basenameOf(s.filePath)).toList(), ['B.wav', 'A.wav']);
    });

    test('全部歌曲：旧 id 命中且**顺序按条目走**', () {
      final out = allSongsOrdered(upgraded, [1000044316, 1000044312], const {});
      expect(out.map((s) => basenameOf(s.filePath)).toList(), ['B.wav', 'A.wav']);
    });

    test('同一个 entry 被两条通道同时命中，歌也只出现一次', () {
      // 稳定 id 与旧 MediaStore id 都指向同一首歌：按 entry 去重的话会重复一首
      final out = playlistSongsOrdered(
        upgraded,
        [1000044312, upgraded.first.id],
        const {},
      );
      expect(out.length, 1);
    });

    test('全部歌曲：旧 id 命中后不会被兜底再追加一遍', () {
      final out = allSongsOrdered(upgraded, [1000044316], const {});
      expect(out.map((s) => basenameOf(s.filePath)).toList(), ['B.wav', 'A.wav']);
    });
  });

  group('真实形状回归：16 条 MediaStore id 在「全部歌曲」顺序里', () {
    // 复刻真机干跑的形状：56 首里 40 首的 id 已经是稳定 id
    // （= 内部副本路径散列），16 首还是 MediaStore 正数 id；all_order 里
    // 两种混着。升级后**顺序必须逐项不变**（不然那 16 首会沉到列表末尾）。
    final stable40 = [
      for (var i = 0; i < 40; i++) mk(stableIdOfPath('$kInner/歌$i.mp3'), '$kInner/歌$i.mp3'),
    ];
    final media16 = [
      for (var i = 0; i < 16; i++) media('采$i.wav', 1000044312 + i),
    ];
    final before = [...media16, ...stable40];
    final order = [for (final s in before) s.id]; // 正数在前、负数在后

    test('升级前：all_order 逐条都能对上歌', () {
      final out = allSongsOrdered(before, order, const {});
      expect(out.length, 56);
      expect(out.map((s) => s.filePath).toList(), before.map((s) => s.filePath).toList());
    });

    test('升级后：同样的顺序逐项不变，一首不塌到末尾', () {
      final idMap = stableIdMapOf(before);
      final after = before.map(withStableId).toList();
      final newOrder = translateLegacyIds(order, idMap);
      final out = allSongsOrdered(after, newOrder, const {});
      expect(out.length, 56);
      expect(out.map((s) => s.filePath).toList(), before.map((s) => s.filePath).toList());
      expect(after.where((s) => s.id > 0), isEmpty); // 全部换成稳定 id
      expect(after.map((s) => s.id).toSet().length, 56); // 无冲突
    });

    test('uri 通道救不了「文件系统扫进来的歌」：漏翻译就乱序（这就是必须翻译的原因）', () {
      // 文件系统补扫进来的歌 uri 是空串，旧 id = scannedId(外部源路径)。
      // 身份升级后 id 变成 scannedId(内部副本路径) —— 旧条目**没有任何通道**能认回来：
      // uri 通道靠 MediaStore id，这里根本没有 uri。只有把顺序翻译一遍才救得回来。
      final fsBefore = [
        for (var i = 0; i < 3; i++)
          mk(
            scannedId('/storage/emulated/0/Music/fs$i.mp3'),
            '$kInner/fs$i.mp3',
            title: 'fs$i',
          ),
      ];
      final after = fsBefore.map(withStableId).toList();
      // 用户自定义顺序 = 倒序（与库内顺序不同，这样才能看出顺序有没有被翻译）
      final custom = [for (final s in fsBefore.reversed) s.id];

      // ① 翻译了 → 顺序逐项照旧
      final ok = allSongsOrdered(after, translateLegacyIds(custom, stableIdMapOf(fsBefore)), const {});
      expect(ok.map((s) => basenameOf(s.filePath)).toList(), ['fs2.mp3', 'fs1.mp3', 'fs0.mp3']);

      // ② 漏翻译 → 条目全对不上，三首塌回库内顺序（自定义顺序被静默抹掉）
      final leaked = allSongsOrdered(after, custom, const {});
      expect(leaked.map((s) => basenameOf(s.filePath)).toList(), ['fs0.mp3', 'fs1.mp3', 'fs2.mp3']);
    });

    test('MediaStore 歌另有 uri 通道兜底（但那是保险，不是主路）', () {
      final after = before.map(withStableId).toList();
      final leaked = allSongsOrdered(after, order, const {}); // 故意漏翻译
      // 那 16 首的 uri 里还留着旧 MediaStore id，所以侥幸没塌；
      // 换成文件系统歌（uri 空）就塌了 —— 见上一条。这条只证明「保险起了作用」。
      expect(leaked.length, 56);
      expect(leaked.map((s) => s.filePath).toList(), before.map((s) => s.filePath).toList());
    });

    test('升级幂等：第二次算出来的顺序与第一次逐项相同', () {
      final idMap1 = stableIdMapOf(before);
      final after = before.map(withStableId).toList();
      final order1 = translateLegacyIds(order, idMap1);
      final idMap2 = stableIdMapOf(after);
      final order2 = translateLegacyIds(order1, idMap2);
      expect(order2, order1);
      expect(after.map(withStableId).map((s) => s.id).toList(), after.map((s) => s.id).toList());
    });
  });

  group('Store.decodeSongs：srcPath 向后兼容（血债：强转抛异常 → 整表判成无缓存）', () {
    test('老索引没有 srcPath 键 → 整表照读，一条都不许丢', () {
      const old = '[{"id":-1,"title":"t","artist":"a","album":"","durationMs":1,'
          '"uri":"","filePath":"/m/a.mp3","albumId":null}]';
      final list = Store.decodeSongs(old);
      expect(list.length, 1);
      expect(list.single.srcPath, '');
    });

    test('新索引带 srcPath 能读出来', () {
      const neu = '[{"id":-1,"title":"t","artist":"a","album":"","durationMs":1,'
          '"uri":"","filePath":"/m/a.mp3","albumId":null,'
          '"srcPath":"/storage/emulated/0/Music/a.mp3"}]';
      expect(Store.decodeSongs(neu).single.srcPath, '/storage/emulated/0/Music/a.mp3');
    });

    test('srcPath 类型不对只丢这一条，不拖垮整表', () {
      const bad = '[{"id":-1,"title":"t","artist":"a","durationMs":1,"uri":"",'
          '"filePath":"/m/a.mp3","srcPath":123},'
          '{"id":-2,"title":"t2","artist":"a","durationMs":1,"uri":"",'
          '"filePath":"/m/b.mp3","srcPath":"/x/b.mp3"}]';
      final list = Store.decodeSongs(bad);
      expect(list.length, 1);
      expect(list.single.srcPath, '/x/b.mp3');
    });
  });
}
