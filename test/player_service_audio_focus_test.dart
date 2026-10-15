/// 原生播放错误 ⇒ UI 说真话 —— 断言（漏洞 1 的 **Dart 那一半**）。
///
/// 背景（真机故障）：系统拒绝音频焦点时，`audioplayers` 的原生侧改造前**什么都不做**
/// ⇒ `MediaPlayer` 从未 `start()`，而 `AudioPlayer._resume()` 在 `_platform.resume()`
/// 返回后**无条件**把状态置成 `PlayerState.playing`（`audioplayer.dart:272-279`）
/// ⇒ **App 显示在播、却一声不响**。
///
/// 原生侧现在会（`third_party/audioplayers_android/.../FocusManager.kt` 的有界重试用尽分支）
/// `playing = false` + 发一个 `AudioFocusDenied` 的 EventChannel 错误。这个文件钉住
/// **Dart 侧有没有把这条错误接回来**：
///
/// 1. **正向**：当前那一副收到 `AudioFocusDenied` ⇒ ①`lastError` 有值（播放栏据此弹 SnackBar）
///    ②`isPlaying` 与 `playbackState.playing` **必须变成 false**（UI 不许继续骗人）
///    ③顺手把播放器转 paused（原生已是暂停，这一发是空操作）；
/// 2. **只有一条路会报错**：同一次原生错误只到**两条**派生流
///    （`_create()` 里 `onError: _eventStreamController.addError` 打进的是 `eventStream`，
///    派生它的只有 `onDurationChanged` / `onPlayerComplete`）
///    ⇒ `lastError` 只许被写**一次**（否则会连弹两条 SnackBar）；
/// 3. **负向（身份守卫）**：错误来自**不在场**的那一副（预热/已退场）⇒ 不许改 UI、不许弹窗；
/// 4. **负向（错误码过滤）**：别的原生错误码不许抢 `lastError`（保持改动前的行为）。
///
/// ⚠️ 用的是**真 `PlayerService`** + 假播放器（与 `player_service_test.dart` /
/// `player_service_dispose_test.dart` 同一套路），不是"把逻辑抄一份到测试里"。
/// `testWidgets` = 0。
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

/// 假播放器：四条流由测试推动；`noSuchMethod` 故意抛 —— 服务里多调一个原生成员会当场响。
class _FakePlayer implements AudioPlayer {
  _FakePlayer(this.playerId);

  @override
  final String playerId;

  final List<String> calls = [];
  final List<Source> sources = [];

  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _state = StreamController<PlayerState>.broadcast();
  final _done = StreamController<void>.broadcast();

  void emitPos(Duration d) => _pos.add(d);
  void emitState(PlayerState s) => _state.add(s);

  /// 照**真**播放器的样子推一次原生错误。
  ///
  /// ★★ 保真度锚点（真机打回来才搞清，别再改回去）★★
  ///
  /// 真插件把错误送到哪：`AudioplayersPlugin.handleError(...)` 第 245-247 行调
  /// `player.eventHandler.error(errorCode, …)`；`EventHandler.error` 是同文件第 **297-299** 行
  /// 的 `eventSink?.error(errorCode, errorMessage, errorDetails)` —— 走的是
  /// **EventChannel 的 error**，不是方法调用 Future、也不是四条各自独立的 controller。
  /// Dart 侧接住它的是 `audioplayers` 的 `AudioPlayer._create()`
  /// （`audioplayer.dart:181-184` 的 `onError: _eventStreamController.addError`），
  /// 而 `_eventStreamController`（`audioplayer.dart:97`）**只喂 `eventStream` 这一条广播流**。
  ///   - `onDurationChanged`（`audioplayer.dart:121-123`）= `eventStream.where(...)` ⇒ **收得到**
  ///   - `onPlayerComplete`  （`audioplayer.dart:131-132`）= `eventStream.where(...)` ⇒ **收得到**
  ///   - `onPlayerStateChanged`（`audioplayer.dart:102-106`）= **另一个** controller，
  ///     `set state`（`:74-82`）只 `add` 值、**从不 `addError`** ⇒ **永远收不到**
  ///   - `onPositionChanged`（`audioplayer.dart:114-115`）= `TimerPositionUpdater.positionStream` ⇒ 收不到
  ///
  /// ⚠️ **早期版本这一函数往四条流都 `addError` —— 那是假夹具，给了假信心**（踩过这个坑）：
  /// 它让"挂在状态流上的报告点"看起来能跑通，而真机上那条路一次都不跑
  /// （9 份 logcat 里探针 `MuBox 原生播放错误：` 出现 **0** 次）。
  /// 所以这里**只推真插件真会推的那两条**；多推一条 = 把负向断言的牙拔掉。
  void emitNativeError(Object e) {
    _dur.addError(e);
    _done.addError(e);
  }

  @override
  Future<void> setSource(Source source) async {
    sources.add(source);
    calls.add('setSource');
  }

  @override
  Future<void> setSourceUrl(String url, {String? mimeType}) async =>
      setSource(UrlSource(url, mimeType: mimeType));

  @override
  Future<void> stop() async => calls.add('stop');

  @override
  Future<void> resume() async => calls.add('resume');

  @override
  Future<void> pause() async => calls.add('pause');

  @override
  Future<void> setVolume(double volume) async => calls.add('setVolume');

  @override
  Future<void> setPlaybackRate(double playbackRate) async =>
      calls.add('setPlaybackRate');

  @override
  Future<void> seek(Duration position) async => calls.add('seek');

  @override
  Future<void> setReleaseMode(ReleaseMode releaseMode) async =>
      calls.add('setReleaseMode');

  @override
  Future<Duration?> getCurrentPosition() async => Duration.zero;

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

/// 等一个条件成立（默认最多 3 秒）—— 比睡固定时长稳。
Future<void> _waitFor(bool Function() cond, {int ms = 3000}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// 原生那边用的错误码（`FocusManager.kt` 的 `handleError("AudioFocusDenied", …)`）。
PlatformException _focusDenied() => PlatformException(
  code: 'AudioFocusDenied',
  message: '系统拒绝了音频焦点（可能被其他应用占用或被系统策略限制），已停止播放',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_focus_');
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

  group('★ 正向：焦点被拒 ⇒ UI 必须说真话（lastError 有值 + 状态转暂停）', () {
    test('当前那一副收到 AudioFocusDenied ⇒ lastError 有值、isPlaying/playbackState 都变 false、'
        '并且把播放器转 paused', () async {
      final a = _FakePlayer('fake-A');
      final ps = _track(PlayerService(player: a));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      a.emitState(PlayerState.playing); // 原生 resume 之后 App 以为在播
      await pumpEventQueue();
      expect(ps.isPlaying, isTrue, reason: '前提检查：先要处于"App 认为在播"的状态');
      expect(ps.lastError.value, isNull, reason: '前提检查：此刻没有错误');

      // ★★ 核心：错误只从 `eventStream` 的两条派生流来（`_dur` / `_done`）。
      //    报告点若还挂在 `onPlayerStateChanged` 上，下面这一发**一次都不会被处理**
      //    ⇒ `lastError` 保持 null、`isPlaying` 保持 true = 真机症状逐字复现。
      a.emitNativeError(_focusDenied());
      await pumpEventQueue();

      expect(ps.lastError.value, isNotNull,
          reason: '★ 原生说"焦点被拒、已停止" ⇒ 必须让播放栏有东西可弹（否则用户只看到"在播却没声"）');
      expect(ps.lastError.value, contains('音频焦点'),
          reason: '★ 文案要说到点子上（是"拿不到音频焦点"，不是"文件损坏"）');
      expect(ps.isPlaying, isFalse,
          reason: '★ UI 状态必须转暂停 —— 这是「App 还在骗人」那一半的判据');
      expect(ps.playbackState.value.playing, isFalse,
          reason: '★ 通知栏/锁屏的 playing 也必须跟着转 false');
      expect(a.calls, contains('pause'),
          reason: '★ 顺手把播放器转 paused（也停掉 500ms 位置轮询）；原生已是暂停，这一发是空操作');
    });

    test('同一次原生错误（dur + complete 各一份）只许写一次 lastError —— 否则会连弹两条 SnackBar', () async {
      final a = _FakePlayer('fake-A');
      final ps = _track(PlayerService(player: a));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      a.emitState(PlayerState.playing);
      await pumpEventQueue();

      var writes = 0;
      ps.lastError.addListener(() => writes++);

      a.emitNativeError(_focusDenied()); // `_dur` 与 `_done` 各收到这一份错误
      await pumpEventQueue();

      expect(writes, 1, reason: '★ 两条派生流各收到一份，但只允许"时长流"那一条去报错（另一条只接住）');
      expect(ps.isPlaying, isFalse, reason: '状态仍要转暂停');
    });
  });

  group('★ 负向：不该报的别报（守卫有牙）', () {
    test('错误来自**不在场**的那一副（预热/已退场）⇒ 不许改 UI、不许弹窗；'
        '同一个错误打到在场那一副时必须有效（证明上一条不是恒真）', () async {
      AppConfig.instance.crossfadeEnabled = true;
      final a = _FakePlayer('fake-A');
      final b = _FakePlayer('fake-B');
      final ps = _track(PlayerService(player: a, playerFactory: () => b));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      a.emitState(PlayerState.playing);
      await pumpEventQueue();
      // 逼 B（空闲那一副）出场：曲末窗口那一拍会 _ensureDeckB()
      a.emitPos(const Duration(milliseconds: 179300));
      await _waitFor(() => b.sources.isNotEmpty);
      expect(b.sources, isNotEmpty, reason: '前提检查：B 那一副要真的被懒建出来');
      expect(ps.isPlaying, isTrue, reason: '前提检查：此刻在场的是 A、且在播');

      // ① 不在场的那一副报错 ⇒ 静默
      b.emitNativeError(_focusDenied());
      await pumpEventQueue();
      expect(ps.lastError.value, isNull,
          reason: '★ 预热那一副的错误不许弹到用户脸上');
      expect(ps.isPlaying, isTrue,
          reason: '★ 也不许改在场那一副的状态');

      // ② 同一个错误打到在场那一副 ⇒ 必须有效
      a.emitNativeError(_focusDenied());
      await pumpEventQueue();
      expect(ps.lastError.value, isNotNull,
          reason: '★ 证明第 ① 条不是恒真：同一种错误、同一个错误对象，打到在场那一副就必须报');
      expect(ps.isPlaying, isFalse, reason: '★ 状态转暂停');
    });

    test('别的原生错误码不许抢 lastError（保持改动前的行为）', () async {
      final a = _FakePlayer('fake-A');
      final ps = _track(PlayerService(player: a));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      a.emitState(PlayerState.playing);
      await pumpEventQueue();

      a.emitNativeError(PlatformException(
        code: 'AndroidAudioError',
        message: 'MEDIA_ERROR_UNKNOWN {what:1}',
      ));
      await pumpEventQueue();

      expect(ps.lastError.value, isNull,
          reason: '★ 只有 AudioFocusDenied 走这套文案；别的原生错误维持原样');
      expect(ps.isPlaying, isTrue,
          reason: '★ 别的错误不该顺手把播放状态改掉');
    });
  });
}
