/// 播放服务（含通知栏媒体会话），由 audio_service 统一管理。
library;

import 'dart:async';
import 'dart:math';

import 'package:audio_service/audio_service.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_config.dart';
import 'ab_loop.dart';
import 'artwork.dart';
import 'eq_engine.dart';
import 'extra_effects.dart';
import 'library_core.dart';
import 'library_data.dart';
import 'models.dart';
import 'playback/crossfade.dart';
import 'playback/prefetch.dart';
import 'playback/queue.dart';
import 'spectrum_engine.dart';
import 'store.dart';
import 'volume_fade.dart';

// audio_service 创建的播放服务实例，供 UI 共享
PlayerService? playerService;

/// 播放状态通知器：ChangeNotifier.notifyListeners 是受保护方法，
/// 通过这个子类在内部转发，避免在非 ChangeNotifier 子类中直连。
class PlayerNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

/// **双播放器（交叉淡变 / 预取）的纯判定** —— 抽出来的唯一理由是让
/// 「`AppConfig.crossfadeEnabled` 取缺省值 false 时**行为完全不变**」这件事
/// 能被**穷举证明**，而不是靠读代码（有单测钉着）。
///
/// 两个函数都是 `enabled && …` 的形状：开关一关，无论别的输入怎么变都恒为 false。
abstract final class DualPlayerPolicy {
  /// 这一拍该不该给「下一首」预热第二个播放器。
  ///
  /// [hasNext] = 队列里算得出下一首（单曲队列 / 排除名单全排掉时为 false）；
  /// [inWindow] = 到了曲末窗口（`PrefetchPolicy.window`，与淡变共用同一个 lead）；
  /// [alreadyLoaded] = 空闲那一副里装的就是这一首（重复 setSource 会白初始化一次解码器）。
  static bool shouldPrefetch({
    required bool enabled,
    required bool hasNext,
    required bool inWindow,
    required bool alreadyLoaded,
  }) => enabled && hasNext && inWindow && !alreadyLoaded;

  /// 这一拍该不该**现在换场**（A 淡出 + B 淡入，300ms 重叠）。
  ///
  /// [prefetched] = 空闲那一副已经预热好**且就是**下一首（没预热就换场 = 空档没消掉）；
  /// [shouldStart] = `CrossfadePlan.shouldStart`（曲末窗口 + 时长都已知）。
  static bool shouldCrossfade({
    required bool enabled,
    required bool prefetched,
    required bool shouldStart,
  }) => enabled && prefetched && shouldStart;
}

/// 一副"牌"：一个播放器 + 它当前的音量。
///
/// 为什么需要它：交叉淡变要求**两个播放器同时在响**，而 `_volume` 原来是单个标量
/// （"App 内音量恒为 1.0"那条硬不变量就是对着它写的）。双播放器下音量必须**按播放器**
/// 记，否则 A 淡到 0.4 时 B 会读到 A 的值 —— 两条曲线互相覆盖，音量台阶对不齐，
/// 而且「每次淡变结束必须回到 1.0」这条不变量再也说不清是"谁的 1.0"。
class _Deck {
  _Deck(this.player);

  final AudioPlayer player;

  /// 这一副当前的 App 内音量（1.0 = 不衰减），只在淡变期间短暂偏离。
  double volume = 1.0;

  @override
  String toString() => '_Deck(${player.playerId}, vol=$volume)';
}

class PlayerService extends BaseAudioHandler {
  PlayerService({AudioPlayer? player, AudioPlayer Function()? playerFactory})
    : _deckA = _Deck(player ?? _newPlayer()),
      _playerFactory = playerFactory ?? _newPlayer;

  /// 造一个**真**播放器。全仓唯一的 `AudioPlayer()` 实例化点 ——
  /// A、B 两副牌都必须从这一个工厂出来（围栏钉着这条，见 `test/audio_session_test.dart`）。
  static AudioPlayer _newPlayer() => AudioPlayer();

  /// 造播放器的口子。**两个参数都只给单测用**：
  /// - [player]：把 A 换成一个假播放器（`test/player_service_test.dart` 的 17 项靠它，
  ///   让「切歌」退化成纯下标算术）；
  /// - [playerFactory]：连 B 也换成假的（`test/player_service_crossfade_test.dart`）。
  ///   ⚠️ 缺省是真的 `AudioPlayer()` ⇒ **双播放器的用例必须显式传它**，别指望注入 A 就够。
  final AudioPlayer Function() _playerFactory;

  /// A 这一副（构造时就存在）。
  /// 关掉 [AppConfig.crossfadeEnabled] 时它**永远是"在场"的那一副**，
  /// 每一处 `_cur.player` 都与改动前的 `_player` 逐项相同。
  final _Deck _deckA;

  /// B 那一副：**懒建**。开关关闭时它永远不会被创建（连 `AudioPlayer()` 都不跑），
  /// 也就不会有第二个 `setSource` 去抢 session。
  _Deck? _deckB;

  /// 现在"在场"的是不是 B。交叉淡变换场的那一刻翻转（翻转前后 `_cur` 的含义见各处注释）。
  bool _onB = false;

  /// 现在**在场**（该播、该收事件、该被 UI 显示）的那一副。
  /// 开关关闭 ⇒ 恒为 `_deckA`。
  _Deck get _cur => _onB ? _deckB! : _deckA;

  /// 现在**空闲**的那一副（预热用 / 交叉淡变的上场方）。调用前必须先 `_ensureDeckB()`。
  _Deck get _idle => _onB ? _deckA : _deckB!;

  /// 懒建 B：只在开关打开、且真的要用它时才创建。
  Future<_Deck> _ensureDeckB() async {
    final d = _deckB;
    if (d != null) return d;
    final nd = _Deck(_playerFactory());
    _deckB = nd;
    // 与 A 同样的 release 语义：stop() 不 release MediaPlayer ⇒ session 不换，
    // 引擎换场重挂不用等新的 session（详见 init() 里那一句）。
    await nd.player.setReleaseMode(ReleaseMode.stop);
    _bindDeck(nd);
    return nd;
  }

  final Random _rng = Random();
  // 供 Flutter UI 监听状态变化的通知器
  final PlayerNotifier notifier = PlayerNotifier();
  // 低频变更通知器：只在切歌/暂停/模式/队列/睡眠等结构状态变化时触发；
  // 播放位置/进度拖拽的高频 tick 不触发它——让歌单/设置这类列表页不会跟着 500ms 重建。
  final PlayerNotifier changeNotifier = PlayerNotifier();

  /// 上一次播放失败的原因（界面弹完即置回 null）。
  /// 以前失败只留一句 debugPrint，用户看到的是「点了播放，没声音也没反应」。
  final ValueNotifier<String?> lastError = ValueNotifier<String?>(null);

  /// 结构/状态变更通知：同时通知变更根（播放栏进度条/歌词）与列表页用的低频通知。
  /// 播放位置的高频 tick 只走上面的 notifier，不走这里，避免列表页跟着 500ms 重建。
  void _emitChange() {
    notifier.notify();
    changeNotifier.notify();
  }

  /// 队列的**结构代次**：每次「换队列 / 加歌 / 删歌 / 移动 / 清空 / 切历史模式」都 +1。
  /// 只有它变了才需要重写 `queue.json` 的队列部分（播放位置由 5 秒一次的 tick 负责）
  /// —— 否则 `playAt` 每次切歌都要白写一遍队列文件。
  int _queueRev = 0;
  /// 已落盘的队列代次（与 [_queueRev] 不等 = 队列变了还没写）。
  int _savedQueueRev = -1;

  List<Song> _queue = [];
  String _queueName = ''; // 当前队列来源名（歌单名/「全部歌曲」/单曲名），显示在队列浮层顶部

  // ---- 随机播放的**固定种子**序 ----
  //
  // 原实现 next 现抽一个随机下标、prev 再抽一个 —— 两条独立随机，所以
  // 「下一首 → 上一首」必然漂到别处（n 首队列里回到同一首的概率只有 1/n）。
  // 现在整条随机序由 [_shuffleSeed] 唯一决定（判定全在 `playback/queue.dart` 的
  // [ShuffleOrder]，那边有单测），前后走同一格，重启后把种子与游标一起读回来接着走。
  ShuffleOrder? _shuffle;
  int _shuffleSeed = 0;
  int _shuffleSeedSeq = 0; // 同一次会话内保证不摇出重复种子（种子只进队列文件，不上屏）

  /// 摇一个新种子（[[_shuffleSeedSeq]] 混进来，免得连摇两次撞上同一颗）。
  int _newShuffleSeed() => _rng.nextInt(1 << 30) + (++_shuffleSeedSeq);

  /// 队列结构变了：作废当前随机序（下次要用时按同一个种子重建一条**同序**的排列，
  /// 而不是换一条 —— 换队列才该换序，见 [playQueue]）。
  void _resetShuffle() => _shuffle = null;

  /// 按需拿到随机序；队列长度变了（排列对不上队列）就按同一个种子重建。
  ShuffleOrder _ensureShuffle() {
    final s = _shuffle;
    if (s != null && s.length == _queue.length) return s;
    final rebuilt = ShuffleOrder.create(_queue.length, _shuffleSeed);
    _shuffle = rebuilt;
    return rebuilt;
  }

  /// 把随机游标对齐到当前曲（切歌 / 恢复会话后都要调，否则「上一首」是从旧位置走）。
  void _syncShuffleCursor() {
    final s = _shuffle;
    if (s == null) return;
    if (!s.seekTo(index)) _shuffle = null; // 当前曲不在排列里：作废，下次重建
  }

  /// 队列结构变更的唯一收口：代次 +1（并作废随机排列）。
  void _queueChanged() {
    _queueRev++;
    _resetShuffle();
  }

  /// 把队列与播放位置落盘（fire-and-forget）。
  ///
  /// 两件事分开算：
  /// - **位置**每次都写（调用点：切歌后、播放中每 5 秒一次）；
  /// - **队列本身**只在 [_queueRev] 变了才写（删歌/排序/清空/追加/换歌单）——
  ///   队列文件是「用户自己攒的队列」，攒完必须马上落盘，不能等 5 秒那一拍。
  Future<void> _saveSession() {
    _persist = _persist.then((_) => _persistNow());
    return _persist;
  }

  /// 落盘本体：判「要不要连队列一起写」，然后交给 [Store]。
  Future<void> _persistNow() async {
    final dirty = _queueRev != _savedQueueRev;
    if (!dirty && (_queue.isEmpty || index < 0)) return;
    final q = QueueState(
      refs: _queue.map((s) => s.filePath).toList(),
      index: index,
      sourceName: _queueName,
    );
    _savedQueueRev = _queueRev;
    await Store.saveLastSession(
      q.refs.toList(),
      q.index,
      pos.inMilliseconds,
      q.sourceName,
      seed: _shuffleSeed,
      cursor: _shuffle?.cursor ?? -1,
    );
  }

  /// 队列 / 播放位置落盘（fire-and-forget）。**唯一调用姿势**：
  /// 这是个「写不进去就算了」的旁路（没有重试、用户也看不见），异常绝不能漏出去
  /// —— 漏出去就是一条没人接的异步错误，在单测里还会污染下一个用例。
  void _saveSessionQuietly() {
    unawaited(_saveSession().catchError((Object _) {}));
  }

  /// 落盘串行链（见 [_saveSession]）；单测用 [debugFlushPersist] 等它落完。
  Future<void> _persist = Future<void>.value();

  /// 等「队列 / 播放位置」这一串落盘都完成。**只给单测用**
  /// （`test/player_service_test.dart` 要断言 queue.json 的内容，不能靠 sleep 碰运气）。
  Future<void> debugFlushPersist() => _persist;

  // ---- 历史播放（放在队列里，可开关：开=切到历史，关=恢复原歌单） ----
  static const int historyLimit = 100; // 历史记录上限（去重，超出挤掉最旧）
  final List<Song> _history = []; // 最近播放（新→旧）
  bool historyMode = false; // 是否处于「历史播放」模式
  List<Song> _baseQueue = []; // 进入历史前的原队列
  String _baseQueueName = ''; // 原队列来源名
  /// 持久化下来的历史（filePath，新→旧）：启动时先读到这儿，等曲库加载完再
  /// 由 [restoreHistory] 映射成 [Song]（playerService.init 跑在曲库之前，那时还没歌）。
  List<String> _historyPaths = [];

  /// 不参与循环播放的歌曲 id 集合；空集合 = 全部参与
  final Set<int> _excludedFromLoop = {};
  int index = -1;
  Song? current;
  bool isPlaying = false;
  Duration pos = Duration.zero;
  Duration dur = Duration.zero;
  String mode = 'list'; // list / single / shuffle
  double speed = 1.0; // 播放倍速

  // ---- 音量淡入淡出（消掉起播/切歌那一下的爆音、暂停时的「啪」） ----
  //
  // 项目约定：音量完全交给系统媒体音量键，App 内不做缩放（见 init 里的说明）。
  // 这里的音量只是为了给淡变一个起点，**每次淡变结束都会回到 1.0**，
  // 不会和系统音量叠加出「越听越小声」。
  // 双播放器下音量**按牌记**（`_Deck.volume`）—— 交叉淡变时两副同时在响，
  // 一个标量存不下两条曲线。
  static const Duration _fadeInTime = Duration(milliseconds: 180);
  static const Duration _fadeOutTime = Duration(milliseconds: 120);

  /// 淡变代次：每次开始新淡变自增，旧循环发现代次变了立刻让位，避免两条曲线抢音量。
  ///
  /// **双播放器下它仍然是全局一个**：一次交叉淡变算「一次淡变」，两条曲线（A 出 / B 入）
  /// 拿的是同一个代次 ⇒ 被打断时两条**一起**让位，不会出现"退场那条已经停了、
  /// 上场那条还在往下走"的半截状态。
  int _fadeToken = 0;

  /// 用户的播放意图：淡出是异步的，用它判断「淡出期间用户是不是又点了播放」
  bool _wantPlaying = false;

  // ---- A-B 片段循环（练歌 / 只听副歌）----
  //
  // 判定逻辑全在 `ab_loop.dart` 的 [AbLoop]（纯数据，有单测）；这里只负责
  // 「按用户操作打点」和「到点了把它 seek 回去」。
  AbLoop _ab = AbLoop.none;

  /// 当前 A-B 打点状态（界面画进度条高亮带、显示标签用）
  AbLoop get ab => _ab;

  /// A-B 守护定时器：位置 tick 是 500ms 一次，光靠它会晚半秒才绕回；
  /// 开着 A-B 时用 120ms 自己查一次位置（只在「生效且正在播放」时跑，其余时候零开销）。
  Timer? _abTimer;

  /// 绕回进行中标记：seek 是异步的，防止两次 tick 叠加出连环 seek
  bool _abWrapping = false;

  /// A-B 打点：一个按钮三态循环 —— 没点 → 打 A → 打 B → 清除。
  /// 返回一句给界面提示的话（调用方弹 SnackBar）。
  String cycleAbLoop() {
    if (current == null) return '先放一首歌再打点';
    if (!_ab.hasA) {
      _setAb(_ab.markA(pos));
      return 'A 点已打：${_ab.label}（再点一下打 B 点）';
    }
    if (!_ab.active) {
      final next = _ab.markB(pos);
      if (!next.active) {
        // B 打在 A 之前/同一位置：这次打点没意义，直接复位免得用户卡在这一态出不来
        _setAb(AbLoop.none);
        return 'B 点要打在 A 点之后，已重置';
      }
      _setAb(next);
      return 'A-B 循环中：${_ab.label}';
    }
    _setAb(AbLoop.none);
    return '已退出 A-B 循环';
  }

  void _setAb(AbLoop v) {
    if (_ab == v) return;
    _ab = v;
    _syncAbTimer();
    _emitChange();
  }

  /// 切歌时清掉 A-B：打点是针对某一首歌的一小段，换歌之后留着只会莫名其妙地循环。
  void _clearAb() {
    if (_ab == AbLoop.none) return;
    _ab = AbLoop.none;
    _syncAbTimer();
  }

  /// 按当前「生效 + 正在播放」调整守护定时器（不满足就停掉，零开销）。
  void _syncAbTimer() {
    if (_ab.active && isPlaying) {
      _abTimer ??= Timer.periodic(
        const Duration(milliseconds: 120),
        (_) => _checkAbWrap(),
      );
    } else {
      _abTimer?.cancel();
      _abTimer = null;
    }
  }

  /// 到 B 点了就绕回 A 点。
  Future<void> _checkAbWrap() async {
    // 已释放：一拍都不许再碰播放器（本方法会跨 await 醒来；闸门总说明见 dispose()）
    if (_disposed || _abWrapping || !_ab.active || !isPlaying) return;
    // getCurrentPosition() 返回 Duration?（原生还没准备好时是 null）——拿不到就跳过这一拍，
    // 下一拍再问；退化成 500ms 的 tick 也不影响（onPositionChanged 同样会推 pos）。
    final p = await _cur.player.getCurrentPosition();
    if (p == null) return;
    // await 期间可能已经暂停/切歌/清掉打点/被释放：重新确认一遍再动
    if (_disposed || _abWrapping || !_ab.active || !isPlaying) return;
    if (!_ab.shouldWrap(p)) return;
    final start = _ab.a;
    if (start == null) return;
    _abWrapping = true;
    try {
      await seek(start);
    } finally {
      _abWrapping = false;
    }
  }

  bool get _fadeEnabled => AppConfig.instance.volumeFadeEnabled;

  /// 写某一副牌的音量（按牌记，值没变就别过桥）。
  Future<void> _setVolumeOn(_Deck d, double v) async {
    // ⚠️ 已释放就别再碰播放器。**这是所有"逐步写音量"的唯一收口**
    //（`_fadeOn` / `_crossfadeTo` / `_abortCrossfade` / `_resumeWithFadeIn` 全走这里）：
    // dispose() 只能保证正在跑的淡变"下一拍让位"（`_fadeToken++`），
    // 保证不了"正卡在这一行 await 里"的那一拍 —— 那一拍醒来时播放器已经 dispose 了，
    // 真 `AudioPlayer` 会抛 `Exception('AudioPlayer has been disposed')`。
    if (_disposed) return;
    final nv = v.clamp(0.0, 1.0);
    if (nv == d.volume) return;
    d.volume = nv;
    await d.player.setVolume(nv);
  }

  /// 把某一副牌的音量从 [from] 线性渐变到 [to]。
  ///
  /// 步数与每步取值全在 `lib/volume_fade.dart` 的纯函数里（那边有单测把
  /// 「终值精确回到 [to]」这条硬不变量钉死）；这里只管过桥、让位与每步延时。
  /// 步进 16ms（约 60 帧）；步数封顶 80 —— 再细人耳也分辨不出，白费 channel 往返。
  Future<void> _fadeOn(_Deck d, double from, double to, Duration duration) async {
    final token = ++_fadeToken;
    if (!_fadeEnabled || duration <= Duration.zero) {
      await _setVolumeOn(d, to);
      return;
    }
    // seq = [起点 from, 第 1 步 … 第 steps 步]，最后一项恒等于 to
    final seq = fadeSequence(from: from, to: to, d: duration);
    await _setVolumeOn(d, seq.first);
    for (var i = 1; i < seq.length; i++) {
      if (token != _fadeToken) return; // 被新的淡变接管：让位，别抢
      await _setVolumeOn(d, seq[i]);
      if (i < seq.length - 1) {
        await Future<void>.delayed(const Duration(milliseconds: kFadeStepMs));
      }
    }
  }

  /// 起播/恢复的共用收尾：先把音量压到 0 再 resume（避免满音量蹦一下），然后淡入。
  /// 先置 [_wantPlaying]：若此刻正有一次淡出在跑，它收尾时会看到「用户想播」而作废。
  Future<void> _resumeWithFadeIn() async {
    _wantPlaying = true;
    final d = _cur;
    if (_fadeEnabled) await _setVolumeOn(d, 0);
    await d.player.resume();
    _startFadeIn();
  }

  /// 淡入到满音量（不 await：淡变不该拖慢切歌/起播）
  void _startFadeIn() {
    _wantPlaying = true;
    final d = _cur;
    unawaited(_fadeOn(d, 0, 1.0, _fadeInTime));
  }

  /// 淡出到静音再暂停，随后把音量复位，这样下次起播仍是满音量淡入。
  /// 淡出是异步的，中间用户若又点了播放（见 [_wantPlaying]）就放弃这次暂停，
  /// 避免「暂停晚到 120ms，把刚起来的播放掐掉」。
  ///
  /// ⚠️ 双播放器下：先把进行中的交叉淡变**作废并收尾**（它会把两副牌的音量都复位到
  /// 1.0，见 [_abortCrossfade]），否则「暂停」只掐掉了退场那一副、上场那一副还在响。
  Future<void> _fadeOutThenPause() async {
    // 睡眠定时到点 / 通知栏暂停都可能与 dispose() 撞上：释放之后不许再淡出、不许再 pause
    if (_disposed) return;
    _wantPlaying = false;
    await _abortCrossfade(keepIncoming: true);
    final d = _cur;
    if (_fadeEnabled && isPlaying) {
      await _fadeOn(d, d.volume, 0, _fadeOutTime);
    }
    // 淡出期间用户又点了播放 ⇒ 这次暂停作废；淡出期间被 dispose ⇒ 更不许碰播放器
    if (_wantPlaying || _disposed) return;
    await d.player.pause();
    if (d.volume != 1.0) await _setVolumeOn(d, 1.0);
  }

  /// 作废进行中的淡变并把音量归位（停止/重置时用）。
  ///
  /// ⚠️ **每一副牌都要复位**（不只是在场那一副）：交叉淡变被打断时退场那一副可能停在
  /// 0.4 之类的中间值上，下次它当值时就会"一开口就小声"—— 这就是 `volume_fade.dart`
  /// 那条「每次淡变结束音量必须回到 1.0」硬不变量的**双播放器版本**。
  Future<void> _abortFade() async {
    _wantPlaying = false;
    _fadeToken++;
    await _abortCrossfade(keepIncoming: true);
    for (final d in _allDecks()) {
      if (d.volume != 1.0) await _setVolumeOn(d, 1.0);
    }
  }

  /// 现有的所有牌（A 恒有；B 只在开关打开、且真的用过之后才有）。
  List<_Deck> _allDecks() => [_deckA, ?_deckB];

  final List<StreamSubscription> _subs = [];
  bool _initialized = false;
  /// [dispose] 跑过了：幂等标记，同时是异步淡变循环"别再碰播放器"的闸门
  ///（后者见 [_setVolumeOn] 开头那句）。清单与顺序见文件末尾的 [dispose]。
  bool _disposed = false;
  // 自动切歌进行中标记：防止上一曲完成事件在切换过程中重复触发 next()
  bool _switching = false;
  // 从上次会话恢复但尚未加载 source 的标记；首次播放时先 load 再 seek
  bool _restored = false;
  Duration _resumePos = Duration.zero; // 恢复后首次播放要 seek 到的位置
  int _lastSavedSlot = -1; // 播放位置持久化节流槽位（每 5 秒）

  Future<void> init() async {
    if (_initialized) return; // 权限重试会再次走到这，防止重复订阅
    _initialized = true;
    await _deckA.player.setReleaseMode(ReleaseMode.stop);
    mode = await Store.loadMode();
    speed = await Store.loadSpeed();
    // 历史只读路径，等 Library 加载完歌曲再调 restoreHistory 映射成 Song
    _historyPaths = await Store.loadHistory();
    // 不做 App 内音量缩放，保持默认 1.0，音量完全交给系统媒体音量键控制

    // 关键修复：audioplayers 默认用 FramePositionUpdater，播放时每一帧都会
    // 跨进程去原生层取一次播放位置，再叠加 playbackState 广播（通知栏/
    // MediaSession 每帧重建）+ 整条播放栏 UI 每帧重建，长时间运行越来越卡。
    // 改成 500ms 轮询：进度条每秒跳 2 次，肉眼感知不到差异。
    // （A、B 两副牌各自一个 —— `TimerPositionUpdater` 只在 resume 后跑、
    //   pause/stop 就停，所以不在场的那一副不会白轮询。见文件末尾的 `_bindDeck`。）

    // 初始化通知栏媒体会话状态
    playbackState.add(
      PlaybackState(
        controls: [
          MediaControl.skipToPrevious,
          MediaControl.pause,
          MediaControl.skipToNext,
          // 快退 / 快进 15 秒：放在末两位 —— androidCompactActionIndices 仍是 [0,1,2]，
          // 收起状态只露「上一首 / 播放暂停 / 下一首」，展开才多出这两颗（不挤紧凑布局）。
          MediaControl.rewind,
          MediaControl.fastForward,
        ],
        systemActions: const {
          MediaAction.seek,
          MediaAction.rewind,
          MediaAction.fastForward,
          MediaAction.play,
          MediaAction.pause,
          MediaAction.stop,
        },
        androidCompactActionIndices: const [0, 1, 2],
        processingState: AudioProcessingState.idle,
        playing: false,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        speed: speed,
      ),
    );

    _bindDeck(_deckA);

    // 耳机拔出 → 暂停，避免突然外放（原生端 ACTION_AUDIO_BECOMING_NOISY 广播触发）
    const noisyChannel = MethodChannel('com.mubox.mu_box_phone/noisy');
    noisyChannel.setMethodCallHandler((call) async {
      if (call.method == 'becomingNoisy') {
        // 耳机拔出要**立刻**停（防突然外放），所以不走淡出，只作废进行中的淡变。
        // ⚠️ 作废必须走 _abortFade()，别手写 `_fadeToken++`：它除了让位代次，
        // 还会把音量复位回 1.0。原先这里漏了复位，正在淡入时拔出会把音量卡在
        // 中间值（Dart 缓存与原生 MediaPlayer 的持久 volume 都是），
        // 破坏「每次淡变结束音量必回 1.0」这条硬不变量（H3）。
        if (isPlaying) {
          await _abortFade(); // 内部已把 _wantPlaying 置回 false
          // 拔出之后用户可能立刻又点了播放（_wantPlaying 又变 true）：上面那次
          // await 期间起来的播放不能被这次迟到的 pause() 掐掉。
          // 与 _fadeOutThenPause 里那句 `if (_wantPlaying) return;` 是同一个守卫。
          if (_wantPlaying) return;
          await _cur.player.pause();
        }
      }
    });
  }

  /// 给一副牌挂上「位置 / 时长 / 状态 / 播完」四条订阅 + 500ms 位置轮询。
  ///
  /// A 在 [init] 里挂、B 在 [_ensureDeckB] 里挂（懒建）。**两条路必须是同一个函数** ——
  /// 抄第二份迟早会漏掉某一条（B 少了 `onPlayerComplete` 就是"第二首播完不切歌"）。
  ///
  /// ⚠️ 四个处理函数第一句都是身份守卫（`identical(d, _cur)`）：不在场的那一副
  /// （预热中的 / 刚退场的）**不许**改 `pos`/`dur`/`isPlaying`/`playbackState`，
  /// 也不许触发切歌。没有这条守卫，预取时那一发 `setSource` 就会把进度条与总时长
  /// 改成下一首的（观感当场出问题）。
  void _bindDeck(_Deck d) {
    final p = d.player;
    p.positionUpdater = TimerPositionUpdater(
      getPosition: p.getCurrentPosition,
      interval: const Duration(milliseconds: 500),
    );
    // ⚠️ 四条订阅**都要挂 onError**（不接就是未处理异步异常），但**只有一条真的收得到**
    // 原生错误 —— 这个区别在真机上打回来过，别再凭想象接线：
    //
    // 原生错误（`AudioplayersPlugin.handleError` ⇒ `EventSink.error`）只进
    // `AudioPlayer._create()` 的 `onError: _eventStreamController.addError`
    // （audioplayer.dart:166/181-184），也就是 **`eventStream` 那一条广播流**。四条派生流里：
    //   ✅ `onDurationChanged` = `eventStream.where(...)`（:121）⇒ **收得到**
    //   ✅ `onPlayerComplete`  = `eventStream.where(...)`（:131）⇒ **收得到**
    //   ❌ `onPlayerStateChanged` = 另一个 controller `_playerStateController`（:102-106），
    //      `set state` 只 `add` 值、**从不 `addError`**（:74-82）⇒ **永远收不到原生错误**
    //   ❌ `onPositionChanged` = `TimerPositionUpdater.positionStream`（:114-115）⇒ 同理收不到
    //
    // ★ 所以报告点必须挂在**收得到**的那一条上：挂在 `onPlayerStateChanged` 上 = 一次都不跑
    //   ⇒ 没有 SnackBar、UI 继续显示在播（日志里那一路一次都不会出现）。
    // 有单测钉死"错误只到 dur/complete"这条路（真 `AudioPlayer` + 假平台）。
    _subs.add(p.onPositionChanged.listen((v) => _onPosTick(d, v), onError: _ignoreNativeError));
    _subs.add(
      p.onDurationChanged.listen((v) => _onDuration(d, v), onError: (Object e) => _onNativeError(d, e)),
    );
    _subs.add(p.onPlayerStateChanged.listen((s) => _onState(d, s), onError: _ignoreNativeError));
    _subs.add(p.onPlayerComplete.listen((_) => _onComplete(d), onError: _ignoreNativeError));
  }

  /// 同一次原生错误会打到**两条**派生流（`onDurationChanged` / `onPlayerComplete`）上：
  /// 除 [_onNativeError] 之外的那一条只做"接住"。
  static void _ignoreNativeError(Object _) {}

  /// 原生播放侧的**错误**（目前唯一来源是 `AudioFocusDenied`，见
  /// `third_party/audioplayers_android/.../player/FocusManager.kt` 的"有界重试用尽"分支）。
  ///
  /// **为什么必须接这条线**：`audioplayers` 的 `AudioPlayer._resume()` 在 `_platform.resume()`
  /// 返回之后**无条件**把状态置成 `PlayerState.playing`（`audioplayer.dart:272-279`）。
  /// 原生哪怕因为拿不到音频焦点而**从未 `start()`**，App 也照样显示"在播"
  /// ⇒ 用户看到的就是「App 认为还在播放音乐，其实没声音」。所以这里把真话接回来：
  /// **UI 转暂停** + **`lastError` 让播放栏弹一条说明**（`PlayerBar._onPlayError`）。
  void _onNativeError(_Deck d, Object e) {
    final code = e is PlatformException ? e.code : '';
    final detail = e is PlatformException ? (e.message ?? '') : '$e';
    debugPrint('MuBox 原生播放错误：$code $detail');
    // 不在场的那一副（预热中 / 刚退场）只留日志：它的错误不该改 UI，也不该弹窗
    if (!identical(d, _cur)) return;
    if (code != 'AudioFocusDenied') return; // 其它原生错误维持原样，不抢 lastError
    // 说真话三件事：① 起播那套别再往回抢 ② UI 转暂停 ③ 明确告诉用户原因。
    // ⚠️ **不许动 `_fadeToken`**：正在跑的淡入必须跑完，否则音量会停在中间值上
    //    （`volume_fade.dart` 那条「每次淡变结束音量必须回到 1.0」的硬不变量）。
    _wantPlaying = false;
    isPlaying = false;
    playbackState.add(playbackState.value.copyWith(playing: false));
    lastError.value = '拿不到音频焦点，已暂停（可能被其他应用占用，或被系统策略限制）';
    // 让 Dart 自己的状态机也转成 paused（也顺手停掉 500ms 位置轮询）。
    // 原生那边已经 `playing=false`，这一发 `pause` 到原生是空操作；它的内部守卫
    //（`if (desiredState == PlayerState.paused)`）还能防止"用户刚点播放又被这一发掐掉"。
    unawaited(d.player.pause());
    _emitChange();
  }

  /// 位置 tick（500ms 一拍）：进度条 / 落盘节流 / **双播放器分支**。
  void _onPosTick(_Deck d, Duration p) {
    if (!identical(d, _cur)) return; // 不在场的那一副不参与 UI、落盘与换场
    if (_crossfading) return; // 交叉淡变进行中：逻辑当前曲已经换成下一首，位置等换场后再收
    pos = p;
    playbackState.add(playbackState.value.copyWith(updatePosition: p));
    notifier.notify(); // 播放位置是高频率变更：只通知变更根（播放栏/歌词），列表页不跟着 500ms 重建
    // 每 5 秒持久化一次播放位置供重启恢复（500ms 轮询里节流，避免频繁写盘）
    final slot = p.inSeconds ~/ 5;
    if (slot != _lastSavedSlot) {
      _lastSavedSlot = slot;
      _saveSessionQuietly();
    }
    _prefetchTick++;
    _tickDual();
  }

  void _onDuration(_Deck d, Duration v) {
    if (!identical(d, _cur)) return; // 预取那一发 setSource 也会报时长：不许改 UI 的总时长
    dur = v;
    // 手动扫描的歌没有时长（durationMs=0），拿到真实时长后回写并持久化，
    // 下次启动列表/通知栏就有时长了（updateDuration 内部已做幂等去重）
    final c = current;
    if (c != null && c.durationMs <= 0 && v.inMilliseconds > 0) {
      Library.instance.updateDuration(c.id, v.inMilliseconds);
    }
    _emitChange();
  }

  void _onState(_Deck d, PlayerState s) {
    if (!identical(d, _cur)) return; // 不在场的那一副的状态不许改写 isPlaying
    isPlaying = s == PlayerState.playing;
    playbackState.add(playbackState.value.copyWith(playing: isPlaying));
    _syncAbTimer(); // 播放/暂停决定 A-B 守护定时器开不开
    _emitChange();
  }

  /// 换一整个队列并从第 [i] 首开始播（点歌单里的一首 / 点「全部歌曲」）。
  ///
  /// 队列的下标算术（含「当前曲跟着队列走」这条不变量）全在 `playback/queue.dart`
  /// 的 [QueueOps] 里，那边有单测；这里只管播放器与通知栏。
  Future<void> playQueue(List<Song> songs, int i, {String title = ''}) async {
    final q = QueueOps.push(
      songs.map((s) => s.filePath).toList(),
      i,
      title: title,
    );
    _queue = List.of(songs); // 交给 playAt 播；index 由 playAt 自己夹与设
    _queueName = q.sourceName;
    _excludedFromLoop.clear(); // 新队列默认全部参与循环
    // 换了一整个队列 = 换一次随机序：不重摇种子的话，上一张歌单听出来的顺序
    // 会被原样套到新歌单上（同一个种子 + 不同长度 → 排列看着像「又抽了一次」，
    // 但同一首歌的点歌路径完全可复现，容易被误当成 bug）。
    _shuffleSeed = _newShuffleSeed();
    _queueChanged();
    queue.add(_queue.map((s) => _mediaItem(s)).toList());
    await playAt(q.index);
  }

  /// 从持久化会话恢复队列、当前曲与播放位置（不自动播放）。
  /// 由 Library 在启动加载完歌曲后调用，传入的 songs 已按 filePath 过滤掉失效项。
  ///
  /// [seed] / [cursor] 是随机序的「固定种子 + 走到哪一格」：老版本没有这两个键，
  /// 那就保持 [_shuffleSeed] 的现值（= 随机），下次切歌时自然重建一条序。
  Future<void> restoreSession(
    List<Song> songs,
    int idx,
    int posMs, {
    String title = '',
    int? seed,
    int? cursor,
  }) async {
    if (songs.isEmpty) return;
    _queue = List.of(songs);
    _queueName = title; // 会话恢复也带来源名，重启后队列浮层标题不丢
    index = idx.clamp(0, songs.length - 1);
    current = _queue[index];
    _restored = true;
    _resumePos = Duration(milliseconds: posMs);
    pos = _resumePos;
    dur = Duration(milliseconds: current!.durationMs);
    _shuffleSeed = seed ?? _shuffleSeed;
    _shuffle = _queue.length > 1
        ? ShuffleOrder.create(_queue.length, _shuffleSeed, cursor: cursor ?? -1)
        : null;
    _syncShuffleCursor();
    _queueChanged(); // 恢复出来的队列也要落盘一次：_savedQueueRev 从 -1 起步
    queue.add(_queue.map(_mediaItem).toList());
    mediaItem.add(_mediaItem(current!));
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.ready,
        updatePosition: pos,
        queueIndex: index,
      ),
    );
    _emitChange();
  }

  /// 通知栏/锁屏用的歌手名：无 artist 标签（或 MediaStore 的占位 `<unknown>`）时返回空串，
  /// 宁可不显示，也不把 `<unknown>` 顶到锁屏/车机上。
  String _notifyArtist(Song s) {
    final a = s.artist.trim();
    if (a.isEmpty || a.toLowerCase() == '<unknown>') return '';
    return a;
  }

  MediaItem _mediaItem(Song s) => MediaItem(
    id: '${s.id}',
    // 通知栏/锁屏标题也以 app 内编辑过的歌名为准
    title: Library.instance.displayTitle(s),
    // 歌曲列表项刻意不显示歌手，但锁屏/车机/手表上「谁唱的」是唯一能看的信息，这里补上
    artist: _notifyArtist(s),
    duration: Duration(milliseconds: s.durationMs),
    // 通知栏大图优先级：App 私有封面缓存（用户设的歌曲图标）> MediaStore 专辑封面 > 无（回退 app 图标）
    artUri: ArtworkStore.uriFor(s) ??
        (s.albumId == null
            ? null
            : Uri.parse('content://media/external/audio/albumart/${s.albumId}')),
  );

  /// 曲库里的"显示名"变了（改名 / 清掉自定义歌名 / 从备份重载覆盖表）之后，
  /// 把**通知栏、锁屏、车机上那一份** metadata 重新推一次。
  ///
  /// 为什么必须有这个入口：`mediaItem` 是一份**快照**，只在"换歌"那三处推
  /// （[playQueue] / [restoreSession] / [playAt]）。**改名不改歌** —— 一次
  /// [playAt] 都不会发生，于是 audio_service 那边
  /// （`audio_service.dart:1031` 的 `_handler.mediaItem.listen`）一直挂着改名前的
  /// 旧 metadata：**App 内已经显示新名，通知栏还是旧名**。
  ///
  /// 由 `Library` 在自定义歌名真的变了之后调用（`library_data.dart` 的
  /// `_publishTitlesToSession`，`titles` 的每一处写点都会过它）。
  /// 没有当前曲（还没播过 / 队列已空）时什么都不做。
  void refreshMediaItem() {
    final c = current;
    if (c == null) return;
    mediaItem.add(_mediaItem(c));
  }

  /// 播第 [i] 首。
  ///
  /// [crossfade] 只给**位置 tick 的曲末换场**用（`_tickDual`）：true 时若空闲那一副
  /// 已经预热好这一首，就走「A 淡出 + B 淡入」而不是硬停重载。
  /// 手动切歌（next/prev/点歌/删歌）一律走 false —— 手切要**立刻响**，
  /// 不该先等 300ms 淡出（那是手感变迟钝，属于改观感，见 `crossfade.dart` 的 `atEnd`）。
  Future<void> playAt(int i, {Duration resumeFrom = Duration.zero, bool crossfade = false}) async {
    if (_disposed) return; // 已释放：入口就挡住（下面每一步都会碰播放器）
    if (_queue.isEmpty) return;
    // 任何一次"重新加载"都先把进行中的交叉淡变作废：
    // 退场那一副的音量会在这里复位回 1.0（硬不变量的双播放器版本），
    // 上场那一副被立刻掐掉（它的曲目已经不是"当前曲"了）。
    await _abortCrossfade(keepIncoming: false);
    i = (i % _queue.length + _queue.length) % _queue.length;
    index = i;
    current = _queue[i];
    _clearAb(); // 换歌了：上一首的 A-B 片段不再适用
    _recordHistory(current!);
    _restored = false; // 正常播放后退出”待恢复”状态
    _resumePos = Duration.zero;
    // 预取的拍号/失败计数按曲重置（退避窗口的时钟就是它，别让它跨曲累计）
    _prefetchTick = 0;
    _prefetchFailures = 0;
    _prefetchLastFailTick = -1;
    pos = resumeFrom; // 恢复场景初始进度直接落到上次位置，进度条不从 0 闪跳
    // 用歌曲元数据时长兜底：单曲循环重新 setSource 同一首歌时，
    // onDurationChanged 可能不再触发，若置 0 进度条会因 dur=0 变灰白禁用。
    dur = Duration(milliseconds: current!.durationMs);
    mediaItem.add(_mediaItem(current!));
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.loading,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
        // 同步当前队列索引给 MediaSession（active item id），供车载/手表等外部读取
        queueIndex: index,
      ),
    );
    _emitChange();
    try {
      await _loadAndPlay(startAt: resumeFrom, crossfade: crossfade);
    } catch (_) {
      // 首次失败多为切歌竞态（上一曲完成回调与 setSource 相互干扰），
      // 短暂延迟后重试一次，避免偶发直接落到“静默没声音”。
      await Future<void>.delayed(const Duration(milliseconds: 80));
      try {
        await _loadAndPlay(startAt: resumeFrom);
      } catch (e) {
        // 文件损坏等确实放不了：记录日志、置空闲，并把原因抛给界面提示，界面不崩
        debugPrint('播放失败：${current?.filePath} $e');
        final name = current == null ? '' : basenameOf(current!.filePath);
        lastError.value = name.isEmpty ? '这首歌播不了（文件损坏或被删）' : '播不了「$name」：文件损坏或被删';
        playbackState.add(
          playbackState.value.copyWith(
            processingState: AudioProcessingState.idle,
          ),
        );
        return;
      }
    }
    playbackState.add(
      playbackState.value.copyWith(processingState: AudioProcessingState.ready),
    );
    // 随机序的游标对齐到刚播的这首：不对齐的话「下一首 → 上一首」会从旧位置
    // 起步走，用户听到的就**不是**刚才那首了。
    _syncShuffleCursor();
    _saveSessionQuietly();
  }

  /// 停止上一曲 → 加载当前曲 source → 开始播放。
  /// [startAt] 非零时在 resume 前先 seek 到该位置：会话恢复时从上次进度继续，
  /// 避免「先从头播、再跳回去」的爆音与进度闪跳。
  ///
  /// [crossfade] = true 且空闲那一副已经预热好这一首时，改走 [_crossfadeTo]
  /// （不 stop、不 setSource，两副重叠 ~300ms）。**不是交叉淡变就逐字走下面的老路。**
  Future<void> _loadAndPlay({
    Duration startAt = Duration.zero,
    bool crossfade = false,
  }) async {
    if (crossfade && _prefetchedIndex == index && _deckB != null) {
      await _crossfadeTo(startAt);
      return;
    }
    // 硬切这条路：空闲那一副里预取的东西这一轮用不上了，标记作废
    // （不做的话下一首的窗口里 `alreadyLoaded` 会误判成"已经装好了"）
    _prefetchedIndex = -1;
    final d = _cur;
    await d.player.stop();
    // 用绝对路径播放（content:// 需要 context 才能解析，audioplayers 不支持）
    final source = current!.filePath.isNotEmpty
        ? DeviceFileSource(current!.filePath)
        : UrlSource(current!.uri);
    await d.player.setSource(source);
    await d.player.setPlaybackRate(speed); // 切歌后重新应用倍速，避免 source 重置
    if (startAt > Duration.zero) {
      await d.player.seek(startAt); // 先 seek 再 resume，恢复场景不从头播
    }
    // 先把音量压到 0 再 resume：起播那一瞬间不会「满音量蹦一下」再淡入
    await _resumeWithFadeIn();
    // 换 source 后 audio session 可能重建：重新把均衡器和音效增挂上去。
    // 不 await —— 挂失败也不该拖慢或打断播放。
    //
    // ⚠️ **必须带上"挂到哪个播放器"**：双播放器下原生若只知道"最后一次 setSource 的
    // 那个"，就会给正在预取、还没出声的那一副挂 effect，而界面上开关照样显示"开着"。
    // 开关关闭时这里恒等于 A 的 id ⇒ 与改造前逐项一致（原生按身份查到的是同一份 session）。
    _retargetEffects(d);
  }

  /// 把"当前在场的是哪个播放器"告诉三个原生引擎（频谱靠身份重新订阅、EQ/音效靠
  /// `open(playerId)`）。**唯二的调用点**是 [_loadAndPlay] 与 [_crossfadeTo] 的换场那一刻。
  void _retargetEffects(_Deck d) {
    final id = d.player.playerId;
    // 频谱：换播放器要重建 Visualizer（它没有改绑 API），所以它内部会先 await cancel
    // 再带新身份重新订阅（这里不 await：挂 effect 不该拖慢起播）
    unawaited(SpectrumEngine.instance.setTargetPlayerId(id));
    unawaited(EqEngine.instance.ensure(playerId: id));
    unawaited(ExtraFxEngine.instance.ensure(playerId: id));
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 双播放器：队列预取 + 曲末交叉淡变（**AppConfig.crossfadeEnabled 默认关闭**）
  //
  // 缺省（false）时这一段**一行都不执行**：
  //   · `_tickDual()` 第一行就返回；
  //   · 第二个播放器**根本不会被创建**（`_ensureDeckB()` 没人调）；
  //   · 于是 `_cur` 恒等于 `_deckA`，每一处调用都与改动前逐项相同。
  // ⚠️ 但真正的总闸是 `DualPlayerPolicy` 里那两个 `enabled &&`
  //   （实测：把 `_tickDual()` 的早退拆掉，缺省路径**依然**等价 —— 拦住它的是纯判定）。
  //   那行早退的独立作用是：省掉 shuffle 模式下每拍一次 `_ensureShuffle()` 的**副作用**
  //   （它会真的把随机排列建出来），以及让"这一段没跑"一眼可见。
  // 穷举证明与"开关有牙"的对照在 `test/player_service_crossfade_test.dart`。
  // ══════════════════════════════════════════════════════════════════════════

  /// 一次交叉淡变正在进行中（位置 tick 与完成事件都要让路）。
  bool _crossfading = false;

  /// 空闲那一副里已经预热好的**队列下标**；-1 = 没有（还没预热 / 已被用掉 / 作废）。
  int _prefetchedIndex = -1;

  /// 预取的拍号（位置 tick 序号，按曲重置）。退避按它算，**不用墙钟**
  /// —— `PrefetchPolicy.decide` 的契约就是"拍"（单测里没法等真实时间）。
  int _prefetchTick = 0;
  int _prefetchFailures = 0;
  int _prefetchLastFailTick = -1;

  /// 位置 tick 里的双播放器分支：**先预热、下一拍再换场**。
  ///
  /// 为什么分两拍：`setSource` 是异步的（要等 prepare），同一拍里既预热又换场的话
  /// 淡变只能推迟开场，甚至等歌播完了才起来。分两拍正好把淡变卡在曲末 ——
  /// 窗口 lead = 淡变时长 + 一拍（`CrossfadePlan.lead`），
  /// 所以第 N 拍（离曲末 ≤ lead）预热、第 N+1 拍（离曲末 ≈ lead-500ms ≈ 淡变时长）
  /// 换场，A 静音与曲末基本同时发生。
  void _tickDual() {
    final enabled = AppConfig.instance.crossfadeEnabled;
    if (!enabled) return; // ★ 缺省关闭：从这里返回就等于"这一段不存在"
    if (_crossfading) return;
    if (_queue.isEmpty || current == null) return;
    final next = _nextIndexForPrefetch();
    if (next < 0) return;
    final nextDur = Duration(milliseconds: _queue[next].durationMs);
    const plan = CrossfadePlan.standard;
    final prefetched = _prefetchedIndex == next;
    final inWindow = PrefetchPolicy.window(
      pos: pos,
      total: dur,
      nextDuration: nextDur,
      plan: plan,
    ).inWindow;
    // ① 预热好了、窗口也到了 ⇒ 换场
    if (DualPlayerPolicy.shouldCrossfade(
      enabled: enabled,
      prefetched: prefetched,
      shouldStart: plan.shouldStart(
        pos: pos,
        total: dur,
        nextDuration: nextDur,
        // 这一拍是"曲末自然到达"那一路；手动切歌根本不走这里（见 playAt 的注释）
        atEnd: true,
      ),
    )) {
      unawaited(playAt(next, crossfade: true));
      return;
    }
    // ② 还没预热 ⇒ 这一拍先预热（下一拍才换场）
    if (DualPlayerPolicy.shouldPrefetch(
      enabled: enabled,
      hasNext: true,
      inWindow: inWindow,
      alreadyLoaded: prefetched,
    )) {
      final d = PrefetchPolicy.decide(
        tick: _prefetchTick,
        pos: pos,
        total: dur,
        nextDuration: nextDur,
        nextIndex: next,
        queueLength: _queue.length,
        alreadyLoaded: prefetched,
        failures: _prefetchFailures,
        lastFailTick: _prefetchLastFailTick,
      );
      if (d.shouldPrefetch) unawaited(_prefetch(d.slotIndex));
    }
  }

  /// 曲末时 `next()` **会选中**的那一首（预取目标必须与它逐项相同）。
  ///
  /// ⚠️ 必须照抄 `_onComplete` 的三条分支（单曲循环原地重来 / 随机走固定序 /
  /// 顺序找下一首参与循环的）—— 预取 A 而真放 B 是这一块最贵的 bug，
  /// 而那正是 `prefetch.dart` 特意**不自己算**下标的原因。
  int _nextIndexForPrefetch() {
    if (_queue.length <= 1) return index; // 单曲队列：next() 也是绕回自己
    if (mode == 'single') return index; // 单曲循环：playAt(index)
    if (mode == 'shuffle') {
      final from = index < 0 ? 0 : index;
      return _ensureShuffle().step(from, 1, excluded: _excludedIndexes());
    }
    return _nextIndex(index, 1);
  }

  /// 把第 [i] 首预热到空闲那一副（只 `setSource`、**不播**，音量压到 0）。
  ///
  /// 这就是"预取"的全部：`setSource` 会让原生 `MediaPlayerWrapper` 按**这副牌自己的
  /// 身份**登记 session（改造后互不抢），但**它不会出声** —— 只有交叉淡变那一步才
  /// `resume()`。
  ///
  /// ⚠️ **目标必须是 [`_idle`]，不是 [`_ensureDeckB`] 的返回值。**
  /// `_ensureDeckB()` 恒返回 **B**（它只管懒建）；而曲末换场结束时会**翻牌**
  /// （`_crossfadeTo` 的 `_onB = !_onB`），此后"空闲那一副"是 **A**。
  /// 写成 `_ensureDeckB()` 的返回值 ⇒ **翻牌之后**预取打在**正在响的那一副**上：
  /// 它先被 `_setVolumeOn(…, 0.0)` 压静音、再被 `setSource(下一首)` 换掉 source
  /// （原生 `MediaPlayerWrapper.setSource` 第一步就是 `mediaPlayer.reset()`），
  /// 而紧接着那句 `identical(_idle, idle)` 守卫**必然**不成立 ⇒ 提前 return，
  /// `_prefetchedIndex` 永远是 -1 ⇒ 换场再也不发生、曲末也没有完成事件来推它
  /// ⇒ **症状：自然听完一首，下一首没声音**。
  /// 有单测钉住「翻牌之后」这一组情形。
  Future<void> _prefetch(int i) async {
    if (i < 0 || i >= _queue.length) return;
    final song = _queue[i];
    final atIndex = index;
    try {
      await _ensureDeckB(); // 只保证两副牌都在（懒建），返回值刻意丢掉
      final idle = _idle; // ★ 空闲那一副：翻过牌之后它是 A
      // 预热期间静音：哪怕这一副因为任何原因响起，也不能"先满音量蹦一下"
      await _setVolumeOn(idle, 0.0);
      final source = song.filePath.isNotEmpty
          ? DeviceFileSource(song.filePath)
          : UrlSource(song.uri);
      await idle.player.setSource(source);
      await idle.player.setPlaybackRate(speed);
      // await 期间可能已经切歌 / 换场：那就作废这次预取（别把脏下标留下来）
      if (index != atIndex || !identical(_idle, idle)) return;
      _prefetchedIndex = i;
      _prefetchFailures = 0;
      _prefetchLastFailTick = -1;
    } catch (e) {
      _prefetchFailures++;
      _prefetchLastFailTick = _prefetchTick;
      _prefetchedIndex = -1;
      // 预取失败不该打扰用户（下一拍会退避重试，真到曲末还有硬切那条老路兜底）
      debugPrint('预取失败：${basenameOf(song.filePath)} $e');
    }
  }

  /// 交叉淡变换场：退场那一副（[_cur]）淡出、预热好的空闲那一副淡入，两副重叠
  /// `kCrossfadeTime`。结束时**翻牌**（[_onB]）并对调主从关系。
  ///
  /// 调用前提（[_loadAndPlay] 已经把过关）：`_prefetchedIndex == index && _deckB != null`。
  Future<void> _crossfadeTo(Duration startAt) async {
    if (_disposed) return; // 已释放：两副牌一把都不许再碰（见 dispose() 的三、）
    final out = _cur; // 退场
    final inn = _idle; // 上场（已预热，音量 0）
    final token = ++_fadeToken; // 一次交叉淡变 = 一次淡变：两条曲线共用一个代次
    _crossfading = true;
    _prefetchedIndex = -1;
    final curves = crossfadeCurves(fromLeft: out.volume, duration: kCrossfadeTime);
    try {
      if (startAt > Duration.zero) {
        await inn.player.seek(startAt);
        if (_disposed) return; // seek 期间被释放：紧接着那句 resume() 会打到死播放器上
      }
      await _setVolumeOn(inn, curves.inRight.first); // 起点恒为 0.0
      await inn.player.resume();
      await _setVolumeOn(out, curves.outLeft.first); // = out.volume，只为把起点落到原生
      for (var i = 1; i < curves.length; i++) {
        if (token != _fadeToken) return; // 被打断：让位（打断方负责复位两副的音量）
        await _setVolumeOn(out, curves.outLeft[i]);
        await _setVolumeOn(inn, curves.inRight[i]);
        if (i < curves.length - 1) {
          await Future<void>.delayed(const Duration(milliseconds: kCrossfadeStepMs));
        }
      }
      // 这一拍之后是"翻牌 + 换 effect + 停掉退场那一副"三件都会碰播放器的事：
      // 被释放就打住，别对着死播放器翻牌（曲线让位那一路已经在上面的 token 检查里 return）
      if (_disposed) return;
      // 终点：上场那一副**精确** 1.0（curves 末项就是 1.0，这里显式钉一次硬不变量）
      await _setVolumeOn(inn, 1.0);
      // 先翻牌：此后退场那一副的所有事件都被身份守卫丢掉（它的 stop 会报"不在播"）
      _onB = !_onB;
      isPlaying = true;
      playbackState.add(
        playbackState.value.copyWith(
          playing: true,
          processingState: AudioProcessingState.ready,
        ),
      );
      notifier.notify();
      // 换 effect：频谱/EQ/低音/响度跟着挂到新的这一副上
      _retargetEffects(_cur);
      // 退场那一副停车并**复位回 1.0**（硬不变量的双播放器版本：
      // 它下次当值时必须是满音量，否则会"一开口就小声"）
      await out.player.stop();
      await _setVolumeOn(out, 1.0);
    } finally {
      _crossfading = false;
    }
  }

  /// 作废进行中的交叉淡变，并把两副牌都收拾干净。
  ///
  /// [keepIncoming]：
  /// - `true`（暂停 / 停止 / 重置 / 拔耳机）：**翻牌**，让"已经出声的那一副"成为在场者
  ///   （逻辑当前曲早就换成下一首了），并把它立刻掐掉、把被放弃的退场那副停掉；
  /// - `false`（重新加载另一首：`playAt`）：留在场者不变，只把上场那一副掐掉 ——
  ///   退场那一副交给紧接着的 `_loadAndPlay` 去 stop+setSource（与改动前的硬切逐项相同）。
  ///
  /// ⚠️ 两条路都会把**两副的音量复位回 1.0** —— 这就是
  /// 「手切歌打断淡变时退场播放器的音量必须复位」那条要求的落点。
  Future<void> _abortCrossfade({required bool keepIncoming}) async {
    if (!_crossfading || _deckB == null) return;
    if (_disposed) return; // 已释放：连"让位 + 复位"都不该做（见 dispose() 的三、）
    _fadeToken++; // 两条曲线立刻让位
    _crossfading = false;
    final inn = _idle;
    final out = _cur;
    if (keepIncoming) {
      _onB = !_onB; // 先把"在场"扶正到已经出声的那一副
    }
    // 它已经出声了：立刻掐掉（不能让它停在半音量上继续响）
    await inn.player.pause();
    if (_disposed) return; // pause 期间被释放：下面那句 stop() 会打到死播放器上
    if (keepIncoming) {
      await out.player.stop(); // 被放弃的那一副（它的曲目已经不算"当前曲"）
      isPlaying = false;
    }
    await _setVolumeOn(inn, 1.0);
    await _setVolumeOn(out, 1.0);
  }

  Future<void> toggle() async {
    if (_disposed) return; // 已释放
    if (current == null) {
      if (_queue.isNotEmpty) await playAt(0);
      return;
    }
    if (isPlaying) {
      await _fadeOutThenPause();
      return;
    }
    if (_restored) {
      // 恢复后首次播放：带上次进度重新加载（seek 在 resume 前完成，不从头播）
      await playAt(index, resumeFrom: _resumePos);
      return;
    }
    await _resumeWithFadeIn();
  }

  Future<void> next() => _step(1);

  Future<void> prev() => _step(-1);

  /// 上/下一首的共用实现：随机模式沿**固定随机序**走一格，顺序模式按方向找下一首
  /// 参与循环的歌。
  Future<void> _step(int dir) async {
    if (_queue.isEmpty) return;
    if (mode == 'shuffle' && _queue.length > 1) {
      // `ShuffleOrder.step` 是纯函数（排列 + 游标），正负方向走**同一条**排列
      // ⇒ 前一首先「下一首」再「上一首」能精确回到同一首。
      final from = index < 0 ? 0 : index;
      final s = _ensureShuffle();
      final i = s.step(from, dir, excluded: _excludedIndexes());
      await playAt(i);
      return;
    }
    await playAt(_nextIndex(index, dir));
  }

  /// 「不参与循环」的名单换算成**下标集合**（排除名单按 Song.id 记，见 [loopEnabled]）。
  ///
  /// ⚠️ 只能按下标算、不能按 id 算：同一首歌在队列里可能出现两次（「下一首播放」
  /// 会插重复），按 id 过滤会把两次一起排掉。
  Set<int> _excludedIndexes() {
    if (_excludedFromLoop.isEmpty) return const {};
    final out = <int>{};
    for (var i = 0; i < _queue.length; i++) {
      if (_excludedFromLoop.contains(_queue[i].id)) out.add(i);
    }
    return out;
  }

  /// 从 from 出发朝 dir 方向找下一首参与循环的歌（dir = 1 下一首 / -1 上一首）。
  /// 全部参与时简单顺序切换。
  int _nextIndex(int from, int dir) {
    if (_excludedFromLoop.isEmpty) {
      return (from + dir + _queue.length) % _queue.length;
    }
    for (var step = 1; step <= _queue.length; step++) {
      final i = (from + dir * step + _queue.length) % _queue.length;
      if (loopEnabled(_queue[i])) return i;
    }
    return (from + dir + _queue.length) % _queue.length;
  }

  /// 上一曲**自然播完**（不是我们 stop 掉的）。
  ///
  /// 双播放器下这条有两个前提检查：
  /// ① 事件必须来自**在场**那一副（不在场的是预热/已退场的，它的"播完"与我们无关）；
  /// ② 交叉淡变进行中直接丢掉 —— 那 300ms 里"逻辑当前曲"已经换成下一首了，
  ///    退场那一副恰好在曲末报完成，接住它就会**多切一首**。
  /// 走完交叉淡变那条路时退场那一副是被 `stop()` 掉的（不发完成事件），
  /// 所以正常情况下这里根本收不到它的完成 —— 这两条守卫是给"淡变刚好卡在曲末"那一瞬兜底的。
  Future<void> _onComplete(_Deck d) async {
    if (!identical(d, _cur)) return;
    if (_crossfading) return;
    if (_switching) return; // 防重入：切歌进行中忽略重复的完成事件
    _switching = true;
    try {
      // 上一曲播放完成时，audioplayers 内部（置 completed 状态 + 位置更新器收尾）
      // 和 native 层的自动 stop/seek 是异步的。立即切歌会与这些清理竞态，
      // 偶发导致 setSource 抛异常被吞掉、下一曲不响。先让一帧让 native 收尾。
      await Future<void>.delayed(const Duration(milliseconds: 30));
      if (mode == 'single') {
        // 单曲循环：同样走统一的重新加载路径（含失败重试），
        // 不再用 seek(0) 捷径，避免 completed 状态下恢复播放的边界情况。
        await playAt(index);
      } else {
        await next();
      }
    } finally {
      _switching = false;
    }
  }

  Future<void> cycleMode() async {
    const order = ['list', 'single', 'shuffle'];
    await setMode(order[(order.indexOf(mode) + 1) % order.length]);
  }

  /// 直接设置播放模式（list / single / shuffle）
  Future<void> setMode(String m) async {
    if (mode == m) return;
    mode = m;
    await Store.saveMode(mode);
    _emitChange();
  }

  /// 设置播放倍速（0.5 ~ 2.0），同步通知栏并持久化，重启后保留。
  ///
  /// 双播放器下两副都要设：空闲那一副可能在预热时就被设过，但换场之后它是在场者，
  /// 而「下一首」那一副是切歌时才 `setPlaybackRate`（`_loadAndPlay` / `_crossfadeTo`
  /// 之前的那一次 `setSource` 之后）。这里补一发不漏掉正在响的那一副。
  @override
  Future<void> setSpeed(double v) async {
    if (_disposed) return; // 已释放（设置页/通知栏都可能晚一拍才调进来）
    speed = v;
    await _cur.player.setPlaybackRate(v);
    final other = _deckB;
    if (other != null && !identical(other, _cur)) {
      await other.player.setPlaybackRate(v);
    }
    playbackState.add(playbackState.value.copyWith(speed: v));
    await Store.saveSpeed(v);
    _emitChange();
  }

  // ---- 睡眠定时（设置页用，到点自动暂停） ----

  Timer? _sleepTimer;
  Duration _sleepRemaining = Duration.zero;

  /// 是否已开启睡眠定时
  bool get sleepActive => _sleepTimer != null;

  /// 剩余倒计时（未开启时为 0）
  Duration get sleepRemaining => _sleepRemaining;

  /// 开启睡眠定时：每秒递减，归零后自动暂停播放（重新开启会重置倒计时）。
  void startSleepTimer(Duration d) {
    _sleepTimer?.cancel();
    _sleepRemaining = d;
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) async {
      _sleepRemaining -= const Duration(seconds: 1);
      if (_sleepRemaining <= Duration.zero) {
        t.cancel();
        _sleepTimer = null;
        await _fadeOutThenPause(); // 到点温柔收尾：有了淡出就不再「啪」一下断掉
        _emitChange(); // 定时结束是结构变化：通知列表页
        return;
      }
      // 倒计时是「位置类」高频 tick：只通知播放栏那层。原实现每秒 _emitChange()
      // 会把歌单页/设置页/背景层一起重建（睡眠定时开着时整机都在每秒重绘）。
      notifier.notify();
    });
    _emitChange();
  }

  /// 取消睡眠定时。
  void cancelSleepTimer() {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepRemaining = Duration.zero;
    _emitChange();
  }

  // ---- 队列管理（播放队列浮层用） ----

  /// 当前播放队列（只读副本）
  List<Song> get queueList => List.unmodifiable(_queue);

  /// 当前队列来源名（歌单名/「全部歌曲」/单曲名），空串表示未知来源
  String get queueSourceName => _queueName;

  /// 历史播放列表（新→旧，只读副本）
  List<Song> get historyList => List.unmodifiable(_history);

  /// 把一首歌记入历史：去重、最新在前、超出上限挤掉最旧。历史模式播放时不再记录。
  /// 去重与持久化都用 **filePath**（刷新后 id 会变，路径稳定）。
  void _recordHistory(Song s) {
    if (historyMode) return;
    _history.removeWhere((e) => e.filePath == s.filePath);
    _history.insert(0, s);
    if (_history.length > historyLimit) {
      _history.removeRange(historyLimit, _history.length);
    }
    _saveHistoryNow();
  }

  /// 曲库加载完后把持久化的历史映射成歌曲（按 filePath 匹配；已失效/被删的丢掉）。
  /// 由 `Library._restoreLastSession` 调用 —— 那时 `Library.songs` 才刚就位。
  void restoreHistory(List<Song> songs) {
    if (_historyPaths.isEmpty || songs.isEmpty) return;
    final byPath = {for (final s in songs) s.filePath: s};
    // 私密歌照样进历史（历史浮层只在 App 内可见），但已经不在库里的要滤掉
    final restored = <Song>[
      for (final p in _historyPaths)
        if (byPath[p] != null) byPath[p]!,
    ];
    if (restored.isEmpty) return;
    _history
      ..clear()
      ..addAll(restored);
    changeNotifier.notify();
  }

  /// 删歌时把历史里的同款一并清掉（否则浮层里会留着一条点不动的死记录）。
  void pruneHistory(Set<int> removedIds) {
    final before = _history.length;
    _history.removeWhere((s) => removedIds.contains(s.id));
    if (_history.length != before) _saveHistoryNow();
  }

  /// 历史落盘：**不做去抖**，直接写。
  /// 记一次历史只在「换一首歌」时发生（不是每帧），一份 ≤100 条路径的 JSON 写起来
  /// 可以忽略；去抖反而会在「听完一首就杀进程」时把刚记的那条丢掉。
  void _saveHistoryNow() {
    unawaited(Store.saveHistory(_history.map((s) => s.filePath).toList()));
  }

  /// 切换历史播放：开 = 保存当前队列并换成历史列表；关 = 恢复原来的歌单。
  /// 播放模式（列表/单曲/随机）不切换，仍按用户当前选择生效。
  Future<void> toggleHistoryMode() async {
    if (!historyMode) {
      _baseQueue = List.of(_queue);
      _baseQueueName = _queueName;
      historyMode = true;
      if (_history.isNotEmpty) {
        await playQueue(_history, 0, title: '历史播放');
      } else {
        // 无历史：切到空历史
        _queue = [];
        _queueName = '历史播放（空）';
        index = -1;
        _queueChanged(); // 队列变了：作废随机序 + 下次落盘写队列本身
        current = null;
        isPlaying = false;
        pos = Duration.zero;
        dur = Duration.zero;
        _excludedFromLoop.clear();
        queue.add([]);
        mediaItem.add(MediaItem(id: '', title: ''));
        playbackState.add(playbackState.value.copyWith(
          playing: false,
          processingState: AudioProcessingState.idle,
          queueIndex: null,
          updatePosition: Duration.zero,
        ));
      }
    } else {
      historyMode = false;
      if (_baseQueue.isNotEmpty) {
        await playQueue(_baseQueue, 0, title: _baseQueueName);
      }
    }
    _emitChange();
  }

  /// 该歌曲是否参与循环播放
  bool loopEnabled(Song s) => !_excludedFromLoop.contains(s.id);

  /// 勾选/取消该歌曲参与循环
  void setLoopEnabled(Song s, bool enabled) {
    if (enabled) {
      _excludedFromLoop.remove(s.id);
    } else {
      _excludedFromLoop.add(s.id);
    }
    _emitChange();
  }

  /// 从播放队列移除歌曲；移除当前正在播放的歌时自动切到下一首。
  ///
  /// 下标怎么挪（删当前曲之前的 / 删当前曲 / 删当前曲之后的，三种各不一样）全在
  /// `QueueOps.removeAt` 里 —— 那是本文件最容易算错的一处，所以搬进了单测。
  Future<void> removeFromQueue(Song s) async {
    final i = _queue.indexWhere((e) => e.id == s.id);
    if (i < 0) return;
    final before = index; // 删之前的当前曲下标（下面所有分支判定都用它）
    final q = QueueOps.removeRef(
      QueueState(refs: _queue.map((e) => e.filePath).toList(), index: before),
      s.filePath,
    );
    _queue.removeAt(i);
    _excludedFromLoop.remove(s.id);
    _queueChanged(); // 队列内容变了：下次落盘要写队列本身
    index = q.index;
    if (q.index < 0) {
      // 删完队列空了
      current = null;
      isPlaying = false;
      pos = Duration.zero;
      dur = Duration.zero;
      queue.add([]);
      _emitChange();
      _saveSessionQuietly(); // 空队列也要落盘：否则重启后「上次那首」又冒出来
      return;
    }
    if (i < before) {
      // 移除的是当前曲之前的歌：当前曲没变，只是索引前移一位，同步给 MediaSession
      playbackState.add(playbackState.value.copyWith(queueIndex: index));
    } else if (i == before) {
      _syncQueueToSession(); // 先把「已移除该曲」的队列同步给通知栏，再切歌
      await playAt(index);
      return;
    }
    _syncQueueToSession();
    _emitChange();
    _saveSessionQuietly();
  }

  /// 把内存队列同步给通知栏/锁屏（MediaSession 的 queue）。
  void _syncQueueToSession() => queue.add(_queue.map(_mediaItem).toList());

  String get modeText => switch (mode) {
    'single' => '单曲循环',
    'shuffle' => '随机播放',
    _ => '列表循环',
  };

  // ---- 通知栏/锁屏控制回调（audio_service） ----
  @override
  Future<void> play() async {
    if (current == null) {
      if (_queue.isNotEmpty) await playAt(0);
      return;
    }
    // 会话恢复后首次播放：MediaPlayer 尚未加载 source，直接 resume 会「显示播放但无声」。
    // 复用恢复逻辑，先加载当前曲再 seek 回上次位置。
    if (_restored) {
      await playAt(index, resumeFrom: _resumePos);
      return;
    }
    await _resumeWithFadeIn();
    // 从暂停恢复时也确认一次（可能刚在 EQ / 音效页改过设置）
    _retargetEffects(_cur);
  }

  @override
  Future<void> pause() async {
    await _fadeOutThenPause();
  }

  @override
  Future<void> seek(Duration position) async {
    if (_disposed) return; // 已释放（进度条拖拽 / A-B 绕回都走这里）
    pos = position;
    notifier.notify(); // 进度拖拽是位置类变更：只通知变更根，列表页不跟着重建
    await _cur.player.seek(position);
  }

  @override
  Future<void> skipToNext() async {
    await next();
  }

  @override
  Future<void> skipToPrevious() async {
    await prev();
  }

  /// 通知栏/锁屏/车机的「快退 / 快进」步长（秒）
  static const Duration kSeekStep = Duration(seconds: 15);

  /// 快退（notification / 蓝牙耳机 / 车机按键都会走到这）
  @override
  Future<void> rewind() => _nudge(-kSeekStep);

  /// 快进
  @override
  Future<void> fastForward() => _nudge(kSeekStep);

  /// 相对当前位置挪一段，夹在 [0, 总时长] 内（超出会被系统播放器拒绝或跳回 0）。
  /// 总时长未知（手动扫描的歌还没拿到真实时长）时只夹下界。
  Future<void> _nudge(Duration delta) async {
    if (current == null) return;
    final len = dur.inMilliseconds > 0 ? dur.inMilliseconds : current!.durationMs;
    var t = pos.inMilliseconds + delta.inMilliseconds;
    if (t < 0) t = 0;
    if (len > 0 && t > len) t = len;
    await seek(Duration(milliseconds: t));
  }

  @override
  Future<void> stop() async {
    if (_disposed) return; // 已释放：不许再 stop 两副牌，也不许再调 super.stop()
    _clearAb();
    // _abortFade 里已经作废交叉淡变并把两副牌的音量复位回 1.0
    await _abortFade();
    // 两副都停：双播放器下只停在场那一副会留下另一副在响
    for (final d in _allDecks()) {
      await d.player.stop();
    }
    await super.stop();
  }

  /// 恢复备份前重置播放状态：停播、清队列与当前曲、同步通知栏。
  Future<void> resetForRestore() async {
    if (_disposed) return; // 已释放
    _clearAb();
    await _abortFade();
    for (final d in _allDecks()) {
      await d.player.stop();
    }
    _prefetchedIndex = -1; // 队列都要清了，预热的下标不再有意义
    _queue = [];
    _queueName = '';
    index = -1;
    _queueChanged(); // 队列代次 +1：紧接着那次落盘会把空队列写进 queue.json
    current = null;
    isPlaying = false;
    pos = Duration.zero;
    dur = Duration.zero;
    _excludedFromLoop.clear();
    queue.add([]);
    mediaItem.add(MediaItem(id: '', title: ''));
    playbackState.add(
      playbackState.value.copyWith(
        playing: false,
        processingState: AudioProcessingState.idle,
        queueIndex: null,
        updatePosition: Duration.zero,
        bufferedPosition: Duration.zero,
      ),
    );
    _emitChange();
    _saveSessionQuietly(); // 备份恢复清了队列，磁盘上的 queue.json 必须跟着清
  }

  // ══════════════════════════════════════════════════════════════════════════
  // 生命周期：释放
  //
  // ⚠️ **本仓库当前没有任何调用点，这是查清后的结论，不是漏接。**
  // `playerService` 是 `main.dart:28` 在 `AudioService.init(builder:)` 里 new 出来的
  // **进程级单例**，从头活到进程结束；全仓 20 多处调用（`playerService!`）全是
  // "用到就读全局"，**没有任何一处拥有它的生命周期** —— 退出根页面、换歌单页、
  // 恢复备份，服务都继续活着（恢复备份走的是 `resetForRestore()`，不是销毁）。
  // 硬接一个调用点只会造出「dispose 完界面还在用」，所以**只加方法、不接调用点**。
  // ══════════════════════════════════════════════════════════════════════════

  /// 释放 [PlayerService] 持有的**全部**东西。幂等（重复调用直接返回）。
  ///
  /// 返回 `Future`：① 五个动作里最后两个是异步的原生释放，能 await 才测得准；
  /// ② 它**不是** Flutter 的 `State.dispose`（本类不继承 `State`/`ChangeNotifier`），
  /// 不受"dispose 必须同步"那条约定约束（样板形状仍照 `pages/artwork_crop_page.dart`：
  /// 一个方法、把持有物放干净、不写 `super`）。
  ///
  /// ## 一、持有物清单（逐项读代码列的 —— 「要不要放 / 为什么」）
  ///
  /// | 持有物 | 声明处 | 放不放 | 为什么 |
  /// |---|---|---|---|
  /// | `_deckA.player` | `:85` `:102` | **要** | 一个真 `AudioPlayer` = 一个原生
  ///   `MediaPlayerWrapper` + 一份 platform channel 会话 + 一个 500ms 的
  ///   `TimerPositionUpdater`。audioplayers 的文档写明「不再用就必须 `dispose()`」——
  ///   不释放就是原生 MediaPlayer 泄漏。 |
  /// | `_deckB?.player` | `:106` | **要**（先判 null） | 同上。它是 `_playerFactory()`
  ///   造出来的，**除了这里没有任何人持有它**；交叉淡变开关关着时它是 null（压根没建过）。 |
  /// | `_subs` | `:459`，由 `:549 _bindDeck` 填 | **要** cancel | 每副牌 4 条：
  ///   `onPositionChanged` / `onDurationChanged` / `onPlayerStateChanged` /
  ///   `onPlayerComplete`。**这是本方法里最要命的一条**：`AudioPlayer.dispose()` 干的
  ///   第一件事是 `state = PlayerState.disposed`（`audioplayer.dart:74-82` 会往
  ///   `_playerStateController` 推一帧），我们的 `_onState` 收到就写 `isPlaying` 并
  ///   `_emitChange()` —— 顺序反了就是**"释放完还在收事件"**，打到已 dispose 的
  ///   `ChangeNotifier` 上（debug 直接断言炸）。订阅不取消还等于回调闭包永远攥着
  ///   `this`，服务回收不掉。 |
  /// | `_abTimer` | `:294` | **要** cancel | 120ms periodic。不取消会一直跑：每拍一次
  ///   跨进程 `getCurrentPosition()`，到点还可能 `seek()`（对着已释放的播放器）。 |
  /// | `_sleepTimer` | `:1137` | **要** cancel | 1s periodic。不取消的话到点还会去
  ///   `_fadeOutThenPause()` —— 对一个已经释放的服务做淡出。 |
  /// | `notifier` | `:133` | **要** dispose | `ChangeNotifier`，高频通知根
  ///   （播放栏 `player_bar`、歌词页都在监听）。不释放则那些页面永远被它攥住。 |
  /// | `changeNotifier` | `:136` | **要** dispose | 同上（列表页 / 背景氛围层）。 |
  /// | `lastError` | `:140` | **要** dispose | `ValueNotifier<String?>`，播放栏
  ///   `:54` 监听它弹 SnackBar。 |
  /// | 500ms 位置轮询 | `:551` 建，挂在 `AudioPlayer.positionUpdater` 上 | **不要单独放** |
  ///   它归 `AudioPlayer` 所有：`AudioPlayer.dispose()` 里那句
  ///   `_positionUpdater!.dispose()`（`audioplayer.dart:505`）已经 `stop()` 掉那个
  ///   periodic —— 这里再放一次是**重复释放（别人的东西）**。 |
  /// | `_persist`（落盘串行链） | `:237` | **不要** | 它不是资源，是个 `Future` 引用；
  ///   链尾自己会跑完。在 `dispose` 里 await 它反而会把释放拖住，而
  ///   `_saveSessionQuietly` 本来就是"写不进去就算了"的旁路。 |
  /// | `_rng` / `_shuffle` / `_queue` / `_history` / `_ab` | — | **不要** | 纯 Dart 数据，
  ///   没有原生资源，GC 管。 |
  /// | `SpectrumEngine.instance` | 只在 `_retargetEffects`(`:793`) 推 playerId | **不要，也不许** |
  ///   它是**进程级单例 + 引用计数**（`acquire()/release()`，见 `spectrum.dart:647`、
  ///   `equalizer_page.dart:110`），持有者是**两个 UI 视图**，`PlayerService` 一次都没
  ///   `acquire()` 过。在这里 `release()` 会把**别人的那一份**放掉 ——
  ///   老 bug「从设置页返回后播放栏频谱被掐停」就是这个形状。它也没有 `dispose()`。 |
  /// | `EqEngine.instance` / `ExtraFxEngine.instance` | `:798` `:799` | **不要** | 同上：
  ///   进程级单例，挂到**播放器的 audio session** 上，session 随
  ///   `AudioPlayer.dispose()` 一起消失，原生侧自己收尾。两者都没有 `dispose()`。 |
  /// | `PlaybackSession` | — | — | **本仓库 Dart 侧没有这个类**（查过：只有 Kotlin 的
  ///   `third_party/audioplayers_android/.../AudioSessionProvider.kt`，那是**播放器**
  ///   登记进去的 per-player 登记表，不是本服务持有的对象）。 |
  /// | `MethodChannel('.../noisy')` 的 handler | `:520` | **不要，刻意** | 耳机拔出广播的
  ///   处理器，`init()` 里挂。它是**全进程一个**的 channel handler，不是"我持有的资源"；
  ///   本服务又活到进程结束 ⇒ 本来就不该摘。真要摘，`setMethodCallHandler(null)` 是
  ///   全局动作（撤掉的是"当前挂着的那个"），比留着更容易出怪事。 |
  ///
  /// ## 二、顺序（每一步都在防一件具体的事）
  ///
  /// ① 先让淡变让位 → ② 再停 tick → ③ 再断订阅 → ④ 再断通知器 → ⑤ 最后放播放器。
  ///
  /// 反过来（先放播放器再断订阅）会同时踩两条：
  /// `AudioPlayer.dispose()` 推的那帧 `PlayerState.disposed` 会被 `_onState` 接住，
  /// 把 `isPlaying` 改掉并通知一堆已经死掉的监听者；而 `_abTimer` 的下一拍会对着
  /// 死播放器 `getCurrentPosition()`（抛 `Exception('AudioPlayer has been disposed')`）。
  ///
  /// ## 三、交叉淡变正跑着被 dispose —— 选了哪条路
  ///
  /// **复用 [`_abortCrossfade`] 的「第一刀」，不复用它后面的「收拾两副牌」。**
  /// - `_abortCrossfade`(`:992`) 做两件事：(a) `_fadeToken++` + `_crossfading = false`
  ///   ——让两条正在跑的曲线在下一个检查点自己 `return`；(b) `pause()/stop()` 两副牌
  ///   并把音量复位回 1.0。
  /// - 这里**只抄 (a)**。(b) **刻意不做**：它存在的意义是"给**还要继续用**的播放器复位
  ///   音量"（`volume_fade.dart` 那条硬不变量的双播放器版本）；而本方法下一步就把两副牌
  ///   都 `dispose()` 了，"复位"不但没意义，还会在 `dispose()` 返回**之后**再去碰已经死掉的
  ///   播放器 —— 正好是上面那条"释放完还在收事件"的镜像。
  /// - 剩下的窗口（曲线正卡在 `_setVolumeOn` 的 `await` 里）由 `_setVolumeOn` 开头那句
  ///   `if (_disposed) return;` 兜住。
  ///
  /// ## 四、非音量路径的闸门（第二道）
  ///
  /// `_setVolumeOn` 只管"写音量"这一个收口，**别的 await 落点一个都没被它盖住**：
  /// `_fadeOutThenPause` 的 `d.player.pause()`、`_checkAbWrap` 醒来后的 `seek()`、
  /// `_abortCrossfade` 的 `out.player.stop()`、`_crossfadeTo` 循环外的 `resume()/stop()`，
  /// 以及各公开入口（`playAt`/`toggle`/`seek`/`setSpeed`/`stop`/`resetForRestore`）——
  /// 它们都可能"已经起步、卡在 await 里"，释放之后醒来就对着死播放器动手：真
  /// `AudioPlayer` 在 `pause()/stop()/resume()` 里那句 `state = …`（`audioplayer.dart:74-77`
  /// / `:246` / `:260` / `:276`）会**必抛** `Exception('AudioPlayer has been disposed')`，
  /// 在 await 它的调用点变成一条没人接的异步异常（`setVolume`/`seek` 不设 state，
  /// 不会抛这个，但会打到已经释放的原生播放器上）。这些点现在各带一句
  /// `if (_disposed) return;`。
  ///
  /// ⚠️ **生产路径上这些闸门恒为假**：`_disposed` 只在生产代码的本方法里被写成 true，而
  /// App 里**没有调用点**（见上面那一段）⇒ 每一处守卫都是**逐项等价的空操作**，只为"将来
  /// 真有人接调用点"那一天留着。单测会真的调它（逐条去掉守卫必红）。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;

    // ① 让正在跑的淡变 / 交叉淡变让位（只抄 _abortCrossfade 的第一刀，理由见上）
    _fadeToken++;
    _crossfading = false;

    // ② 停 tick：两个 periodic Timer，都是会去碰播放器的那种
    _abTimer?.cancel();
    _abTimer = null;
    _sleepTimer?.cancel();
    _sleepTimer = null;

    // ③ 断订阅：**必须早于 ⑤**（播放器 dispose 时会推最后一帧状态）
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();

    // ④ 断通知器：走完 ③ 之后就不会再有回调进来碰它们了
    notifier.dispose();
    changeNotifier.dispose();
    lastError.dispose();

    // ⑤ 最后放播放器：先 B（懒建的那一副，没建过就是 null），A 压尾
    final b = _deckB;
    if (b != null) await b.player.dispose();
    await _deckA.player.dispose();
  }
}
