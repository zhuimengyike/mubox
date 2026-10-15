/// **右下角搜索悬浮按钮 + 全局搜索**（`search_fab`）。
///
/// ## 要解决的是什么
/// 需求：设置里加一个开关，开不开自行决定；开了就在右下角（播放栏上方）
/// 放一个带圆角的正方形按钮，按下去直接进入搜索界面，搜索范围是整个曲库。
///
/// 1. 歌单详情页那颗放大镜的搜索面板抽成公共组件
///    （`lib/widgets/song_search_sheet.dart`），**行为逐项不变**；
/// 2. 根页面右下角（播放栏上方）多一颗圆角正方形悬浮按钮，点它 = 直接搜**整个曲库**；
/// 3. 开关 = `AppConfig.instance.searchFabEnabled`（prefs `search_fab`，**缺省 false**）。
///
/// ## 每条都配正/负一对
/// * ★1 老入口（歌单详情页放大镜）行为不变：标题 / 条数 / 结果子集；
/// * ★2 开关缺省 false ⇒ 按钮**不在树上**；置 true ⇒ 出现 + 点它直接进搜索界面；
///   再置 false ⇒ 消失（正负在同一条里）；
/// * ★3 全局搜索：歌单外的歌能搜到；**私密歌一首都不出现**；
/// * ★4 ★3 的负向对照：**同一台量具**（同一个 `showSongSearchSheet`）喂
///   `Library.instance.songs`（含私密）⇒ 私密歌立刻被搜出来 ⇒ 证明 ★3 的绿是过滤生效，
///   不是"搜索坏了所以搜不到"；
/// * ★5 全局搜索的集合就是 `songsOf(kAllSongs)`（换回 `songs` 这条立刻红）；
/// * ★6 享受页不显示（且回主页面又出现）；
/// * ★7 切开关 **不 bump rebuild**、也不惊动 `AppConfig` 自己的监听者；
/// * ★8 落盘 `search_fab`：开关两半都落盘、读得回来；
/// * ★9 几何：把**真 `PlayerBar`** 摆进与根页面同序的 Stack，量真矩形 ⇒ 与播放栏
///   **零重叠**；★10 是 ★9 的量具自证（人为压低 40px ⇒ 必须重叠）。
///
/// ## ⚠️ 两条已经踩过的量具纪律
/// 1. **禁 `pumpAndSettle`**（本仓页面挂着常驻动画会一直等），一律固定时长 `pump`；
/// 2. **`AppConfig` 缓存了自己那份 `SharedPreferences` 实例**（`app_config.dart` 的
///    `_prefs`，见 `bg_hint_test.dart` 文件头那段 ⚠️）：`setMockInitialValues` 只换底层
///    存储、**不换它**。所以「磁盘是干净的」这类断言**只能放在本文件第一个碰 AppConfig
///    的用例里**（★2），其后的用例一律**显式置值**，不指望 `load()` 读到空盘。
library;

import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/library_core.dart';
import 'package:mu_box_phone/library_data.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/pages/playlists_page.dart';
import 'package:mu_box_phone/pages/root_page.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:mu_box_phone/widgets/player_bar.dart';
import 'package:mu_box_phone/widgets/song_search_sheet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const MethodChannel _kPathProvider =
    MethodChannel('plugins.flutter.io/path_provider');
const MethodChannel _kAudioQuery =
    MethodChannel('com.lucasjosino.on_audio_query');
const MethodChannel _kPowerSave =
    MethodChannel('com.mubox.mu_box_phone/power_save');

late Directory _docs;

/// 哑播放器：本文只渲页面，一次原生调用都不许发生。
/// 没用到的成员一律抛 —— 服务里多调一个原生成员会当场响（与 `library_rescue_test`
/// 同一约定；`null` 兜底会把"多调了一个原生方法"静默咽掉）。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub-search';

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

// ───────────────────────── 现场：4 首歌，1 首私密 ─────────────────────────
//
// 故意的形状：歌单「我的歌单」只有甲、乙两首；丙只在库里、不在这个歌单里；
// 丁是私密歌（在库里，但任何公共面都不该看见它）。

const String _s1 = '歌单里的歌甲';
const String _s2 = '歌单里的歌乙';
const String _s3 = '歌单外的歌丙';
const String _secret = '私密歌丁';

Song _mk(String title) => Song(
      id: stableIdOfPath('/docs/music/$title.mp3'),
      title: title,
      artist: '某某歌手',
      durationMs: 1000,
      uri: '',
      filePath: '/docs/music/$title.mp3',
    );

late Song _a;
late Song _b;
late Song _c;
late Song _p;

/// 把曲库摆成上面那个形状（**直接给内存字段**：省掉整条扫描链）。
Future<void> _fixtureLibrary() async {
  _a = _mk(_s1);
  _b = _mk(_s2);
  _c = _mk(_s3);
  _p = _mk(_secret);
  final lib = Library.instance;
  lib.songs = [_a, _b, _c, _p];
  lib.allOrder = [_a.id, _b.id, _c.id, _p.id];
  lib.playlists = {
    '我的歌单': [_a.id, _b.id],
  };
  lib.loading = false;
  lib.permDenied = false;
  // 私密名单走 App 自己的入口（`setPrivate` 会一并落盘 prefs）
  await lib.setPrivate(_p, value: true);
}

/// 逻辑视口钉死（`physicalSize` ÷ `devicePixelRatio` = 逻辑尺寸）。
void _setSurface(WidgetTester tester, [Size logical = const Size(360, 800)]) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.reset);
}

/// 走几拍稳定状态。
///
/// ⚠️ **一拍不够**：动画 ticker 的起点在**下一帧**（`Ticker._startTime ??= timeStamp`）
/// ⇒ 第一次 `pump(300ms)` 只是"起跑"，真正推进的只有第二次那 16ms。
/// 实测（本文件 ★3 第一版就是这么红的）：弹层入场 250ms，`pump(300)+pump(16)` 之后
/// 面板才升起来 21%（`Rect(1.0, 673.3, 359.0, 1273.3)`），"歌手"那颗分段按钮还在屏幕外
/// （y=834 > 800）⇒ `tap` 打空、断言红在别处，特别难查。
/// ⛔ 依旧不用 `pumpAndSettle`：本仓页面挂着常驻动画（氛围层/频谱），那样会一直等。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// 掐掉**已知噪音**：`ListTile` 与最近的 `Material` 祖先之间夹着一层有底色的玻璃容器
/// ⇒ debug 下报 `ListTile background color…`（框架层已知的观感告警，**故意不修**，release
/// 一条没有）。不掐它会把用例拖成 "Multiple exceptions" 判红，把真断言淹掉。
/// ⚠️ 必须**在用例体内**装：binding 会在 `runTest` 开始时重置 `FlutterError.onError`。
Future<void> _quiet(Future<void> Function() body) async {
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    final e = details.exception;
    if (e is FlutterError && e.toString().contains('ListTile background color')) {
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

/// 挂**真歌单页**（歌单详情页那颗放大镜 = 抽组件前就有的老入口）。
Future<void> _pumpPlaylists(WidgetTester tester) async {
  _setSurface(tester);
  await tester.pumpWidget(
    const MaterialApp(home: Scaffold(body: PlaylistsPage())),
  );
  await _settle(tester);
}

/// 挂**真根页面**（六页 + 播放栏 + 右下角悬浮按钮都在里面）。
Future<void> _pumpRoot(WidgetTester tester,
    [Size surface = const Size(360, 800)]) async {
  _setSurface(tester, surface);
  await tester.pumpWidget(const MaterialApp(home: RootPage()));
  await _settle(tester);
  // 前置：内存里的曲库夹具必须还在（根页面 `initState` 会调 `Library.instance.init()`；
  // 万一它真跑了一遍扫描，夹具就被冲掉了 —— 那种情况必须当场红，而不是静默搜不到歌）
  expect(Library.instance.songs, hasLength(4),
      reason: '前置：曲库夹具被冲掉了（`Library.init()` 又跑了一遍？）');
}

/// 打开弹层后，在搜索框里敲字（弹层里只有一个 `TextField`）。
Future<void> _type(WidgetTester tester, String q) async {
  await tester.enterText(find.byType(TextField), q);
  await tester.pump();
}

// ⚠️ 断言必须**限定在弹层之内**（`kSongSearchSheetKey`），两个理由：
// 1. 弹层背后的歌单页/曲库列表里也有同样的歌名 —— 裸 `find.text` 会一次匹配到两个；
// 2. 敲进搜索框的字**自己也是一个 `Text`**（`EditableText`）—— 搜"歌丙"时裸
//    `find.text('歌丙')` 会把输入框里那串也算上（实测 "Found 2 widgets"）。
Finder _inSheet(Finder f) =>
    find.descendant(of: find.byKey(kSongSearchSheetKey), matching: f);

/// 弹层结果列表里那一行（`ListTile`），不是输入框里的字。
Finder _row(String title) => _inSheet(find.widgetWithText(ListTile, title));

Finder get _noMatch => _inSheet(find.text('没有匹配的歌曲'));

/// 播放栏**主体**那个矩形（`player_bar.dart` 的 `Positioned(left:10,right:10,bottom:8)`
/// → `Material` → `BackdropFilter`）。
///
/// 播放栏自己那个 Stack 里有两个 `BackdropFilter`：队列浮层（`_panelHeight=320`）在前、
/// 主体在后 ⇒ 取 `.at(1)`。这条口径由 ★9 打印的两个矩形 + 两条自证断言钉住。
Rect _barRect(WidgetTester tester) => tester.getRect(
      find
          .descendant(
            of: find.byType(PlayerBar),
            matching: find.byType(BackdropFilter),
          )
          .at(1),
    );

/// 把「悬浮按钮摆在哪」单独量出来：**与 `root_page.dart` 同序同参数**
/// （按钮在前、播放栏在后；`right: kSearchFabRight` / `bottom: kSearchFabBottom`）。
Widget _fabOverBar({double bottom = kSearchFabBottom}) {
  return MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          Positioned(
            right: kSearchFabRight,
            bottom: bottom,
            child: SearchFab(onTap: () {}),
          ),
          const Positioned.fill(child: PlayerBar()),
        ],
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _docs = Directory.systemTemp.createTempSync('mubox_searchfab_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPathProvider, (call) async => _docs.path);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kAudioQuery, (call) async {
      if (call.method == 'permissionsRequest') return true;
      if (call.method == 'querySongs') return <Object?>[];
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSave, (call) async => null);
    playerService = PlayerService(player: _StubPlayer());
    AppConfig.instance.searchFabEnabled.value = false; // 每个用例都从缺省值起步
    // 先把 `Library` 真的初始化一遍（`_initialized=true`）：根页面 `initState` 会调
    // `Library.instance.init()`，初始化过就是空转，免得它在一片"没有原生通道"的测试
    // 环境里跑半条扫描链、把内存夹具冲掉。
    await Library.instance.reload();
    await _fixtureLibrary();
  });

  tearDown(() async {
    playerService = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPathProvider, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kAudioQuery, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPowerSave, null);
    await deleteTempDir(_docs);
  });

  // ───────────────── 一、抽组件：老入口行为逐项不变 ─────────────────

  testWidgets('★1 歌单详情页那条入口：标题仍是「搜索当前歌单」、结果仍是该歌单的子集',
      (tester) => _quiet(() async {
    await _pumpPlaylists(tester);

    // 进详情页（点歌单卡）
    await tester.tap(find.text('我的歌单').first);
    await _settle(tester);

    // 右上角那颗放大镜（tooltip 与改动前逐字符相同）
    await tester.tap(find.byTooltip('搜索当前歌单'));
    await _settle(tester);

    expect(_inSheet(find.text('搜索当前歌单')), findsOneWidget,
        reason: '★ 标题必须逐字符不变（用户看惯了这四个字）');
    expect(_inSheet(find.text('共 2 首 · 点歌曲播放')), findsOneWidget,
        reason: '★ 条数取自传入的歌单（不是全库）');
    expect(_row(_s1), findsOneWidget);
    expect(_row(_s2), findsOneWidget);
    expect(_row(_s3), findsNothing,
        reason: '★ 结果仍是**该歌单**的子集：库里那首不在本歌单的歌不许出现');
    expect(_row(_secret), findsNothing);

    // 搜本歌单里没有、库里有那首 ⇒ 必须「没有匹配」
    await _type(tester, _s3);
    expect(_noMatch, findsOneWidget,
        reason: '★ 这条入口搜的是当前歌单：搜"歌单外"那首必须搜不到');
  }));

  // ───────────────── 二、开关（本文第一个碰 AppConfig 的用例） ─────────────────

  testWidgets('★2 缺省 false ⇒ 按钮不在树上；置 true ⇒ 出现且点它就是搜索界面；再置 false ⇒ 消失',
      (tester) => _quiet(() async {
    // ⚠️ 本文件**只有这一条**能断言"磁盘是干净的"（见文件头纪律 2）
    // 真读盘：先 `resetStatic()` 再 `getInstance()`（见 ★8 那段的说明）
    SharedPreferences.resetStatic();
    final sp0 = await SharedPreferences.getInstance();
    expect(sp0.getBool('search_fab'), isNull,
        reason: '★ 缺省一个字节都不落盘：一落盘，"关了就是当前界面"就没有证据了');

    await AppConfig.load(); // 与冷启动同一条路：空 prefs
    expect(AppConfig.instance.searchFabEnabled.value, isFalse,
        reason: '★ 缺省必须还是 false（别写 `?? true`：老用户升级后不该凭空多一颗按钮）');

    await _pumpRoot(tester);
    expect(find.byKey(kSearchFabKey), findsNothing,
        reason: '★ 缺省 false ⇒ 这颗按钮**根本不在树上**（不是"透明了还挡点击"）');

    // 正向：当场打开（不重启）
    await AppConfig.instance.setSearchFabEnabled(true);
    await tester.pump();
    expect(find.byKey(kSearchFabKey), findsOneWidget, reason: '★ 置 true 之后必须出现');
    expect(find.byType(SearchFab), findsOneWidget);

    // 点它 = 直接进搜索界面
    await tester.tap(find.byKey(kSearchFabKey));
    await _settle(tester);
    expect(find.text('搜索曲库'), findsOneWidget, reason: '★ 按下去就直接进搜索界面');
    expect(find.text('共 3 首 · 点歌曲播放'), findsOneWidget,
        reason: '★ 搜的是整个曲库（3 = 4 首减掉私密那首）');

    // 关掉弹层 ⇒ 回到当前界面
    // ⚠️ 关闭按钮要**限定在弹层里**取：队列浮层右上角那颗 ✕ 也是 `Icons.close`，
    //    而它一直挂在树上、位置在屏幕外 ⇒ 裸 `.first` 会点到它（只报一条 warning、
    //    什么都不发生），于是"关掉了没有"变成一条没有牙的假绿。
    await tester.tap(_inSheet(find.byIcon(Icons.close)));
    await _settle(tester);
    expect(find.byKey(kSongSearchSheetKey), findsNothing,
        reason: '前置：弹层真的关掉了');
    await AppConfig.instance.setSearchFabEnabled(false);
    await tester.pump();
    expect(find.byKey(kSearchFabKey), findsNothing, reason: '★ 关掉就是当前状态');
  }));

  // ───────────────── 三、全局搜索：搜整个曲库 + 私密过滤 ─────────────────

  testWidgets('★3 全局搜索：歌单外的歌能搜到；★ 私密歌一首都不出现',
      (tester) => _quiet(() async {
    await AppConfig.instance.setSearchFabEnabled(true);
    await _pumpRoot(tester);

    await tester.tap(find.byKey(kSearchFabKey));
    await _settle(tester);

    // 正向：不在任何"当前歌单"上下文里，也能搜到库里的歌
    await _type(tester, _s3);
    expect(_row(_s3), findsOneWidget,
        reason: '★ 全局搜索必须能搜到"不在当前歌单里"的歌');
    // 歌单里的歌当然也能搜到
    await _type(tester, _s1);
    expect(_row(_s1), findsOneWidget);

    // 「歌名 / 歌手二选一」这条语义一个字没动：切到「歌手」再按歌手搜
    await tester.tap(_inSheet(find.text('歌手')));
    await tester.pump();
    await _type(tester, '某某'); // 三首歌的歌手都是「某某歌手」
    expect(_row(_s1), findsOneWidget, reason: '★ 歌手模式仍然是子串匹配');
    expect(_row(_s3), findsOneWidget);
    expect(_row(_secret), findsNothing,
        reason: '★ 私密过滤在歌手模式下同样成立（别只测歌名那一半）');

    // 切回「歌名」，再验私密那首
    await tester.tap(_inSheet(find.text('歌名')));
    await tester.pump();

    // ★★ 私密歌：一首都不许出现
    await _type(tester, _secret);
    expect(_row(_secret), findsNothing,
        reason: '★ 私密过滤：全局搜索是"从任意页面直接暴露界面"的路径，私密歌不许出现');
    expect(_noMatch, findsOneWidget);
  }));

  testWidgets('★4 ★3 的负向对照：同一个弹层喂 Library.instance.songs ⇒ 私密歌立刻被搜出来',
      (tester) => _quiet(() async {
    // 只管一件事：证明"搜不到私密歌"是**过滤**造成的，不是搜索链坏了。
    // 用同一台量具（同一个 `showSongSearchSheet`），只把集合换成含私密的那份。
    expect(Library.instance.songs.map((s) => s.title), contains(_secret),
        reason: '前置：私密歌确实在 `Library.instance.songs` 里（否则这条对照是空气）');

    _setSurface(tester);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (ctx) => TextButton(
              onPressed: () => showSongSearchSheet(
                ctx,
                songs: Library.instance.songs, // ← 故意不过滤（负向）
                title: '负向对照',
              ),
              child: const Text('开对照面板'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('开对照面板'));
    await _settle(tester);
    expect(find.text('负向对照'), findsOneWidget, reason: '前置：对照面板开了');

    await _type(tester, _secret);
    expect(_row(_secret), findsOneWidget,
        reason: '★ 同一台量具下私密歌**搜得到** ⇒ ★3 的"搜不到"才是过滤生效，'
            '不是搜索坏了（否则 ★3 是假绿）');
  }));

  test('★5 全局搜索的集合 = songsOf(kAllSongs)：库里那首在、私密那首不在', () {
    final all = globalSearchSongs();
    expect(all.map((s) => s.title).toList(), [_s1, _s2, _s3],
        reason: '★ 全局搜索搜的就是「全部歌曲」那份（顺序也照 allOrder）');
    expect(all.map((s) => s.title), isNot(contains(_secret)));
    // 负向对照的另一半：同一时刻的原始列表里**有**它
    expect(Library.instance.songs.map((s) => s.title), contains(_secret),
        reason: '★ 把上面那行换成 Library.instance.songs ⇒ 这条立刻红（私密歌漏出去）');
  });

  testWidgets('★5b 空曲库点悬浮按钮 ⇒ 提示「曲库还没有歌曲」、不开一个空弹层（与歌单页那条入口同规矩）',
      (tester) => _quiet(() async {
    // 歌单详情页那条入口对空歌单是「弹一句提示、不开面板」（`_enterSearch` 的守卫）；
    // 新开的全局入口照同一条规矩来 —— 否则用户会看到一个「共 0 首」的空面板。
    Library.instance.songs = [];
    Library.instance.allOrder = [];
    await AppConfig.instance.setSearchFabEnabled(true);

    _setSurface(tester);
    await tester.pumpWidget(const MaterialApp(home: RootPage()));
    await _settle(tester);

    await tester.tap(find.byKey(kSearchFabKey));
    await _settle(tester);

    expect(find.byKey(kSongSearchSheetKey), findsNothing,
        reason: '★ 空曲库不许开一个空搜索面板');
    expect(find.text('曲库还没有歌曲'), findsOneWidget, reason: '★ 要说话，别点了没反应');

    // 负向的另一半：把曲库填回去 ⇒ 同一颗按钮立刻能开面板
    Library.instance.songs = [_a, _b, _c, _p];
    Library.instance.allOrder = [_a.id, _b.id, _c.id, _p.id];
    await tester.pump();
    await tester.tap(find.byKey(kSearchFabKey));
    await _settle(tester);
    expect(find.text('搜索曲库'), findsOneWidget,
        reason: '★ 有歌的时候必须照常开（证明上面那条红的是"空库"，不是"按钮坏了"）');
  }));

  testWidgets('★6 六个页面逐个走一遍：只有享受页不给它，其余五页都在、且点得到',
      (tester) => _quiet(() async {
    await AppConfig.instance.setSearchFabEnabled(true);
    // ⚠️ 宽度取 420 而不是 360：`settings_page.dart`「歌单列数」那张卡在 360 宽下有
    // **1.6px 的横向溢出**（与本次改动无关的既有问题，`row_turn_scroll_test.dart`
    // 的 ★8 也为此绕开 360）。那是一条 debug-only 的渲染异常，会把用例判红。
    await _pumpRoot(tester, const Size(420, 800));
    expect(find.byKey(kSearchFabKey), findsOneWidget,
        reason: '前置：默认页（上行中列 = 歌单页）有它');

    // ⚠️ 走格子必须**先回到上行、再换列、最后才下行**：上下两行是懒建的
    // （`find.byType(PageView)` 只有 2 个 —— 看得见的那一行 + 外层），
    // 停在下行时**上行的 `PageView` 根本不在树上** ⇒ 按 `at(1)` 取"上行那个"
    // 会取到下行那个，于是"换列"实际是去推下行的锁死控制器：列号没变、
    // 断言红在一个看不出来的地方（实测踩过）。
    // 两行的区分靠 physics：上行 = 可滑（`_LoosePagePhysics`），下行 = `NeverScrollable`。
    PageController outer() => tester
        .widgetList<PageView>(find.byType(PageView))
        .firstWhere((p) => p.scrollDirection == Axis.vertical)
        .controller!;
    PageController topCol() => tester
        .widgetList<PageView>(find.byType(PageView))
        .firstWhere((p) =>
            p.scrollDirection == Axis.horizontal &&
            p.physics is! NeverScrollableScrollPhysics)
        .controller!;

    Future<void> go(int row, int col) async {
      outer().jumpToPage(0); // 先上行：保证上行那个 PageView 在树上
      await _settle(tester);
      topCol().jumpToPage(col);
      await _settle(tester);
      if (row != 0) {
        outer().jumpToPage(row);
        await _settle(tester);
      }
    }

    // 六个页面：上行 = 壁纸 / 歌单 / 设置，下行 = 享受 / 歌词 / 自定义
    await go(0, 0); // 壁纸页
    expect(find.byKey(kSearchFabKey), findsOneWidget, reason: '★ 壁纸页要有');
    await go(0, 2); // 设置页
    expect(find.byKey(kSearchFabKey), findsOneWidget, reason: '★ 设置页要有');

    await go(1, 0); // 享受页
    expect(AppConfig.instance.enjoyActive.value, isTrue,
        reason: '前置：根页面确实停在享受页（`_syncEnjoy` 与悬浮按钮读的是同一套 `_row/_col`）');
    expect(find.byKey(kSearchFabKey), findsNothing,
        reason: '★ 享受页是刻意留白的纯视觉页 ⇒ 六个页面里只有它不给这颗按钮');

    await go(1, 1); // 歌词页
    expect(find.byKey(kSearchFabKey), findsOneWidget, reason: '★ 歌词页要有');
    await go(1, 2); // 自定义页
    expect(find.byKey(kSearchFabKey), findsOneWidget, reason: '★ 自定义页要有');

    // 「全局」不只是"画在那儿"：在非默认页上点它，照样开搜索界面
    await tester.tap(find.byKey(kSearchFabKey));
    await _settle(tester);
    expect(find.text('搜索曲库'), findsOneWidget,
        reason: '★ 在自定义页上点这颗按钮也必须能开搜索（不是被页面盖住点不到）');
    await tester.tap(_inSheet(find.byIcon(Icons.close)));
    await _settle(tester);
    expect(find.byKey(kSongSearchSheetKey), findsNothing, reason: '前置：弹层真的关掉了');

    // 回到默认页 ⇒ 还在（不是"翻过页就再也不出现"）
    await go(0, 1);
    expect(AppConfig.instance.enjoyActive.value, isFalse);
    expect(find.byKey(kSearchFabKey), findsOneWidget, reason: '★ 回到默认页仍然在');
  }));

  test('★7 切开关：不 bump rebuild、也不惊动 AppConfig 自己的监听者', () async {
    final rev0 = AppConfig.instance.rebuildRevision.value;
    var appConfigNotified = 0;
    var fabNotified = 0;
    void onCfg() => appConfigNotified++;
    void onFab() => fabNotified++;
    AppConfig.instance.addListener(onCfg);
    AppConfig.instance.searchFabEnabled.addListener(onFab);
    addTearDown(() {
      AppConfig.instance.removeListener(onCfg);
      AppConfig.instance.searchFabEnabled.removeListener(onFab);
    });

    await AppConfig.instance.setSearchFabEnabled(true);
    await AppConfig.instance.setSearchFabEnabled(false);

    expect(AppConfig.instance.rebuildRevision.value, rev0,
        reason: '★ 它不是"要重建整棵 App"的配置（同 volumeFadeEnabled/crossfadeEnabled）：'
            'bump 一次 = 整棵 MaterialApp 重建');
    expect(appConfigNotified, 0,
        reason: '★ 连 notifyListeners 都不调：歌单页/设置页都监听着 AppConfig.instance，'
            '为这一颗按钮让它们各重建一次是白费');
    expect(fabNotified, 2,
        reason: '★ 显隐只由这个 ValueNotifier 驱动（照 enjoyActive 先例）⇒ 两次切换各推一次');
  });

  testWidgets('★8 落盘 search_fab：开/关两半都写进真 prefs，且读得回来',
      (tester) async {
    // ⚠️ 读盘必须**先 `resetStatic()` 再 `getInstance()`**：`SharedPreferences` 会把
    //    实例和它那份内存快照缓存起来（`_completer`），而 `AppConfig._prefs` 是**另一个**
    //    实例 —— 直接 `getInstance()` 拿到的是 setUp 里那份"空盘快照"，写着写着也看不见。
    //    `resetStatic()` 是包自己给的 `@visibleForTesting` 入口，用它才是**真读盘**。
    Future<bool?> disk() async {
      SharedPreferences.resetStatic();
      return (await SharedPreferences.getInstance()).getBool('search_fab');
    }

    await AppConfig.instance.setSearchFabEnabled(true);
    expect(await disk(), isTrue, reason: '★ 真的要落盘');
    await AppConfig.load();
    expect(AppConfig.instance.searchFabEnabled.value, isTrue, reason: '重启后仍是开的');

    await AppConfig.instance.setSearchFabEnabled(false);
    expect(await disk(), isFalse,
        reason: '★ 关也要落盘 —— 否则重启又自己开回来');
    await AppConfig.load();
    expect(AppConfig.instance.searchFabEnabled.value, isFalse, reason: '重启后仍是关的');
  });

  // ───────────────── 四、几何：不遮播放栏 ─────────────────

  testWidgets('★9 悬浮按钮与播放栏零重叠（真 PlayerBar 量真矩形）',
      (tester) => _quiet(() async {
    _setSurface(tester);
    await tester.pumpWidget(_fabOverBar());
    await _settle(tester);

    final bar = _barRect(tester);
    final fab = tester.getRect(find.byKey(kSearchFabKey));
    // ignore: avoid_print
    print('SEARCHFAB: 屏幕=${tester.view.physicalSize} 播放栏=$bar 悬浮按钮=$fab '
        '（按钮底 ${fab.bottom} vs 播放栏顶 ${bar.top}，间隙 ${bar.top - fab.bottom}）');

    expect(bar.height, lessThan(320),
        reason: '量具自证：取到的必须是**播放栏主体**（队列浮层是 320 高），取错了整条判据就没意义');
    expect(bar.bottom, closeTo(800 - 8, 0.5),
        reason: '量具自证：播放栏主体贴着屏幕底部 8px（`player_bar.dart` 的 `bottom: 8`）');
    expect(fab.right, closeTo(360 - kSearchFabRight, 0.5),
        reason: '右边距与播放栏同一列（right: 10）');
    expect(fab.width, kSearchFabSize);
    expect(fab.height, kSearchFabSize, reason: '带圆角的**正方形**');
    expect(fab.left, greaterThan(0), reason: '不许跑出屏幕左边');
    expect(fab.bottom, lessThanOrEqualTo(bar.top),
        reason: '★ 与播放栏重叠 ⇒ 会挡住进度条 / 上一首 / 播放 / 下一首 / 收藏 / A-B / 倍速 / 队列'
            '（播放栏实测 $bar，按钮 $fab）');
  }));

  testWidgets('★10 ★9 的量具自证：把按钮人为压低 40px ⇒ 必须重叠（这条判据有牙）',
      (tester) => _quiet(() async {
    _setSurface(tester);
    await tester.pumpWidget(_fabOverBar(bottom: kSearchFabBottom - 40));
    await _settle(tester);

    final bar = _barRect(tester);
    final fab = tester.getRect(find.byKey(kSearchFabKey));
    // ignore: avoid_print
    print('SEARCHFAB: 压低 40 之后 播放栏顶=${bar.top} 按钮底=${fab.bottom}');
    expect(fab.bottom, greaterThan(bar.top),
        reason: '★ 前提被破坏时必须真的重叠 —— 否则 ★9 只是"恒真"的假绿');
  }));
}
