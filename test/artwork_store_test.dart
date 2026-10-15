/// 封面缓存（`ArtworkStore`）的存储语义单测。
///
/// 这组用例存在的理由：这块是「同一首歌换图标」的坑窝 —— 文件名不变、内容变了，
/// 而 Flutter 的 `ImageCache` 以**文件路径**为键（`FileImage` 的相等性只看路径），
/// 不 evict 就永远显示旧图。锁死三条行为：
/// ① 缓存名恒为 `<歌名去扩展名>.jpg`（改名会让已有的在线封面缓存全部失效）；
/// ② `save` / `remove` 都自增 `revision`（列表与播放栏靠它重画）；
/// ③ `save` / `remove` 都把同一路径的解码缓存踢掉。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/artwork.dart';
import 'package:mu_box_phone/models.dart';

import 'support/temp_docs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory docs;

  setUpAll(() async {
    docs = await Directory.systemTemp.createTemp('mubox_artwork_test');
    // flutter test 跑在宿主 VM 上、插件没注册，path_provider 落到默认的
    // MethodChannelPathProvider，所以拦这个老通道就够了
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => call.method == 'getApplicationDocumentsDirectory'
              ? docs.path
              : null,
        );
    await ArtworkStore.ensureInit();
  });

  tearDownAll(() async {
    // 同一个「删临时目录」的纪律：带重试，删不掉就抛（别退回 catch (_) {}，
    // 那是每跑一轮往 %TEMP% 里攒垃圾的来源 —— 见 support/temp_docs.dart）。
    await deleteTempDir(docs);
  });

  tearDown(() {
    imageCache.clear();
    imageCache.clearLiveImages();
  });

  Song song(String stem) => Song(
    id: stem.hashCode,
    title: stem,
    artist: '',
    durationMs: 0,
    uri: '',
    filePath: '/Music/$stem.mp3',
  );

  test('缓存名 = 歌名去扩展名 + .jpg', () async {
    final s = song('plain');
    await ArtworkStore.save(s, Uint8List.fromList([1, 2, 3]));
    expect(ArtworkStore.has(s), isTrue);
    expect(ArtworkStore.fileFor(s)!.path, endsWith('plain.jpg'));
  });

  test('歌名里有多个点时只砍最后一段（a.b.c.mp3 → a.b.c.jpg）', () async {
    final s = song('a.b.c');
    await ArtworkStore.save(s, Uint8List.fromList([1]));
    expect(ArtworkStore.fileFor(s)!.path, endsWith('a.b.c.jpg'));
  });

  test('PNG 字节原样落盘进 .jpg 名（后缀不参与解码）', () async {
    final s = song('pngbytes');
    // 真 PNG 的魔数（不是有效图片，这条只验「字节没被加工」）
    final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0, 1, 2, 3]);
    await ArtworkStore.save(s, png);
    expect(await ArtworkStore.load(s), png);
    expect(await ArtworkStore.fileFor(s)!.readAsBytes(), png);
  });

  test('save / remove 都自增 revision', () async {
    final s = song('rev');
    final before = ArtworkStore.revision.value;
    await ArtworkStore.save(s, Uint8List.fromList([9]));
    expect(ArtworkStore.revision.value, before + 1);
    await ArtworkStore.remove(s);
    expect(ArtworkStore.revision.value, before + 2);
    expect(ArtworkStore.has(s), isFalse);
    expect(ArtworkStore.uriFor(s), isNull);
  });

  test('换图时踢掉解码缓存：同一路径不会被旧图命中', () async {
    final s = song('swap');
    await ArtworkStore.save(s, Uint8List.fromList([1, 2, 3]));
    // 用界面同款取路径（fileFor），确保和 evict 用的是同一串字符
    final path = ArtworkStore.fileFor(s)!.path;
    // 模拟「界面已经显示过这张图」：往 ImageCache 占一个 pending 位，
    // 免得为了造一张真图去跑解码（要验的是键的相等性与 evict，不是解码）
    final never = Completer<ImageInfo>();
    imageCache.putIfAbsent(
      FileImage(File(path)),
      () => OneFrameImageStreamCompleter(never.future),
    );
    expect(
      imageCache.containsKey(FileImage(File(path))),
      isTrue,
      reason: '同一路径的新 FileImage 实例命中的是同一个缓存键 —— 这正是必须 evict 的原因',
    );

    await ArtworkStore.save(s, Uint8List.fromList([4, 5, 6]));
    expect(
      imageCache.containsKey(FileImage(File(path))),
      isFalse,
      reason: '内容变了，旧解码结果必须被踢掉，否则列表还挂着旧图',
    );
    expect(await ArtworkStore.load(s), [4, 5, 6]);
  });

  test('删除时同样踢掉解码缓存', () async {
    final s = song('swapdel');
    await ArtworkStore.save(s, Uint8List.fromList([7]));
    final path = ArtworkStore.fileFor(s)!.path;
    final never = Completer<ImageInfo>();
    imageCache.putIfAbsent(
      FileImage(File(path)),
      () => OneFrameImageStreamCompleter(never.future),
    );
    await ArtworkStore.remove(s);
    expect(imageCache.containsKey(FileImage(File(path))), isFalse);
    expect(File(path).existsSync(), isFalse);
  });

  test('没缓存时 remove 不抛（也不产生脏索引）', () async {
    final s = song('nothing');
    await ArtworkStore.remove(s);
    expect(ArtworkStore.has(s), isFalse);
  });

  test('has() 查的是内存索引，不做文件 IO（性能约定，别改成 existsSync）', () async {
    final s = song('manual');
    await File('${docs.path}/artwork/manual.jpg').writeAsBytes([1]);
    expect(ArtworkStore.has(s), isFalse);
    expect(ArtworkStore.fileFor(s), isNull);
  });
}
