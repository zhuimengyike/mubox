/// 音量淡变的纯计算 + **硬不变量「每次淡变结束音量必须回到 1.0」**。
///
/// 背景：`lib/player_service.dart`（874 行）在这之前零单测，而音量淡变是它最容易
/// 静默出错的一段 —— 淡变结束时音量没回到 1.0，用户听到的是「越听越小声」，
/// 而且只会以为是手机的问题。这里把 `_fade` 的步进/取值抽到 `lib/volume_fade.dart`
/// 的纯函数后逐条钉死，最后再用一条源码围栏确认「真身确实在用这两个纯函数」——
/// 否则测的就是一份没人调用的副本。
///
/// ⚠️ 180ms / 120ms（`player_service.dart` 的 `_fadeInTime` / `_fadeOutTime`）
/// 是**观感默认值，不许改**；这里只测它们算出来的步数。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/volume_fade.dart';

/// 取出某个方法（或函数）的函数体：签名后第一个 `{` 到行首对齐两格的 `}`。
String _bodyOf(String src, String signature) {
  final sig = src.indexOf(signature);
  expect(sig, greaterThanOrEqualTo(0), reason: '源码里找不到 $signature');
  final open = src.indexOf('{', sig);
  expect(open, greaterThan(sig), reason: '$signature 后面没有函数体');
  final close = src.indexOf('\n  }', open);
  expect(close, greaterThan(open), reason: '$signature 的函数体没找到结尾');
  return src.substring(open, close);
}

void main() {
  group('步进：ceil(ms / 16).clamp(1, 80)（改动前的公式）', () {
    test('起播渐入 180ms → 12 步', () {
      expect(fadeSteps(const Duration(milliseconds: 180)), 12);
    });

    test('暂停渐出 120ms → 8 步', () {
      expect(fadeSteps(const Duration(milliseconds: 120)), 8);
    });

    test('0ms / 负时长也至少 1 步（= 直接到位，不会死循环）', () {
      expect(fadeSteps(Duration.zero), 1);
      expect(fadeSteps(const Duration(milliseconds: -500)), 1);
    });

    test('边界不差一：16ms→1 步、17ms→2 步', () {
      expect(fadeSteps(const Duration(milliseconds: 16)), 1);
      expect(fadeSteps(const Duration(milliseconds: 17)), 2);
    });

    test('封顶 80 步：再长也是 80（省 channel 往返）', () {
      expect(fadeSteps(const Duration(seconds: 1)), 63);
      expect(fadeSteps(const Duration(seconds: 10)), 80);
      expect(fadeSteps(const Duration(hours: 1)), 80);
    });

    test('每步间隔常量就是 16ms、上限就是 80', () {
      expect(kFadeStepMs, 16);
      expect(kFadeMaxSteps, 80);
    });
  });

  group('硬不变量：每次淡变结束音量必须回到 1.0', () {
    test('渐入（0 → 1.0）：任何时长，序列末项**精确**等于 1.0', () {
      for (final ms in [1, 16, 17, 100, 120, 180, 300, 999, 1000, 5000, 60000]) {
        final seq = fadeSequence(
          from: 0,
          to: 1.0,
          d: Duration(milliseconds: ms),
        );
        expect(seq.last, 1.0, reason: '$ms ms 的淡入没回到 1.0（必须是精确 1.0）');
      }
    });

    test('从任意残留音量淡入（淡出被打断过）也精确回到 1.0', () {
      for (var i = 0; i <= 100; i++) {
        final from = i / 100;
        final seq = fadeSequence(
          from: from,
          to: 1.0,
          d: const Duration(milliseconds: 180),
        );
        expect(seq.last, 1.0, reason: 'from=$from 起的淡入没回到 1.0');
      }
    });

    test('淡出（→ 0.0）：末项精确等于 0.0', () {
      final seq = fadeSequence(
        from: 1.0,
        to: 0,
        d: const Duration(milliseconds: 120),
      );
      expect(seq.last, 0.0);
    });

    test('序列 = [起点] + 步数项；起点是 from', () {
      final seq = fadeSequence(
        from: 0.4,
        to: 1.0,
        d: const Duration(milliseconds: 180),
      );
      expect(seq.length, 1 + fadeSteps(const Duration(milliseconds: 180)));
      expect(seq.first, 0.4);
    });

    test('单调不过冲（淡入递增、淡出递减，不会忽大忽小出爆音）', () {
      final up = fadeSequence(
        from: 0.3,
        to: 1.0,
        d: const Duration(milliseconds: 180),
      );
      for (var i = 1; i < up.length; i++) {
        expect(up[i], greaterThanOrEqualTo(up[i - 1]));
        expect(up[i], lessThanOrEqualTo(1.0));
      }
      final down = fadeSequence(
        from: 1.0,
        to: 0,
        d: const Duration(milliseconds: 120),
      );
      for (var i = 1; i < down.length; i++) {
        expect(down[i], lessThanOrEqualTo(down[i - 1]));
        expect(down[i], greaterThanOrEqualTo(0.0));
      }
    });

    test('越界入参被夹进 0..1（原生 setVolume 也只接受这段）', () {
      expect(
        fadeStepValue(from: -3, to: 9, step: 3, steps: 10),
        inInclusiveRange(0.0, 1.0),
      );
      final seq = fadeSequence(
        from: -1,
        to: 2,
        d: const Duration(milliseconds: 64),
      );
      for (final v in seq) {
        expect(v, inInclusiveRange(0.0, 1.0));
      }
    });
  });

  group('源码围栏：真身确实在用这两个纯函数（别把公式抄回异步循环）', () {
    final src = File('lib/player_service.dart').readAsStringSync();

    // ⚠️ 淡变改成**按播放器**的（`_fade` → `_fadeOn(_Deck, …)`）：
    // 交叉淡变要求 A 出、B 入两条曲线同时走，一个 `_volume` 标量存不下。
    // 断言跟着改的是**名字**，不是判定逻辑本身 —— 公式仍然只许在 volume_fade.dart 里。
    test('_fadeOn 走 fadeSequence + kFadeStepMs', () {
      final body = _bodyOf(src, 'Future<void> _fadeOn(');
      expect(body.contains('fadeSequence('), isTrue,
          reason: '_fadeOn 必须照纯函数给的序列过桥，否则上面那些用例测的是死代码');
      expect(body.contains('kFadeStepMs'), isTrue,
          reason: '步进间隔要走常量，别再写字面量 16');
      expect(RegExp(r'ceil\(\)\s*\.clamp\(1,\s*80\)').hasMatch(src), isFalse,
          reason: '步进公式不许再抄一份到 player_service 里（两份迟早不一致）');
    });

    test('淡出结束 / 作废淡变两条路径都把音量复位回 1.0', () {
      expect(
        _bodyOf(src, 'Future<void> _fadeOutThenPause()').contains('_setVolumeOn(d, 1.0)'),
        isTrue,
        reason: '淡出到 0 之后必须复位 1.0，否则下次起播从 0 附近起步 = 越听越小声',
      );
      // 阶段 2b 起是"每一副牌都复位"（循环 _allDecks），因为退场那一副可能停在
      // 0.4 之类的中间值上、下次它当值就"一开口就小声"。
      final abort = _bodyOf(src, 'Future<void> _abortFade()');
      expect(abort.contains('_allDecks()'), isTrue,
          reason: '作废淡变要遍历**每一副**牌，不能只复位在场那一副（双播放器的 H3）');
      expect(abort.contains('_setVolumeOn(d, 1.0)'), isTrue,
          reason: '作废淡变（停止/重置/耳机拔出）也要复位 1.0 —— H3 就是这个漏的');
      expect(
        _bodyOf(src, 'Future<void> _abortCrossfade(').contains('_setVolumeOn(out, 1.0)'),
        isTrue,
        reason: '★ 手切歌打断交叉淡变时，**退场**那一副的音量必须复位回 1.0'
            '（这条硬不变量的双播放器版本）',
      );
    });
  });
}
