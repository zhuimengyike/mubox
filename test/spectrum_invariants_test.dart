/// 频谱的两条硬不变量 —— **拿源码当护栏**。
///
/// 背景：「频谱节流」已经拍板 = **保持现状、什么都不做**（峰值衰减是帧基的，
/// 改成时间基会改观感）。所以这里不去复刻 `spectrum.dart` 的绘制逻辑（它是 widget，
/// 本仓 `testWidgets` = 0，不为它开新测试类别），只用源码扫描钉两条
/// 「有人手一滑就会踩」的线：
///
/// 1. `lib/` 里**不存在** `SpectrumEngine.instance.start()` / `.stop()` 的直接调用
///    —— 引擎是引用计数的（`acquire()` / `release()`）。直接 `stop()` 会把播放栏或
///    设置页预览另一份使用者一起掐停，而且 `stop()` 会把 `_holders` 归零，之后
///    那个视图记着「我已持有」→ 再也不会申请（引用计数被归零之后
///    视图侧的持有标记与引擎侧不一致，就再也不会有谁去 `acquire()`）。
/// 2. `lib/widgets/spectrum.dart` 里**不出现** `DateTime.now` / `Stopwatch` / `elapsed`
///    —— `_peakDecay = 0.93` 是**帧基**衰减，一旦有人加了时间基节流（或把衰减改成
///    按真实时间算），峰值亮点的停留时长就变了，那是明确拍过板「不许动」的观感。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 遍历 `lib/` 下所有 .dart，对每一行跑 [hit]。
Map<String, List<int>> _scanLib(bool Function(String line) hit) {
  final out = <String, List<int>>{};
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final lines = e.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (hit(lines[i])) {
        // 统一成 posix 风格的分隔符，Windows 上跑也是同一个键
        out.putIfAbsent(e.path.replaceAll(r'\', '/'), () => []).add(i + 1);
      }
    }
  }
  return out;
}

/// `spectrum.dart` 里凡是「时间」的痕迹都算违规（帧基语义不许被换掉）。
final _timeBased = RegExp(r'DateTime\.now|Stopwatch|\belapsed\b');

void main() {
  test('lib/ 存在（下面的扫描有赖于 cwd = 包根目录）', () {
    expect(Directory('lib').existsSync(), isTrue,
        reason: 'flutter test 的 cwd 应当是包根目录');
  });

  test('没有任何地方直接调 SpectrumEngine.instance.start() / .stop()', () {
    final hits = _scanLib(
      (l) =>
          l.contains('SpectrumEngine.instance.start') ||
          l.contains('SpectrumEngine.instance.stop'),
    );
    expect(
      hits,
      isEmpty,
      reason: '这几处绕开了引用计数：$hits\n'
          '一律改用 acquire()/release() —— 直接 stop 会把别处（播放栏/设置页预览）'
          '还开着的那份使用者一起掐停，且 _holders 被归零后再也申请不回来。',
    );
  });

  test('引擎自己那一份仍是引用计数实现，且全仓确实在用 acquire/release', () {
    final src = File('lib/spectrum_engine.dart').readAsStringSync();
    expect(src.contains('void acquire()'), isTrue,
        reason: 'acquire() 是唯一入口，别改签名');
    expect(src.contains('void release()'), isTrue,
        reason: 'release() 是唯一出口，别改签名');
    final hits = _scanLib(
      (l) =>
          l.contains('SpectrumEngine.instance.acquire()') ||
          l.contains('SpectrumEngine.instance.release()'),
    );
    expect(
      hits.keys.toSet(),
      {'lib/widgets/spectrum.dart', 'lib/pages/equalizer_page.dart'},
      reason: '用频谱的那两处（播放栏/特效设置页里的 SpectrumView、EQ 页曲线底衬）'
          '都要走引用计数；这份名单变了就说明有人换了调度方式',
    );
  });

  test('lib/widgets/spectrum.dart 里没有时间基节流 / 时间差分（帧基语义不许换）', () {
    final hits = <int>[];
    final lines = File('lib/widgets/spectrum.dart').readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      if (_timeBased.hasMatch(lines[i])) hits.add(i + 1);
    }
    expect(
      hits,
      isEmpty,
      reason: 'spectrum.dart 第 $hits 行出现了时间基写法。\n'
          '峰值衰减 _peakDecay = 0.93 是**帧基**的，用户已拍板「频谱节流保持现状、'
          '什么都不做」—— 加时间基节流/时间差分就是改观感，当场红。',
    );
  });

  test('帧基衰减因子没被偷偷改值（_peakDecay = 0.93）', () {
    final src = File('lib/widgets/spectrum.dart').readAsStringSync();
    expect(RegExp(r'_peakDecay\s*=\s*0\.93\s*;').hasMatch(src), isTrue,
        reason: '改 0.93 就是改峰值亮点停留时长 = 改观感');
  });
}
