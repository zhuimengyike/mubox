/// `PlayerService.dispose()` 的**断言**：放干净了没有、放完之后还会不会动。
///
/// 这个文件回答四件事，正向 + 负向成对：
///
/// 1. **正向**：`dispose()` 之后，播放器再推事件**不许**改状态、**不许**再通知；
/// 2. **正向**：两副牌（A 恒有、B 懒建）都被释放、两个 `Timer` 都停、订阅都断；
/// 3. **正向**：交叉淡变正跑着被 `dispose` ⇒ 两条曲线让位，谁都不再去碰已经释放的播放器；
/// 4. **幂等**：连调两次不炸、不重复释放。
///
/// ⚠️ 用的是**真 `PlayerService`** + 假播放器（与 `player_service_test.dart` /
/// `player_service_crossfade_test.dart` 同一套路），不是"把逻辑抄一份到测试里"。
/// `testWidgets` 仍然 = 0。
library;

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

late Directory _docs;

/// 假播放器：位置/时长/状态/播完四条流由测试推动，**并且照抄真播放器"释放后不可用"**。
///
/// 关键的一条是 [dispose] 里的顺序 —— 与 `audioplayers-6.8.1/lib/src/audioplayer.dart`
/// 逐项一致：
/// ```
/// state = desiredState = PlayerState.disposed;   // ← 会往 onPlayerStateChanged 推一帧！
/// ... 关掉四个 controller ...
/// ```
/// 正是这一帧让「先断订阅、再放播放器」变成硬要求：顺序反了，服务的 `_onState`
/// 会在播放器已经 disposed 之后被叫起来，去写 `isPlaying` 并 `_emitChange()`。
class _FakePlayer implements AudioPlayer {
  _FakePlayer(this.playerId);

  @override
  final String playerId;

  /// 已经释放（真播放器释放后再用会抛，见 [_guard]）。
  bool disposed = false;

  /// 按顺序的调用日志（**先记后抛**：这样"释放后还被调了一次"既有痕迹、也会当场响）。
  final List<String> calls = [];

  final List<Source> sources = [];
  final List<double> volumeWrites = [];

  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _state = StreamController<PlayerState>.broadcast();
  final _done = StreamController<void>.broadcast();

  void emitPos(Duration d) => _pos.add(d);
  void emitDuration(Duration d) => _dur.add(d);
  void emitState(PlayerState s) => _state.add(s);
  void emitComplete() => _done.add(null);

  /// 真 `AudioPlayer` 释放后再被调用的行为：`set state` 里
  /// `if (_playerState == PlayerState.disposed) throw Exception('AudioPlayer has been disposed');`
  /// （`audioplayer.dart:74-77`）。假播放器照抄 —— 这就是"释放完还在碰播放器"的探针。
  void _guard(String name) {
    calls.add(name);
    if (disposed) {
      throw StateError('AudioPlayer($playerId) has been disposed: $name');
    }
  }

  @override
  Future<void> setSource(Source source) async {
    _guard('setSource');
    sources.add(source);
  }

  @override
  Future<void> setSourceUrl(String url, {String? mimeType}) async =>
      setSource(UrlSource(url, mimeType: mimeType));

  @override
  Future<void> stop() async => _guard('stop');

  @override
  Future<void> resume() async => _guard('resume');

  @override
  Future<void> pause() async => _guard('pause');

  @override
  Future<void> setVolume(double volume) async {
    _guard('setVolume');
    volumeWrites.add(volume);
  }

  @override
  Future<void> setPlaybackRate(double playbackRate) async =>
      _guard('setPlaybackRate');

  @override
  Future<void> seek(Duration position) async => _guard('seek');

  @override
  Future<void> setReleaseMode(ReleaseMode releaseMode) async =>
      _guard('setReleaseMode');

  @override
  Future<Duration?> getCurrentPosition() async {
    _guard('getCurrentPosition');
    return Duration.zero;
  }

  /// ★ 顺序照抄 `AudioPlayer.dispose()`：**先推 `PlayerState.disposed` 那一帧**，
  /// 再关四条流。是否有人收到那一帧，就是"subs 有没有先断"的断言。
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    calls.add('dispose');
    _state.add(PlayerState.disposed); // ← 与 audioplayer.dart:502 对应
    await _pos.close();
    await _dur.close();
    await _state.close();
    await _done.close();
  }

  @override
  set positionUpdater(PositionUpdater? updater) {}

  @override
  Stream<Duration> get onPositionChanged => _pos.stream;

  @override
  Stream<Duration> get onDurationChanged => _dur.stream;

  @override
  Stream<PlayerState> get onPlayerStateChanged => _state.stream;

  @override
  Stream<void> get onPlayerComplete => _done.stream;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('假播放器没实现 ${invocation.memberName}');
}

/// 本文件建过的**全部**服务：tearDown 要等它们的落盘链走完再删临时目录。
final List<PlayerService> _live = <PlayerService>[];

PlayerService _track(PlayerService ps) {
  _live.add(ps);
  return ps;
}

Future<void> _drainPersists() async {
  for (final ps in _live) {
    await ps.debugFlushPersist();
  }
}

List<Song> _songs() => [
  for (final (i, ms) in [(0, 180000), (1, 200000), (2, 220000)])
    Song(
      id: 1000 + i,
      title: '歌$i',
      artist: '',
      durationMs: ms,
      uri: 'content://media/external/audio/media/${1000 + i}',
      filePath: '/m/$i.mp3',
    ),
];

/// 等一个条件成立（默认最多 1.5 秒）—— 比睡固定时长稳。
Future<void> _waitFor(bool Function() cond, {int ms = 1500}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_dispose_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => _docs.path,
        'getTemporaryDirectory' => _docs.path,
        _ => null,
      };
    });
    SharedPreferences.setMockInitialValues({});
    AppConfig.instance.crossfadeEnabled = false; // 每个用例都从缺省值起步
  });

  tearDown(() async {
    AppConfig.instance.crossfadeEnabled = false;
    await _drainPersists();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    await deleteTempDir(_docs);
  });

  group('★ 正向：dispose() 之后不许再收事件、不许再改状态', () {
    test('释放后播放器推来的最后一帧（PlayerState.disposed）进不来，通知也断了', () async {
      final a = _FakePlayer('fake-A');
      final ps = _track(PlayerService(player: a));
      await ps.init();
      await ps.playQueue(_songs(), 0);

      // 通知计数：释放**之前**挂上（释放后 notifier 已 dispose，挂不上了）
      var lowFreq = 0;
      var highFreq = 0;
      ps.changeNotifier.addListener(() => lowFreq++);
      ps.notifier.addListener(() => highFreq++);
      await pumpEventQueue();
      final lowBefore = lowFreq;
      final highBefore = highFreq;

      // ★ 手工置成"正在播"：这样"释放后还能收到 disposed 那一帧"会留下**可见痕迹**
      //   （_onState 会把 isPlaying 改成 false）。不置的话这条断言只剩"抛不抛"一种牙。
      ps.isPlaying = true;
      final posBefore = ps.pos;
      final durBefore = ps.dur;
      final titleBefore = ps.current!.title;

      await ps.dispose();
      expect(a.disposed, isTrue, reason: 'A 那一副必须被释放');

      // 假播放器 dispose() 里推的那一帧是**异步**送达的（broadcast controller）：
      // 等事件队列排空，让它有机会到达。
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 60));

      expect(ps.isPlaying, isTrue,
          reason: '★ 释放后播放器报什么状态都不许再改 isPlaying —— '
              '真 AudioPlayer 在 dispose() 里会推一帧 PlayerState.disposed，'
              '订阅没先断就会被 _onState 接住');
      expect(ps.pos, posBefore, reason: '释放后位置 tick 进不来');
      expect(ps.dur, durBefore, reason: '释放后时长事件进不来');
      expect(ps.current!.title, titleBefore, reason: '释放后完成事件进不来（不许再切歌）');
      expect(ps.queueList.length, 3, reason: '队列内容不该被释放动作改动');
      expect(lowFreq, lowBefore,
          reason: '★ 释放后 changeNotifier 不许再被通知（它已经 dispose 了）');
      expect(highFreq, highBefore,
          reason: '★ 释放后 notifier 不许再被通知（它已经 dispose 了）');
    });

    test('两个 Timer 都停了：A-B 守护与睡眠定时都不再跑', () async {
      final a = _FakePlayer('fake-A');
      final ps = _track(PlayerService(player: a));
      await ps.playQueue(_songs(), 0);
      ps.isPlaying = true;

      // A-B 打点：A=0 → B=5s，生效且"正在播" ⇒ _syncAbTimer 起 120ms 守护定时器
      ps.cycleAbLoop(); // 打 A（pos 此刻是 0）
      ps.pos = const Duration(seconds: 5);
      ps.cycleAbLoop(); // 打 B
      expect(ps.ab.active, isTrue, reason: '前提检查：A-B 循环要真的生效');
      ps.startSleepTimer(const Duration(minutes: 30));
      expect(ps.sleepActive, isTrue, reason: '前提检查：睡眠定时要真的开起来');

      await ps.dispose();

      // 释放前先把两颗定时器的痕迹清掉，之后只要再有调用就是"没停"
      a.calls.clear();
      await Future<void>.delayed(const Duration(milliseconds: 400)); // 120ms 定时器够跑 3 拍
      expect(
        a.calls.where((c) => c == 'getCurrentPosition'),
        isEmpty,
        reason: '★ A-B 守护定时器没被 cancel：释放后还在每 120ms 问一次播放位置',
      );
      expect(a.calls.where((c) => c == 'setVolume' || c == 'pause'), isEmpty,
          reason: '★ 睡眠定时器没被 cancel：释放后到点还会去做淡出+暂停');
    });

    test('两副牌都释放：交叉淡变开关打开、B 已经懒建出来时，A 和 B 都要 dispose', () async {
      AppConfig.instance.crossfadeEnabled = true;
      final a = _FakePlayer('fake-A');
      final b = _FakePlayer('fake-B');
      final ps = _track(PlayerService(player: a, playerFactory: () => b));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      // 逼 B 出场：曲末窗口里那一拍会 _ensureDeckB()（预取）
      a.emitPos(const Duration(milliseconds: 179300));
      await _waitFor(() => b.sources.isNotEmpty, ms: 3000);
      expect(b.sources, isNotEmpty, reason: '前提检查：B 那一副要真的被懒建出来');

      await ps.dispose();
      expect(a.disposed, isTrue, reason: 'A 必须被释放');
      expect(b.disposed, isTrue,
          reason: '★ B（懒建的第二副）必须被释放 —— 它是 _playerFactory() 造出来的，'
              '除了 dispose() 没有任何人持有它');
    });

    test('幂等：连调两次不炸、播放器只被 dispose 一次', () async {
      final a = _FakePlayer('fake-A');
      final ps = _track(PlayerService(player: a));
      await ps.playQueue(_songs(), 0);

      await ps.dispose();
      await ps.dispose(); // 第二次必须直接返回
      expect(a.calls.where((c) => c == 'dispose').length, 1,
          reason: '第二次 dispose() 不许再放一遍播放器');
    });
  });

  group('★ 交叉淡变正跑着被 dispose（要把这条路说清）', () {
    test('两条曲线让位，谁都不再去碰已经释放的播放器', () async {
      AppConfig.instance.crossfadeEnabled = true;
      final a = _FakePlayer('fake-A');
      final b = _FakePlayer('fake-B');
      final ps = _track(PlayerService(player: a, playerFactory: () => b));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      // 等第一首的淡入跑完（末项精确 1.0），再从曲末窗口推两拍：先预热、再换场
      await _waitFor(
        () => a.volumeWrites.isNotEmpty && a.volumeWrites.last == 1.0,
        ms: 3000,
      );
      a.emitPos(const Duration(milliseconds: 179300));
      await _waitFor(() => b.sources.isNotEmpty, ms: 3000);
      a.emitPos(const Duration(milliseconds: 179800));

      // 前提：此刻交叉淡变**真的在跑**（上场那一副已出声、退场那一副已不在满音量）
      await _waitFor(
        () => b.calls.contains('resume') && a.volumeWrites.last < 0.95,
        ms: 3000,
      );
      expect(b.calls, contains('resume'), reason: '前提检查：上场那一副要真的出声了');
      expect(a.volumeWrites.last, lessThan(0.95),
          reason: '前提检查：淡变进行中，退场那一副的音量应低于 0.95');

      await ps.dispose(); // ★ 淡变还没跑完就释放
      expect(a.disposed, isTrue);
      expect(b.disposed, isTrue);

      final aVol = a.volumeWrites.length;
      final bVol = b.volumeWrites.length;
      final aCalls = a.calls.length;
      final bCalls = b.calls.length;
      // 淡变全长 300ms：等得比它长，让"不肯让位的那条曲线"有充分机会继续写
      await Future<void>.delayed(const Duration(milliseconds: 600));

      expect(a.volumeWrites.length, aVol,
          reason: '★ 释放后还有人往 A 写音量 —— 曲线没让位（_fadeToken 没自增）');
      expect(b.volumeWrites.length, bVol,
          reason: '★ 释放后还有人往 B 写音量 —— 曲线没让位（_fadeToken 没自增）');
      expect(a.calls.length, aCalls,
          reason: '★ 释放后还有人调 A（真播放器这时会抛 "has been disposed"）');
      expect(b.calls.length, bCalls,
          reason: '★ 释放后还有人调 B（真播放器这时会抛 "has been disposed"）');
    });
  });
}
