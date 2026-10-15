/// ★★ **保真度锚点**：原生播放错误在 `audioplayers` 里到底能走到哪几条派生流 ★★
///
/// 本文件的存在理由只有一个 —— **钉死那条真实通路，免得下一个人又照着想象接线**。
///
/// ## 真机事实
///
/// `appops set com.mubox.mu_box_phone TAKE_AUDIO_FOCUS deny` ⇒ 点播放，实测：
/// `media_session=PLAYING` 而 `media.audio_flinger=[0,0,0]`、位置冻住 14.7 秒、
/// 两张截图逐像素同一个时间戳、**没有 SnackBar、UI 不转暂停**。
/// 9 份 logcat 里 `PlayerService._onNativeError` 的探针 `MuBox 原生播放错误：` 出现 **0 次**。
///
/// ## 真实通路（一句话）
///
/// 原生把错误 `EventSink.error(...)` 打进 **EventChannel 的 error**
/// （`third_party/audioplayers_android/.../AudioplayersPlugin.kt:245-247` 的 `handleError`
/// ⇒ 同文件 `:297-299` 的 `eventSink?.error`），
/// Dart 侧由 `AudioPlayer._create()` 的 `onError: _eventStreamController.addError` 接住
/// （`audioplayer.dart:181-184`），落进 `_eventStreamController`（`:97`）——
/// **而它只喂 `eventStream` 这一条广播流**。于是四条派生流里只有两条收得到：
///
/// | 派生流 | 底层 | 收得到原生 error？ |
/// |---|---|---|
/// | `onDurationChanged` | `eventStream.where(...)`（`audioplayer.dart:121-123`） | ✅ |
/// | `onPlayerComplete` | `eventStream.where(...)`（`:131-132`） | ✅ |
/// | `onPlayerStateChanged` | 另一个 controller `_playerStateController`（`:102-106`），`set state` 只 `add` **值**、从不 `addError`（`:74-82`） | ❌ **永远收不到** |
/// | `onPositionChanged` | `TimerPositionUpdater.positionStream`（`:114-115`） | ❌ |
///
/// ⇒ **报告点挂在 `onPlayerStateChanged` 上 = 一次都不跑**（早先就是这么接的）。
///
/// ## 为什么这条断言必须用**真** `AudioPlayer`
///
/// 假播放器（`player_service_audio_focus_test.dart` 的 `_FakePlayer`）可以"往四条流都推错误"，
/// 那样测出来的是**测试作者以为的路由**，不是插件的路由 —— 假夹具给过假信心。
/// 这里用**真 `AudioPlayer`** + 只替换方法/事件通道的假平台：路由是插件自己的代码算的，
/// 谁改 `audioplayers` 的接线、或谁把报告点挂错流，本文件立刻红。
library;

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:audioplayers_platform_interface/audioplayers_platform_interface.dart';
import 'package:audioplayers_platform_interface/src/audioplayers_platform.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
const _globalChannel = MethodChannel('xyz.luan/audioplayers.global');

late Directory _docs;
final List<PlayerService> _live = <PlayerService>[];

/// 假平台：成员一个不少（继承真 `AudioplayersPlatform`），只把
/// 「方法通道」换成记账、「事件通道」换成测试自己的 controller。
/// 事件通道的语义与真机一致 —— **`addError` 只会到插件真会送到的那几条派生流**。
class _FakePlatform extends AudioplayersPlatform {
  final Map<String, StreamController<AudioEvent>> _events = {};
  final List<String> calls = [];

  StreamController<AudioEvent> ctrl(String id) =>
      _events.putIfAbsent(id, () => StreamController<AudioEvent>.broadcast());

  /// 照原生的样子推一次错误：**只进事件通道**，不进任何派生 controller。
  void emitNativeError(String playerId, Object error) => ctrl(playerId).addError(error);

  /// 照原生 `setSourceUrl` 成功的样子回一次 `audio.onPrepared` + `audio.onDuration`
  /// （`AudioplayersPlugin.kt:223-239` 那几个 `eventHandler.success(...)`）。
  /// 真 `AudioPlayer` 收到这两个事件后才会把状态机推到 playing
  /// （`_onPrepared` 完成后 `state = PlayerState.playing`，`audioplayer.dart`），
  /// 于是 `PlayerService._onState` 才会把 `isPlaying` 置真。
  void _emitPrepared(String playerId) {
    final c = ctrl(playerId);
    c.add(const AudioEvent(eventType: AudioEventType.prepared, isPrepared: true));
    c.add(const AudioEvent(
      eventType: AudioEventType.duration,
      duration: Duration(milliseconds: 180000),
    ));
  }

  @override
  Future<void> create(String playerId) async => calls.add('create');

  @override
  Future<void> dispose(String playerId) async => calls.add('dispose');

  @override
  Stream<AudioEvent> getEventStream(String playerId) => ctrl(playerId).stream;

  @override
  Future<void> setSourceUrl(String playerId, String url, {bool? isLocal, String? mimeType}) async {
    calls.add('setSourceUrl');
    _emitPrepared(playerId);
  }

  @override
  Future<void> resume(String playerId) async => calls.add('resume');

  @override
  Future<void> pause(String playerId) async => calls.add('pause');

  @override
  Future<void> stop(String playerId) async => calls.add('stop');

  @override
  Future<void> release(String playerId) async => calls.add('release');

  @override
  Future<void> seek(String playerId, Duration position) async => calls.add('seek');

  @override
  Future<void> setVolume(String playerId, double volume) async => calls.add('setVolume');

  @override
  Future<void> setBalance(String playerId, double balance) async => calls.add('setBalance');

  @override
  Future<void> setPlaybackRate(String playerId, double playbackRate) async =>
      calls.add('setPlaybackRate');

  @override
  Future<void> setReleaseMode(String playerId, ReleaseMode releaseMode) async =>
      calls.add('setReleaseMode');

  @override
  Future<void> setPlayerMode(String playerId, PlayerMode playerMode) async =>
      calls.add('setPlayerMode');

  @override
  Future<void> setAudioContext(String playerId, AudioContext audioContext) async =>
      calls.add('setAudioContext');

  @override
  Future<int?> getDuration(String playerId) async => 180000;

  @override
  Future<int?> getCurrentPosition(String playerId) async => 0;
}

/// 驱动真 `AudioPlayer` 的错码：与 `WrappedPlayer.kt` 的
/// `handleError("AudioFocusDenied", …)`（`:150-154`）逐字一致。
Object _focusDenied() => PlatformException(
      code: 'AudioFocusDenied',
      message: '系统拒绝了音频焦点（可能被其他应用占用或被系统策略限制），已停止播放',
    );

List<Song> _songs() => [
  for (final (i, ms) in [(0, 180000)])
    Song(
      id: 1000 + i,
      title: '歌$i',
      artist: '',
      durationMs: ms,
      uri: 'content://media/external/audio/media/${1000 + i}',
      filePath: '/m/$i.mp3',
    ),
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakePlatform platform;
  late AudioplayersPlatformInterface savedPlatform;

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_routing_');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, (call) async {
      return switch (call.method) {
        'getApplicationDocumentsDirectory' => _docs.path,
        'getTemporaryDirectory' => _docs.path,
        _ => null,
      };
    });
    // global.ensureInitialized() 走独立方法通道（`AudioPlayer._create()` 第一步）。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_globalChannel, (call) async => 1);
    SharedPreferences.setMockInitialValues({});
    AppConfig.instance.crossfadeEnabled = false;
    savedPlatform = AudioplayersPlatformInterface.instance;
    platform = _FakePlatform();
    AudioplayersPlatformInterface.instance = platform;
  });

  tearDown(() async {
    AudioplayersPlatformInterface.instance = savedPlatform;
    AppConfig.instance.crossfadeEnabled = false;
    for (final ps in _live) {
      await ps.debugFlushPersist();
    }
    _live.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_globalChannel, null);
    await deleteTempDir(_docs);
  });

  group('★★ 保真度锚点：原生 error 只到 eventStream 的两条派生流', () {
    test('一条 EventChannel error ⇒ onDurationChanged / onPlayerComplete 收到；'
        'onPlayerStateChanged / onPositionChanged **一次都收不到**', () async {
      final p = AudioPlayer(playerId: 'pin-1');
      addTearDown(p.dispose);
      final hits = <String>[];
      p.onPositionChanged.listen((_) {}, onError: (Object _) => hits.add('pos'));
      p.onDurationChanged.listen((_) {}, onError: (Object _) => hits.add('dur'));
      p.onPlayerStateChanged.listen((_) {}, onError: (Object _) => hits.add('state'));
      p.onPlayerComplete.listen((_) {}, onError: (Object _) => hits.add('done'));
      await pumpEventQueue();

      platform.emitNativeError('pin-1', _focusDenied());
      await pumpEventQueue();

      // ★ 这条断言就是上一轮假夹具掩盖掉的事实：状态流**收不到**原生错误。
      expect(hits, isNot(contains('state')),
          reason: '★★ `onPlayerStateChanged` 是另一个 controller，`set state` 只 add 值、从不 addError '
              '（audioplayer.dart:74-82 / 102-106）⇒ 报告点挂在这条上 = 一次都不跑（真机 0 次探针）。'
              '这一条若变红 = audioplayers 改了内部接线，Dart 侧报告点要重新核对。');
      expect(hits, isNot(contains('pos')),
          reason: '`onPositionChanged` 来自 TimerPositionUpdater，同样与 eventStream 无关');
      expect(hits, contains('dur'),
          reason: '`onDurationChanged` = eventStream.where(...)（audioplayer.dart:121-123）⇒ 必须收到');
      expect(hits, contains('done'),
          reason: '`onPlayerComplete` = eventStream.where(...)（audioplayer.dart:131-132）⇒ 必须收到');
    });

    test('★ 端到端：真 AudioPlayer + 真 PlayerService，原生 AudioFocusDenied ⇒ '
        'lastError 有值（播放栏有 SnackBar 可弹）+ isPlaying/playbackState 转 false', () async {
      final real = AudioPlayer(playerId: 'pin-e2e');
      final ps = PlayerService(player: real);
      _live.add(ps);
      await ps.init();
      await ps.playQueue(_songs(), 0);
      await pumpEventQueue();
      // 原生 `resume` 返回后 Dart 无条件置 playing（audioplayer.dart:272-279）——
      // 这正是"App 以为在播"的来源。
      expect(ps.isPlaying, isTrue, reason: '前提检查：此刻 App 认为在播（真机 PLAYING(3)）');
      expect(ps.lastError.value, isNull, reason: '前提检查：此刻没有错误');

      platform.emitNativeError('pin-e2e', _focusDenied());
      await pumpEventQueue();

      expect(ps.lastError.value, isNotNull,
          reason: '★★ 真机判据：点播放（焦点被拒）⇒ 必须弹 SnackBar。'
              '报告点若挂在收不到错误的流上，这里就是 null = 真机症状');
      expect(ps.lastError.value, contains('音频焦点'));
      expect(ps.isPlaying, isFalse, reason: '★★ 真机判据：UI 必须转暂停（实测真机上没转）');
      expect(ps.playbackState.value.playing, isFalse, reason: '通知栏/锁屏也不能继续显示在播');
      expect(platform.calls, contains('pause'),
          reason: '顺手把播放器转 paused；原生已经是暂停，这一发是空操作');
    });

    test('★ 只写一次：同一个错误对象打到两条派生流，`lastError` 仍只写一次', () async {
      final real = AudioPlayer(playerId: 'pin-once');
      final ps = PlayerService(player: real);
      _live.add(ps);
      await ps.init();
      await ps.playQueue(_songs(), 0);
      await pumpEventQueue();

      var writes = 0;
      ps.lastError.addListener(() => writes++);
      platform.emitNativeError('pin-once', _focusDenied());
      await pumpEventQueue();

      expect(writes, 1, reason: '★ 只允许"时长流"那一条去报错，另一条只接住 ⇒ 只弹一条 SnackBar');
      expect(ps.lastError.value, isNotNull);
    });

    test('★ 负向：别的原生错误码不许抢 lastError、不许动播放状态', () async {
      final real = AudioPlayer(playerId: 'pin-other');
      final ps = PlayerService(player: real);
      _live.add(ps);
      await ps.init();
      await ps.playQueue(_songs(), 0);
      await pumpEventQueue();

      platform.emitNativeError(
        'pin-other',
        PlatformException(code: 'AndroidAudioError', message: 'MEDIA_ERROR_UNKNOWN {what:1}'),
      );
      await pumpEventQueue();

      expect(ps.lastError.value, isNull, reason: '★ 只有 AudioFocusDenied 走那套文案；别的原生错误维持原样');
      expect(ps.isPlaying, isTrue, reason: '★ 别的错误不该顺手把播放状态改掉');
    });

    test('★ 负向有牙的反面：同一次错误若被报告点"收起来"（挂回状态流），lastError 必然为 null',
        () async {
      // 这里**故意**不经过 PlayerService，直接复刻"报告点挂在状态流上"的接线方式，
      // 用真 AudioPlayer 证明那条路是死的 —— 也就是上一轮真机上发生的事。
      final p = AudioPlayer(playerId: 'pin-dead');
      addTearDown(p.dispose);
      var reportedByStateStream = 0;
      p.onPlayerStateChanged.listen((_) {}, onError: (Object _) => reportedByStateStream++);
      await pumpEventQueue();

      platform.emitNativeError('pin-dead', _focusDenied());
      await pumpEventQueue();

      expect(reportedByStateStream, 0,
          reason: '★★ 这就是"收起修复必须能复现"的那条：报告点挂在状态流上时，原生错误一次都不经过它 '
              '⇒ lastError 不写、UI 不转暂停、没有 SnackBar —— 与真机 9 份 logcat 里探针 0 次逐字一致');
      debugPrint('保真度锚点：状态流收到原生错误 $reportedByStateStream 次（期望 0）');
    });
  });
}
