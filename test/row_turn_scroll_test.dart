/// 缺陷①的断言：**歌单页 / 壁纸页的列表被锁成永不滚动 ⇒ 超出一屏的内容点不到**。
///
/// ## 原样（改前）
/// `playlists_page.dart` 的 1 列 `ListView.builder` 与多列 `GridView.builder`、
/// 以及 `wallpaper_page.dart` 的 `ListView` 都写死 `NeverScrollableScrollPhysics`，
/// 外面又是 `Expanded → Column → SafeArea`（再往上没有任何可滚动祖先）⇒ 内容比视口高时
/// 下面那截被**静默裁掉**，永远滑不出来；而手指上滑会被外层垂直 `PageView` 吃掉
/// （变成翻到「下行」）。
///
/// ## 为什么不能只把 physics 换成 Clamping
/// 内层滚动会赢下手势竞技场（Flutter 里更深的 `Scrollable` 必胜）⇒
/// 「上滑去下行」这条既有导航就断了。所以按设置页那套补：**滑到底之后再上滑 → 翻页**
/// （`lib/row_turn.dart` + `widgets/row_turn_scroll.dart`，三个页面共用一套）。
/// 内容**装得下**时不用这条 —— `shouldAcceptUserOffset` 为假 ⇒ Flutter 连拖拽识别器
/// 都不注册（`scrollable.dart:775-785`）⇒ 手势原样落给外层 `PageView`，与改前逐像素一致。
///
/// ## 判定语义（**一次滑动 = 一个动作**）
/// 旧判定是「累积溢出 > 50px 就翻」⇒ 往下滚列表、刚滚到底、手指还没抬又多拖了 50px
/// 就**误翻页**（在设置页被坑过好几次：滚到底跳「自定义特效」页）。新判定：
/// * 手指按下时**已经在底部** ⇒ 这一次滑动才可能翻页（仍要越过 50px，防手抖）；
/// * 手指按下时**不在底部** ⇒ 这一次滑动**只负责滚到底**，拖多远都不翻，要翻**再滑一次**；
/// * 手势**中途**才到底 ⇒ 不算「已在底」。
///
/// 本组断言的 ★6/★7/★8 就是这三条：**第一次大拖（溢出 110px，旧判定必翻）⇒ 页面必须
/// 停在原地**；紧接着**第二次**才翻。★9 量的是 50px 边界。
///
/// ## 这里用什么量
/// 真页面（真 `GridView`/`ListView`、真 `ScrollPosition`）+ 真垂直 `PageView`，
/// 读的是 `ScrollPosition.pixels / maxScrollExtent` 与 `PageController.page`，
/// 不是"看代码里写的是哪个 physics"。量具纪律同 `queue_panel_scroll_test.dart`：
/// **禁 `pumpAndSettle`**（本仓页面挂着常驻动画会一直等），一律固定时长 `pump`。
library;

import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/library_data.dart';
import 'package:mu_box_phone/pages/playlists_page.dart';
import 'package:mu_box_phone/pages/settings_page.dart';
import 'package:mu_box_phone/pages/wallpaper_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:mu_box_phone/row_turn.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const MethodChannel _kPathProvider =
    MethodChannel('plugins.flutter.io/path_provider');

late Directory _docs;

/// 哑播放器：本文件只渲页面，一次原生调用都不许发生。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub-rowturn';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 走两拍稳定状态：lazy 列表要到下一帧才按新 offset 重建可见项
/// （只 pump 一拍时 `pixels` 已经对了、`find` 到的子树还是旧的 ⇒ 断言会假红）。
Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 16));
}

/// 把「翻页 / 回弹」这类**动画**真的跑完。
///
/// ⚠️ 为什么不能只 `_settle`：动画 ticker 的起点是拖动之后的**第一帧**
/// （`Ticker._startTime ??= timeStamp`），所以第一次 `pump(400ms)` 只算「起跑」，
/// 第二次 `pump(16ms)` 才走了 16ms —— 实测 `nextPage()`（280ms）那一刻停在
/// `page=0.1589`（`easeOutCubic(16/280)`），会被误判成「没翻页」。
/// ⛔ 依旧不用 `pumpAndSettle`（本仓页面挂着常驻动画，会一直等）。
Future<void> _settleMotion(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// 把逻辑视口钉死（`physicalSize` ÷ `devicePixelRatio` = 逻辑尺寸）。
/// 顺带证明这些用例**不依赖真机分辨率**。
void _setSurface(WidgetTester tester, Size logical) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.reset);
}

/// 把页面挂进一棵**真**垂直 `PageView` 里（与 `root_page.dart:102-138` 同形状）。
Future<PageController> _boot(
  WidgetTester tester, {
  required Widget page,
}) async {
  final ctrl = PageController();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: PageView(
          controller: ctrl,
          scrollDirection: Axis.vertical,
          children: [page, const Center(child: Text('下行'))],
        ),
      ),
    ),
  );
  await _settle(tester);
  return ctrl;
}

/// 页面里那个垂直可滚动列表的滚动位置（⚠️ 必须限定在页面自己的滚动件之内：
/// 外层 `PageView` 自己也是 `Scrollable`，裸 `find.byType(Scrollable).first` 会拿到它
/// ⇒ 断言恒为「没滚」的假绿）。
///
/// ⚠️ 再用 `.first`：**设置页的 `ListView` 里嵌着一个 `GridView`**（主题色 8 格，
/// `shrinkWrap` + `NeverScrollableScrollPhysics`）—— 它自己也是个 `Scrollable`，
/// 于是「列表的子树里有几个 Scrollable」= 2，`tester.state` 会抛 `Bad state: Too many elements`
/// （实测）。深度优先遍历里**列表自己那个 Scrollable 排在前面**，`.first` 拿的就是它。
ScrollPosition _posIn(WidgetTester tester, Finder scrollView) =>
    tester
        .state<ScrollableState>(
          find
              .descendant(of: scrollView, matching: find.byType(Scrollable))
              .first,
        )
        .position;

Finder get _grid => find.byType(GridView);
Finder get _list => find.byType(ListView);

Future<PageController> _bootPlaylists(
  WidgetTester tester, {
  required int playlists,
  int columns = 2,
  Size surface = const Size(360, 800),
  ValueChanged<bool>? onDetailChanged,
}) async {
  _setSurface(tester, surface);
  AppConfig.instance.playlistColumns = columns;
  final lib = Library.instance;
  lib.loading = false;
  lib.permDenied = false;
  lib.playlists = {
    for (var i = 0; i < playlists; i++) '歌单$i': const <int>[],
  };
  return _boot(
    tester,
    page: PlaylistsPage(onDetailChanged: onDetailChanged),
  );
}

/// 挂**真设置页**（第三个共用这套判定的页面；原先它自己写了一份 `_handleScroll`）。
Future<PageController> _bootSettings(
  WidgetTester tester, {
  Size surface = const Size(360, 800),
}) async {
  _setSurface(tester, surface);
  final lib = Library.instance;
  lib.loading = false;
  lib.permDenied = false;
  return _boot(tester, page: const SettingsPage());
}

/// 把列表停在「离底 30px」——手势开始时**不在底部**的确定起点。
///
/// ⚠️ 用 `clamp` 兜住「整页只溢出不到 30px」的机型：那样落在顶部（`0 < max`，
/// 依旧算「不在底」，断言不受影响）。
double _stopShortOfBottom(ScrollPosition pos) =>
    (pos.maxScrollExtent - 30).clamp(0.0, pos.maxScrollExtent);

/// **量具自证**：证明「这一次拖动在**旧判定**下必然会翻页」。
///
/// 旧判定 = 累积溢出 > 50。`tester.drag` 会先走掉 [kDragSlopDefault]（20px）的拖拽 slop
/// （`DragStartBehavior.start` 下这 20px **不落到滚动上**，实测见 `row_turn.dart` 的
/// ★6/★7 打印：拖 120 ⇒ 溢出 100），剩下的才真的驱动列表；其中「滚到底」用掉
/// `travelled` 像素，多出来的就是溢出量。
///
/// ⚠️ 没有这条前置断言，用例可能是**没牙的**：比如设置页的 `maxScrollExtent` 是**估算值**、
/// 滚动中会变（实测 628.7 → 712.5），一次「离底 30px + 拖 160px」可能只溢出 20 多像素，
/// 旧判定本来就不会翻 —— 那样 ★8 就算绿也证明不了新判定有用。
void _assertOldRuleWouldTurn({
  required String tag,
  required double dragDistance,
  required double startPx,
  required ScrollPosition pos,
}) {
  final applied = dragDistance - kDragSlopDefault; // 真正落给滚动的量
  final travelled = pos.pixels - startPx; // 其中「滚到底」用掉的部分
  final overscroll = applied - travelled;
  // ignore: avoid_print
  print('ROWTURN: $tag 旧判定会攒到 $overscroll（拖 $dragDistance - slop '
      '$kDragSlopDefault - 滚到底用掉 $travelled）');
  expect(overscroll, greaterThan(kRowTurnThreshold),
      reason: '前置（量具自证）：这一次拖动在旧判定下必须攒够 > $kRowTurnThreshold 的溢出，'
          '否则本条用例没有牙（旧判定本来就不会翻）');
}

/// 每个用例的用例体都包一层：只为掐掉下面那条**已知噪音**，其余异常一个都不吞。
///
/// 歌单页左侧抽屉和队列浮层一个毛病：`ListTile` 与最近的 `Material` 祖先之间夹着
/// 一层有底色的玻璃容器 ⇒ debug 下每个被构建的 ListTile 各报一条
/// `ListTile background color…`（`list_tile.dart` 的 `_debugCheckBackgroundIsHidden`，
/// 框架层已知的观感告警，**故意不修**）。它只 debug 报、release 一条没有，但会把用例拖成
/// "Multiple exceptions (N)" 判红。
///
/// ⚠️ 必须**在用例体内**装（不能只在 `setUp` 里装）：`TestWidgetsFlutterBinding` 会在
/// `runTest` 开始时自己重置 `FlutterError.onError`，`setUp` 里装的那份会被盖掉
/// —— 实测踩过（噪音照样把用例判红）。
Future<void> _quiet(Future<void> Function() body) async {
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    final e = details.exception;
    if (e is FlutterError &&
        e.toString().contains('ListTile background color')) {
      return;
    }
    prev?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prev;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _docs = Directory.systemTemp.createTempSync('mubox_rowturn_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPathProvider, (call) async => _docs.path);
    playerService = PlayerService(player: _StubPlayer());
  });

  tearDown(() async {
    playerService = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPathProvider, null);
    await deleteTempDir(_docs);
  });

  // ───────────── 歌单页 ─────────────

  testWidgets('★1 正向：32 张歌单卡（远超一屏）⇒ 网格真的能滚，最后一张卡能滑到并点得到',
      (tester) => _quiet(() async {
    var detail = false;
    await _bootPlaylists(
      tester,
      playlists: 30,
      onDetailChanged: (v) => detail = v,
    );

    // (a) 结构：physics 不许再是「永不滚动」
    final physics = tester.widget<GridView>(_grid).physics;
    expect(physics, isNot(isA<NeverScrollableScrollPhysics>()),
        reason: '★ physics 仍是 NeverScrollable ⇒ 下面的行永远滑不出来（本缺陷的原样）');
    expect(physics, isA<ClampingScrollPhysics>(),
        reason: '与设置页同一套（Bouncing 不发 OverscrollNotification，判定不会触发）');

    final pos = _posIn(tester, _grid);
    // ignore: avoid_print
    print('ROWTURN: grid vp=${pos.viewportDimension} max=${pos.maxScrollExtent}');
    expect(pos.maxScrollExtent, greaterThan(100),
        reason: '前置：30 张卡在 360×800 上必须真的超出一屏（否则本用例测的是空气）');

    // (b) 行为：真拖一把，偏移必须动
    await tester.drag(_grid, const Offset(0, -300));
    await _settle(tester);
    expect(pos.pixels, greaterThan(0),
        reason: '★ 拖了 300px 而 offset 还是 0 ⇒ 视口在静默裁剪（缺陷①的症状）');

    // (c) 最后一张卡必须能被滑进视口
    pos.jumpTo(pos.maxScrollExtent);
    await _settle(tester);
    final last = find.text('歌单29');
    expect(last, findsOneWidget, reason: '滑到底后最后一张卡必须被构建出来（懒列表）');
    final vp = tester.getRect(_grid);
    final card = tester.getRect(last);
    expect(card.bottom, lessThanOrEqualTo(vp.bottom + 0.5),
        reason: '最后一张卡的下边被视口切掉了：$card vs $vp');
    expect(card.top, greaterThanOrEqualTo(vp.top - 0.5), reason: '同理上边');

    // (d) 点得到：点它必须真的进得去（能滑到 ≠ 能点到）
    await tester.tap(last);
    await _settle(tester);
    expect(detail, isTrue, reason: '★ 点最后一张卡必须进得了它的详情');
    expect(_grid, findsNothing, reason: '★ 进详情后网格该整个换掉');
  }));

  testWidgets('★1b 正向：1 列（长方形横条）那条分支同样可滚',
      (tester) => _quiet(() async {
    await _bootPlaylists(tester, playlists: 30, columns: 1);

    final physics = tester.widget<ListView>(_list).physics;
    expect(physics, isA<ClampingScrollPhysics>(),
        reason: '★ 1 列分支同样写死过 NeverScrollable');
    final pos = _posIn(tester, _list);
    expect(pos.maxScrollExtent, greaterThan(100), reason: '前置：超出一屏');
    await tester.drag(_list, const Offset(0, -300));
    await _settle(tester);
    expect(pos.pixels, greaterThan(0), reason: '★ 1 列分支也要真的能滚');
  }));

  testWidgets('★2 反向：装得下时「上滑 ⇒ 翻到下行」照旧，且列表一个像素都不动',
      (tester) => _quiet(() async {
    final ctrl = await _bootPlaylists(tester, playlists: 1); // 3 张卡，一屏装得下

    final pos = _posIn(tester, _grid);
    expect(pos.maxScrollExtent, 0.0,
        reason: '前置：装得下（min==max==0）⇒ Flutter 不注册拖拽识别器，手势归外层');

    expect(ctrl.page, 0.0);
    await tester.drag(_grid, const Offset(0, -600));
    await _settleMotion(tester);
    // ignore: avoid_print
    print('ROWTURN: fits pixels=${pos.pixels} page=${ctrl.page}');
    expect(pos.pixels, 0.0, reason: '★ 装得下时列表不许被拖走（改前就是这个行为）');
    expect(ctrl.page, closeTo(1.0, 0.01),
        reason: '★ 上滑去下行是既有导航，换 physics 不许把它弄坏');
  }));

  testWidgets('★3 溢出时也不卡死：滑到底后继续上滑 ⇒ 翻到下行',
      (tester) => _quiet(() async {
    final ctrl = await _bootPlaylists(tester, playlists: 30);

    final pos = _posIn(tester, _grid);
    pos.jumpTo(pos.maxScrollExtent); // 用户滑到底
    await _settle(tester);
    expect(ctrl.page, 0.0, reason: '前置：还在上行');

    await tester.drag(_grid, const Offset(0, -120)); // 到底之后再上滑
    await _settleMotion(tester);
    expect(ctrl.page, closeTo(1.0, 0.01),
        reason: '★ 内层能吃手势之后，「上滑去下行」必须靠这条判定接回来');
  }));

  // ───────────── 壁纸页 ─────────────

  testWidgets('★4 壁纸页：内容超出一屏时同样能滚（同一处理，不是只改歌单页）',
      (tester) => _quiet(() async {
    // 360×640 是常见小屏；这一页内容实测 672 高（标题 + 200 预览 + 设置卡 + 底部留白）
    _setSurface(tester, const Size(360, 640));
    final page = const WallpaperPage();
    final ctrl = await _boot(tester, page: page);

    final physics = tester.widget<ListView>(_list).physics;
    expect(physics, isA<ClampingScrollPhysics>(),
        reason: '★ 壁纸页原先也写死 NeverScrollableScrollPhysics');
    final pos = _posIn(tester, _list);
    // ignore: avoid_print
    print('ROWTURN: wallpaper vp=${pos.viewportDimension} max=${pos.maxScrollExtent}');
    expect(pos.maxScrollExtent, greaterThan(0),
        reason: '前置：这一页在小屏上确实超出一屏（「恢复默认背景」那张卡会掉到屏幕外）');

    // 先拉一小把：只够滚到底（溢出的那点还不满 50）⇒ 先滚、不翻页
    // ★ 新语义下更强的理由：**手势开始时不在底** ⇒ 这一次滑动本来就不许翻
    await tester.drag(_list, const Offset(0, -60));
    await _settle(tester);
    // ignore: avoid_print
    print('ROWTURN: wallpaper pixels=${pos.pixels} page=${ctrl.page}');
    expect(pos.pixels, greaterThan(0), reason: '★ 壁纸页也必须真的能滚');
    expect(ctrl.page, 0.0, reason: '★ 不在底 ⇒ 这一次滑动只负责滚到底，不翻页');

    // 已经到底了，再滑一次 ⇒ 翻到下行（与歌单页同一套判定）
    await tester.drag(_list, const Offset(0, -120));
    await _settleMotion(tester);
    expect(ctrl.page, closeTo(1.0, 0.01), reason: '★ 壁纸页的上滑去下行也要接回来');
  }));

  testWidgets('★5 壁纸页反向：装得下时上滑照旧翻到下行',
      (tester) => _quiet(() async {
    _setSurface(tester, const Size(360, 900)); // 高屏：内容装得下
    final ctrl = await _boot(tester, page: const WallpaperPage());

    final pos = _posIn(tester, _list);
    // ignore: avoid_print
    print('ROWTURN: wallpaper-tall max=${pos.maxScrollExtent}');
    expect(pos.maxScrollExtent, 0.0, reason: '前置：装得下');
    await tester.drag(_list, const Offset(0, -700));
    await _settleMotion(tester);
    expect(pos.pixels, 0.0, reason: '★ 装得下时列表不许被拖走');
    expect(ctrl.page, closeTo(1.0, 0.01), reason: '★ 上滑去下行照旧');
  }));

  // ───────── 新语义：一次滑动 = 一个动作 ─────────
  //
  // 这三条（★6/★7/★8）就是用户的抱怨本身：**往下滚列表，刚滚到底、手指还没抬、
  // 又多拖了一段 ⇒ 页面自己翻走了**。★6/★7/★8 的第一段拖动都故意做成
  // 「开始时离底 30px、拖 160px（落地溢出 ≈ 110px，旧判定必翻）」，
  // 然后把「这一次不许翻」钉死；第二段才允许翻。

  testWidgets('★6 歌单页：不在底的那一次滑动**只滚到底、不翻页**，再滑一次才翻',
      (tester) => _quiet(() async {
    final ctrl = await _bootPlaylists(tester, playlists: 30);
    final pos = _posIn(tester, _grid);

    final start = _stopShortOfBottom(pos);
    pos.jumpTo(start); // 用户自己滚到离底 30px 的地方
    await _settle(tester);
    expect(pos.pixels, lessThan(pos.maxScrollExtent),
        reason: '前置：手指按下时**不在底**（这就是被坑的场景）');

    // 这一次滑动拖得足够远：旧判定（累积溢出 > 50）在这里**必然翻页**
    await tester.drag(_grid, const Offset(0, -160));
    await _settleMotion(tester);
    // ignore: avoid_print
    print('ROWTURN: ★6 第一次拖 px=${pos.pixels}/${pos.maxScrollExtent} page=${ctrl.page}');
    expect(pos.pixels, pos.maxScrollExtent, reason: '这一次滑动该把列表滚到底');
    _assertOldRuleWouldTurn(
      tag: '★6',
      dragDistance: 160,
      startPx: start,
      pos: pos,
    );
    expect(ctrl.page, 0.0,
        reason: '★ 手势开始时不在底 ⇒ 这一次滑动**坚决不翻页**（一次滑动 = 一个动作）');

    // 第二次：手指按下时已经在底 ⇒ 这一次才翻
    await tester.drag(_grid, const Offset(0, -120));
    await _settleMotion(tester);
    // ignore: avoid_print
    print('ROWTURN: ★6 第二次拖 px=${pos.pixels}/${pos.maxScrollExtent} page=${ctrl.page}');
    expect(ctrl.page, closeTo(1.0, 0.01), reason: '★ 已经到底了 ⇒ 再滑一次就该翻到下行');
  }));

  testWidgets('★7 壁纸页：同一套判定（不在底只滚到底、已在底一次就翻）',
      (tester) => _quiet(() async {
    _setSurface(tester, const Size(360, 640));
    final ctrl = await _boot(tester, page: const WallpaperPage());
    final pos = _posIn(tester, _list);
    expect(pos.maxScrollExtent, greaterThan(0), reason: '前置：这一页在小屏上超出一屏');

    pos.jumpTo(_stopShortOfBottom(pos));
    await _settle(tester);
    expect(pos.pixels, lessThan(pos.maxScrollExtent), reason: '前置：不在底');
    final start7 = pos.pixels;

    await tester.drag(_list, const Offset(0, -160));
    await _settleMotion(tester);
    // ignore: avoid_print
    print('ROWTURN: ★7 第一次拖 px=${pos.pixels}/${pos.maxScrollExtent} page=${ctrl.page}');
    expect(pos.pixels, pos.maxScrollExtent, reason: '这一次滑动该把列表滚到底');
    _assertOldRuleWouldTurn(
      tag: '★7',
      dragDistance: 160,
      startPx: start7,
      pos: pos,
    );
    expect(ctrl.page, 0.0, reason: '★ 壁纸页同样：不在底 ⇒ 这一次不翻');

    await tester.drag(_list, const Offset(0, -120));
    await _settleMotion(tester);
    expect(ctrl.page, closeTo(1.0, 0.01), reason: '★ 已在底 ⇒ 再滑一次就翻');
  }));

  testWidgets('★8 设置页：用户被坑的那一页 —— 不在底只滚到底、已在底一次就翻',
      (tester) => _quiet(() async {
    // ⚠️ 宽度特意取 420 而不是 360：360 宽下这一页**本来就**有一条与本次改动无关的
    // 横向溢出（`SegmentedButton` 自己的内部 Row，`settings_page.dart` 歌单列数那张卡，
    // 实测 1.6px —— `RowTurnScroll` 不加任何约束/padding，不是它引起的）。
    // 那条 debug-only 的溢出会把用例拖成 "Multiple exceptions" 判红，所以这里绕开它；
    // 本用例要的是**纵向**溢出（下面有 maxScrollExtent 前置断言）。
    final ctrl = await _bootSettings(tester, surface: const Size(420, 640));
    final pos = _posIn(tester, _list); // 这一页只有一个 ListView
    // ignore: avoid_print
    print('ROWTURN: ★8 设置页 vp=${pos.viewportDimension} max=${pos.maxScrollExtent}');
    expect(pos.maxScrollExtent, greaterThan(100),
        reason: '前置：设置页在 420×640 上必须真的超出一屏（否则本用例测的是空气）');

    // ⚠️ 先真的滑到底一次：这一页的 `maxScrollExtent` 是**懒列表的估算值**，会在滚动中
    // 变大（实测 628.7 → 712.5）。先把尾巴构建出来，后面「离底 30px」才是个确定的起点。
    pos.jumpTo(pos.maxScrollExtent);
    await _settle(tester);
    pos.jumpTo(_stopShortOfBottom(pos));
    await _settle(tester);
    final start8 = pos.pixels;
    expect(start8, lessThan(pos.maxScrollExtent), reason: '前置：不在底');
    expect(ctrl.page, 0.0, reason: '前置：还在上行');

    await tester.drag(_list, const Offset(0, -160));
    await _settleMotion(tester);
    // ignore: avoid_print
    print('ROWTURN: ★8 第一次拖 px=${pos.pixels}/${pos.maxScrollExtent} page=${ctrl.page}');
    expect(pos.pixels, pos.maxScrollExtent, reason: '这一次滑动该把设置页滚到底');
    _assertOldRuleWouldTurn(
      tag: '★8',
      dragDistance: 160,
      startPx: start8,
      pos: pos,
    );
    expect(ctrl.page, 0.0,
        reason: '★ 设置页：往下滚到底不许翻到「自定义特效」页（用户的原症状）');

    await tester.drag(_list, const Offset(0, -120));
    await _settleMotion(tester);
    expect(ctrl.page, closeTo(1.0, 0.01),
        reason: '★ 已经在底了 ⇒ 这一次滑动才翻到自定义页（既有的「上滑去下行」不许断）');
  }));

  testWidgets('★9 歌单页阈值边界：已在底但拖不够（溢出 40）不翻，拖够了（80）才翻',
      (tester) => _quiet(() async {
    final ctrl = await _bootPlaylists(tester, playlists: 30);
    final pos = _posIn(tester, _grid);
    pos.jumpTo(pos.maxScrollExtent); // 已经在底
    await _settle(tester);
    expect(pos.pixels, pos.maxScrollExtent, reason: '前置：已在底');

    // 拖 60px ⇒ 扣掉拖拽 slop(~20) 后落地溢出 ≈ 40 ≤ 50 ⇒ 不许翻（最小拖动量真有牙）
    await tester.drag(_grid, const Offset(0, -60));
    await _settleMotion(tester);
    // ignore: avoid_print
    print('ROWTURN: ★9 小拖 page=${ctrl.page}');
    expect(ctrl.page, 0.0, reason: '★ 溢出 40 不够 50 ⇒ 不翻（轻点/手抖不许翻页）');

    // 再拖 100px ⇒ 溢出 ≈ 80 > 50 ⇒ 翻（同一个手势资格下，攒够就翻）
    await tester.drag(_grid, const Offset(0, -100));
    await _settleMotion(tester);
    // ignore: avoid_print
    print('ROWTURN: ★9 大拖 page=${ctrl.page}');
    expect(ctrl.page, closeTo(1.0, 0.01), reason: '★ 已经在底、拖够了 ⇒ 翻');
  }));

  testWidgets('★10 已在底 + 手指按住不动很久再滑 ⇒ 照样一次就翻，但按住不动本身不翻',
      (tester) => _quiet(() async {
    final ctrl = await _bootPlaylists(tester, playlists: 30);
    final pos = _posIn(tester, _grid);
    pos.jumpTo(pos.maxScrollExtent);
    await _settle(tester);
    expect(pos.pixels, pos.maxScrollExtent, reason: '前置：已在底');

    final g = await tester.startGesture(tester.getCenter(_grid));
    await tester.pump(const Duration(milliseconds: 800)); // 手指按住不动很久
    expect(ctrl.page, 0.0, reason: '★ 只按住不动 ⇒ 一个动作都没发生（不是「轻点就翻」）');

    // 越过拖拽 slop（kTouchSlop 18）之后拖拽才算开始 ⇒ 那一刻的「已在底」才是资格来源
    await g.moveBy(const Offset(0, -20));
    await tester.pump(const Duration(milliseconds: 16));
    await g.moveBy(const Offset(0, -100));
    await tester.pump(const Duration(milliseconds: 16));
    await g.up();
    await _settleMotion(tester);
    // ignore: avoid_print
    print('ROWTURN: ★10 按住后滑 page=${ctrl.page}');
    expect(ctrl.page, closeTo(1.0, 0.01),
        reason: '★ 已在底 + 真的滑了一把 ⇒ 一次就翻（按住多久都不影响）');
  }));
}
