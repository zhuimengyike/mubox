/// `PlayerService.dispose()` **第二刀**的断言：非音量路径的 `_disposed` 闸门。
///
/// 第一刀（订阅 / 定时器 / 通知器 / 两副播放器 + `_setVolumeOn` 开头那道闸门）的断言在
/// `test/player_service_dispose_test.dart`（5 项）。这里只回答它答不了的那一问：
///
/// ★ **已经起步、正卡在 `await` 里的那几条异步路径，醒来时还碰不碰已经释放的播放器？**
///
/// | 路径 | 卡在哪 | 不设防会怎样（真播放器） |
/// |---|---|---|
/// | 睡眠定时到点 / 暂停 → `_fadeOutThenPause()` | `_fadeOn` 里那一步 `setVolume` | 淡变让位之后仍走 `d.player.pause()`：`pause()` 里那句 `state = PlayerState.paused`（`audioplayer.dart:246` → `:74-77`）**必抛** `Exception('AudioPlayer has been disposed')` |
/// | A-B 守护（120ms）→ `_checkAbWrap()` | `await getCurrentPosition()` | 醒来时 `_ab.active && isPlaying` 仍然成立 ⇒ 直接 `seek()` 到死播放器上 |
/// | 交叉淡变被打断 → `_abortCrossfade()` | `await inn.player.pause()` | `keepIncoming` 那条路接着 `await out.player.stop()` ⇒ 打到死播放器上 |
/// | 交叉淡变收尾 → `_crossfadeTo()` 循环外 | `seek` / `resume` / 收尾那三件 | 翻牌 + 换 effect + 停退场那一副，全是"对着死播放器"的动作 |
/// | 各公开入口 | — | `playAt`/`toggle`/`seek`/`setSpeed`/`stop`/`resetForRestore` 会 `setSource`/`resume`/`stop` 一副死牌 |
///
/// ⚠️ 用的是**真 `PlayerService` + 假播放器**（与 `player_service_dispose_test.dart`、
/// `player_service_crossfade_test.dart` 同一套路），不是"把逻辑抄一份到测试里"。
/// 假播放器照抄真播放器的两件事：① 释放后再用**会抛**；② **先记调用、后抛** ——
/// 所以"释放后还被碰了一下"一定留痕，不依赖那个异常有没有被谁吞掉。
///
/// ⚠️ 四个用例都用**闸门**（`holdNextVolume` / `holdNextPause` / 位置闸门）把异步路径
/// **停在 `await` 里**再 dispose，不靠 sleep 碰运气 —— 这正是「dispose 正好落在中间」
/// 那个窄窗口唯一可复现的造法。
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

/// 假播放器：四条流由测试推动；**并且照抄真播放器"释放后不可用"**（`audioplayer.dart:74-77`
/// 的 `if (_playerState == PlayerState.disposed) throw`）。
class _FakePlayer implements AudioPlayer {
  _FakePlayer(this.playerId);

  @override
  final String playerId;

  /// 已经释放（释放后再被调用会抛，见 [_guard]）。
  bool disposed = false;

  /// 按顺序的调用日志（**先记后抛** ⇒ "释放后还被碰了一下"既有痕迹、也会当场响）。
  final List<String> calls = [];

  final List<Source> sources = [];
  final List<double> volumeWrites = [];

  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _state = StreamController<PlayerState>.broadcast();
  final _done = StreamController<void>.broadcast();

  void emitPos(Duration d) => _pos.add(d);

  // ---- 闸门：把某条异步路径停在 await 里，好让 dispose 正好落在中间 ----------------

  /// 非 null 时：**下一条** `setVolume` 卡在这上面，直到 [releaseVolume]。
  Completer<void>? holdNextVolume;

  /// 非 null 时：**下一条** `pause` 卡在这上面，直到 [releasePause]。
  Completer<void>? holdNextPause;

  /// 非 null 时：**第一条音量正好等于该值**的 `setVolume` 卡在这上面，直到
  /// [releaseVolume]。交叉淡变里用它把路径停在"上场那一副的最后一拍"（末项恒为 1.0）。
  double? holdVolumeAtValue;

  /// 非 null 时：**每一条** `getCurrentPosition` 都卡在这上面，直到 [releasePosition]
  /// （守护定时器 120ms 一拍，用"只卡第一条"会漏掉后面几拍）。
  Completer<void>? positionGate;

  Completer<void>? _heldVolume;
  Completer<void>? _heldPause;
  int _positionWaiting = 0;

  bool get volumeHeld => _heldVolume != null;
  bool get pauseHeld => _heldPause != null;
  bool get positionHeld => _positionWaiting > 0;

  /// 卡住的那条 `getCurrentPosition` 醒来时该返回的位置。
  Duration positionValue = Duration.zero;

  void releaseVolume() {
    final h = _heldVolume;
    _heldVolume = null;
    h?.complete();
  }

  void releasePause() {
    final h = _heldPause;
    _heldPause = null;
    h?.complete();
  }

  void releasePosition() {
    final g = positionGate;
    positionGate = null;
    g?.complete();
  }

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
  Future<void> stop() async => _guard('stop');

  @override
  Future<void> resume() async => _guard('resume');

  @override
  Future<void> pause() async {
    _guard('pause');
    final h = holdNextPause;
    if (h != null) {
      holdNextPause = null;
      _heldPause = h;
      await h.future;
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    _guard('setVolume');
    volumeWrites.add(volume);
    final atValue = holdVolumeAtValue;
    if (atValue != null && volume == atValue && _heldVolume == null) {
      holdVolumeAtValue = null;
      final h = _heldVolume = Completer<void>();
      await h.future;
      return;
    }
    final h = holdNextVolume;
    if (h != null) {
      holdNextVolume = null;
      _heldVolume = h;
      await h.future;
    }
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
    final g = positionGate;
    if (g != null) {
      _positionWaiting++;
      await g.future;
      _positionWaiting--;
    }
    return positionValue;
  }

  /// 顺序照抄 `AudioPlayer.dispose()`：先推 `PlayerState.disposed` 那一帧，再关四条流。
  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    calls.add('dispose');
    _state.add(PlayerState.disposed);
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

/// 本文件建过的全部服务：tearDown 要等它们的落盘链走完再删临时目录。
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
      uri: 'content://media/external/media/${1000 + i}',
      filePath: '/m/$i.mp3',
    ),
];

/// 等一个条件成立（默认最多 3 秒）—— 比睡固定时长稳。
Future<void> _waitFor(bool Function() cond, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_pdispose_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => _docs.path,
        'getTemporaryDirectory' => _docs.path,
        _ => null,
      };
    });
    SharedPreferences.setMockInitialValues({});
    AppConfig.instance.crossfadeEnabled = false;
    AppConfig.instance.volumeFadeEnabled = true; // 淡出那条路的断言靠它
  });

  tearDown(() async {
    AppConfig.instance.crossfadeEnabled = false;
    AppConfig.instance.volumeFadeEnabled = true;
    await _drainPersists();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    await deleteTempDir(_docs);
  });

  group('★ 卡在 await 里的异步路径，醒来时不许再碰已经释放的播放器', () {
    test('淡出正卡在 setVolume 里被 dispose：醒来后不许再 pause 死播放器', () async {
      final a = _FakePlayer('fake-A');
      final ps = _track(PlayerService(player: a));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      ps.isPlaying = true;
      a.volumeWrites.clear();

      // 与「睡眠定时到点」同一条路：pause() → _fadeOutThenPause() → _fadeOn()
      a.holdNextVolume = Completer<void>();
      unawaited(ps.pause());
      await _waitFor(() => a.volumeHeld);
      expect(a.volumeHeld, isTrue, reason: '前提检查：淡出必须真的卡在 setVolume 的 await 里');

      await ps.dispose();
      final after = a.calls.length;

      a.releaseVolume(); // 曲线醒来：它会发现自己该让位了，然后……
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        a.calls.skip(after),
        isEmpty,
        reason:
            '★ 释放后还有调用落到 A 上（${a.calls.skip(after).toList()}）—— '
            '淡出那条路没被闸门挡住；真播放器这时会抛 '
            'Exception("AudioPlayer has been disposed")',
      );
    });

    test('A-B 守护正卡在 getCurrentPosition 里被 dispose：醒来后不许再绕回 seek', () async {
      final a = _FakePlayer('fake-A');
      final ps = _track(PlayerService(player: a));
      await ps.playQueue(_songs(), 0);
      ps.isPlaying = true;
      ps.cycleAbLoop(); // 打 A 点（pos 此刻是 0）
      ps.pos = const Duration(seconds: 5);
      ps.cycleAbLoop(); // 打 B 点（5s）⇒ 生效 + 在播 ⇒ 120ms 守护定时器起来
      expect(ps.ab.active, isTrue, reason: '前提检查：A-B 循环要真的生效');

      a.positionValue = const Duration(seconds: 9); // 已越过 B ⇒ 醒来就该绕回 A
      a.positionGate = Completer<void>();
      await _waitFor(() => a.positionHeld);
      expect(a.positionHeld, isTrue, reason: '前提检查：守护定时器要真的打进来并卡住');

      await ps.dispose();
      final after = a.calls.length;
      final posBefore = ps.pos;

      a.releasePosition();
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(
        a.calls.skip(after),
        isEmpty,
        reason: '★ 释放后还有人碰 A（${a.calls.skip(after).toList()}）—— A-B 绕回没被挡住',
      );
      expect(ps.pos, posBefore, reason: '★ 释放后 A-B 绕回还在改 pos');
    });

    test('公开入口在 dispose 之后一律空转：不再 setSource / resume / stop 一副死牌', () async {
      final a = _FakePlayer('fake-A');
      final ps = _track(PlayerService(player: a));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      await ps.dispose();

      a.calls.clear();
      ps.isPlaying = true; // 装作还在播：入口没挡住的话，这一串会留下明显痕迹
      await ps.playAt(1);
      await ps.next();
      await ps.toggle();
      await ps.seek(const Duration(seconds: 3));
      await ps.setSpeed(1.5);
      await ps.stop();
      await ps.resetForRestore();
      await ps.pause();
      await pumpEventQueue();

      expect(
        a.calls,
        isEmpty,
        reason: '★ 释放后这些入口还有调用落到 A 上：${a.calls}',
      );
    });

    test('交叉淡变被打断正卡在 pause 里被 dispose：醒来后不许再停退场那一副', () async {
      AppConfig.instance.crossfadeEnabled = true;
      final a = _FakePlayer('fake-A');
      final b = _FakePlayer('fake-B');
      final ps = _track(PlayerService(player: a, playerFactory: () => b));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      // 等第一首的淡入跑完（末项精确 1.0），再从曲末窗口推两拍：先预热、再换场
      await _waitFor(
        () => a.volumeWrites.isNotEmpty && a.volumeWrites.last == 1.0,
      );

      a.emitPos(const Duration(milliseconds: 179300));
      await _waitFor(() => b.sources.isNotEmpty);
      expect(b.sources, isNotEmpty, reason: '前提检查：B 要真的被预热出来');

      // 把换场卡在"写退场那一副音量"的那一拍 ⇒ _crossfading 恒为 true
      a.holdNextVolume = Completer<void>();
      a.emitPos(const Duration(milliseconds: 179800));
      await _waitFor(() => a.volumeHeld);
      expect(a.volumeHeld, isTrue, reason: '前提检查：交叉淡变必须真的在跑并被卡住');
      expect(b.calls, contains('resume'), reason: '前提检查：上场那一副要真的出声了');

      // 再把"作废交叉淡变"卡在 inn.player.pause() 里
      ps.isPlaying = true;
      b.holdNextPause = Completer<void>();
      unawaited(ps.pause()); // → _fadeOutThenPause → _abortCrossfade(keepIncoming: true)
      await _waitFor(() => b.pauseHeld);
      expect(b.pauseHeld, isTrue,
          reason: '前提检查：_abortCrossfade 要真的卡在 inn.player.pause() 里');

      await ps.dispose();
      final aAfter = a.calls.length;
      final bAfter = b.calls.length;

      a.releaseVolume();
      b.releasePause();
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        a.calls.skip(aAfter),
        isEmpty,
        reason: '★ 释放后还有人碰 A（${a.calls.skip(aAfter).toList()}）—— '
            'out.player.stop() 那条没被挡住',
      );
      expect(
        b.calls.skip(bAfter),
        isEmpty,
        reason: '★ 释放后还有人碰 B（${b.calls.skip(bAfter).toList()}）',
      );
    });

    test('交叉淡变收尾正卡在最后一拍音量上被 dispose：不许翻牌、不许停退场那一副', () async {
      AppConfig.instance.crossfadeEnabled = true;
      final a = _FakePlayer('fake-A');
      final b = _FakePlayer('fake-B');
      final ps = _track(PlayerService(player: a, playerFactory: () => b));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      await _waitFor(
        () => a.volumeWrites.isNotEmpty && a.volumeWrites.last == 1.0,
      );

      a.emitPos(const Duration(milliseconds: 179300));
      await _waitFor(() => b.sources.isNotEmpty);
      expect(b.sources, isNotEmpty, reason: '前提检查：B 要真的被预热出来');

      // 上场那一副的曲线**末项恒为 1.0** ⇒ 卡住那一拍 = 停在"循环之后那三件事"之前
      b.holdVolumeAtValue = 1.0;
      a.emitPos(const Duration(milliseconds: 179800));
      await _waitFor(() => b.volumeHeld);
      expect(b.volumeHeld, isTrue, reason: '前提检查：换场要真的跑到收尾那一拍');
      expect(a.volumeWrites.last, lessThan(1.0),
          reason: '前提检查：退场那一副此刻还没到终点（说明淡变真的在跑）');

      await ps.dispose();
      final aAfter = a.calls.length;
      final bAfter = b.calls.length;

      b.releaseVolume(); // 循环走完 ⇒ 紧接着就是"翻牌 + 通知 + 停掉退场那一副"
      await Future<void>.delayed(const Duration(milliseconds: 400));

      expect(
        a.calls.skip(aAfter),
        isEmpty,
        reason: '★ 释放后还有人碰 A（${a.calls.skip(aAfter).toList()}）—— '
            '收尾那句 out.player.stop() 没被挡住',
      );
      expect(
        b.calls.skip(bAfter),
        isEmpty,
        reason: '★ 释放后还有人碰 B（${b.calls.skip(bAfter).toList()}）',
      );
    });
  });
}
