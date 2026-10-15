/// 播放栏 / 歌词校准面板「白化 + 裸字形」断言。
///
/// **断言分两层，别混**：★1~★6 是**渲染级**（真 widget 进真 `MaterialApp`，量真树）；
/// ★7 / ★8 是**源级守卫**（读 `lib/` 源码文本，不渲染）。
/// ⚠️ ★8 **没有**渲染级断言 —— 原因见下面 `## 断言的牙` 里 ★8 那一条。
///
/// ## 产品规则是什么
/// 播放/暂停那颗按钮原先做成「主题色实心圆盘 + 挖空符号」，进度条也跟着主题色走。
/// 规则要求：**播放/暂停按钮与歌曲进度条一律裸字形 + 纯白，不跟主题色**；
/// 频谱不动，保留原样。
///
/// ⇒ 三处目标（`lib/widgets/player_bar.dart`）：
/// * 播放/暂停：`Icons.pause_circle_filled` / `Icons.play_circle_fill` 染 `primary`
///   （= 主题色实心圆盘，符号是挖空的）→ 裸字形 `Icons.pause` / `Icons.play_arrow` + `Colors.white`；
/// * 进度条：`Slider.activeColor: primary` → `Colors.white`（`inactiveColor: Colors.white12` 未动）；
/// * 频谱（`lib/widgets/spectrum.dart`）**一个字节都没动**。
///
/// ## 同一条产品规则推到全 app 最后两处
/// * **裸三角嫌大** ⇒ 播放栏那颗 `iconSize: 40 → 34`（只改数字，字形/颜色不动）；
/// * `lib/pages/lyrics_page.dart` 的「分段校准」面板（`_SegSheet`）里那颗播放/暂停
///   也是 circle **实心**那一族染 primary ⇒ 改成裸字形 + 白，`iconSize: 38 → 34`；
///   同面板的歌曲进度条 `activeTrackColor: primary → Colors.white`；
///   ⚠️ 口径说准：原先这里有一条例外 ——「`lib/` 里只剩
///   `search_download_page.dart` 那颗 `play_circle_**outline**`（**空心**、
///   "试听/预览"开关，不是播放控件），它刻意不纳入规则」。
///   **那个文件已随「全程离线」改造整份删除**（在线音源搜索下载页）
///   ⇒ 例外的对象不存在了，全 `lib/` 已经没有 circle 那一族的播放控件。
///   ★7 点名的那两个 circle-**filled** 名字仍然一个都不许出现（断言一字未动）。
/// * ⛔ **刻意没动**：同面板的 `ChoiceChip.selectedColor`、基准线 `Switch.activeThumbColor`、
///   基准线 `Slider.activeColor`（那些是**设置类**控件，主题色留在它们身上是对的）。
///   规则一句话：**播放/暂停控件 + 歌曲进度条 = 白；其它选择器/装饰保持主题色。**
///
/// ## 断言的牙（为什么本文件不是"看着是白的"）
/// * ★1~★3 是**结构性**的：直接读 `Icon.icon` / `Icon.color` / `Slider.activeColor` 三个字段。
///   ⚠️ **刻意不拿像素形状当图标字形的断言**：`flutter test` 里 Material 图标字体不全，
///   字形本身会渲染成方块 —— 那是正常现象，拿它判"是不是 pause 字形"只会编出一条假绿。
///   字形认 `Icon.icon` 属性 + 真机截图。
/// * ★4~★5 是**这条规则真正的牙**：把同一棵子树分别放到**两个非白的主题主色**（红 / 橙 / 绿）下，
///   断言三处**仍然是白**。⚠️ 只断言「== Colors.white」证明不了「不跟主题」——
///   必须有「换主题色 ⇒ 值不动」这一步。故 ★4/★5 里各带一条**量具自证**：
///   从 `PlayerBar` 自己的 context 读 `colorScheme.primary`，证明它**真的看得见**那个非白主色。
/// * ★4/★5 还带一条**不对称对照**：同一棵树、同一个主题下，队列浮层里那颗 `Checkbox`
///   （`activeColor: primary`，**规则没要求改它**）**必须跟着主题变** —— 它证明
///   「换主题后这棵树确实重建了」，于是三处目标「不动」才是一个有信息量的结果，
///   而不是"树根本没重建"造成的恒真。
/// * 几何（★6）：播放栏主体矩形、播放/暂停那颗 `IconButton` 的 `Size`/`Center`、
///   图标自身的渲染尺寸，全部与**改动前量到的值冻结比对**（⛔ 不是"看起来没变"）。
/// * ★7 是**全仓源级守卫**：扫 `lib/` 下全部 `.dart`（**原样文本，注释也算**），
///   `pause_circle_filled` / `play_circle_fill` 一个都不许再出现；带两条自证
///   ——「扫到多少个 `.dart`」与「读到的确实是源码（`Icons.xxx` 计数）」，
///   ⚠️ 后一条刻意用与被守卫名字**无关**的记号（早先拿裸字形当正向对照，
///   一收回修复它先红、报的却是"尺子坏了"，把诊断方向带反了）；
///   最后再补一条产品规则的**正面**写法：那两处必须真的含裸字形。
///   ⛔ **别在 `lib/` 的注释里把那两个被禁常量名拼出来** —— 它自己就会红
///   （被守卫的名字只要出现在 `lib/` 的文本里，不管在不在注释里都算违规）。
/// * ★8 是**源级守卫**（⚠️ **没有渲染级断言** —— 别误读）：切片
///   `lyrics_page.dart` 的 `_buildProgressBar` / `_buildSegActions`，断言歌词页
///   「分段校准」面板里那颗播放/暂停是裸字形 + 白 + `iconSize: 34`、歌曲进度条
///   `activeTrackColor` 是白，**并拿同一面板里"设置类控件仍吃主题色"作不对称对照**。
///   ★ **为什么不做渲染级**（实测过，不是嫌麻烦）：`testWidgets` 的测试体跑在
///   fake-async 区里，**await 真实文件 IO 永不完成**（探针：`writeAsString` 30 秒超时、
///   一行都没回来）；而挂那个面板的**真入口本身就要文件 IO**（`LyricView._load()` 的
///   `Lrc.load`、`_openCalibChooser` 的 `await ImportedLyricsStore.has` 都在 fake-async 区）
///   ⇒ 歌词永远载不进来、长按入口永不弹，**结构上进不去**。
///   详见 ★8 上面那段注释（`:513` 起）与那次探针的原始输出。
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

const MethodChannel _kPathProvider =
    MethodChannel('plugins.flutter.io/path_provider');

late Directory _docs;
late PlayerService _ps;

/// 哑播放器：本文件只渲染界面，一次原生调用都不许发生
/// （`noSuchMethod` 兜住 `AudioPlayer` 的全部成员，与 `queue_panel_scroll_test.dart` 同一约定）。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub-pbar-colors';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

// ───────────────────────── 量具 ─────────────────────────

/// 播放/暂停那颗按钮。
///
/// ⚠️ **播放栏里只有它带 `iconSize`**（`player_bar.dart` 里 `iconSize` 只出现一次）
/// ⇒ 这条 finder 唯一。用 `iconSize` 而不是 `byIcon` 找它，是为了
/// **改动前后都能定位到同一颗按钮**（`byIcon(Icons.pause)` 在改动前根本找不到东西，
/// 那样就没法量"改动前的几何"）。
///
/// ⚠️ 数字 **40 → 34** 是既定的产品口径（同一处改动里 `player_bar.dart` 与
/// `lyrics_page.dart` 一起从 40/38 统一到 34）。⛔ finder 与源码里的 `iconSize`
/// 必须一起改，否则这条 finder 找不到东西、整个文件红。
Finder get _playPauseButton =>
    find.byWidgetPredicate((w) => w is IconButton && w.iconSize == 34);

Finder get _iconInPlayPause =>
    find.descendant(of: _playPauseButton, matching: find.byType(Icon));

/// 进度条那颗 `Slider`。
///
/// ⚠️ 队列浮层里的 `Checkbox`（`:865`）也吃 `primary`，但它**不是** `Slider`
/// ⇒ `find.byType(Slider)` 在 `PlayerBar` 之内唯一。这条唯一性由 ★3 自己断言
/// （找错/找到两颗 ⇒ 当场红，而不是"挑一颗来判"）。
Finder get _progressSlider => find.descendant(
      of: find.byType(PlayerBar),
      matching: find.byType(Slider),
    );

/// 播放栏**主体**那个矩形（`player_bar.dart` 的 `Positioned(left:10,right:10,bottom:8)`
/// → `Material` → `BackdropFilter`，`:300`）。
///
/// `PlayerBar` 那个 `Stack` 里有两个 `BackdropFilter`：队列浮层（`_panelHeight=320`，
/// `:669`）在前、主体在后 ⇒ 取 `.at(1)`。这条口径由 ★6 的两条自证断言钉住
/// （主体高度 < 320、底边贴屏幕底 8px、左右各内缩 10px）。
Rect _barRect(WidgetTester tester) => tester.getRect(
      find
          .descendant(
            of: find.byType(PlayerBar),
            matching: find.byType(BackdropFilter),
          )
          .at(1),
    );

Icon _playPauseIcon(WidgetTester tester) {
  final btn = tester.widget<IconButton>(_playPauseButton);
  final icon = btn.icon;
  expect(icon, isA<Icon>(),
      reason: '量具自证：那颗 IconButton 的 `icon` 字段必须真的是一个 Icon');
  return icon as Icon;
}

Slider _slider(WidgetTester tester) => tester.widget<Slider>(_progressSlider);

/// `PlayerBar` **自己那个 context** 看得见的主题主色。
///
/// ★ 这是 ★4/★5 的**量具自证**：只有它等于我们灌进去的非白色，
/// 「三处仍然是白」才是一句有信息量的话（否则可能是主题压根没生效 ⇒ 恒真假绿）。
Color _primaryAtPlayerBar(WidgetTester tester) =>
    Theme.of(tester.element(find.byType(PlayerBar))).colorScheme.primary;

/// **不对称对照**用的哨兵：队列浮层里第一颗 `Checkbox` 的 `activeColor`
/// （`player_bar.dart:865` 的 `activeColor: primary`，**规则没要求改它**）。
///
/// ⚠️ 它必须**跟着主题走** —— 这才证明"换了主题之后这棵树重建过了"。
Color _queueCheckboxColor(WidgetTester tester) {
  final boxes = find.descendant(
    of: find.byType(PlayerBar),
    matching: find.byType(Checkbox),
  );
  expect(boxes, findsWidgets,
      reason: '量具自证：队列浮层里的 Checkbox 必须在树上（它是"树确实重建了"的哨兵）；'
          '找不到 ⇒ 哨兵失效，★4/★5 会退化成恒真的假绿');
  final ws = tester.widgetList<Checkbox>(boxes).toList();
  for (final w in ws) {
    expect(w.activeColor, ws.first.activeColor,
        reason: '哨兵必须同色（同一棵树同一个 primary）');
  }
  return ws.first.activeColor!;
}

// ───────────────────────── 宿主 ─────────────────────────

/// 把**真** `PlayerBar` 放进一个主题主色为 [primary] 的 `MaterialApp` 里。
Widget _host(Color primary) => MaterialApp(
      theme: ThemeData(colorScheme: ColorScheme.dark(primary: primary)),
      home: const Scaffold(body: PlayerBar()),
    );

/// 逻辑视口钉死（`physicalSize` ÷ `devicePixelRatio` = 逻辑尺寸）。
void _setSurface(WidgetTester tester, [Size logical = const Size(360, 800)]) {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.reset);
}

/// 走几拍稳定状态。
///
/// ⚠️ 一律固定时长 `pump`，**⛔ 不用 `pumpAndSettle`**：本仓页面挂着常驻动画
/// （氛围层 / 频谱），那种树永远 settle 不了。
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

/// 掐掉**已知噪音**：队列每行的 `ListTile` 与最近的 `Material` 祖先之间夹着浮层
/// 自己的玻璃底 ⇒ debug 下每个被构建的 ListTile 各报一条 `ListTile background color…`
/// （框架层已知的观感告警，**故意不修** —— release 一条没有）。
/// 不掐它会把用例拖成 "Multiple exceptions" 判红、把真断言淹掉。
/// ⚠️ 必须**在用例体内**装（binding 会在 `runTest` 开始时重置 `FlutterError.onError`）。
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

/// 起歌曲会话（真 `PlayerService`，假 `AudioPlayer`），再把真 `PlayerBar` 挂进
/// 主题主色为 [primary] 的树里。
Future<void> _boot(
  WidgetTester tester, {
  required bool playing,
  Color primary = const Color(0xFF7C4DFF),
}) async {
  _setSurface(tester);
  // `isPlaying` 是 `player_service.dart:257` 的**公开字段**，直接摆成两态之一
  //（本文件不跑播放链路，一次原生调用都不发）。
  _ps.isPlaying = playing;
  await tester.pumpWidget(_host(primary));
  await _settle(tester);
}

/// 三处目标当前的值 —— ★4/★5 就是拿它在两个主题之间逐值比对。
({IconData glyph, Color iconColor, Color active, Color inactive}) _triple(
  WidgetTester tester,
) {
  final icon = _playPauseIcon(tester);
  final sl = _slider(tester);
  return (
    glyph: icon.icon!,
    iconColor: icon.color!,
    active: sl.activeColor!,
    inactive: sl.inactiveColor!,
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _docs = Directory.systemTemp.createTempSync('mubox_pbar_colors_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_kPathProvider, (call) async => _docs.path);
    _ps = PlayerService(player: _StubPlayer());
    playerService = _ps;
    // 真队列（≥2 首）⇒ 进度条有分母、队列浮层里的 Checkbox 哨兵也在树上。
    await _ps.restoreSession(
      [
        for (var i = 0; i < 3; i++)
          Song(
            id: 700 + i,
            title: 'Song $i',
            artist: 'A',
            durationMs: 102000,
            uri: '',
            filePath: 'docs/music/s$i.mp3',
          ),
      ],
      0,
      11000,
      title: '探针歌单',
    );
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

  // ─────────────── 一、三处目标本身 ───────────────

  testWidgets('★1 isPlaying=false（界面停在暂停态 ⇒ 按钮显示「播放」）：裸字形 Icons.play_arrow + Colors.white',
      (tester) => _quiet(() async {
    await _boot(tester, playing: false);

    final icon = _playPauseIcon(tester);
    // ignore: avoid_print
    print('PBAR: isPlaying=false glyph=${icon.icon} color=${icon.color} '
        'iconSize=${tester.widget<IconButton>(_playPauseButton).iconSize} '
        'btn=${tester.getSize(_playPauseButton)} glyphBox=${tester.getSize(_iconInPlayPause)}');

    expect(icon.icon, Icons.play_arrow,
        reason: '★ 必须是**裸字形** play_arrow：换成任何 *_circle_* 都是'
            '「主题色实心圆盘 + 挖空符号」那副样子，正是用户要去掉的');
    // 四条负向：把用户说的"有底色的圆盘字形"逐个点名（正向那条已蕴含，这里留作可读的反例）
    expect(icon.icon, isNot(Icons.play_circle_fill));
    expect(icon.icon, isNot(Icons.play_circle_outline));
    expect(icon.icon, isNot(Icons.pause_circle_filled));
    expect(icon.icon, isNot(Icons.pause_circle_outline));
    expect(icon.color, Colors.white,
        reason: '★ 字形本身是**纯白**（⛔ 不是 primary，也不是任何带 alpha 的白）');
  }));

  testWidgets('★2 isPlaying=true（界面在播 ⇒ 按钮显示「暂停」）：裸字形 Icons.pause + Colors.white',
      (tester) => _quiet(() async {
    await _boot(tester, playing: true);

    final icon = _playPauseIcon(tester);
    // ignore: avoid_print
    print('PBAR: isPlaying=true glyph=${icon.icon} color=${icon.color}');

    expect(icon.icon, Icons.pause,
        reason: '★ 裸字形 pause（不是 *_circle_*）');
    expect(icon.icon, isNot(Icons.pause_circle_filled));
    expect(icon.icon, isNot(Icons.pause_circle_outline));
    expect(icon.icon, isNot(Icons.play_circle_fill));
    expect(icon.color, Colors.white, reason: '★ 字形本身是纯白');
  }));

  testWidgets('★3 进度条：activeColor 纯白 / inactiveColor 仍是 white12（且 PlayerBar 里只有这一颗 Slider）',
      (tester) => _quiet(() async {
    await _boot(tester, playing: false);

    // 量具自证：整条播放栏里**恰好一颗** Slider ⇒ 「挑一颗来判」这种取样错误不可能发生
    expect(_progressSlider, findsOneWidget,
        reason: '量具自证：`PlayerBar` 之内必须恰好一颗 Slider '
            '（队列浮层里的 Checkbox 也吃 primary，但它不是 Slider）');

    final sl = _slider(tester);
    // ignore: avoid_print
    print('PBAR: slider active=${sl.activeColor} inactive=${sl.inactiveColor}');

    expect(sl.activeColor, Colors.white,
        reason: '★ 已播那一段必须是纯白（⛔ 不是 primary）');
    expect(sl.inactiveColor, Colors.white12,
        reason: '未播那一段**本来就是** white12、不是主题色 ⇒ 这一单不许顺手改它');
  }));

  // ─────────────── 二、★这条规则真正的牙：不跟主题色 ───────────────

  testWidgets('★4 ★不跟主题色：红主色下三处仍然全白（带量具自证 + 不对称对照）',
      (tester) => _quiet(() async {
    await _boot(tester, playing: true, primary: Colors.red);

    // ★ 量具自证 1：PlayerBar 自己的 context 里，主色**真的是红**
    expect(_primaryAtPlayerBar(tester), Colors.red,
        reason: '量具自证：灌进去的红必须落在 PlayerBar 自己的 context 上；'
            '不然「仍然是白」只是主题没生效造成的恒真废判据');
    // ★ 量具自证 2（不对称对照）：同一棵树上，哨兵 Checkbox **必须**跟着变红
    expect(_queueCheckboxColor(tester), Colors.red,
        reason: '★ 对照：这一条没让改的那颗 Checkbox 仍然吃 primary ⇒ 证明'
            '「换主题之后这棵树确实重建了」。有了它，下面三处「不动」才是信息');

    final t = _triple(tester);
    expect(t.glyph, Icons.pause,
        reason: '红主色下 isPlaying=true ⇒ 仍然是裸字形 pause');
    expect(t.iconColor, Colors.white,
        reason: '★ 红主色下播放/暂停字形仍然是白 —— 这就是「不跟主题色」');
    expect(t.active, Colors.white, reason: '★ 红主色下进度条已播段仍然是白');
    expect(t.inactive, Colors.white12);
  }));

  testWidgets('★5 ★不跟主题色：橙 / 绿两个主色各 pump 一次，三处逐值都不动',
      (tester) => _quiet(() async {
    await _boot(tester, playing: false, primary: Colors.orange);
    expect(_primaryAtPlayerBar(tester), Colors.orange);
    expect(_queueCheckboxColor(tester), Colors.orange,
        reason: '对照：哨兵跟着橙走');
    final orange = _triple(tester);

    // 换第二个非白主色，**同一棵树**再 pump 一次
    await tester.pumpWidget(_host(Colors.green));
    await _settle(tester);
    expect(_primaryAtPlayerBar(tester), Colors.green,
        reason: '量具自证：第二个主题真的换上了');
    expect(_queueCheckboxColor(tester), Colors.green,
        reason: '对照：哨兵跟着绿走 ⇒ 树确实重建了');
    final green = _triple(tester);

    // ignore: avoid_print
    print('PBAR: 橙=$orange 绿=$green');

    // ★ 两个主题的主色互不相同、且都不是白 —— 否则"逐值不动"没有信息量
    expect(Colors.orange == Colors.green, isFalse);
    expect(Colors.orange == Colors.white, isFalse);
    expect(Colors.green == Colors.white, isFalse);

    expect(green.glyph, orange.glyph, reason: '★ 换主题 ⇒ 字形不动');
    expect(orange.glyph, Icons.play_arrow,
        reason: 'isPlaying=false ⇒ 这颗按钮显示的仍是裸字形 play_arrow');
    expect(green.iconColor, orange.iconColor, reason: '★ 换主题 ⇒ 图标颜色不动');
    expect(green.active, orange.active, reason: '★ 换主题 ⇒ activeColor 不动');
    expect(green.inactive, orange.inactive, reason: '★ 换主题 ⇒ inactiveColor 不动');

    expect(green.iconColor, Colors.white);
    expect(green.active, Colors.white);
    expect(green.inactive, Colors.white12);
  }));

  // ─────────────── 三、几何零变化 ───────────────

  testWidgets('★6 几何：播放栏主体矩形 / 那颗 IconButton 的 Size·Center / 图标渲染尺寸 与改动前逐值一致',
      (tester) => _quiet(() async {
    await _boot(tester, playing: false);

    // 量具自证：播放栏里只有这一颗带 `iconSize` 的 IconButton
    // （`tester.getSize` 本身在多命中时会抛，这里把口径写成明说的断言）
    expect(_playPauseButton, findsOneWidget,
        reason: '量具自证：`iconSize == 34` 的 IconButton 在整条播放栏里必须唯一');

    final bar = _barRect(tester);
    final btn = tester.getSize(_playPauseButton);
    final btnCenter = tester.getCenter(_playPauseButton);
    final glyphBox = tester.getSize(_iconInPlayPause);

    // ⚠️ `Rect`/`Size`/`Offset` 的 `toString()` 走 `toStringAsFixed(1)`
    //    ⇒ **看不出 0.x 以下的差别**。下面这行刻意把 double 的**完整精度**打出来：
    //    本用例第一次跑就靠 `==` 抓到过一个 < 0.05px 的中心偏移，
    //    而 `Offset(253.6, 745.0)` 与 `Offset(253.59999999999997, 745.0)` **打印一模一样**。
    // ignore: avoid_print
    print('PBAR-GEO: bar=$bar barSize=${bar.size} '
        'btnSize=$btn btnCenter=$btnCenter glyphBox=$glyphBox');
    // ignore: avoid_print
    print('PBAR-GEO-EXACT: bar='
        '${bar.left},${bar.top},${bar.right},${bar.bottom} '
        'btn=${btn.width},${btn.height} '
        'btnCenter=${btnCenter.dx},${btnCenter.dy} '
        'glyphBox=${glyphBox.width},${glyphBox.height}');

    // —— 量具自证（口径由这两条钉死，量错对象后面全没意义）——
    expect(bar.left, closeTo(10, 0.01), reason: '主体左右各内缩 10（`:291/:292`）');
    expect(bar.right, closeTo(360 - 10, 0.01));
    expect(bar.bottom, closeTo(800 - 8, 0.01), reason: '主体贴屏幕底 8px（`:293`）');
    expect(bar.height, lessThan(320),
        reason: '量具自证：取到的必须是**主体**（队列浮层是 320 高）——取错了整条判据就没意义');

    // —— ★ 与改动前冻结值逐值一致（数字来自改动前跑本用例的打印）——
    expect(bar, _kBeforeBar, reason: '播放栏主体矩形必须与改动前逐值一致');
    expect(btn, _kBeforeBtn, reason: '播放/暂停那颗 IconButton 的 Size 必须与改动前逐值一致');
    expect(btnCenter, _kBeforeBtnCenter,
        reason: '那颗按钮的中心必须与改动前逐值一致（iconSize 改了但布局不许跟着动）');
    expect(glyphBox, _kBeforeGlyphBox,
        reason: '图标自身的渲染盒子 —— 见下面金标块：这一条是**有意改动**（尺寸 40→34），不是回归');
  }));

  // ─────────── 四、全仓源级守卫：播放/暂停一律裸字形 ───────────

  test('★7 全仓源级守卫：lib/ 下再没有 `pause_circle_filled` / `play_circle_fill`', () {
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    final src = <String, String>{
      for (final f in files) f.path.replaceAll(r'\', '/'): f.readAsStringSync(),
    };

    // —— 量具自证 ①：尺子必须真的扫到了整个 lib/ ——
    // ⚠️ 实测值（`os.walk('lib')` 逐文件数）：**lib/ 下 77 个 `.dart`**。
    //    这里的 `>= 50` 只是**地板**（防"扫到空目录 / CWD 不对"），⛔ 不是"必须等于 77"
    //    的硬金标 —— 否则以后删两个文件就会红成一片噪音。
    expect(src.length, greaterThanOrEqualTo(50),
        reason: '量具自证：lib/ 下实测 77 个 .dart，只扫到 ${src.length} 个 ⇒ '
            '工作目录不对/尺子坏了 —— 那样下面报的 0 一文不值');

    // —— 量具自证 ②：尺子必须读得到**内容**。⚠️ 这里刻意用一个与被守卫的名字
    //    **无关**的记号：早先版本拿 `Icons.pause` 当正向对照，结果一收回修复，
    //    它先红、报出来的是"尺子坏了"，而真相是"代码违规了" —— 诊断方向被带反。
    final iconUses =
        src.values.fold(0, (a, s) => a + RegExp(r'Icons\.\w+').allMatches(s).length);
    expect(iconUses, greaterThanOrEqualTo(50),
        reason: '量具自证：整个 lib/ 里 `Icons.xxx` 只命中 $iconUses 次 ⇒ 读到的不是真源码');

    // —— 断言本身：把冒犯的位置**逐个列出来**（不是先写数字再补出处）——
    final hits = <String>[];
    src.forEach((path, s) {
      for (final m in RegExp('pause_circle_filled|play_circle_fill').allMatches(s)) {
        final line = '\n'.allMatches(s.substring(0, m.start)).length + 1;
        hits.add('$path:$line  ${m.group(0)}');
      }
    });
    expect(hits, isEmpty,
        reason: '★ 产品规则：**播放/暂停控件一律裸字形 + 纯白**，'
            '⛔ 不许再有「主题色实心圆盘 + 挖空符号」。还在用的地方：\n${hits.join('\n')}\n'
            '（注：`play_circle_outline` 不在此规则内 —— 搜索下载页那颗是"试听/预览"按钮，'
            '刻意没动，所以本判据只点名这两个名字）');

    // —— 产品规则的**正面写法**：这两处的播放/暂停必须真的是裸字形 ——
    //    ⚠️ 放在违规列表**之后**：收回修复时要先看到"哪里违规"，
    //    而不是先看到一条长得像"尺子坏了"的自证断言。
    for (final f in const [
      'lib/widgets/player_bar.dart',
      'lib/pages/lyrics_page.dart',
    ]) {
      expect(src.containsKey(f), isTrue, reason: '量具自证：清单里要有 $f');
      expect(RegExp(r'Icons\.pause\b').hasMatch(src[f]!), isTrue,
          reason: '★ $f 里必须有**裸字形**暂停键（`Icons.pause`，不是 circle 版）');
      expect(RegExp(r'Icons\.play_arrow\b').hasMatch(src[f]!), isTrue,
          reason: '★ $f 里必须有**裸字形**播放键（`Icons.play_arrow`，不是 circle 版）');
    }
  });

  // ─────────── 五、歌词页「分段校准」面板（源级守卫）───────────
  //
  // ⚠️ **这里刻意只做源级守卫，没做渲染级断言** —— 理由是**实测出来的**，不是嫌麻烦：
  //    `testWidgets` 的测试体跑在 fake-async 区里，**await 真实文件 IO 永不完成**。
  //    实测（一次性探针，跑完已删）：
  //      · 探针 1：测试体里 `await File(...).writeAsString('hello')`
  //        ⇒ 只打出 `PROBE 1: tmp=...`，**30 秒超时，后面的 `PROBE 2` 一行都没打**；
  //      · 探针 2：`await LyricsStore.save(...)` ⇒ 同样 30 秒超时。
  //    ⇒ 而挂这个面板的**真入口本身就要文件 IO**：
  //      `LyricView._load()`（`:205`，`Lrc.load`）与 `_openCalibChooser`（`:302`，
  //      `await ImportedLyricsStore.has(song)`）都在 fake-async 区里
  //      ⇒ 歌词永远载不进来、长按入口永远不弹。**这是结构性的**，
  //      不是"多写几行就能挂上"。
  //    ⇒ 本仓既有的 widget 测试之所以没事，是因为它们的文件 IO 全在 `setUp`/`tearDown`
  //      （那两处**不在** fake-async 区里）。
  //    ⛔ 所以**别在这儿编一条"渲染级"的假绿**。要真渲染级断言，得先给歌词页做可注入接缝。
  //    ✅ 下面这条源级守卫有牙：把 `activeTrackColor` 改回 `primary`、或把字形改回 circle 版，
  //      它当场红（这次改造里实测过）。

  test('★8 歌词页「分段校准」面板：源级守卫（播放/暂停=裸字形+白+34、歌曲进度条=白；设置类控件仍吃主题色）', () {
    final src = File('lib/pages/lyrics_page.dart').readAsStringSync();

    /// 切出一个方法的函数体：从签名切到下一个顶格成员声明（`Widget `/`Future<`）之前。
    String methodBody(String signature) {
      final start = src.indexOf(signature);
      expect(start, greaterThan(0),
          reason: '量具自证：切片锚点 `$signature` 必须找得到（找不到 ⇒ 本判据整条失效）');
      var end = src.indexOf('\n  Widget ', start + 1);
      final f = src.indexOf('\n  Future<', start + 1);
      if (f > 0 && (end < 0 || f < end)) end = f;
      expect(end, greaterThan(start), reason: '量具自证：切片必须有终点');
      final body = src.substring(start, end);
      expect(body.length, greaterThan(400),
          reason: '量具自证：切出来的函数体只有 ${body.length} 字符 ⇒ 锚点切错地方了，'
              '下面那些"不含 primary"会退化成恒真的假绿');
      return body;
    }

    // ---- ① 歌曲进度条：白 ----
    final bar = methodBody('Widget _buildProgressBar(Color primary) {');
    expect(bar.contains('activeTrackColor: Colors.white'), isTrue,
        reason: '★ 歌曲进度条已播段 = 纯白（原来 `activeTrackColor: primary`）');
    expect(bar.contains('inactiveTrackColor: Colors.white12'), isTrue,
        reason: '未播段仍是 white12（本来就不是主题色，没动）');
    expect(bar.contains('thumbColor: Colors.white'), isTrue,
        reason: '圆点本来就是白的，不许改');
    expect(bar.contains('activeTrackColor: primary'), isFalse,
        reason: '★ 不许再跟主题色');

    // ---- ② 同面板那颗播放/暂停：裸字形 + 白 + 与播放栏同一个 iconSize ----
    final at = bar.indexOf('iconSize: 34');
    expect(at, greaterThan(0),
        reason: '量具自证：面板里那颗播放键必须带 `iconSize: 34`（与播放栏统一）');
    final toggle = bar.substring(
      bar.lastIndexOf('IconButton(', at),
      bar.indexOf('onPressed: playerService!.toggle', at),
    );
    expect(toggle.contains('Icons.pause'), isTrue, reason: '在播时 = Icons.pause');
    expect(toggle.contains('Icons.play_arrow'), isTrue, reason: '暂停时 = Icons.play_arrow');
    expect(toggle.contains('color: Colors.white'), isTrue,
        reason: '★ 纯白，不跟主题色');
    expect(toggle.contains('color: primary'), isFalse,
        reason: '★ 这颗不许再吃主题色');

    // ---- ③ ★ 不对称对照：同面板的**设置类**控件必须仍然吃主题色 ----
    // ⚠️ 切片归属是核对过的：跳秒档位的 `ChoiceChip` 就在 `_buildProgressBar` **里面**
    //    （那条 `Row` 与进度条同一个方法）⇒ 它跟"被刷白的进度条"在同一段源码里，
    //    对照最直观；基准线那两件（Switch + 滑杆）在 `_buildSegActions`。
    expect(bar.contains('selectedColor: primary'), isTrue,
        reason: '★ `selectedColor: primary`（跳秒档位 ChoiceChip）必须留着 —— 它是**设置类**'
            '控件，主题色留在它身上是对的。规则：播放/暂停 + 歌曲进度条 = 白；'
            '其它选择器/装饰 = 主题色。这条同时是对照：证明 ① 不是"把整页刷白"刷出来的');
    final actions = methodBody('Widget _buildSegActions(Color primary) {');
    for (final keep in const [
      'activeThumbColor: primary', // Switch：基准线显示开关
      'activeColor: primary', // Slider：基准线位置
    ]) {
      expect(actions.contains(keep), isTrue,
          reason: '★ `$keep` 必须留着 —— 那是**设置类**控件（基准线那一对），'
              '主题色留在它们身上是对的');
    }
  });
}

// ⚠️ `_kBeforeBar` / `_kBeforeBtn` / `_kBeforeBtnCenter` 三个是**真正的"改动前"值**
//    （HEAD `27c394f`，未改 `lib/widgets/player_bar.dart`），跑本用例 `PBAR-GEO-EXACT`
//    那行打印出来的**完整精度**实测值，逐值冻结，**一个都不许跟着改**。
//    ⛔ 别为了让断言变绿去改它们 —— 几何真的变了就得先解释为什么，再谈要不要更新金标。
//
  // 🔴 **量具教训（本用例第一版就栽在这）**：`Rect`/`Size`/`Offset` 的 `toString()` 走
//    `toStringAsFixed(1)` ⇒ 打印出来的 `Offset(253.6, 745.0)` 与真值
//    `Offset(253.64999961853027, 745.0)`（253.65 的 float32 形态）**长得一模一样**。
//    第一版照 1 位小数的打印填金标 ⇒ ★6 变红，而 `Expected` 与 `Actual` 两行**逐字符相同**，
//    看着像"断言坏了"。⇒ **冻结浮点几何一律看完整精度，别信 `toString()`。**
const Rect _kBeforeBar = Rect.fromLTRB(10.0, 692.0, 350.0, 792.0);
const Size _kBeforeBtn = Size(48.0, 48.0);
const Offset _kBeforeBtnCenter = Offset(253.64999961853027, 745.0);

/// 图标渲染盒子 = `iconSize`。**这一条是唯一一个被有意更新的金标。**
///
/// * 旧值 `Size(40, 40)`（更早的版本）；
/// * 新值 `Size(34, 34)` —— **既定的产品口径**：
///   原话意思是「裸三角我看着嫌大，给弄小点」。这是**有意改动，不是回归**。
/// * ⚠️ 只放宽了「图标盒子」这一格：`_kBeforeBar`（播放栏矩形）、
///   `_kBeforeBtn`（按钮仍 48×48）、`_kBeforeBtnCenter`（中心仍在
///   `253.64999961853027,745.0`）**逐值不变** —— 即「只把墨迹改小、布局一个像素没动」。
/// * ⛔ 别顺手把上面三个也"更新"成新量到的值：那正是这条断言存在的意义。
const Size _kBeforeGlyphBox = Size(34.0, 34.0);
