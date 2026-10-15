/// ★ 氛围层「动画心跳」的断言 —— 只要「视觉特效时不时停住」这个故障回来了，这里就红。
///
/// ## 病灶
///
/// 症状：**视觉特效会时不时停下来**，明明歌曲还放着、没切页也没息屏。
/// 氛围层也一样停 —— 视觉 / 氛围 / 边框本来就是同一个 `_c` 驱动。
///
/// 站得住的现场证据：两张**不同文件名**的截图（相隔几分钟）显示**画面主体区恒为 0 像素变化**，
/// 而同屏**频谱（12~18%）与进度条照常动** ⇒ 只有这一层死，且当时 `player.isPlaying == true`
/// （播放栏暂停图标读的正是它，`player_bar.dart:472`）。
/// ⚠️ **曾报过的「连续 85 秒 / 8 分钟 0 像素」等长窗口数字已作废**：那是采样循环把每帧写进
/// **同一个文件名**、又吞掉 `adb pull` 错误 ⇒ 之后一直在拿同一张旧图自己比自己。
/// 教训：**取证脚本自己必须能分辨「新抓的帧」和「上一张旧图」** —— 否则量出来的
/// 「长时间零变化」是脚本的产物，不是 App 的症状。
///
/// 根因：`_syncAnimation()` 是**唯一**能把停下的表重新拉起来的地方（`_c.repeat()` 在它里面），
/// 而它原本**只挂事件**（`AppConfig` / `playerService.changeNotifier` /
/// `AppLifecycleState` / `initState`）—— **没有任何周期重估**。
/// 于是「门值假过一下、又变回真，而恰好没有任何事件来重估」时，
/// `_c` 就**永远停在 stop 态**。
///
/// 为什么频谱没事（最有价值的一条对照）：`SpectrumView` 的父级每 500ms 重建一次
/// （`player_bar.dart` 的 `ListenableBuilder` 里含 `playerService.notifier`）⇒
/// `didUpdateWidget → _sync()` **顺带把它救了回来**；`AmbientLayer` 只听低频
/// `changeNotifier`，**没有这条路**。
///
/// ## 这组断言怎么有牙（三条，缺一不可）
///
/// * **正向复现冻结**（★1）：用一个**忠实假件** —— `isPlaying` **静默**置 true、
///   **不发 `notifyListeners()`**（真实现 `player_service.dart:1082`
///   `_abortCrossfade(keepIncoming:true)` 里那句 `isPlaying = false` **就是不通知**）
///   ⇒ 装上心跳前 `pump(3s)` 后动画**仍停着**（= 复现真机冻结）；
/// * **★2 装上心跳 ⇒ 被拉起来**；
/// * **★3 负向对照（防"心跳把该停的也拉起来"）**：真暂停 / `freezeOnPause=false` /
///   （预览身份本就不冻结，单独在 ★3c 钉住）时，心跳跑 3 秒后**必须仍然停着** ——
///   省电语义不许被这次修法破坏。
///
/// ⚠️ **量具纪律**（同 `fx_layer_render_test.dart` / `custom_page_groups_test.dart`）：
/// **禁 `pumpAndSettle`**（这一层挂着常驻 `repeat()` 动画，永远 settle 不了）；
/// 一律用 `pump()` / `pump(Duration)`。每个用例都显式 `dispose` 掉 widget 树，
/// 免得心跳计时器漏到下一个用例。
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/effect_catalog.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:mu_box_phone/widgets/ambient_layer.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 哑播放器：`PlayerService` 的必需构造参数（这一族页面会读全局 `playerService`）。
class _StubPlayer implements AudioPlayer {
  @override
  String get playerId => 'stub';

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

/// 一首「正在放」的歌。`filePath` 指向不存在的文件是**故意的**：
/// `Lrc.load` / `SubLyricsStore.load` 内部都 `try/catch` 且 `exists()` 为假时返回空，
/// 不会把异步异常漏出来（核实：`lrc.dart:70-75`、`sub_lyrics.dart:34-41`）。
Song _song() => Song(
      id: -1001, // 「内部副本路径散列取负」的稳定 id（`library_core.stableIdOfPath`）
      title: '判据用歌',
      artist: 'test',
      durationMs: 200000,
      uri: 'file:///nonexistent/a.mp3',
      filePath: '/nonexistent/a.mp3',
    );

AppConfig get _cfg => AppConfig.instance;

/// 把全局世界摆成「正在播一首歌」。
///
/// ⚠️ **`emitState` 是这组断言的关键口子**：
/// * `emitState: true`（默认，= **忠实**）—— 只写 `isPlaying`，**不发任何通知**
///   （对齐真实现 `player_service.dart:1082` 那条"静默写脏"的路径）；
/// * `emitState: false`（= **不忠实**，**故意留的反例**）—— 额外
///   `changeNotifier.notify()`，模拟"事件恰好来了"。★5 用它证明
///   「没有心跳时，光靠事件确实也能救回来」⇒ 反证 ★1 的冻结**不是因为判定逻辑变了**，
///   而是因为**没有事件**。这两条一起才说明「心跳」是必需的，不是多余的。
void _world({required bool playing, bool emitState = true}) {
  _cfg.heartEnabled = true;
  _cfg.rainEnabled = false;
  _cfg.edgeEnabled = false;
  _cfg.spectrumEnabled = false;
  _cfg.ambientEffect = 0;
  _cfg.visualLayers
    ..clear()
    ..add(const VisualLayer(effect: 0, slot: 0));
  final ps = playerService!;
  ps.current = _song();
  ps.isPlaying = playing;
  if (!emitState) ps.changeNotifier.notify();
}

/// 起树。`freezeOnPause: true` = `root_page.dart:97` 那处**唯一的真背景**。
Future<void> _mount(WidgetTester tester, {bool freezeOnPause = true}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AmbientLayer(freezeOnPause: freezeOnPause),
    ),
  ));
  await tester.pump();
  // ⛔ 这里**不能**用 pumpAndSettle：本层挂着常驻 repeat()。
}

/// 推进 [seconds] 秒（分段 pump，让 1 秒心跳有机会跑）。
Future<void> _advance(WidgetTester tester, int seconds) async {
  for (var i = 0; i < seconds * 2; i++) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

/// 当前动画在不在跑（`_c.isAnimating`，见 `AmbientLayer.debugAnimationRunning`）。
///
/// ⚠️ 必须经 `dynamic` 取：`_AmbientLayerState` 是**私有**类型，静态类型只能是
/// `State<AmbientLayer>`，而那个基类上没有这个口子。加 `as dynamic` 只是取一下，
/// 不改变任何东西。
bool _running(WidgetTester tester) =>
    (tester.state(find.byType(AmbientLayer)) as dynamic)
        .debugAnimationRunning as bool;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    playerService = PlayerService(player: _StubPlayer());
    // 氛围层会 listen 省电模式的 EventChannel（测试里没有原生实现）。
    // 给个哑 handler，否则 MissingPluginException 会把与渲染无关的用例判红。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.mubox.mu_box_phone/power_save'),
      (call) async => null,
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('com.mubox.mu_box_phone/power_save'), null);
    playerService = null;
  });

  // ─────────────────────────────────────────────────────────────────────
  // ★1 复现真机冻结：门"静默"变真，而事件一个都不来 ⇒ 表停着
  // ─────────────────────────────────────────────────────────────────────

  testWidgets('★1 复现冻结：isPlaying 静默置真（不发通知）⇒ 停下的表自己起不来',
      (tester) async {
    // 先摆成「暂停」：有歌 + freezeOnPause ⇒ 门 = playing = false ⇒ 应当冻结
    _world(playing: false);
    await _mount(tester);
    expect(_running(tester), isFalse,
        reason: '有歌 + freezeOnPause + 暂停 ⇒ 门为假，动画必须停（这是原有的省电语义）');

    // ★ 关键动作：**静默**把 isPlaying 改成 true —— 不发任何 notifyListeners()。
    //   这正是真机上的形态（player_service.dart:1082 就是"写了不通知"）。
    playerService!.isPlaying = true;

    // ⛔ 注意：这里**故意不**让任何事件发生（不 notify、不动 AppConfig、不切歌）。
    //   0.5 秒 ⇒ 心跳还没到（1 秒一次），所以这一刻**必然**还是停着的。
    await _advance(tester, 0);
    await tester.pump(const Duration(milliseconds: 500));
    expect(_running(tester), isFalse,
        reason: '★ 门已为真但没有任何事件 ⇒ 表仍停着 —— 这就是真机上「门值假过一下又变真、'
            '而没有任何事件来重估」那个状态（现场见 test 头注释，长窗口数字已作废）');

    // 再等满 1.5 秒 ⇒ 心跳来过 ⇒ 表必须被拉起来。
    await _advance(tester, 2);
    expect(_running(tester), isTrue,
        reason: '★ 心跳（1s）到了 ⇒ `_syncAnimation` 重估 ⇒ 门为真 ⇒ 必须重新跑起来');

    // 收尾：dispose 掉树（心跳计时器要跟着停）
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // ─────────────────────────────────────────────────────────────────────
  // ★2 心跳不该有的副作用：门本来就为真时，它什么都不用做
  // ─────────────────────────────────────────────────────────────────────

  testWidgets('★2 门本来就为真：心跳跑 3 秒，动画一直在跑（不抖、不重置）',
      (tester) async {
    _world(playing: true);
    await _mount(tester);
    expect(_running(tester), isTrue, reason: '正在播放 ⇒ 一开始就该跑');

    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      expect(_running(tester), isTrue,
          reason: '第 ${i + 1} 个 500ms：心跳**不许**把正在跑的动画停掉或重启'
              '（心跳只调 _syncAnimation，而 need 恒为真 ⇒ 两个分支都不进）');
    }

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // ─────────────────────────────────────────────────────────────────────
  // ★3 负向对照：心跳**不许**把该停的东西拉起来
  // ─────────────────────────────────────────────────────────────────────

  testWidgets('★3a 真暂停（有歌 + freezeOnPause）⇒ 心跳 3 秒后仍必须停着',
      (tester) async {
    _world(playing: false);
    await _mount(tester);
    await _advance(tester, 3);
    expect(_running(tester), isFalse,
        reason: '★ 暂停冻结是用户拍板过的省电语义：心跳只许"重新评估"，'
            '不许把 paused 的东西拉起来');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('★3b freezeOnPause=false（= 非真背景的旧行为）⇒ 暂停时也照跑',
      (tester) async {
    _world(playing: false);
    await _mount(tester, freezeOnPause: false);
    await _advance(tester, 3);
    expect(_running(tester), isTrue,
        reason: '没开冻结的调用点必须与改动前逐项一致：暂停也照跑（`ambient_policy.dart:34`）');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('★3c 整片特效全关（heart/rain/edge 全 false）⇒ 心跳也没救、必须停',
      (tester) async {
    _world(playing: true);
    _cfg.heartEnabled = false; // 整片视觉区关闭（rain/edge 在 _world 里已关）
    await _mount(tester);
    await _advance(tester, 3);
    expect(_running(tester), isFalse,
        reason: '★ `hasAnyEffect` 为假 ⇒ 一个像素都不该画');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  // ─────────────────────────────────────────────────────────────────────
  // ★4 「没有心跳、光靠事件」也能救回来 —— 反证冻结的成因是"没有事件"
  // ─────────────────────────────────────────────────────────────────────

  testWidgets('★4 反例（不忠实假件）：临时补一发 notify ⇒ 没有心跳也能救回来',
      (tester) async {
    _world(playing: false);
    await _mount(tester);
    expect(_running(tester), isFalse, reason: '起点：暂停 ⇒ 停');

    // 静默置真 + 立刻补一发低频通知（= 真机上"恰好有事件"的情形）
    playerService!.isPlaying = true;
    playerService!.changeNotifier.notify(); // ← 唯一的一发事件
    await tester.pump();
    expect(_running(tester), isTrue,
        reason: '★ 这条证明：判据本身没坏 —— 只要有**一发**事件，停下的表立刻就能起来。'
            '⇒ ★1 的冻结成因是"没有事件"，不是"判定错了"');

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
