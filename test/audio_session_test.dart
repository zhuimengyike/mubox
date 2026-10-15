/// `lib/playback/audio_session.dart` 的用例 —— **阶段 2b「原生会话归属」的可执行证据**。
///
/// 这个文件是两个方向都要有牙的尺子：
///
/// 1. **正向（新能力）**：per-player 登记表下，第二个播放器 `setSource`（= 预取）
///    **抢不走**第一个播放器的 session ⇒ 三个引擎按身份挂，频谱/EQ/低音/响度换场后仍生效；
/// 2. **负向（旧事实仍在）**：那个**兼容格子**（`AudioSessionProvider.sessionId`）
///    依然"谁最后写谁占" —— 它证明"引擎读它就一定会挂错人"，
///    所以三个引擎的判定里**必须**带播放器身份。
///
/// ⚠️ **锚点一律是内容，不是行号**：`.kt` 是 fork 的一部分，以后还会被改
/// （换行、加注释、调顺序都会漂行号），而"那一行代码还在不在"才是要盯的事实。
/// 反射式地钉行号只会让下一次改造先红一片无关用例。
///
/// ⚠️ 这个文件早先钉的是**反面**（`supportsRebind == false`、只有一个格子、
/// 三个引擎构造时绑定…）。原生会话归属改成 per-player 之后那些都过时了，
/// 所以断言整体翻到新事实这一面 —— **改完必须顺手更新锚点**，否则它就成了假红源。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/playback/audio_session.dart';

const _kAudioSessionProvider =
    'third_party/audioplayers_android/android/src/main/kotlin/xyz/luan/audioplayers/AudioSessionProvider.kt';
const _kMediaPlayerWrapper =
    'third_party/audioplayers_android/android/src/main/kotlin/xyz/luan/audioplayers/player/MediaPlayerWrapper.kt';
const _kWrappedPlayer =
    'third_party/audioplayers_android/android/src/main/kotlin/xyz/luan/audioplayers/player/WrappedPlayer.kt';
const _kPlugin =
    'third_party/audioplayers_android/android/src/main/kotlin/xyz/luan/audioplayers/AudioplayersPlugin.kt';
const _kSpectrum =
    'android/app/src/main/kotlin/com/mubox/mubox/SpectrumEngine.kt';
const _kEqualizer =
    'android/app/src/main/kotlin/com/mubox/mubox/EqualizerEngine.kt';
const _kExtraEffects =
    'android/app/src/main/kotlin/com/mubox/mubox/ExtraEffectsEngine.kt';
// ★ 「同播放器 + 同 session」那道身份闸（以及那条不许改成 `&&` 的早退 `||`）
//   搬进了 `EffectAttachPolicy.kt` —— 零 Android 依赖 ⇒ 能被 kotlinc 离线直接驱动
//   （不进 APK 的一份副本，与进包的是同一份字节）。判定逻辑一个字没变，锚点必须跟着文件走。
const _kAttachPolicy =
    'android/app/src/main/kotlin/com/mubox/mubox/EffectAttachPolicy.kt';
const _kPlayerService = 'lib/player_service.dart';
const _kSpectrumDart = 'lib/spectrum_engine.dart';
const _kEqDart = 'lib/eq_engine.dart';
const _kExtraFxDart = 'lib/extra_effects.dart';
const _kCrossfadeDart = 'lib/playback/crossfade.dart';
const _kPrefetchDart = 'lib/playback/prefetch.dart';

String _read(String path) => File(path).readAsStringSync();

/// 断言某个 Kotlin/Dart 事实仍在原处（锚点是**内容**，不是行号）。
void _expectAnchor(String path, String needle, {String? why}) {
  expect(
    _read(path).contains(needle),
    isTrue,
    reason: '$path 里找不到「$needle」。\n'
        '${why ?? '它是阶段 2b「原生会话归属」那条链的一环：它没了/被改了，'
            '说明有人动了 session 归属那条线，本文件与交付说明都要跟着复核。'}',
  );
}

void main() {
  group('★ 正向：per-player 登记表 —— 双播放器谁也抢不走谁的 session', () {
    test('两个播放器各自 setSource：按身份查到的仍是自己那份', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      final b = NativePlayerHandle('B', playerId: 'uuid-B', sessionId: 202);

      reg.put(a); // A setSource
      expect(reg.sessionOf('uuid-A'), 101);
      reg.put(b); // ★ 预取：给 B setSource（只加载、不播）
      expect(reg.sessionOf('uuid-A'), 101, reason: '★ A 的 session 没有被抢走');
      expect(reg.sessionOf('uuid-B'), 202);
      expect(reg.legacyStolenBy(a), isTrue,
          reason: '兼容格子确实被 B 抢了 —— 这条不是要修的 bug，'
              '而是"引擎绝不能再读兼容格子"的理由（见下面那条负向）');
    });

    test('三个引擎按身份挂：预取期间各自仍挂在正在播的 A 上', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      final b = NativePlayerHandle('B', playerId: 'uuid-B', sessionId: 202);
      final eq = EqualizerLike();
      final fx = ExtraEffectsLike();
      final viz = SpectrumLike();

      reg.put(a);
      expect(eq.attach(reg, playerId: 'uuid-A'), isTrue);
      expect(fx.attach(reg, playerId: 'uuid-A'), isTrue);
      expect(viz.start(reg, playerId: 'uuid-A'), isTrue);
      expect(eq.matchesActive(a), isTrue);
      expect(fx.matchesActive(a), isTrue);
      expect(viz.matchesActive(a), isTrue);

      reg.put(b); // 预取（B setSource）—— 改造前这一刻三个引擎就全指错了
      expect(eq.matchesActive(a), isTrue, reason: '★ EQ 还挂在 A 上（按身份查，没被抢）');
      expect(fx.matchesActive(a), isTrue);
      expect(viz.matchesActive(a), isTrue);
      expect(reg.legacySlot, 202, reason: '兼容格子已经是 B 的了（旧事实）');
    });

    test('换场（交叉淡变交接）：三个引擎都能改绑到 B，且真的换过去了', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      final b = NativePlayerHandle('B', playerId: 'uuid-B', sessionId: 202);
      final eq = EqualizerLike();
      final fx = ExtraEffectsLike();
      final viz = SpectrumLike();
      reg.put(a);
      eq.attach(reg, playerId: 'uuid-A');
      fx.attach(reg, playerId: 'uuid-A');
      viz.start(reg, playerId: 'uuid-A');
      reg.put(b); // 预取写入 B

      // ★ 改绑入口（签名）：rebind(registry, playerId: …)
      expect(eq.rebind(reg, playerId: 'uuid-B'), isTrue);
      expect(fx.rebind(reg, playerId: 'uuid-B'), isTrue);
      expect(viz.rebind(reg, playerId: 'uuid-B'), isTrue);
      expect(eq.matchesActive(b), isTrue);
      expect(fx.matchesActive(b), isTrue);
      expect(viz.matchesActive(b), isTrue);
      expect(eq.matchesActive(a), isFalse, reason: '旧 session 上的 effect 必须已经被放掉');
    });

    test('同一个身份重复 attach = 空操作（别每拍重建一次 Visualizer）', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      final viz = SpectrumLike();
      final eq = EqualizerLike();
      reg.put(a);
      expect(viz.start(reg, playerId: 'uuid-A'), isTrue);
      expect(viz.rebuilds, 1);
      expect(viz.start(reg, playerId: 'uuid-A'), isTrue, reason: '同身份：短路返回');
      expect(viz.rebuilds, 1, reason: '★ Visualizer 没有被白白重建（一次都不能多）');
      expect(eq.attach(reg, playerId: 'uuid-A'), isTrue);
      expect(eq.attach(reg, playerId: 'uuid-A'), isFalse, reason: '同身份同 session：不动');
      expect(eq.rebuilds, 1);
    });

    test('同一个播放器的 session 变了（MediaPlayer 被重建）⇒ 也要重挂', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      final eq = EqualizerLike();
      reg.put(a);
      expect(eq.attach(reg, playerId: 'uuid-A'), isTrue);
      // MediaPlayer 被 release 又重建（ReleaseMode.RELEASE 或 playerMode 变更）：
      // 旧的 effect 挂在死掉的 session 上，必须重挂
      reg.forget(a);
      expect(reg.sessionOf('uuid-A'), -1, reason: '按身份的登记已撤销 ⇒ 原生报 available=false');
      a.sessionId = 303;
      reg.put(a);
      expect(eq.attach(reg, playerId: 'uuid-A'), isTrue);
      expect(eq.attachedSession, 303);
      expect(reg.legacySlot, 303, reason: '兼容格子也跟着更新（旧语义：最后一次写入的值）');
    });

    test('★ 均衡器的 OPEN/CLOSE 广播成对：换场时先 CLOSE 旧的、再 OPEN 新的', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      final b = NativePlayerHandle('B', playerId: 'uuid-B', sessionId: 202);
      final eq = EqualizerLike();
      reg.put(a);
      eq.attach(reg, playerId: 'uuid-A');
      expect(eq.broadcasts, ['OPEN:101']);
      reg.put(b);
      eq.rebind(reg, playerId: 'uuid-B');
      expect(eq.broadcasts, ['OPEN:101', 'CLOSE:101', 'OPEN:202'],
          reason: 'CLOSE 用的必须是**旧** session（101），OPEN 用新的（202）—— '
              '这条配对是官方约定（ACTION_OPEN/CLOSE_AUDIO_EFFECT_CONTROL_SESSION）');
    });

    test('音效增强刻意不发广播（统一由均衡器发，避免重复 open/close）', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      final fx = ExtraEffectsLike();
      reg.put(a);
      fx.attach(reg, playerId: 'uuid-A');
      expect(fx.rebuilds, 1);
      // 类里根本没有 broadcasts 这个成员 —— 用类型层面钉住"它不发广播"
      expect(fx, isNot(isA<EqualizerLike>()));
    });
  });

  group('★ 负向：兼容格子仍然会被抢（所以引擎读它就一定挂错人）', () {
    test('第二个播放器 setSource ⇒ 兼容格子指向它，但按身份查不受影响', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      final b = NativePlayerHandle('B', playerId: 'uuid-B', sessionId: 202);
      reg.put(a);
      reg.put(b);
      expect(reg.legacySlot, 202, reason: '★ 旧事实：谁最后 setSource 谁占格子');
      expect(reg.lastWriter, 'uuid-B');
      expect(reg.legacyStolenBy(a), isTrue);
      // 不带身份 = 老调用点：读到的就是被抢走的那个值（这正是要避免的用法）
      expect(reg.sessionOf(null), 202, reason: '不带身份的调用仍然指错人');
    });

    test('release 不清兼容格子 —— 与原生一致（只在按身份的表里撤销）', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      reg.put(a);
      reg.forget(a);
      expect(reg.sessionOf('uuid-A'), -1, reason: '按身份的登记撤掉了');
      expect(reg.legacySlot, 101,
          reason: '兼容格子仍指着死掉的 session（改造前就有的真实缺陷，刻意保留）');
      expect(reg.lastWriter, 'uuid-A');
    });

    test('session 没就绪 ⇒ available=false（不是"挂上了但没声"）', () {
      final reg = AudioSessionRegistry();
      expect(reg.sessionOf('uuid-A'), -1);
      expect(EqualizerLike().attach(reg, playerId: 'uuid-A'), isFalse);
      expect(ExtraEffectsLike().attach(reg, playerId: 'uuid-A'), isFalse);
      expect(SpectrumLike().start(reg, playerId: 'uuid-A'), isFalse);
    });

    test('SpectrumLike.startWithRetry 用满 MAX_RETRY 才放弃（= 原生退避 8 次后报错）', () {
      final reg = AudioSessionRegistry(); // 一直没有这个播放器的登记
      final viz = SpectrumLike();
      expect(viz.startWithRetry(reg, playerId: 'uuid-A'), SpectrumLike.maxRetry + 1,
          reason: '对应 SpectrumEngine「重试 8 次仍失败，放弃」并回 SPECTRUM_UNAVAILABLE');
      expect(viz.running, isFalse);
    });
  });

  group('★ 源码锚点：故障链的每一环都真的改成了新形状', () {
    test('① 登记表按身份存，兼容格子只有 put 能写', () {
      final src = _read(_kAudioSessionProvider);
      _expectAnchor(_kAudioSessionProvider, 'object AudioSessionProvider');
      _expectAnchor(_kAudioSessionProvider, 'fun put(playerId: String, session: Int)',
          why: 'per-player 写入入口没了 ⇒ 引擎只能又去读全局格子');
      _expectAnchor(_kAudioSessionProvider, 'fun sessionOf(playerId: String?): Int',
          why: 'per-player 查询通道就是它 —— 这是最核心的需求');
      _expectAnchor(_kAudioSessionProvider, 'fun forget(playerId: String)',
          why: 'MediaPlayer 被 release 后不撤销登记 ⇒ 引擎会拿死 session 去 attach');
      _expectAnchor(_kAudioSessionProvider, 'var sessionId: Int = -1');
      _expectAnchor(_kAudioSessionProvider, 'private set',
          why: '兼容格子必须只能由 put 写：外部随手赋值 = 又回到"谁都能抢"的旧世界');
      expect(src.contains('sessions[playerId]'), isTrue,
          reason: '按身份的存储要真的存在（不是只有个签名）');
    });

    test('② 两处写入都带上播放器身份；release 时撤销登记', () {
      final src = _read(_kMediaPlayerWrapper);
      final writes = 'AudioSessionProvider.put(wrappedPlayer.playerId,'.allMatches(src).length;
      expect(writes, 2,
          reason: 'setSource 与 onPrepared 各登记一次（现在是 $writes 处）。'
              '写点数量变了 ⇒ "什么时候能查到 session"的结论要重新验');
      _expectAnchor(_kMediaPlayerWrapper, 'AudioSessionProvider.forget(wrappedPlayer.playerId)',
          why: 'MediaPlayer 真 release 之后不撤销 ⇒ 引擎挂到一个死 session 上还查不出原因');
      // 身份从哪来：Dart 的 playerId → AudioplayersPlugin → WrappedPlayer → MediaPlayerWrapper
      _expectAnchor(_kWrappedPlayer, 'val playerId: String');
      _expectAnchor(_kPlugin, 'WrappedPlayer(playerId, this, eventHandler');
    });

    test('③ 三个引擎都按身份取 session + 判据里带身份（不再是构造时绑死）', () {
      _expectAnchor(_kSpectrum, 'AudioSessionProvider.sessionOf(playerId)');
      _expectAnchor(_kSpectrum, 'if (playerId == attachedPlayerId) return',
          why: '频谱的短路必须是"每播放器"的：同身份才不重建，换身份要重建');
      _expectAnchor(_kSpectrum, 'val viz = Visualizer(sessionId)');
      _expectAnchor(_kSpectrum, 'stop() // 换了播放器：重建（Visualizer 无改绑 API）');

      _expectAnchor(_kEqualizer, 'AudioSessionProvider.sessionOf(playerId)');
      _expectAnchor(_kEqualizer, 'val e = Equalizer(0, session)');
      _expectAnchor(_kEqualizer, 'attachedPlayerId == playerId && attachedSession == session',
          why: 'EQ 的重挂判据少了身份 ⇒ 换播放器时它以为"已经挂好了"，'
              'effect 留在旧 session 上静默失效、开关还显示开着');

      _expectAnchor(_kExtraEffects, 'AudioSessionProvider.sessionOf(playerId)');
      _expectAnchor(_kAttachPolicy,
          'i.attachedPlayerId == i.playerId && i.attachedSession == i.session',
          why: 'ExtraEffects 的重挂判据少了身份 ⇒ 换播放器时它以为"已经挂好了"，'
              'effect 留在旧 session 上静默失效、开关还显示开着');
      // ⛔ 这条钉的是文档里明确否决过的那个改法（别再把 `||` 改成 `&&`）：
      //    只认 BassBoost、不认 LoudnessEnhancer 的老 ROM 上 `loud` 恒为 null，
      //    改 `&&` 会让早退永不成立 ⇒ 连自动路径（播放中每轮 ensure）都重建两个 effect。
      _expectAnchor(_kAttachPolicy, '(i.bassAttached || i.loudAttached)',
          why: '早退判据的 `||` 被改成了别的形状 ⇒ 自动路径的代价按秒计地放大');

      // 三个引擎都要能按身份挂（MethodChannel / EventChannel 的参数）
      _expectAnchor(_kEqualizer, 'call.argument<String>("playerId")');
      _expectAnchor(_kExtraEffects, 'call.argument<String>("playerId")');
      _expectAnchor(_kSpectrum, 'if (arguments is String) arguments else null');
    });

    test('④ 真机上用来取证的三行日志前缀**一个都没变**（换场时看它们有没有再出现）', () {
      _expectAnchor(_kSpectrum, '"Visualizer started, sessionId=');
      _expectAnchor(_kEqualizer, '"attached, sessionId=');
      _expectAnchor(_kExtraEffects, '"attached, sessionId=');
      // 并且都补上了 playerId（否则真机上看不出"挂在谁身上"）
      expect(_read(_kSpectrum).contains('playerId=\$playerId'), isTrue);
      expect(_read(_kEqualizer).contains('playerId=\$playerId'), isTrue);
      expect(_read(_kExtraEffects).contains('playerId=\$playerId'), isTrue);
    });

    test('⑤ 整仓只有一个 AudioPlayer 实例化点，两副牌都从它出来', () {
      final src = _read(_kPlayerService);
      expect(
        src.contains('static AudioPlayer _newPlayer() => AudioPlayer();'),
        isTrue,
        reason: '$_kPlayerService 的"造真播放器"入口形态变了 —— '
            'test/player_service_test.dart 的注入口子（player:）和 '
            'test/player_service_crossfade_test.dart 的 playerFactory: 都靠它',
      );
      final code = _codeOnly(src);
      expect('AudioPlayer('.allMatches(code).length, 1,
          reason: 'player_service.dart 里出现了第二个 AudioPlayer 实例化点'
              '（数的是剥离注释后的代码）—— 两副牌必须都从 _newPlayer() 出来');
      expect(code.contains('static AudioPlayer _newPlayer()'), isTrue);
      expect(code.contains('_Deck(player ?? _newPlayer())'), isTrue,
          reason: 'A 那一副必须走同一个工厂');
      expect(code.contains('_Deck(_playerFactory())'), isTrue,
          reason: 'B 那一副必须走同一个工厂（懒建）');
    });

    test('⑥ Dart 侧把"挂到哪个播放器"一路传下去（三处调用点都在）', () {
      _expectAnchor(_kSpectrumDart, 'Future<void> setTargetPlayerId(String? id)',
          why: '频谱的改绑入口：带身份重新订阅（原生据此重建 Visualizer）');
      _expectAnchor(_kSpectrumDart, 'receiveBroadcastStream(_targetPlayerId)');
      _expectAnchor(_kEqDart, "playerId == null ? null : {'playerId': playerId}");
      _expectAnchor(_kExtraFxDart, "playerId == null ? null : {'playerId': playerId}");
      // 服务侧的唯二推送点
      _expectAnchor(_kPlayerService, 'SpectrumEngine.instance.setTargetPlayerId(id)');
      _expectAnchor(_kPlayerService, 'EqEngine.instance.ensure(playerId: id)');
      _expectAnchor(_kPlayerService, 'ExtraFxEngine.instance.ensure(playerId: id)');
      // 缺省（不带身份）时仍然是老调用姿势 ⇒ 行为与改造前逐项一致
      _expectAnchor(_kEqDart, 'Future<void> ensure({bool force = false, String? playerId})');
      _expectAnchor(_kExtraFxDart, 'Future<void> ensure({bool force = false, String? playerId})');
    });

    test('⑦ 接线确实做完了（阶段 2 那三条"不许接线"的围栏已经翻转）', () {
      final ps = _read(_kPlayerService);
      expect(ps.contains("import 'playback/crossfade.dart';"), isTrue);
      expect(ps.contains("import 'playback/prefetch.dart';"), isTrue);
      expect(_read(_kCrossfadeDart).contains('本文件当前【没有任何调用点】'), isFalse,
          reason: 'crossfade.dart 的文件头还写着"没有调用点" —— 接线完了要一起更新，'
              '否则下一个人会以为它还是死的');
      expect(_read(_kPrefetchDart).contains('本文件当前【没有任何调用点】'), isFalse,
          reason: 'prefetch.dart 同上');
    });
  });

  group('模型的边界（别把模型本身写错，否则上面的判据是假的）', () {
    test('登记表初值：查不到就是 -1（原生据此报 available=false）', () {
      final reg = AudioSessionRegistry();
      expect(reg.sessionOf('nobody'), -1);
      expect(reg.sessionOf(null), -1);
      expect(reg.legacySlot, -1);
      expect(reg.lastWriter, isNull);
    });

    test('同一个 playerId 覆盖写：拿到的是最新那个 session', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      reg.put(a);
      a.sessionId = 505;
      reg.put(a);
      expect(reg.sessionOf('uuid-A'), 505);
    });

    test('detach 之后再 matchesActive 恒为 false（别留下"看起来还挂着"的状态）', () {
      final reg = AudioSessionRegistry();
      final a = NativePlayerHandle('A', playerId: 'uuid-A', sessionId: 101);
      final eq = EqualizerLike();
      reg.put(a);
      eq.attach(reg, playerId: 'uuid-A');
      eq.detach();
      expect(eq.attachedSession, -1);
      expect(eq.attachedPlayerId, isNull);
      expect(eq.matchesActive(a), isFalse);
    });
  });
}

/// 把 `///` 文档注释与 `/* */` 去掉（只留代码），供"数实例化点"这类计数用。
///
/// 为什么要剥注释：`player_service.dart` 的文档注释里就写着 `AudioPlayer()` 这个形状
/// —— 直接数文本会把它算成第二个实例化点。
String _codeOnly(String src) => src
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .split('\n')
    .where((l) => !l.trimLeft().startsWith('///'))
    .join('\n');
