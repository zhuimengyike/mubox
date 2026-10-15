/// `lib/playback/crossfade.dart` 的用例 —— 曲线、时序窗口、以及「线性 ⇒ 零削波」那条
/// 可以**数学证明**的性质。
///
/// ⚠️ 本文件里同时有两种测试，别混：
/// - **正向**：交叉淡变自己的性质（端点、互补、不削波、窗口容差）；
/// - **负向对照**：把"改动前那条路"（硬停 + 180ms 淡入）整个复刻一遍，证明
///   **新的断言确实有牙** —— 它必须能区分这两条路，否则就是一把没牙的尺子。
///
/// 本仓 `testWidgets` = 0，这条线也不破例：交叉淡变全部走纯函数，零 Flutter 依赖。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/playback/crossfade.dart';
import 'package:mu_box_phone/volume_fade.dart';

/// 改动前那条路（`player_service.dart` 的 `_loadAndPlay`）：硬停上一首，
/// 新的一首从 0 淡入 180ms。**这就是"逐帧一致"要对比的基准**。
List<double> _legacyPathIncoming() =>
    fadeSequence(from: 0, to: 1.0, d: const Duration(milliseconds: 180));

/// 交叉淡变上场那一路。
List<double> _crossfadeIncoming() =>
    crossfadeCurves(fromLeft: 1.0, duration: kCrossfadeTime).inRight;

void main() {
  group('时序窗口：什么时候该开始淡出', () {
    const plan = CrossfadePlan.standard; // 300ms + 500ms 一拍 = lead 816ms
    const total = Duration(minutes: 4);
    const next = Duration(minutes: 3);

    test('离曲末还有 1 秒：还不该开始（提前太多 = 歌被提前切掉）', () {
      expect(
        plan.shouldStart(
          pos: total - const Duration(seconds: 1),
          total: total,
          nextDuration: next,
          atEnd: true,
        ),
        isFalse,
      );
    });

    test('★ 提前量 = 淡变实际总时长 + 一拍 tick（500ms）', () {
      expect(plan.effectiveDuration, const Duration(milliseconds: 304));
      expect(plan.lead, const Duration(milliseconds: 804));
      // 恰好落在窗口边界上：该开始
      expect(
        plan.shouldStart(
          pos: total - plan.lead,
          total: total,
          nextDuration: next,
          atEnd: true,
        ),
        isTrue,
      );
      // 差 1ms 还没进窗口
      expect(
        plan.shouldStart(
          pos: total - plan.lead - const Duration(milliseconds: 1),
          total: total,
          nextDuration: next,
          atEnd: true,
        ),
        isFalse,
      );
    });

    test('★ 500ms 一拍的位置 tick 也能踩上：不至于"永远差半秒"', () {
      // 模拟真实 tick：每 500ms 报一次位置，从曲末往前扫
      var firedAt = -1;
      for (var left = 3000; left >= 0; left -= kPositionTickMs) {
        if (plan.shouldStart(
          pos: total - Duration(milliseconds: left),
          total: total,
          nextDuration: next,
          atEnd: true,
        )) {
          firedAt = left;
          break;
        }
      }
      expect(firedAt, greaterThanOrEqualTo(0), reason: '整首歌都没触发，淡变永远不会开始');
      // 触发时离曲末必须还有富余（否则 B 还没 prepare 完 A 就没了）
      expect(firedAt, greaterThanOrEqualTo(plan.effectiveDuration.inMilliseconds));
    });

    test('已经过点（pos > total）不再起一轮淡变', () {
      expect(
        plan.shouldStart(
          pos: total + const Duration(seconds: 1),
          total: total,
          nextDuration: next,
          atEnd: true,
        ),
        isFalse,
      );
    });

    test('用户手点「下一首」（atEnd = false）⇒ 立刻响，不等 300ms', () {
      expect(
        plan.shouldStart(
          pos: total - const Duration(milliseconds: 50),
          total: total,
          nextDuration: next,
          atEnd: false,
        ),
        isFalse,
        reason: '手动切歌先等 300ms 淡出 = 手感变迟钝，那是改观感',
      );
    });

    test('时长未知 / 下一首太短 / 关闭态 ⇒ 一律不淡变', () {
      const inWindow = Duration(seconds: 10);
      // 总时长未知（手动扫进来的歌一开始就是 0）
      expect(
        plan.shouldStart(
          pos: Duration.zero,
          total: Duration.zero,
          nextDuration: next,
          atEnd: true,
        ),
        isFalse,
      );
      // 下一首时长未知
      expect(
        plan.shouldStart(
          pos: total - inWindow,
          total: total,
          nextDuration: Duration.zero,
          atEnd: true,
        ),
        isFalse,
      );
      // 下一首比淡变还短：淡完它自己就结束了 ⇒ 两首歌同时在响
      expect(
        plan.shouldStart(
          pos: total - inWindow,
          total: total,
          nextDuration: const Duration(milliseconds: 200),
          atEnd: true,
        ),
        isFalse,
      );
      // 关闭态（Duration.zero）
      expect(
        CrossfadePlan.off.shouldStart(
          pos: total - inWindow,
          total: total,
          nextDuration: next,
          atEnd: true,
        ),
        isFalse,
      );
      expect(CrossfadePlan.off.enabled, isFalse);
      expect(CrossfadePlan.standard.enabled, isTrue);
    });

    test('timeUntilStart 的符号：进窗口为负、没进为正', () {
      expect(plan.timeUntilStart(pos: total - const Duration(seconds: 5), total: total),
          greaterThan(Duration.zero));
      expect(plan.timeUntilStart(pos: total - plan.lead, total: total),
          Duration.zero);
      expect(plan.timeUntilStart(pos: total - const Duration(milliseconds: 100), total: total),
          lessThan(Duration.zero));
    });
  });

  group('★ 端点精确：A 精确到 0.0、B 精确到 1.0（硬不变量的同源要求）', () {
    test('退场那一路末项精确等于 0.0', () {
      for (final ms in [1, 16, 17, 100, 180, 300, 999, 1000]) {
        final c = crossfadeCurves(
          fromLeft: 1.0,
          duration: Duration(milliseconds: ms),
        );
        expect(c.outLeft.last, 0.0, reason: '$ms ms：退场没静音，交接点会留下残响');
      }
    });

    test('上场那一路末项精确等于 1.0（这就是"每次淡变结束音量必须回到 1.0"）', () {
      for (final ms in [1, 16, 17, 100, 180, 300, 999, 1000]) {
        final c = crossfadeCurves(
          fromLeft: 1.0,
          duration: Duration(milliseconds: ms),
        );
        expect(c.inRight.last, 1.0, reason: '$ms ms：没回到 1.0 ⇒ 越听越小声（本项目血债）');
      }
    });

    test('两条序列等长，长度 = 步数 + 1（起点那一项也在里面）', () {
      final c = crossfadeCurves(fromLeft: 1.0, duration: kCrossfadeTime);
      expect(c.length, 1 + fadeSteps(kCrossfadeTime));
      expect(c.outLeft.length, c.inRight.length);
      expect(c.outLeft.first, 1.0, reason: '起点必须是 A 现在的真实音量');
      expect(c.inRight.first, 0.0, reason: '起点必须是静音，否则 B 会"蹦"一下');
    });

    test('fromLeft 传真实残留音量时起点跟着走（被打断过的淡变不留台阶）', () {
      final c = crossfadeCurves(
        fromLeft: 0.42,
        duration: const Duration(milliseconds: 180),
      );
      expect(c.outLeft.first, 0.42);
    });

    test('越界入参被夹进 0..1', () {
      final c = crossfadeCurves(
        fromLeft: -5,
        duration: const Duration(milliseconds: 64),
        toRight: 9,
      );
      for (final v in c.outLeft) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
      for (final v in c.inRight) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
      expect(c.outLeft.first, 0.0);
      expect(c.inRight.last, 1.0);
    });
  });

  group('★ 线性互补 ⇒ 零削波（这是选线性曲线的唯一理由）', () {
    test('a + b 恒等于 1.0（逐点，精确）', () {
      final c = crossfadeCurves(fromLeft: 1.0, duration: kCrossfadeTime);
      for (var i = 0; i < c.length; i++) {
        expect(
          c.outLeft[i] + c.inRight[i],
          1.0,
          reason: '第 $i 步不互补：两路叠加会越过满刻度或掉音量',
        );
      }
    });

    test('峰值和 == 1.0（不削波是结构性结论，不是"大概不会")', () {
      expect(
        crossfadeCurves(fromLeft: 1.0, duration: kCrossfadeTime).peakSum,
        1.0,
      );
    });

    test('★ 负向对照：等功率（sin/cos）曲线在中点会到 1.414 ⇒ 有削波风险', () {
      // 这不是"另一种选择"，这是**被否掉的那一种**：写在这儿是为了让后来人
      // 想换曲线时先看到代价。同样 300ms 的淡变，改成等功率曲线量峰值和。
      final steps = fadeSteps(kCrossfadeTime);
      var peak = 0.0;
      for (var i = 0; i <= steps; i++) {
        final t = i / steps;
        final s = _equalPowerOut(t) + _equalPowerIn(t);
        if (s > peak) peak = s;
      }
      expect(peak, greaterThan(1.4),
          reason: '等功率曲线中点应当接近 √2 ≈ 1.414（这就是它会被削波的原因）');
      // 而线性曲线一个点都不过 1.0
      final lin = crossfadeCurves(fromLeft: 1.0, duration: kCrossfadeTime);
      for (var i = 0; i < lin.length; i++) {
        expect(lin.outLeft[i] + lin.inRight[i], lessThanOrEqualTo(1.0));
      }
      expect(lin.peakSum, lessThan(peak),
          reason: '线性必须严格优于等功率，否则这段对照没有意义');
    });

    test('fromLeft < 1（A 还在淡入途中就被切）时峰值和只会更低，绝不更高', () {
      for (final f in [0.0, 0.2, 0.5, 0.9, 1.0]) {
        final c = crossfadeCurves(
          fromLeft: f,
          duration: kCrossfadeTime,
        );
        expect(c.peakSum, lessThanOrEqualTo(1.0), reason: 'fromLeft=$f');
      }
    });

    test('单调且不过冲：A 递减、B 递增，全程 0..1', () {
      final c = crossfadeCurves(fromLeft: 0.8, duration: kCrossfadeTime);
      for (var i = 1; i < c.length; i++) {
        expect(c.outLeft[i], lessThanOrEqualTo(c.outLeft[i - 1]));
        expect(c.inRight[i], greaterThanOrEqualTo(c.inRight[i - 1]));
        expect(c.outLeft[i], inInclusiveRange(0.0, 1.0));
        expect(c.inRight[i], inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('★ 负向对照：证明这把尺子有牙（先收刀，看它红不红）', () {
    test('进场曲线 != 改动前那条（否则"淡变"根本没发生，用例却全绿）', () {
      final legacy = _legacyPathIncoming(); // 180ms 淡入，12 步
      final cross = _crossfadeIncoming(); // 300ms，19 步
      expect(
        cross.length == legacy.length && _sameUpTo(cross, legacy),
        isFalse,
        reason: '交叉淡变的进场曲线与改动前的 180ms 淡入逐项相同 —— '
            '那说明"淡变"这两个字是空的，用例再多也证明不了任何事',
      );
    });

    test('★ 关键负向：把时序窗口还原成旧行为（不预留一拍 tick），这条用例当场红', () {
      // 旧行为：按 pos + 淡变时长 == 总时长 卡点（不留 tick 容差）
      bool legacyShouldStart(Duration pos, Duration total) =>
          pos + kCrossfadeTime >= total;

      const total = Duration(minutes: 4);
      const next = Duration(minutes: 3);
      // 造一个"真实 tick 落在窗口外侧"的位置：离曲末 600ms
      final pos = total - const Duration(milliseconds: 600);

      expect(
        CrossfadePlan.standard.shouldStart(
          pos: pos,
          total: total,
          nextDuration: next,
          atEnd: true,
        ),
        isTrue,
        reason: '新实现应当在这一拍就触发（窗口含一拍容差）',
      );
      expect(
        legacyShouldStart(pos, total),
        isFalse,
        reason: '旧实现（无容差）在这一拍还不触发 —— 两者必须不同，'
            '否则上面那条"有容差"的判据是没牙的',
      );
    });

    test('★ 关键负向：退场一路若不自证"末项 0.0"，旧路径的写法会漏掉', () {
      // 旧路径根本没有"退场曲线"（硬停），所以随便造一条非零收敛的假曲线，
      // 断言本文件的断言能把它抓出来 —— 这就是"按整条路还原"的对照。
      final fake = <double>[1.0, 0.5, 0.25, 0.125]; // 只衰减不复位
      expect(fake.last, isNot(0.0));
      expect(
        () => expect(fake.last, 0.0),
        throwsA(isA<TestFailure>()),
        reason: '末项不为 0 的假曲线必须被 [0.0] 这条判据判红（否则"末项 0.0"是句空话）',
      );
    });
  });

  group('源码围栏：已接线 —— 只许 player_service.dart 接（阶段 2b 拆掉了旧围栏）', () {
    const selfPath = 'lib/playback/crossfade.dart';
    // 阶段 2 那三条围栏里的一条：当时**任何产品文件都不许 import 本文件**，
    // 因为接上就得有第二个 AudioPlayer，而它的 setSource 会抢走全进程唯一的
    // session 格子 ⇒ 频谱停摆 + EQ/低音/响度静默失效。
    // 阶段 2b 把「per-player session 查询通道」做出来之后，这条围栏**翻转**成：
    // 接线点是唯一的（player_service.dart），别人不许再各接一套。
    const allowed = {
      'lib/player_service.dart', // ★ 唯一允许接线的地方
      'lib/playback/prefetch.dart', // 与本文件共用同一个窗口
      'lib/playback/audio_session.dart', // 原生会话归属的可执行规格
    };

    test('只有 player_service.dart 接了交叉淡变（别处各接一套 = 两套时序）', () {
      final hits = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final p = e.path.replaceAll(r'\', '/');
        if (p == selfPath || allowed.contains(p)) continue;
        final src = e.readAsStringSync();
        for (final m in RegExp(r"""import\s+'([^']+)'""").allMatches(src)) {
          if (_resolveImport(p, m.group(1)!) == selfPath) {
            hits.add(p);
            break;
          }
        }
      }
      expect(
        hits,
        isEmpty,
        reason: '交叉淡变被接进了这些文件：$hits。\n'
            '**唯一接线点 = lib/player_service.dart**（`_tickDual()` → `playAt(crossfade:)`）'
            '—— 接线本身现在允许了（per-player session 已经做好），但两套时序一定对不齐。',
      );
      expect(
        File('lib/player_service.dart').readAsStringSync().contains("import 'playback/crossfade.dart';"),
        isTrue,
        reason: '围栏翻转之后必须**真的接上**：player_service.dart 里没有这条 import，'
            '说明有人把接线又拆了（那本组用例就只剩"没接线"这一个结论）',
      );
    });

    test('围栏检测器本身有牙：三种 import 写法都要认，隔壁模块不算', () {
      // ⚠️ `import 'playback/x.dart';`（无前导点）在 Dart 里也是合法相对导入 ——
      // 第一版只认 `.` 开头，把它漏成了"没接线"（已实测）。
      expect(_isWired("import 'playback/crossfade.dart';", 'lib/player_service.dart'),
          isTrue);
      expect(_isWired("import './playback/crossfade.dart';", 'lib/player_service.dart'),
          isTrue);
      expect(_isWired("import '../playback/crossfade.dart';", 'lib/pages/root_page.dart'),
          isTrue);
      expect(
        _isWired("import 'package:mu_box_phone/playback/crossfade.dart';",
            'lib/player_service.dart'),
        isTrue,
      );
      // 反向：隔壁模块 / dart: / 别家 package ⇒ 不算接线
      expect(_isWired("import '../volume_fade.dart';", 'lib/playback/prefetch.dart'), isFalse);
      expect(_isWired("import 'dart:io';", 'lib/x.dart'), isFalse);
      expect(_isWired("import 'package:flutter_test/flutter_test.dart';", 'lib/x.dart'), isFalse);
      // ⚠️ 但 `lib/playback/prefetch.dart` 里写 `import 'crossfade.dart';` **算接线**
      // —— 它确实解析到 lib/playback/crossfade.dart。prefetch_test 里那条
      // 「只有 player_service 接」的对照就是靠这个分辨率的。
      expect(_isWired("import 'crossfade.dart';", 'lib/playback/prefetch.dart'), isTrue);
    });

    test('接线点在真身里：开关 + 换场 + 硬切兜底三件事都在同一个文件里', () {
      final src = File('lib/player_service.dart').readAsStringSync();
      expect(src.contains('CrossfadePlan'), isTrue, reason: '窗口/时长判定必须走本文件的纯函数');
      // 总闸：缺省关闭（缺省值下逐项等价改动前的落点）
      expect(src.contains('AppConfig.instance.crossfadeEnabled'), isTrue,
          reason: '接线必须挂在 AppConfig 的开关上（默认关闭）');
      // 关掉时"第二个播放器根本不会被创建"：懒建入口只有一处
      expect(src.contains('_ensureDeckB()'), isTrue);
      // 换场与打断两条路都要有
      expect(src.contains('_crossfadeTo('), isTrue);
      expect(src.contains('_abortCrossfade('), isTrue);
    });
  });
}

/// 去掉 `.` / `..` 段，统一成 posix 风格。
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

/// 把 import 的 URI 解析成 `lib/` 下的 posix 路径（与 prefetch_test 里那份同源）。
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

/// 这段 import 语句算不算"接上了交叉淡变"。
bool _isWired(String src, String importerPath) {
  for (final m in RegExp(r"""import\s+'([^']+)'""").allMatches(src)) {
    if (_resolveImport(importerPath, m.group(1)!) == 'lib/playback/crossfade.dart') {
      return true;
    }
  }
  return false;
}

/// 等功率曲线的两路（只为上面那条负向对照服务，产品代码里没有它们）。
double _equalPowerOut(double t) => math.cos(t * math.pi / 2);

double _equalPowerIn(double t) => math.sin(t * math.pi / 2);

bool _sameUpTo(List<double> a, List<double> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
