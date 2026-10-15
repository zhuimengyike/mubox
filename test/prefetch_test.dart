/// `lib/playback/prefetch.dart` 的用例 —— 预取窗口、预取目标、失败退避。
///
/// ⚠️ **阶段 2b 起这个模块已经接线**（`lib/player_service.dart` 的 `_tickDual()`）。
/// 阶段 2 时它接不上，因为预取的定义就是「给另一个还没播的播放器 `setSource`」，
/// 而那时 `MediaPlayerWrapper.setSource()` 会把**全进程唯一**的
/// `AudioSessionProvider.sessionId` 抢走 ⇒ 预取与双播放器踩同一个雷。
/// 现在原生侧改成了 **per-player 登记表**（`AudioSessionProvider.put/sessionOf`），
/// 三个引擎按身份取 session，接线的前提才成立。
///
/// 这里测的仍然是**判定**，不是播放（播放那条路在
/// `test/player_service_crossfade_test.dart`，用假播放器驱动真服务）。`testWidgets` = 0。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/playback/crossfade.dart';
import 'package:mu_box_phone/playback/prefetch.dart';
import 'package:mu_box_phone/volume_fade.dart';

/// 改动前那条路的"预取策略"：**没有预取**。任何时刻都返回"不动手"。
/// 这就是负向对照的基准 —— 新断言必须能把它和真预取区分开。
PrefetchDecision _legacyDecide() => PrefetchDecision.idle;

/// 一条 4 分钟的歌、下一首 3 分钟的开始位置（离曲末 10 秒）。
const _total = Duration(minutes: 4);
const _next = Duration(minutes: 3);
Duration _posLeft(Duration left) => _total - left;

void main() {
  group('预取窗口：与交叉淡变同一个窗口（不许各算一套）', () {
    test('离曲末 10 秒：不在窗口内（还早，白占一个解码器）', () {
      final d = PrefetchPolicy.decide(
        tick: 1,
        pos: _posLeft(const Duration(seconds: 10)),
        total: _total,
        nextDuration: _next,
        nextIndex: 1,
        queueLength: 5,
      );
      expect(d.shouldPrefetch, isFalse);
      expect(d.slotIndex, -1);
      expect(d, PrefetchDecision.idle);
    });

    test('★ 窗口边界 = 交叉淡变的 lead（含 500ms 一拍容差）', () {
      final plan = CrossfadePlan.standard;
      final w = PrefetchPolicy.window(
        pos: _posLeft(plan.lead),
        total: _total,
        nextDuration: _next,
      );
      expect(w.inWindow, isTrue);
      expect(w.lead, plan.lead, reason: '预取与淡变必须用同一个 lead，否则会各算一套');
      expect(
        PrefetchPolicy.window(
          pos: _posLeft(plan.lead + const Duration(milliseconds: 1)),
          total: _total,
          nextDuration: _next,
        ).inWindow,
        isFalse,
      );
    });

    test('进窗口 ⇒ 预取，且目标下标就是传进来的下一个', () {
      final d = PrefetchPolicy.decide(
        tick: 5,
        pos: _posLeft(const Duration(milliseconds: 700)),
        total: _total,
        nextDuration: _next,
        nextIndex: 3,
        queueLength: 5,
      );
      expect(d.shouldPrefetch, isTrue);
      expect(d.slotIndex, 3);
      expect(d.retryAfterTick, 0);
    });

    test('时长未知 / 下一首太短 / 关闭态 ⇒ 不预取（与淡变同一条口径）', () {
      final pos = _posLeft(const Duration(milliseconds: 700));
      // 总时长未知
      expect(
        PrefetchPolicy.decide(
          tick: 1,
          pos: pos,
          total: Duration.zero,
          nextDuration: _next,
          nextIndex: 1,
          queueLength: 5,
        ).shouldPrefetch,
        isFalse,
      );
      // 下一首时长未知
      expect(
        PrefetchPolicy.decide(
          tick: 1,
          pos: pos,
          total: _total,
          nextDuration: Duration.zero,
          nextIndex: 1,
          queueLength: 5,
        ).shouldPrefetch,
        isFalse,
      );
      // 下一首比淡变还短
      expect(
        PrefetchPolicy.decide(
          tick: 1,
          pos: pos,
          total: _total,
          nextDuration: const Duration(milliseconds: 100),
          nextIndex: 1,
          queueLength: 5,
        ).shouldPrefetch,
        isFalse,
      );
    });

    test('已经装好了同一首 ⇒ 不再 setSource（重复 setSource 会再抢一次全局 session）', () {
      final d = PrefetchPolicy.decide(
        tick: 5,
        pos: _posLeft(const Duration(milliseconds: 700)),
        total: _total,
        nextDuration: _next,
        nextIndex: 3,
        queueLength: 5,
        alreadyLoaded: true,
      );
      expect(d.shouldPrefetch, isFalse);
    });

    test('tick 为负（异常入参）⇒ 不动手', () {
      expect(
        PrefetchPolicy.decide(
          tick: -1,
          pos: _posLeft(const Duration(milliseconds: 700)),
          total: _total,
          nextDuration: _next,
          nextIndex: 1,
          queueLength: 5,
        ),
        PrefetchDecision.idle,
      );
    });
  });

  group('预取目标：必须与"真到曲末时 next() 会选中的那首"逐项相同', () {
    test('合法下标原样返回', () {
      expect(PrefetchPolicy.targetIndex(2, 5), 2);
      expect(PrefetchPolicy.targetIndex(0, 1), 0);
    });

    test('空队列 / 越界 / 负数 ⇒ -1（不许自己夹成 0，那会预取错歌）', () {
      expect(PrefetchPolicy.targetIndex(0, 0), -1);
      expect(PrefetchPolicy.targetIndex(-1, 5), -1);
      expect(PrefetchPolicy.targetIndex(5, 5), -1);
      expect(PrefetchPolicy.targetIndex(99, 5), -1);
    });

    test('★ 负向对照：单曲循环（nextIndex 指向自己）时预取自己 —— 由调用方负责不传这种值', () {
      // 这条不是"要求 targetIndex 处理单曲循环"，而是把口径钉死：
      // targetIndex 只做范围校验，**不猜语义**。单曲循环该不该预取由接线那一层决定
      // （现状 `player_service.dart:687-693` 是 `playAt(index)` 重载同一首）。
      expect(PrefetchPolicy.targetIndex(2, 5), 2);
      // 若真去预取"自己"，就是又一次无谓的 setSource → 再抢一次全局 session。
      // 所以这条断言是提醒：调用方必须显式排除 nextIndex == index 的情形。
      expect(PrefetchPolicy.targetIndex(2, 5) == 2, isTrue);
    });
  });

  group('失败退避：损坏的歌不许一直重试到曲末', () {
    PrefetchDecision at(int tick, {required int failures, required int lastFail}) =>
        PrefetchPolicy.decide(
          tick: tick,
          pos: _posLeft(const Duration(milliseconds: 700)),
          total: _total,
          nextDuration: _next,
          nextIndex: 1,
          queueLength: 5,
          failures: failures,
          lastFailTick: lastFail,
        );

    test('退避窗口内不动手，并说出"还差到哪一拍"', () {
      final d = at(10, failures: 1, lastFail: 10);
      expect(d.shouldPrefetch, isFalse);
      expect(d.slotIndex, -1);
      expect(d.retryAfterTick, 11, reason: '1 次失败 = 退避 1 拍');
    });

    test('退避拍数是指数的：1、2、4、8→封顶 5', () {
      expect(at(20, failures: 1, lastFail: 20).retryAfterTick, 21);
      expect(at(20, failures: 2, lastFail: 20).retryAfterTick, 22);
      expect(at(20, failures: 3, lastFail: 20).retryAfterTick, 24);
      expect(at(20, failures: 4, lastFail: 20).retryAfterTick, 25);
    });

    test('退避到点 ⇒ 再试一次', () {
      expect(at(11, failures: 1, lastFail: 10).shouldPrefetch, isTrue);
      expect(at(30, failures: 3, lastFail: 20).shouldPrefetch, isTrue);
    });

    test('连续失败到上限 ⇒ 彻底放弃（不再重试，等下一次切歌重置）', () {
      final d = at(999, failures: kPrefetchMaxRetryTicks, lastFail: 900);
      expect(d, PrefetchDecision.idle);
      expect(d.shouldPrefetch, isFalse);
      expect(d.retryAfterTick, 0);
    });

    test('★ 负向对照：没有退避的旧写法会一拍不落地重试 —— 两者必须不同', () {
      // 旧写法（没有预取，也就没有退避）：任何时候都"不动手"。
      // 新写法在退避窗口内同样"不动手"，但窗口外必须动手 ⇒ 两者可区分。
      expect(_legacyDecide(), PrefetchDecision.idle);
      expect(at(10, failures: 1, lastFail: 10), isNot(PrefetchDecision.idle),
          reason: '退避中的决策必须带上 retryAfterTick，否则和"永远不预取"分不开');
      expect(at(11, failures: 1, lastFail: 10).shouldPrefetch, isTrue,
          reason: '退避到点就得动手，否则退避写成了"永不重试"');
    });
  });

  group('源码围栏：已接线 —— 只许 player_service.dart 接（阶段 2b 拆掉了旧围栏）', () {
    /// 某个 .dart 的源码里有没有 import `lib/<name>`（包导入 + 相对导入，任意深度）。
    bool importsLib(String path, String src, String name) {
      for (final m in RegExp(r"""import\s+'([^']+)'""").allMatches(src)) {
        if (_resolveImport(path, m.group(1)!) == 'lib/$name') return true;
      }
      return false;
    }

    test('检测器本身有牙：造一个"接了线"的样本，它必须报 true', () {
      // ⚠️ 三种写法都要认：Dart 里 `import 'playback/x.dart';` 也是合法的相对导入
      // （不带前导 `./`）—— 第一版只认 `.` 开头，把这种写法漏成了"没接线"（已实测）。
      expect(importsLib('lib/player_service.dart', "import 'playback/prefetch.dart';", 'playback/prefetch.dart'),
          isTrue);
      expect(importsLib('lib/player_service.dart', "import './playback/prefetch.dart';", 'playback/prefetch.dart'),
          isTrue);
      expect(importsLib('lib/pages/root_page.dart', "import '../playback/prefetch.dart';", 'playback/prefetch.dart'),
          isTrue);
      expect(
        importsLib('lib/player_service.dart',
            "import 'package:mu_box_phone/playback/prefetch.dart';", 'playback/prefetch.dart'),
        isTrue,
      );
      // 反向：隔壁模块 / dart: / package: 别的包 ⇒ 不算接线
      expect(importsLib('lib/playback/crossfade.dart', "import '../volume_fade.dart';", 'playback/prefetch.dart'),
          isFalse);
      expect(importsLib('lib/playback/prefetch.dart', "import 'crossfade.dart';", 'playback/prefetch.dart'),
          isFalse);
      expect(importsLib('lib/x.dart', "import 'dart:io';", 'playback/prefetch.dart'), isFalse);
      expect(importsLib('lib/x.dart', "import 'package:flutter_test/flutter_test.dart';", 'playback/prefetch.dart'),
          isFalse);
    });

    test('只有 player_service.dart 接了预取（唯一接线点），而且真的接上了', () {
      final hits = _libImportersOf('playback/prefetch.dart');
      expect(
        hits..sort(),
        ['lib/player_service.dart'],
        reason: '预取的**唯一**接线点 = lib/player_service.dart（`_tickDual()` 里调 '
            'PrefetchPolicy.decide；真的 setSource 在 `_prefetch()`）。\n'
            '多出来的文件说明有人另接了一套（两套窗口/退避一定对不齐）。',
      );
      expect(
        File('lib/player_service.dart').readAsStringSync().contains('PrefetchPolicy'),
        isTrue,
        reason: '围栏翻转之后必须真的接上：没有 PrefetchPolicy 就说明接线被拆了',
      );
    });

    test('预取的唯一执行点是 player_service 的 _prefetch()，而且只碰**空闲**那一副', () {
      final src = File('lib/player_service.dart').readAsStringSync();
      final i = src.indexOf('Future<void> _prefetch(');
      expect(i, greaterThanOrEqualTo(0), reason: '_prefetch() 没了 ⇒ 接线被拆了');
      final body = src.substring(i, src.indexOf('\n  }', i));
      expect(body.contains('_ensureDeckB()'), isTrue,
          reason: '预取要落到**第二副**牌上（懒建），不是在场那一副');
      expect(body.contains('_idle'), isTrue,
          reason: '预取期间要确认还是那一副空闲的（await 期间可能已经换场）');
      expect(body.contains('_cur'), isFalse,
          reason: '★ 预取绝不许碰在场的那一副：碰了就是"把正在播的打断"');
      expect(body.contains('resume'), isFalse,
          reason: '★ 预取只 setSource 不播（resume 是换场那一刻才发的）——'
              '这里出现 resume 就是"预取偷偷开播"，两首歌会一起响');
    });

    test('预取窗口的 lead 就是交叉淡变的 lead（不许各写一个常量）', () {
      final src = File('lib/playback/prefetch.dart').readAsStringSync();
      expect(src.contains('plan.lead'), isTrue,
          reason: '窗口必须从 CrossfadePlan 取 lead —— 抄一份常量下来迟早会与淡变脱节'
              '（预取早了白占解码器，晚了等于没预取）');
      expect(RegExp(r'Duration\(milliseconds:\s*8\d\d\)').hasMatch(src), isFalse,
          reason: '出现了硬编码的窗口毫秒数：应当走 CrossfadePlan.lead');
      expect(kPrefetchMaxRetryTicks, 5);
      expect(kFadeStepMs, kCrossfadeStepMs, reason: '两套步进必须一致（台阶才对得齐）');
    });
  });
}

/// 把一条 import 的 URI 解析成 `lib/` 下的 posix 相对路径；解析不出来返回空串。
///
/// 三种形态都要认（第一版只认 `.` 开头，漏了 `import 'playback/x.dart';` 这种
/// **合法的无前导点相对导入** —— 那会让围栏静默失效）：
/// - `package:mu_box_phone/<rest>` → `lib/<rest>`
/// - `.` 开头 → 相对导入文件所在目录
/// - 其它不含 `:` 的裸路径 → 同样按相对导入处理（Dart 2+ 的语义）
/// - `dart:` / 别家 `package:` → 空串（与本包无关）
String _resolveImport(String importerPath, String uri) {
  if (uri.startsWith('dart:')) return '';
  if (uri.startsWith('package:')) {
    const self = 'package:mu_box_phone/';
    if (!uri.startsWith(self)) return '';
    return 'lib/${uri.substring(self.length)}';
  }
  if (uri.contains(':')) return '';
  final dir = importerPath.substring(0, importerPath.lastIndexOf('/'));
  return _normalizePosix('$dir/$uri');
}

/// 去掉 `.` / `..` 段，统一成 posix 风格（Windows 上跑也是同一个键）。
String _normalizePosix(String path) {
  final out = <String>[];
  for (final seg in path.replaceAll(r'\', '/').split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
      continue;
    }
    out.add(seg);
  }
  return out.join('/');
}

/// `lib/` 下所有 import 了 `lib/<name>` 的文件（排除它自己）。
///
/// ⚠️ 断言按**解析后的路径**算，不是"源码里出现过这个词" —— 否则
/// `crossfade_test.dart` 这种文件名就会把围栏误判成"接了线"。
List<String> _libImportersOf(String name) {
  final hits = <String>[];
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final p = e.path.replaceAll(r'\', '/');
    if (p.endsWith('lib/$name')) continue; // 自己不算
    final src = e.readAsStringSync();
    for (final m in RegExp(r"""import\s+'([^']+)'""").allMatches(src)) {
      if (_resolveImport(p, m.group(1)!) == 'lib/$name') {
        hits.add(p);
        break;
      }
    }
  }
  return hits;
}
