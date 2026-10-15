/// 频谱断流看门狗（`lib/playback/spectrum_watchdog.dart`）的断言 + 接线护栏。
///
/// 背景：症状是「app 认为还在播放音乐，其实**频谱没在跳舞**」。FFT 是原生回调推的，
/// Dart 侧此前**没有任何"多久没收到帧"的断言**
/// ⇒ 回调链一停，界面就把最后一帧当"还在跳"永远画下去。这个文件钉三件事：
///
/// 1. **行为本身**（纯 Dart，时钟注入）：宽限期 / 边界 / 回活 / 自愈节流；
/// 2. **有牙**：同一段"帧停了"的脚本，**旧规则**（只要 `active` 就算活着）必须
///    停在冻结那一帧，**新规则**必须落回静止基座 —— 两条对照都写出来，
///    谁也糊不过去；
/// 3. **接线**：`spectrum.dart` 里旧那句 `if (active) return;` 必须**已经不在了**，
///    换成带 `stalled` 的判定（有人手一滑改回去，这里当场红）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/playback/spectrum_watchdog.dart';

/// 可控时钟：单测里"等 10 秒"就是 `clock.advance(10s)`，不许真的 sleep。
class _FakeClock {
  DateTime now = DateTime(2026, 10, 2, 8, 0, 0);
  DateTime call() => now;
  void advance(Duration d) => now = now.add(d);
}

/// 复刻 `SpectrumView._onTick` 的**帧基**衰减（`_peakDecay = 0.93`，<0.005 归零）。
/// 只复刻到"柱子主体"这一半 —— 峰值残响的回落在两种规则下都跑，与本次判定无关。
void _decayStep(List<double> smoothed) {
  for (var i = 0; i < smoothed.length; i++) {
    final v = smoothed[i] * 0.93;
    smoothed[i] = v < 0.005 ? 0.0 : v;
  }
}

/// 旧规则（改动前）的一拍：引擎"订阅着"就直接返回，**不问帧**。
void _oldTick(List<double> smoothed, {required bool active}) {
  if (active) return;
  _decayStep(smoothed);
}

/// 新规则（改动后）的一拍：`active && !stalled` 才返回。
void _newTick(
  List<double> smoothed, {
  required bool active,
  required bool stalled,
}) {
  if (active && !stalled) return;
  _decayStep(smoothed);
}

void main() {
  group('判定（正/负向）', () {
    test('★ 正向：每 50ms 一帧地喂 10 秒 ⇒ 从不断流、从不要自愈', () {
      final c = _FakeClock();
      final w = SpectrumWatchdog(clock: c.call);
      for (var i = 0; i < 200; i++) {
        w.markFrame();
        expect(w.stalled, isFalse, reason: '第 $i 帧之后不该判断流');
        expect(w.shouldHeal, isFalse);
        c.advance(const Duration(milliseconds: 50));
      }
    });

    test('★ 正向：安静的间奏（帧照来、值全 0）不算断流 —— 判据只看帧来没来', () {
      final c = _FakeClock();
      final w = SpectrumWatchdog(clock: c.call);
      // 这 4 秒里"频谱全是 0"（安静），但原生照 20Hz 送帧
      for (var i = 0; i < 80; i++) {
        w.markFrame();
        c.advance(const Duration(milliseconds: 50));
      }
      expect(w.stalled, isFalse,
          reason: '静音的一拍不是断流 —— 否则安静的间奏会把柱子错误地清掉');
    });

    test('★ 负向：帧停了 1.9 秒还不断流、停到 2.1 秒才断（边界是 > 不是 >=）', () {
      final c = _FakeClock();
      final w = SpectrumWatchdog(clock: c.call);
      w.markFrame();
      c.advance(const Duration(milliseconds: 1900));
      expect(w.stalled, isFalse, reason: '1.9s < 2s：还没到判死的点');
      expect(w.shouldHeal, isFalse);
      c.advance(const Duration(milliseconds: 100)); // 正好 2.0s
      expect(w.stalled, isFalse, reason: '恰好等于 staleAfter：那一帧可能正在路上');
      c.advance(const Duration(milliseconds: 100)); // 2.1s
      expect(w.stalled, isTrue, reason: '2.1s > 2s：这就是断流');
      expect(w.shouldHeal, isTrue);
    });

    test('★ 负向：新订阅有 2 秒宽限期（否则每次换订都白重建一次 Visualizer）', () {
      final c = _FakeClock();
      final w = SpectrumWatchdog(clock: c.call);
      w.reset(); // 刚换订：原生要几百毫秒才有第一帧
      c.advance(const Duration(milliseconds: 900));
      expect(w.stalled, isFalse,
          reason: '刚订阅就判死 ⇒ 切歌后立刻白发一次重建（节流会把它变成"每次换订白重建一次"）');
      expect(w.shouldHeal, isFalse);
      c.advance(const Duration(seconds: 2)); // 订阅后 2.9s 仍然一帧没来
      expect(w.stalled, isTrue, reason: '过了宽限期还一帧没来 —— 这才该自愈');
      expect(w.shouldHeal, isTrue);
    });

    test('★ 正向：断流后收到一帧 ⇒ 立刻回活（不留滞后窗口）', () {
      final c = _FakeClock();
      final w = SpectrumWatchdog(clock: c.call);
      w.markFrame();
      c.advance(const Duration(seconds: 5));
      expect(w.stalled, isTrue);
      w.markFrame();
      expect(w.stalled, isFalse);
      expect(w.shouldHeal, isFalse);
      expect(w.lastFrameAt, c.now);
    });

    test('★ 正向：自愈节流 —— 15 秒内只准一次，过了才准下一次', () {
      final c = _FakeClock();
      final w = SpectrumWatchdog(clock: c.call);
      w.markFrame();
      c.advance(const Duration(seconds: 3));
      expect(w.shouldHeal, isTrue, reason: '第一次：没有历史，直接准');
      w.markHeal();
      expect(w.shouldHeal, isFalse, reason: '刚自愈完，不许再来');
      c.advance(const Duration(seconds: 14));
      expect(w.shouldHeal, isFalse, reason: '还差 1 秒');
      c.advance(const Duration(seconds: 1));
      expect(w.shouldHeal, isTrue, reason: '满 15 秒：准下一次');
      expect(w.untilHeal() <= Duration.zero, isTrue);
    });

    test('★ 负向：reset() 不许清掉自愈节流账（否则重建完立刻又重建）', () {
      final c = _FakeClock();
      final w = SpectrumWatchdog(clock: c.call);
      w.markFrame();
      c.advance(const Duration(seconds: 3));
      w.markHeal(); // 自愈：马上会 reset() 重订
      w.reset();
      c.advance(const Duration(seconds: 3)); // 重建后仍没帧
      expect(w.stalled, isTrue, reason: '一帧没来，仍然是断流');
      expect(w.shouldHeal, isFalse,
          reason: 'reset 顺手把节流账也清了的话，这里就会变成"重建→没帧→立刻再重建"的死循环');
    });

    test('★ 负向：连续 3 次自愈都换不来一帧 ⇒ 收手，不再无脑重建', () {
      final c = _FakeClock();
      final w = SpectrumWatchdog(clock: c.call);
      w.markFrame();
      for (var i = 1; i <= kSpectrumMaxHeals; i++) {
        c.advance(const Duration(seconds: 16)); // 越过节流窗口
        expect(w.shouldHeal, isTrue, reason: '第 $i 次自愈还该准');
        w.markHeal();
        w.reset(); // 自愈就是"重订"：原生重建完要几百毫秒才有帧
      }
      expect(w.healExhausted, isTrue);
      c.advance(const Duration(minutes: 10));
      expect(w.stalled, isTrue, reason: '一帧没来，仍然是断流');
      expect(w.shouldHeal, isFalse,
          reason: '上限的意义：持续性断流不许变成"一直播就一直每 17 秒重建一次"');
      expect(w.healsSinceFrame, kSpectrumMaxHeals);
    });

    test('★ 正向：收到一帧 ⇒ 自愈次数清零（节流窗口照旧要等满，别让打嗝变成风暴）', () {
      final c = _FakeClock();
      final w = SpectrumWatchdog(clock: c.call);
      w.markFrame();
      for (var i = 0; i < kSpectrumMaxHeals; i++) {
        c.advance(const Duration(seconds: 16));
        w.markHeal();
        w.reset();
      }
      expect(w.healExhausted, isTrue);
      w.markFrame(); // 帧终于来了
      expect(w.healExhausted, isFalse, reason: '收到帧 = 这条路又通了，次数重新起算');
      expect(w.stalled, isFalse);
      c.advance(const Duration(seconds: 5)); // 又断了（超过 staleAfter）
      expect(w.stalled, isTrue);
      expect(w.shouldHeal, isFalse,
          reason: '次数清零了，但**节流窗口**照旧要等满 15 秒 —— '
              '清零只解除"上限"，不解除"节流"，否则一打嗝就变成每两秒重建一次');
      c.advance(const Duration(seconds: 11)); // 距上次自愈满 16 秒
      expect(w.shouldHeal, isTrue, reason: '窗口满了：打嗝型的下一次断流照旧能救');
    });
  });

  group('★ 有牙：同一段脚本，旧规则必须停在冻结、新规则必须落回基座', () {
    /// 造一份"断流前最后一帧"的柱子：37 根，值各不相同（好看出"定格"）。
    List<double> frozenBars() =>
        List<double>.generate(37, (i) => 0.2 + (i % 9) * 0.08);

    test('旧规则（active 就算活着）：柱子永远停在最后一帧 —— 这就是用户看到的"定格"', () {
      final bars = frozenBars();
      final before = List<double>.of(bars);
      for (var i = 0; i < 120; i++) {
        _oldTick(bars, active: true); // active 为真（引擎订阅着，只是帧停了）
      }
      expect(bars, before,
          reason: '旧写法 `if (SpectrumEngine.instance.active) return;` 会把最后一帧'
              '永远当活的画下去 —— 界面"看起来在跳其实定格了"，一个字都不说');
      expect(bars.any((v) => v > 0.005), isTrue);
    });

    test('新规则（active && !stalled 才活着）：断流后按同一套帧基因子落回静止基座', () {
      final c = _FakeClock();
      final w = SpectrumWatchdog(clock: c.call);
      final bars = frozenBars();
      w.markFrame(); // 最后一帧到了
      c.advance(const Duration(seconds: 3)); // 之后一直没有帧

      var ticks = 0;
      while (bars.any((v) => v > 0.005) && ticks < 500) {
        _newTick(bars, active: true, stalled: w.stalled);
        ticks++;
      }
      expect(ticks, lessThan(500), reason: '必须真的落下去（不是慢慢磨）');
      expect(bars.every((v) => v == 0.0), isTrue,
          reason: '断流时界面给的是"静止基座"，不是最后一帧');
      expect(ticks, lessThan(120),
          reason: '帧基 0.93 衰减：约 60~70 帧落到底（≈1 秒 @60fps），'
              '与暂停时的回落速度逐项相同（观感没变）');
    });

    test('新规则在"帧真的在来"时一拍都不衰减（正常播放的观感逐项不变）', () {
      final bars = frozenBars();
      final before = List<double>.of(bars);
      for (var i = 0; i < 120; i++) {
        _newTick(bars, active: true, stalled: false);
      }
      expect(bars, before, reason: '正常播放中仍然由 _handleBars 驱动，_onTick 不许插手');
    });

    test('引擎停了（active=false）两条规则都衰减（暂停回落的老行为不许变）', () {
      final bars = frozenBars();
      for (var i = 0; i < 200; i++) {
        _newTick(bars, active: false, stalled: false);
      }
      expect(bars.every((v) => v == 0.0), isTrue);
    });
  });

  group('接线（源码锚点：判定必须真的接上，而且不能把时钟塞回 spectrum.dart）', () {
    String read(String p) => File(p).readAsStringSync();

    test('lib/spectrum_engine.dart：看门狗已接上（markFrame / stalled / 自愈）', () {
      final src = read('lib/spectrum_engine.dart');
      expect(src.contains("import 'playback/spectrum_watchdog.dart';"), isTrue,
          reason: '看门狗没被 import ⇒ 判据是死的');
      expect(src.contains('final SpectrumWatchdog _watch = SpectrumWatchdog();'),
          isTrue);
      expect(src.contains('_watch.markFrame();'), isTrue,
          reason: '收到帧必须记一笔，否则永远"没收到过帧"');
      expect(src.contains('_watch.reset();'), isTrue,
          reason: '新订阅/停止要清起点（宽限期靠它）');
      expect(src.contains('bool get stalled => _sub != null && _watch.stalled;'),
          isTrue,
          reason: 'stalled 必须带 `_sub != null`：停采集不是断流（那是 active 的事）');
      expect(src.contains('Future<void> healIfStalled() async'), isTrue);
      expect(src.contains("debugPrint('Spectrum: stalled"), isTrue,
          reason: '断流必须在 logcat 留一句（ASCII 前缀 Spectrum:），否则真机上'
              '又是一次"只能靠人眼看"的排查');
    });

    test('★ 接线：spectrum.dart 里旧那句 `if (active) return;` 必须已经不在了', () {
      final src = read('lib/widgets/spectrum.dart');
      expect(
        src.contains('if (SpectrumEngine.instance.active) return;'),
        isFalse,
        reason: '旧判据只问"订阅着没有"、不问"帧还在不在来" —— 它就是"频谱定格"的成因。'
            '有人改回这一行 ⇒ 本用例当场红。',
      );
      expect(src.contains('engine.active && !engine.stalled'), isTrue,
          reason: '新判据必须在（正常播放时仍然一拍都不插手）');
      expect(src.contains('engine.healIfStalled()'), isTrue,
          reason: '断流要试着重挂一次（节流在引擎/看门狗里）');
    });

    test('★ 接线：spectrum.dart 仍然零时间基写法（用户拍过板的帧基语义）', () {
      final lines = File('lib/widgets/spectrum.dart').readAsLinesSync();
      final hits = <int>[];
      for (var i = 0; i < lines.length; i++) {
        if (RegExp(r'DateTime\.now|Stopwatch|\belapsed\b').hasMatch(lines[i])) {
          hits.add(i + 1);
        }
      }
      expect(hits, isEmpty,
          reason: 'spectrum.dart 第 $hits 行出现了时间基写法。判据（时间）只许待在 '
              'playback/spectrum_watchdog.dart，本文件依旧是帧基的。');
    });

    test('看门狗自己：零 Flutter 依赖（否则纯 Dart 单测跑不起来）', () {
      final src = read('lib/playback/spectrum_watchdog.dart');
      expect(src.contains("package:flutter/"), isFalse,
          reason: '一旦 import Flutter，这个文件就只能靠 widget 测试了');
      expect(src.contains('library;'), isTrue,
          reason: '本仓纯计算文件的写法：顶部 library; + 文件级文档');
    });
  });
}
