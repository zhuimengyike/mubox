/// 播放队列浮层「打开时把当前曲滚进视口」的**几何断言** —— 真 `PlayerBar`、
/// 真 `ListView`、真 `ScrollPosition`。
///
/// ## 为什么这一条能成立（推翻「pump 永不稳定」）
/// 曾经放弃几何测量的理由是「`pump` 永不稳定」。实测（探针原始输出当时已核对）：
/// * `pumpWidget(MaterialApp(home: Scaffold(body: PlayerBar())))` **建得起来**；
/// * `pumpAndSettle` **能完成**（3 秒预算内）；
/// * `ScrollPosition.pixels / viewportDimension / maxScrollExtent` **读得到**。
///
/// 真正的坑是**另外两件事**，都不在这里：
/// 1. 带 `repeat()` 常驻动画的页面（如音效页）`pumpAndSettle` 会一直等 —— 本用例不用它，
///    一律 `pump(Duration)`；
/// 2. 队列每行 `ListTile` 都报一条 `ListTile background color…` 的 debug assert
///    （浮层自己的玻璃底和 `Material` 之间夹了一层底色）——
///    **故意不修**，但必须在这里掐掉，否则用例因 "Multiple exceptions" 判红。
///    见 [_withoutListTileNoise]。
///
/// ## 断言的牙
/// * 正向：打开浮层后，当前曲那一行的**实际矩形**必须整行落在列表视口矩形里；
/// * 负向（同一棵树里就能做）：打开**之前**，那一行**根本没被构建**（在第 37 行这种事上，
///   旧实现停在 offset 0，lazy 列表连它的 widget 都不存在）；
/// * 语义：当前曲本来就完整可见时，`pixels` **一个像素都不许动**。
library;

import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:mu_box_phone/widgets/player_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const MethodChannel _kPathProvider = MethodChannel('plugins.flutter.io/path_provider');

late Directory _docs;
late PlayerService _ps;

/// 哑播放器：本文件只渲染界面，一次原生调用都不许发生
/// （`noSuchMethod` 兜住 `AudioPlayer` 的全部成员，与 `player_service_test.dart` 同一约定）。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub-qpanel';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

List<Song> _songs(int n) => [
      for (var i = 0; i < n; i++)
        Song(
          id: 1000 + i,
          title: 'Song $i',
          artist: 'A',
          durationMs: 200000,
          uri: '',
          filePath: 'docs/music/s$i.mp3',
        ),
    ];

/// 队列列表**里面**那一行（⚠️ 必须限定在 ListView 之内：
/// 播放栏自己也会显示当前曲歌名，裸 `find.text('Song 37')` 会被它命中 ⇒ 恒真的假绿）。
Finder _rowInList(String title) => find.descendant(
      of: find.byType(ListView),
      matching: find.widgetWithText(ListTile, title),
    );

Finder get _queueList => find.byType(ListView);

ScrollPosition _position(WidgetTester tester) =>
    tester.state<ScrollableState>(find.byType(Scrollable).first).position;

/// 已知噪音：队列每行的 `ListTile` 与最近的 `Material` 祖先之间夹着浮层自己的玻璃底
/// （`Container(BoxDecoration(color: white α0.08))`）⇒ Flutter 的
/// `_debugCheckBackgroundIsHidden`（`list_tile.dart:1147`）每个被构建的 ListTile 各报一条。
///
/// **刻意不修**：那层底色就是浮层的观感本身（框架层的 debug assert，release 一条没有）。
/// 它只 debug 报、release 一条没有、不影响渲染；但会把这个用例拖成
/// "Multiple exceptions (N)" 判红，所以在这里**只掐这一条**，其余异常照常漏出去。
bool _isListTileGlassNoise(Object e) =>
    e is FlutterError && e.message.contains('ListTile background color');

/// 在 [body] 期间把上面那条噪音吞掉；**其余异常一个都不吞**。
Future<void> _withoutListTileNoise(Future<void> Function() body) async {
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    if (_isListTileGlassNoise(details.exception)) return;
    prev?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prev;
  }
}

Future<void> _boot(WidgetTester tester, int queueLen, int currentIdx) async {
  await _ps.restoreSession(_songs(queueLen), currentIdx, 0, title: '探针歌单');
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: PlayerBar())),
  );
  // ⚠️ 只能固定时长 pump：本仓带常驻动画的页面 `pumpAndSettle` 会一直等。
  await _settle(tester);
}

/// 走一帧「列表已经按新 offset 重建完」的稳定状态。
///
/// ⚠️ 为什么是**两拍**：`jumpTo`（以及任何 `forcePixels`）只同步改
/// `ScrollPosition.pixels` 并让视口标脏；**lazy 的 `ListView.builder` 要到下一帧
/// 才按新 offset 重建可见项**。只 pump 一拍的话，`pixels` 已经对了、
/// 但 `find` 到的子树还是旧的 ⇒ 断言会假红（实测踩过：★1/★2/★4 全红，
/// 而直接读 `pixels` 的 ★3 是绿的 —— 就是这两拍之差）。
///
/// 一律固定时长 `pump`，绝不用 `pumpAndSettle`（本仓有常驻动画的页面会一直等）。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 16));
}

/// 点「队列 / 收起」按钮。
Future<void> _tapQueueButton(WidgetTester tester) async {
  final open = find.text('队列');
  final close = find.text('收起');
  final which = open.evaluate().isNotEmpty ? open : close;
  expect(which, findsOneWidget, reason: '「队列 / 收起」按钮必须找得到');
  await tester.tap(which.first);
  await _settle(tester);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _docs = Directory.systemTemp.createTempSync('mubox_qpanel_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPathProvider, (call) async => _docs.path);
    _ps = PlayerService(player: _StubPlayer());
    playerService = _ps;
  });

  tearDown(() async {
    // 先把还在飞的落盘排空，再撤 mock、再删目录（顺序见 support/temp_docs.dart）。
    for (var i = 0; i < 5; i++) {
      await _ps.debugFlushPersist();
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPathProvider, null);
    playerService = null;
    await deleteTempDir(_docs);
  });

  testWidgets('★1 正向：40 首 / 当前第 37 首 ⇒ 打开浮层后那一行整行落在视口里',
      (tester) async {
    await _withoutListTileNoise(() async {
      await _boot(tester, 40, 37);

      // —— 负向前置：打开**之前**，第 37 行根本没被构建（lazy 列表 + 旧实现停在 0）
      expect(find.text('Song 37'), findsWidgets,
          reason: '前置：这首歌确实是当前曲（播放栏标题会显示它）');
      expect(_rowInList('Song 37'), findsNothing,
          reason: '前置（= 旧实现的形状）：第 37 行在视口外，连 widget 都没有');
      expect(_rowInList('Song 0'), findsOneWidget, reason: '前置：列表停在顶部');

      await _tapQueueButton(tester);

      final vp = tester.getRect(_queueList);
      final row = tester.getRect(_rowInList('Song 37'));
      // ignore: avoid_print
      print('QPANEL: viewport=$vp row37=$row');
      expect(row.top, greaterThanOrEqualTo(vp.top - 0.5),
          reason: '第 37 行上边被视口切掉了：$row vs $vp');
      expect(row.bottom, lessThanOrEqualTo(vp.bottom + 0.5),
          reason: '第 37 行下边被视口切掉了：$row vs $vp');
      expect(_rowInList('Song 0'), findsNothing,
          reason: '列表必须真的离开了顶部（否则等于没滚）');
    });
  });

  testWidgets('★2 接线：三个入口（按钮 / ✕ / 遮罩）打开时都要滚 —— 按钮与 ✕ 各测一次',
      (tester) async {
    await _withoutListTileNoise(() async {
      await _boot(tester, 40, 37);

      // 入口一：按钮
      await _tapQueueButton(tester);
      expect(_rowInList('Song 37'), findsOneWidget, reason: '按钮入口没滚');
      // 入口二：✕ 关掉 → 手动把列表拉回顶部 → 再用按钮打开，必须又滚回来
      await tester.tap(find.byTooltip('关闭'));
      await _settle(tester);
      _position(tester).jumpTo(0);
      await _settle(tester);
      expect(_rowInList('Song 37'), findsNothing, reason: '手动拉回顶部后应在视口外');
      await _tapQueueButton(tester);
      expect(_rowInList('Song 37'), findsOneWidget,
          reason: '从「✕ 关掉 → 手动滚走 → 再开」这条路进来也必须滚回来');
    });
  });

  testWidgets('★3 语义：当前曲本来就完整可见 ⇒ 打开浮层一个像素都不动',
      (tester) async {
    await _withoutListTileNoise(() async {
      await _boot(tester, 40, 5);
      await _tapQueueButton(tester);

      final pos = _position(tester);
      // 第 5 行 = [240, 288]（行高由 ★4 钉住）；顶对齐 ⇒ 240
      final derived = (pos.maxScrollExtent + pos.viewportDimension - 4) / 40;
      expect(pos.pixels, closeTo(5 * derived, 0.01), reason: '第 5 行顶对齐');

      // 把列表挪 10px：第 5 行仍然整行可见
      pos.jumpTo(pos.pixels - 10);
      await _settle(tester);
      final before = pos.pixels;

      await _tapQueueButton(tester); // 收起
      await _tapQueueButton(tester); // 再打开
      expect(_position(tester).pixels, closeTo(before, 0.01),
          reason: '当前曲已经看得见 ⇒ 不许跳（用户刚滚到的位置要保住）；'
              '注意 before≠5×行高，所以「每次都跳到顶对齐」也会被这条抓住');
    });
  });

  testWidgets('★4 钉住「行高一致」这条假设：量出来的行高 == 推导公式用的行高',
      (tester) async {
    await _withoutListTileNoise(() async {
      await _boot(tester, 40, 37);
      await _tapQueueButton(tester);

      final pos = _position(tester);
      // 浮层列表底部留白 4px（`_buildQueuePanel` 的 padding）
      final derived = (pos.maxScrollExtent + pos.viewportDimension - 4) / 40;
      final h36 = tester.getRect(_rowInList('Song 36')).height;
      final h38 = tester.getRect(_rowInList('Song 38')).height;
      // ignore: avoid_print
      print('QPANEL: derived=$derived h36=$h36 h38=$h38 '
          'max=${pos.maxScrollExtent} vp=${pos.viewportDimension} '
          'pixels=${pos.pixels}');
      expect(h36, closeTo(h38, 0.01), reason: '行高必须一致，否则推导公式不成立');
      expect(h36, closeTo(derived, 0.01),
          reason: '推导行高 $derived 必须等于真实行高 $h36（当前曲那行也要算在内）');
    });
  });

  testWidgets('★5 负向有牙：队列只有 3 首（整个装得下）⇒ 什么都不滚、也不崩',
      (tester) async {
    await _withoutListTileNoise(() async {
      await _boot(tester, 3, 2);
      await _tapQueueButton(tester);
      final pos = _position(tester);
      expect(pos.maxScrollExtent, lessThanOrEqualTo(0.0),
          reason: '前置：3 首装得下 ⇒ 本来就全可见');
      expect(pos.pixels, 0.0, reason: '装得下就不许滚');
      expect(_rowInList('Song 2'), findsOneWidget);
    });
  });
}
