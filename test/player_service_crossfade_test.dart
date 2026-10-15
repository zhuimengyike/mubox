/// 双播放器（队列预取 + 曲末交叉淡变）的**接线断言**。
///
/// 这个文件回答三个问题，每一个都有正/负一对：
///
/// 1. **缺省值下逐项等价改动前**（第一铁律）：`AppConfig.crossfadeEnabled` 缺省 false
///    ⇒ ①第二个播放器**根本不会被创建**（工厂调用数 == 0）；
///    ②同一个脚本跑出来的调用日志与改动前**逐项相同**（金标）；
///    ③`DualPlayerPolicy` 对**穷举的布尔输入**恒为 false（照 `ambient_policy_test.dart`
///    的套路）。
/// 2. **开关有牙**（负向对照）：同一段脚本把开关打开 ⇒ 日志**必须不一样**
///    （否则第 1 条的"等价"只是因为这套东西压根没实现）。
/// 3. **正/负向行为**：曲末两拍 ⇒ 预取 + 交叉淡变 + 换场（正向）；
///    手切歌打断淡变 ⇒ **两副音量都复位回 1.0**（负向，`volume_fade.dart` 那条硬不变量
///    的双播放器版本）。
///
/// ⚠️ 用的是**真 `PlayerService`** + 假播放器（与 `player_service_test.dart` 同一套路），
/// 不是"把逻辑抄一份到测试里"。`testWidgets` 仍然 = 0。
library;

import 'dart:async';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/app_config.dart';
import 'package:mu_box_phone/models.dart';
import 'package:mu_box_phone/player_service.dart';
import 'package:mu_box_phone/playback/crossfade.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/temp_docs.dart';

const _pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

/// 一次交叉淡变要走多少步（由纯函数定的：`fadeSteps(kCrossfadeTime)`）。
/// 测试里不写死 19，直接问纯函数 —— 改时长时这里跟着走。
final int kCrossfadeSteps = CrossfadePlan.standard.steps;

late Directory _docs;

/// 本文件建过的**全部**服务：tearDown 要等它们的落盘链走完再删临时目录。
///
/// 服务从不 dispose，落盘又是 fire-and-forget 串行链 ⇒ 用例体跑完那一刻
/// `queue.json` 可能还在写，句柄没放掉，删目录就会撞 Windows 共享冲突
/// （根因 + 实测到的两种真实异常见 `support/temp_docs.dart`）。
final List<PlayerService> _live = <PlayerService>[];

/// 建服务并登记（**本文件所有构造点都要走这里**，漏一个就漏一个目录）。
PlayerService _track(PlayerService ps) {
  _live.add(ps);
  return ps;
}

/// 把本文件所有服务的落盘链排空 —— `tearDown` 删目录之前的那一步（根因修复）。
Future<void> _drainPersists() async {
  for (final ps in _live) {
    await ps.debugFlushPersist();
  }
}

/// 假播放器：记录**按顺序**的调用日志，位置/时长/状态三条流由测试自己推。
///
/// `noSuchMethod` 故意抛 —— 服务里多调一个原生成员会当场响（与
/// `player_service_test.dart` 的假播放器同一个约定）。
class _FakePlayer implements AudioPlayer {
  _FakePlayer(this.playerId);

  @override
  final String playerId;

  /// 按顺序的调用日志（`setVolume` 也进，便于看两条曲线的交错）。
  final List<String> log = [];

  /// 只留"结构性"调用：**去掉 setVolume 的逐步写入**（那是音量包络，另有断言：
  /// `volumeWrites` 的端点与"压到 0 必须在 resume 之前"）。
  List<String> get shape =>
      [for (final e in log) if (!e.startsWith('setVolume:')) e];

  final List<Source> sources = [];
  final List<double> volumeWrites = [];
  final List<String> calls = [];

  final _pos = StreamController<Duration>.broadcast();
  final _dur = StreamController<Duration>.broadcast();
  final _state = StreamController<PlayerState>.broadcast();
  final _done = StreamController<void>.broadcast();

  void emitPos(Duration d) => _pos.add(d);
  void emitDuration(Duration d) => _dur.add(d);
  void emitComplete() => _done.add(null);
  void emitState(PlayerState s) => _state.add(s);

  String _src(Source s) => s is DeviceFileSource ? s.path : '$s';

  @override
  Future<void> setSource(Source source) async {
    sources.add(source);
    log.add('setSource:${_src(source)}');
    calls.add('setSource');
  }

  @override
  Future<void> setSourceUrl(String url, {String? mimeType}) async =>
      setSource(UrlSource(url, mimeType: mimeType));

  @override
  Future<void> stop() async {
    log.add('stop');
    calls.add('stop');
  }

  @override
  Future<void> resume() async {
    log.add('resume');
    calls.add('resume');
  }

  @override
  Future<void> pause() async {
    log.add('pause');
    calls.add('pause');
  }

  @override
  Future<void> setVolume(double volume) async {
    volumeWrites.add(volume);
    log.add('setVolume:$volume');
    calls.add('setVolume');
  }

  @override
  Future<void> setPlaybackRate(double playbackRate) async {
    log.add('setPlaybackRate:$playbackRate');
    calls.add('setPlaybackRate');
  }

  @override
  Future<void> seek(Duration position) async {
    log.add('seek:${position.inMilliseconds}');
    calls.add('seek');
  }

  @override
  Future<void> setReleaseMode(ReleaseMode releaseMode) async {
    log.add('setReleaseMode:${releaseMode.name}');
    calls.add('setReleaseMode');
  }

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

/// 三首歌，**时长各不相同** —— 这样"预取那一副不许改 UI 的总时长"才验得出来。
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

/// 等一个条件成立（默认最多 1.5 秒）——比睡固定时长稳，也比固定时长快。
Future<void> _waitFor(bool Function() cond, {int ms = 1500}) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    if (cond()) return;
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

/// 跑一段统一的脚本，返回 `(服务, A, B, 工厂被调用次数)`。
///
/// 脚本：播第一首 → 位置 tick 到"离曲末 700ms"（窗口内，先预热）→
/// 再 tick 到"离曲末 200ms"（该换场了）。
///
/// ⚠️ 必须 `init()`：位置 tick 的订阅是 init 里挂的（`_bindDeck`）。
/// 不调 init 的话推位置事件没人收，整条双播放器路径都不会被触发 ——
/// 那样的"绿"是假的（本文件第一版就踩了这个：所有用例都"通过"了，因为什么都没发生）。
Future<({PlayerService ps, _FakePlayer a, _FakePlayer b, int factoryCalls})>
_runScript({required bool crossfade, bool waitForCrossfade = true}) async {
  AppConfig.instance.crossfadeEnabled = crossfade;
  var made = 0;
  final a = _FakePlayer('fake-A');
  final b = _FakePlayer('fake-B');
  final ps = _track(PlayerService(player: a, playerFactory: () {
    made++;
    return b;
  }));
  await ps.init();
  await ps.playQueue(_songs(), 0);
  // ⚠️ 等第一首的淡入**真的跑完**（末项精确 1.0）再推 tick。
  // 不等的话换场的 out 曲线会从中间值起步（`crossfadeCurves(fromLeft: out.volume)`
  // 刻意支持这种情形，但那样两条曲线就不再互补了）—— 「零削波」那条断言要的
  // 是**曲末换场**这个真实场景：那时上一首的淡入早就跑完了。
  await _waitFor(() => a.volumeWrites.isNotEmpty && a.volumeWrites.last == 1.0,
      ms: 3000);
  // ① 窗口内：这一拍只该**预热**
  a.emitPos(const Duration(milliseconds: 179300));
  await pumpEventQueue();
  await _waitFor(() => made > 0 && b.sources.isNotEmpty);
  // ② 离曲末 200ms：该**换场**了
  a.emitPos(const Duration(milliseconds: 179800));
  if (waitForCrossfade) {
    // 等换场真的跑完：退场那一副被**第二次** stop（第一次是起播时的），且上场那一副已 resume
    await _waitFor(
      () =>
          a.calls.where((c) => c == 'stop').length >= 2 &&
          b.calls.contains('resume'),
      ms: 3000,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));
  } else {
    // 停在淡变中途：退场那一副已经明显低于满音量、上场那一副已经出声
    await _waitFor(() => a.volumeWrites.last < 0.9 && b.volumeWrites.last > 0.05);
  }
  return (ps: ps, a: a, b: b, factoryCalls: made);
}

/// 四首歌（比 [_songs] 多一首）：**连续三轮**自然换场要用满 4 首（0→1→2→3）。
List<Song> _songs4() => [
  for (final (i, ms) in [(0, 180000), (1, 200000), (2, 220000), (3, 240000)])
    Song(
      id: 1000 + i,
      title: '歌$i',
      artist: '',
      durationMs: ms,
      uri: 'content://media/external/audio/media/${1000 + i}',
      filePath: '/m/$i.mp3',
    ),
];

/// 一轮「曲末自然到达」的现场记录（预取那一拍 + 换场那一拍）。
class _Round {
  _Round({
    required this.round,
    required this.fromDeck,
    required this.toDeck,
    required this.prefetchDeck,
    required this.curTouched,
    required this.titleBeforeSwitch,
    required this.crossfaded,
    required this.titleAfter,
  });

  final int round;

  /// 这一轮开始时**在场**的是哪一副（`_onB` 的真身）。
  final String fromDeck;

  /// 这一轮结束时**在场**的是哪一副 —— 也是预取**应该**打的那一副。
  final String toDeck;

  /// 预取那一拍把 `setSource` 打到哪一副（`''` = 谁都没收到）。
  final String prefetchDeck;

  /// 预取那一拍，**在场那一副**（正在响的）收到的致命调用 —— 必须是空的。
  final List<String> curTouched;

  /// 预取那一拍结束时 UI 上的当前曲（预取不许动它）。
  final String titleBeforeSwitch;

  /// 曲末那一拍真的换场了吗。
  final bool crossfaded;

  /// 这一轮结束时 UI 上的当前曲。
  final String titleAfter;

  @override
  String toString() => '第$round轮：$fromDeck→$toDeck，预取打在「$prefetchDeck」，'
      '在场那副收到$curTouched，预取后当前曲「$titleBeforeSwitch」，'
      '换场=$crossfaded，换场后当前曲「$titleAfter」';
}

/// [_walk] 的返回：两副假播放器 + 逐轮现场 + 第二副牌的工厂被调用次数。
typedef _Walk = ({
  PlayerService ps,
  _FakePlayer a,
  _FakePlayer b,
  List<_Round> rounds,
  int factoryCalls,
});

/// 走**连续** [rounds] 轮曲末自然换场，逐轮把现场记下来（[_Round.toString] 就是失败信息）。
///
/// 每一轮的脚本与 `_runScript` 同一套节奏：位置 tick 到「离曲末 700ms」（窗口内，
/// 该预热）→ 再 tick 到「离曲末 200ms」（该换场）。区别只在**不换服务、不换假播放器**
/// —— 只跑一轮是不够的，**翻牌（`_onB`）之后的那一轮**才是关键那段：
/// 那时"空闲那一副"是 A，不再是 B。
Future<_Walk> _walk({int rounds = 3}) async {
  AppConfig.instance.crossfadeEnabled = true;
  var made = 0;
  final a = _FakePlayer('fake-A');
  final b = _FakePlayer('fake-B');
  final ps = _track(PlayerService(player: a, playerFactory: () {
    made++;
    return b;
  }));
  await ps.init();
  final songs = _songs4();
  await ps.playQueue(songs, 0);
  // 与 _runScript 同一个前提：第一首的淡入要真的跑完（末项精确 1.0）再推曲末 tick。
  await _waitFor(
    () => a.volumeWrites.isNotEmpty && a.volumeWrites.last == 1.0,
    ms: 3000,
  );

  final logs = <_Round>[];
  var cur = a;
  var idle = b;
  var curName = 'A';
  var idleName = 'B';
  for (var r = 0; r < rounds; r++) {
    final totalMs = songs[r].durationMs;
    final curSrc0 = cur.sources.length;
    final idleSrc0 = idle.sources.length;
    final curLog0 = cur.log.length;
    final curCalls0 = cur.calls.length;
    final idleCalls0 = idle.calls.length;

    // ① 窗口内那一拍：只该预热**空闲**那一副（离曲末 700ms ≤ lead 804ms）
    cur.emitPos(Duration(milliseconds: totalMs - 700));
    await pumpEventQueue();
    await _waitFor(
      () => idle.sources.length > idleSrc0 || cur.sources.length > curSrc0,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    final prefetchDeck = idle.sources.length > idleSrc0
        ? idleName
        : (cur.sources.length > curSrc0 ? curName : '');
    final touched = <String>[
      for (final e in cur.log.sublist(curLog0))
        if (e.startsWith('setSource') || e == 'setVolume:0.0') e,
    ];
    final titleBeforeSwitch = ps.current?.title ?? '';

    // ② 曲末那一拍：该换场了（上场方 = 上面刚预热的空闲那一副）
    cur.emitPos(Duration(milliseconds: totalMs - 200));
    await _waitFor(
      () =>
          idle.calls.skip(idleCalls0).contains('resume') &&
          cur.calls.skip(curCalls0).contains('stop'),
      ms: 3000,
    );
    await Future<void>.delayed(const Duration(milliseconds: 60));

    logs.add(
      _Round(
        round: r + 1,
        fromDeck: curName,
        toDeck: idleName,
        prefetchDeck: prefetchDeck,
        curTouched: touched,
        titleBeforeSwitch: titleBeforeSwitch,
        crossfaded: idle.calls.skip(idleCalls0).contains('resume'),
        titleAfter: ps.current?.title ?? '',
      ),
    );
    // 翻牌：下一轮"在场"的是这一轮上场的（原来的空闲）那一副
    final swapDeck = cur;
    cur = idle;
    idle = swapDeck;
    final swapName = curName;
    curName = idleName;
    idleName = swapName;
  }
  return (ps: ps, a: a, b: b, rounds: logs, factoryCalls: made);
}

/// 改动前（单播放器、无预取）同一条脚本的**结构性调用日志** —— 金标。
///
/// 逐项写死是故意的：这就是"逐项等价改动前"里的"逐项"。
/// ⚠️ 这里没有 `setVolume` —— [\_FakePlayer.shape] 刻意滤掉了音量包络（那是逐步写入，
/// 另有两条断言盯着它：起播先压 0、淡变结束精确回 1.0；顺序见下面那条 indexOf 断言）。
/// 顺序 = init 里的 release 模式 → 起播（stop → setSource → 倍速 → resume）。
const _kLegacyShape = <String>[
  'setReleaseMode:stop', // init()
  'stop',
  'setSource:/m/0.mp3',
  'setPlaybackRate:1.0',
  'resume',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    _docs = Directory.systemTemp.createTempSync('mubox_xfade_');
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
    // ★ 顺序不能反：① 先排空落盘（mock 还挂着，迟到的写才找得到同一个目录）——
    //   这一步才是根因修复（句柄放掉）；② 再拆 mock；③ 最后删目录（带重试）。
    //   以前是「拆 mock → 删 → catch (_) {}」，于是每跑一轮全量在 %TEMP% 里
    //   攒一个 mubox_xfade_*（实测 errno 32）。
    await _drainPersists();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_pathProviderChannel, null);
    await deleteTempDir(_docs);
  });

  group('★ 总闸：AppConfig.crossfadeEnabled（缺省 false，且不许 bump rebuild）', () {
    test('缺省值就是 false：没存过这个键时 load 出来必须是关的', () async {
      SharedPreferences.setMockInitialValues({});
      await AppConfig.load();
      expect(AppConfig.instance.crossfadeEnabled, isFalse,
          reason: '缺省值一旦变成 true，观感当场就变（两首重叠 ~300ms + 通知栏提前跳）');
      expect(AppConfig.instance.volumeFadeEnabled, isTrue,
          reason: '顺带确认另一个开关没被这次改动碰过');
    });

    test('开关能落盘、能读回来，且**不** bump rebuild', () async {
      SharedPreferences.setMockInitialValues({});
      await AppConfig.load();
      final rev = AppConfig.instance.rebuildRevision.value;
      await AppConfig.instance.setCrossfadeEnabled(true);
      expect(AppConfig.instance.crossfadeEnabled, isTrue);
      expect(AppConfig.instance.rebuildRevision.value, rev,
          reason: '它不是"要重建整棵 App"的配置（同 volumeFadeEnabled）');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getBool('fx_crossfade'), isTrue);
      await AppConfig.load();
      expect(AppConfig.instance.crossfadeEnabled, isTrue, reason: '重启后要记得住');
    });
  });

  group('★ 穷举布尔：缺省值下两个判定恒等于"不走这条路"', () {
    test('shouldPrefetch：enabled=false 时对 8 种输入组合全为 false（开启时等于合取）', () {
      for (final hasNext in [true, false]) {
        for (final inWindow in [true, false]) {
          for (final alreadyLoaded in [true, false]) {
            final tag = 'hasNext=$hasNext inWindow=$inWindow '
                'alreadyLoaded=$alreadyLoaded';
            expect(
              DualPlayerPolicy.shouldPrefetch(
                enabled: false,
                hasNext: hasNext,
                inWindow: inWindow,
                alreadyLoaded: alreadyLoaded,
              ),
              isFalse,
              reason: '缺省值下必须一个都不走：$tag',
            );
            // 有牙：同样的输入把开关打开，结论必须**跟着输入变** ——
            // 否则上面那条"恒 false"可能只是因为函数压根不看输入
            expect(
              DualPlayerPolicy.shouldPrefetch(
                enabled: true,
                hasNext: hasNext,
                inWindow: inWindow,
                alreadyLoaded: alreadyLoaded,
              ),
              hasNext && inWindow && !alreadyLoaded,
              reason: '开关打开时必须等于合取：$tag',
            );
          }
        }
      }
    });

    test('shouldCrossfade：enabled=false 时对 4 种输入组合全为 false（开启时等于合取）', () {
      for (final prefetched in [true, false]) {
        for (final shouldStart in [true, false]) {
          expect(
            DualPlayerPolicy.shouldCrossfade(
              enabled: false,
              prefetched: prefetched,
              shouldStart: shouldStart,
            ),
            isFalse,
          );
          expect(
            DualPlayerPolicy.shouldCrossfade(
              enabled: true,
              prefetched: prefetched,
              shouldStart: shouldStart,
            ),
            prefetched && shouldStart,
          );
        }
      }
    });

    test('围栏：这两个纯判定真的被 player_service 用着（别测成死代码）', () {
      final src = File('lib/player_service.dart').readAsStringSync();
      expect(src.contains('DualPlayerPolicy.shouldPrefetch('), isTrue);
      expect(src.contains('DualPlayerPolicy.shouldCrossfade('), isTrue);
      expect(src.contains('AppConfig.instance.crossfadeEnabled'), isTrue);
    });
  });

  group('★ 缺省值下逐项等价改动前（负向，有金标）', () {
    test('开关关闭：第二个播放器连构造函数都不会跑（工厂调用数 == 0）', () async {
      AppConfig.instance.crossfadeEnabled = false;
      var made = 0;
      final a = _FakePlayer('fake-A');
      final ps = _track(PlayerService(player: a, playerFactory: () {
        made++;
        return _FakePlayer('fake-B');
      }));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      await Future<void>.delayed(const Duration(milliseconds: 260));
      a.emitPos(const Duration(milliseconds: 179300)); // 窗口内也不许动
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      a.emitPos(const Duration(milliseconds: 179800));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(made, 0,
          reason: '★ 缺省值下第二个 AudioPlayer 不该被创建 —— 没有第二个播放器，'
              '就没有第二个 setSource，也就没有"抢 session"这回事');
      expect(ps.current!.title, '歌0', reason: '曲末窗口里什么都不该发生（还在放第一首）');
    });

    test('开关关闭：同一段脚本的结构性调用日志 == 改动前的金标', () async {
      final r = await _runScript(crossfade: false);
      expect(
        r.a.shape,
        _kLegacyShape,
        reason: '★ 这就是"逐项等价改动前"里的**逐项**：\n'
            '起播 = stop → setSource → 倍速 → 压到 0 → resume。\n'
            '多一条/少一条/换顺序都说明缺省路径被这次改动动过了。',
      );
      expect(r.factoryCalls, 0);
      expect(r.a.volumeWrites.first, 0.0, reason: '起播先把音量压到 0（老行为）');
      expect(r.a.volumeWrites.last, 1.0,
          reason: '硬不变量：淡入结束音量精确回到 1.0');
      // 顺序也要对：压到 0 **在 resume 之前**（否则起播会满音量蹦一下）
      expect(
        r.a.log.indexOf('setVolume:0.0'),
        lessThan(r.a.log.indexOf('resume')),
        reason: '先压 0 再 resume —— 这是改动前就有的顺序，缺省路径不许改',
      );
      expect(r.a.sources.length, 1, reason: '关着的时候只有一次 setSource');
      expect(r.b.log, isEmpty, reason: '第二副牌一个调用都没有');
      expect(r.ps.current!.title, '歌0', reason: '关着的时候曲末窗口不换场');
    });

    test('★ 开关有牙（负向对照）：同一段脚本打开开关，日志必须不一样', () async {
      final off = await _runScript(crossfade: false);
      final on = await _runScript(crossfade: true);
      expect(off.a.shape, _kLegacyShape);
      expect(
        on.a.shape,
        isNot(_kLegacyShape),
        reason: '开关打开后日志还是老样子 ⇒ 这套东西压根没接线（上面那条"等价"就是假的）',
      );
      expect(on.factoryCalls, 1, reason: '打开开关才会懒建第二副牌');
      expect(on.b.sources, isNotEmpty, reason: '第二副牌里要装预取进来的下一首');
    });
  });

  group('★ 正向：曲末两拍 = 先预热、再换场', () {
    test('第①拍只预热：第二副牌 setSource 了下一首，但**没出声**、也没动 UI', () async {
      AppConfig.instance.crossfadeEnabled = true;
      var made = 0;
      final a = _FakePlayer('fake-A');
      final b = _FakePlayer('fake-B');
      final ps = _track(PlayerService(player: a, playerFactory: () {
        made++;
        return b;
      }));
      await ps.init();
      await ps.playQueue(_songs(), 0);
      await Future<void>.delayed(const Duration(milliseconds: 260));
      final durBefore = ps.dur;
      a.emitPos(const Duration(milliseconds: 179300)); // 离曲末 700ms
      await pumpEventQueue();
      await _waitFor(() => made > 0 && b.sources.isNotEmpty);

      expect(made, 1);
      expect(b.sources.length, 1);
      expect('${b.sources.single}', contains('1.mp3'),
          reason: '预取的必须是**下一首**（_nextIndexForPrefetch 与 next() 同源）');
      expect(b.calls, isNot(contains('resume')),
          reason: '★ 预取只加载不播：resume 是换场那一刻才发的');
      expect(b.volumeWrites, [0.0], reason: '预热期间要把这一副压到 0（不许蹦一下）');
      expect(ps.current!.title, '歌0', reason: '第①拍还没换场');
      expect(ps.dur, durBefore, reason: '预取不许改 UI 的总时长');

      // 有牙：不在场那一副报上来的时长/状态必须被身份守卫丢掉
      b.emitDuration(const Duration(seconds: 999));
      b.emitState(PlayerState.playing);
      await pumpEventQueue();
      expect(ps.dur, durBefore,
          reason: '★ 不在场那一副（预取/退场）不许改 dur —— 没有身份守卫时'
              '进度条会显示下一首的时长');
    });

    test('第②拍换场：两条互补曲线、两副末音量精确 1.0、当前曲换成下一首', () async {
      final r = await _runScript(crossfade: true);
      final a = r.a;
      final b = r.b;
      final ps = r.ps;

      expect(ps.current!.title, '歌1', reason: '★ 换场之后"当前曲"必须是下一首');
      expect(ps.isPlaying, isTrue, reason: '换场结束时新那一副正在响');

      // ① 退场那一副：先被淡到 0，最后**复位回 1.0** 并停车
      expect(a.volumeWrites.last, 1.0,
          reason: '★ 硬不变量的双播放器版本：退场那一副的音量必须复位回 1.0，'
              '否则它下次当值就"一开口就小声"');
      expect(a.calls, contains('stop'), reason: '退场那一副要停车');
      final aDuring = [
        for (final v in a.volumeWrites)
          if (v != 1.0) v,
      ];
      expect(aDuring, isNotEmpty, reason: '退场那一副真的被淡出过（不是硬停）');
      expect(aDuring.reduce((x, y) => x < y ? x : y), lessThan(0.2),
          reason: '淡出必须真的走到接近 0');

      // ② 上场那一副：从 0 淡到 1.0
      expect(b.volumeWrites.first, 0.0, reason: '预取时压到 0');
      expect(b.volumeWrites.last, 1.0, reason: '淡入终点精确 1.0');
      expect(b.calls, contains('resume'));
      expect(b.volumeWrites.length, greaterThan(5),
          reason: '真的走了多步曲线（不是"0 直接跳 1"）');

      // ③ 两条曲线是**互补**的：同一拍写入的两个值加起来 == 1.0 ——
      // 这就是 crossfade.dart 承诺的"零削波"（线性互补 ⇒ 任意时刻 a+b == 1），
      // 接线之后必须真的成立（不是只有纯函数里成立）。
      // 前提（_runScript 已经等住）：换场开始时退场那一副的音量是**精确 1.0**。
      expect(a.volumeWrites.last, 1.0);
      // A 的尾巴 = [out_1 … out_19, 复位 1.0]；B 的头一项是预取的 0.0。
      final aTail = a.volumeWrites.sublist(a.volumeWrites.length - kCrossfadeSteps - 1,
          a.volumeWrites.length - 1);
      final bTail = b.volumeWrites.sublist(1);
      expect(aTail.length, kCrossfadeSteps);
      expect(bTail.length, kCrossfadeSteps);
      expect(aTail.first, greaterThan(0.9), reason: 'out 曲线从接近 1.0 起步');
      for (var i = 0; i < kCrossfadeSteps; i++) {
        expect(aTail[i] + bTail[i], closeTo(1.0, 1e-9),
            reason: '第 ${i + 1} 拍：退场 ${aTail[i]} + 上场 ${bTail[i]} 必须等于 1.0'
                '（线性互补 ⇒ 两首同时在响也不会削波）');
      }

      // ④ 换场后 effect 跟着换人（三处推送都带上新的 playerId）
      expect(ps.current!.durationMs, 200000);
    });

    test('换场期间的位置/状态事件不许打架（退场那一副的 complete 不许再切一首）', () async {
      final r = await _runScript(crossfade: true);
      // 退场那一副"刚好在曲末报完成"——这是最危险的一瞬（会多切一首）
      r.a.emitComplete();
      await pumpEventQueue();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(r.ps.current!.title, '歌1',
          reason: '★ 退场那一副的完成事件必须被丢掉（身份守卫 + _crossfading），'
              '否则一次曲末会连切两首');
    });
  });

  group('★ 负向：手切歌打断交叉淡变', () {
    test('打断时**两副**音量都复位回 1.0，新曲走硬切（与改动前一致）', () async {
      final r = await _runScript(crossfade: true, waitForCrossfade: false);
      final a = r.a;
      final b = r.b;
      final ps = r.ps;

      // 前提：此刻淡变真的在跑（退场那一副已经不在满音量上了）
      expect(a.volumeWrites.last, lessThan(1.0),
          reason: '前提检查：淡变进行中，退场那一副的音量应低于 1.0');
      final midB = b.volumeWrites.last;
      expect(midB, greaterThan(0.0), reason: '前提检查：上场那一副已经出声了');

      // ★ 断言要能分辨"复位过"和"没复位但被后面的加载盖过去"：
      // 硬切那条路紧接着就会把在场那一副压到 0，所以只看"末项是不是 1.0"是**没牙**的
      // （有牙实验实测：拆掉 _abortCrossfade 里的复位，末项照样是 1.0，用例不红）。
      // 真正的断言 = 打断之后、**新曲压 0 之前**，必须出现过一次精确 1.0 的复位。
      final aLen = a.volumeWrites.length;
      final bLen = b.volumeWrites.length;

      await ps.next(); // ★ 手切歌：打断淡变
      expect(ps.current!.title, '歌2', reason: '手切选中谁就是谁（不受淡变影响）');
      await Future<void>.delayed(const Duration(milliseconds: 500)); // 等新的淡入跑完

      final aAfter = a.volumeWrites.sublist(aLen);
      final bAfter = b.volumeWrites.sublist(bLen);
      expect(aAfter.takeWhile((v) => v != 0.0).contains(1.0), isTrue,
          reason: '★ 退场播放器在下一次压 0 **之前**必须被复位回 1.0 —— '
              '否则它停在 0.79 这种中间值上，下次当值就"一开口就小声"：$aAfter');
      expect(bAfter, contains(1.0),
          reason: '★ 被打断的上场那一副同样要复位回 1.0（它下一轮还要当值）：$bAfter');
      expect(a.volumeWrites.last, 1.0, reason: '末项仍是 1.0（硬不变量）');
      expect(b.volumeWrites.last, 1.0, reason: '末项仍是 1.0（硬不变量）');
      expect(b.calls, contains('pause'), reason: '被打断的那一副要立刻掐掉，不能停在半音量继续响');
      expect('${a.sources.last}', contains('2.mp3'),
          reason: '手切是**硬切**：新曲加载在"在场"那一副上（与改动前逐项相同，'
              '不等 300ms 淡出，手切要立刻响）');
      expect(a.calls.lastIndexOf('stop'), greaterThan(0));
    });
  });

  // ══════════════════════════════════════════════════════════════════════════
  // ★ 翻牌之后的那一轮起（这一段原来一条用例都没有，而症状就出在这儿）
  //
  // 症状：开了交叉淡变听一晚 ⇒「自然听完一首歌，下一首**没声音**，或者是乱放」。
  //
  // 机器形状：`_crossfadeTo` 结束时**翻牌**（`_onB`），此后"空闲那一副"是 **A**。
  // 而 `_prefetch` 找空闲那副用的是 `_ensureDeckB()` —— 它恒返回 **B**。
  // ⇒ 翻牌之后，预取把 setSource 打在**正在响的那一副**上：
  //    `_setVolumeOn(它在响的那副, 0.0)` + `setSource(下一首)` ⇒ 当前曲当场哑掉；
  //    紧接着那句 `identical(_idle, idle)` 守卫**必然**不成立（`_idle` 是 A、
  //    `idle` 是 B）⇒ 提前 return，`_prefetchedIndex` 永远是 -1 ⇒ **换场再也不会发生**，
  //    曲末也没有完成事件推它（source 被换掉了）⇒ 一直没声音。
  // 这两条用例是**一对**：正向（还得能一轮轮换下去）+ 负向（在响的那副一个字节
  // 都不许被碰）。把修复收起来 ⇒ 两条都红（有牙的证明在提交信息里）。
  // ══════════════════════════════════════════════════════════════════════════
  group('★ 第二轮起（翻牌之后）：预取必须打在**空闲**那一副上', () {
    test('正向：连续三轮曲末自然换场都成立、当前曲逐轮推进', () async {
      final r = await _walk(rounds: 3);
      final detail = r.rounds.join('\n');
      expect(
        [for (final x in r.rounds) x.crossfaded],
        [true, true, true],
        reason: '★ 翻牌之后还得能接着换场 —— 只有第一轮换得成，就等于"开一晚只有第一次接得上"：\n$detail',
      );
      expect(
        [for (final x in r.rounds) x.titleAfter],
        ['歌1', '歌2', '歌3'],
        reason: '★ 自然听完一首就要接上下一首，且**顺序**要对（不许跳/不许回头）：\n$detail',
      );
      expect(r.ps.isPlaying, isTrue, reason: '换场结束时那一副正在响');
      expect(r.factoryCalls, 1,
          reason: '三轮换场只该有**一个**第二副牌（懒建一次）—— 两副牌滚着用，不许每轮新建');
      expect(r.rounds[0].titleBeforeSwitch, '歌0',
          reason: '预取那一拍还没换场（预取不许动 UI）');
    });

    test('负向：正在响的那一副在预取那一拍**一个字节都不许被碰**', () async {
      final r = await _walk(rounds: 3);
      final detail = r.rounds.join('\n');
      for (final x in r.rounds) {
        expect(
          x.prefetchDeck,
          x.toDeck,
          reason: '第${x.round}轮：预取该打在**空闲**那一副（=${x.toDeck}），'
              '实际打在「${x.prefetchDeck}」\n$detail',
        );
        expect(
          x.curTouched,
          isEmpty,
          reason: '★★ 第${x.round}轮：在响的「${x.fromDeck}」那一副被静音 / 换了 source '
              '—— 这就是"自然听完一首，下一首**没声音**"的机器形状'
              '（音量被压到 0、source 被换成下一首、曲末完成事件再也不来）：\n$detail',
        );
        expect(
          x.titleBeforeSwitch,
          '歌${x.round - 1}',
          reason: '第${x.round}轮：预取那一拍不许动"当前曲"\n$detail',
        );
      }
    });
  });
}
