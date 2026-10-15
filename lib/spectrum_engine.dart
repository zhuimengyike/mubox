/// 频谱数据层：通过 EventChannel 接收原生 Visualizer 的 FFT 频域数据，
/// 降采样到 37 根柱子幅度；无权限/不支持时保持空数据，UI 暂不绘制。
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'playback/spectrum_watchdog.dart';

class SpectrumEngine {
  SpectrumEngine._();

  static final SpectrumEngine instance = SpectrumEngine._();

  static const EventChannel _channel =
      EventChannel('com.mubox.mu_box_phone/spectrum');

  /// 频谱柱子根数（与 SpectrumPainter 的 n 一致）
  static const int barCount = 37;

  StreamSubscription? _sub;

  /// ★ **断流看门狗**：判定在 `playback/spectrum_watchdog.dart`（纯 Dart、带单测），
  /// 这里只负责「收到一帧就记一笔 / 换订就清零 / 断流了就重建一次 Visualizer」。
  ///
  /// 为什么必须有它：FFT 数据是原生**回调**推上来的，Dart 侧此前**没有任何
  /// "多久没收到帧"的判定** —— 回调链一停，`bars` 就停在最后一帧，而
  /// `SpectrumView._onTick` 里那句 `if (SpectrumEngine.instance.active) return;`
  /// 会一直当它活着 ⇒ **界面把最后一帧当成"还在跳"，不报错、不自愈**，
  /// 表现就是「App 认为还在播放音乐，频谱却不再跳」。
  final SpectrumWatchdog _watch = SpectrumWatchdog();

  /// 当前该挂到**哪个播放器**的 session 上（`AudioPlayer.playerId`，由
  /// `player_service.dart` 在起播/换场时推过来）。`null` = 走原生的兼容格子
  /// （老行为，单播放器下与改造前逐项一致）。
  ///
  /// 为什么要有它：双播放器（交叉淡变/预取）下"全进程一个 session 格子"会被
  /// 正在预取的那个播放器抢走，频谱就挂到还没播的那一个上（原生退避重试 8 次后
  /// 报 `SPECTRUM_UNAVAILABLE`）。带身份重新订阅 = 让原生按身份取 session。
  String? _targetPlayerId;

  /// **改绑入口**：告诉频谱"现在该挂哪个播放器"。
  ///
  /// `Visualizer` 没有改绑 API ⇒ 换播放器只能让原生**重建**它，
  /// 而原生重建的唯一触发点就是「带着新身份重新 `onListen`」——
  /// 所以这里先 `cancel()`（等它真的落地！）再重新订阅。
  ///
  /// ⚠️ **刻意不走 `stop()`**：`stop()` 会把 `_holders` 归零，而引用计数是**使用者**
  /// 的（`SpectrumView` 记着"我已持有"），归零之后再也不会申请，频谱就再也起不来了
  /// （`stop()` 会连使用者的持有数一起清掉）。这里只换订阅，不动持有数。
  ///
  /// ⚠️ 必须 `await cancel()` 之后再 `listen`：不等的话原生可能**先**收到新的
  /// `onListen`、**后**收到旧的 `onCancel`，刚建好的 `Visualizer` 会被掐掉。
  Future<void> setTargetPlayerId(String? id) async {
    if (id == _targetPlayerId) return;
    _targetPlayerId = id;
    final old = _sub;
    if (old == null) return; // 现在没人用频谱：下次 start() 自然带上新身份
    _sub = null;
    await old.cancel();
    if (_sub != null || _targetPlayerId != id) return; // 期间又被换过目标：让最后一次赢
    _listen();
  }

  /// 每根柱子的峰值包络（近期最大值）：上行瞬时保持、下行慢落。
  final List<double> _peaks = List.filled(barCount, 0.2);
  /// 每根柱子的谷值包络（近期最小值）：下行瞬时保持、上行慢升。
  final List<double> _valleys = List.filled(barCount, 0.05);
  /// 降采样原始柱高缓冲（barCount 长度）：每帧复用，避免高频帧反复分配造成 GC。
  final List<double> _raw = List.filled(barCount, 0);

  /// 最近一帧降采样后的柱子幅度（0..1）；空表示暂无真实数据
  final ValueNotifier<List<double>> bars = ValueNotifier(const []);

  /// 低频能量（鼓点/贝斯所在频段，0..1），驱动视觉/氛围动效跟随音乐节拍
  final ValueNotifier<double> bass = ValueNotifier(0);

  /// 旋律能量（中高频段，人声/乐器旋律所在，0..1），驱动动效随旋律起伏变色/变亮
  final ValueNotifier<double> melody = ValueNotifier(0);

  bool get active => _sub != null;

  /// ★ 订阅还在、但已经 [kSpectrumStaleAfter] 没有收到任何一帧 ⇒ **断流**。
  ///
  /// 调用点 = `lib/widgets/spectrum.dart` 的 `_onTick`：断流时不再把最后一帧
  /// 当成"还在跳"，而是让柱子按**原来的帧基因子**慢慢落回静止基座。
  /// `_sub == null`（没在采集）恒为 false —— 那种情况由 `active` 自己判，
  /// 两件事不要混在一起。
  bool get stalled => _sub != null && _watch.stalled;

  /// 断流自愈：带着**同一个身份**重新订阅 ⇒ 原生 `onCancel` + `onListen`
  /// 重建 `Visualizer`（它没有改绑 API，重建是唯一的复活路径）。
  ///
  /// ⚠️ 必须 `await cancel()` 之后再 `_listen()`：不等的话原生可能**先**收到新的
  /// `onListen`、**后**收到旧的 `onCancel`，刚建好的 `Visualizer` 会被掐掉
  /// （同 [setTargetPlayerId] 的理由）。
  /// ⚠️ 刻意**不碰 `_holders`**（引用计数是使用者的），也刻意**不走 `start()` /
  /// `stop()`** —— `stop()` 会把 `_holders` 归零，之后持有者再也不会申请，
  /// 频谱就再也起不来了（`test/spectrum_invariants_test.dart`
  /// 拿源码当护栏钉着这条）。
  /// ⚠️ 节流在 [_watch] 里（[kSpectrumHealMinInterval]）：断流期间 `_onTick`
  /// 每帧都会问一次，不节流就是每秒 60 次重建。
  /// ⚠️ 次数上限也在 [_watch] 里（[kSpectrumMaxHeals]）：持续性断流下节流会变成
  /// 「一直播就一直重建」—— 连换 3 次都没换来一帧就收手，界面停在静止基座（诚实），
  /// 只在 logcat 留最后一句，等用户自己拨开关/重启播放再试。
  Future<void> healIfStalled() async {
    if (_sub == null) return;
    if (_watch.healExhausted) {
      if (!_gaveUpLogged) {
        _gaveUpLogged = true;
        debugPrint('Spectrum: stalled healExhausted=${_watch.healsSinceFrame} '
            'playerId=$_targetPlayerId → 不再重建（界面停静止基座）');
      }
      return;
    }
    if (!_watch.shouldHeal) return;
    _watch.markHeal();
    final sinceMs = _watch.sinceJudged.inMilliseconds;
    // ASCII 前缀照本项目约定（中文关键词在 logcat 里可能被转义过滤不到）。
    debugPrint('Spectrum: stalled sinceLastFrameMs=$sinceMs '
        'heal=${_watch.healsSinceFrame} playerId=$_targetPlayerId → 重建 Visualizer');
    final old = _sub;
    _sub = null;
    await old?.cancel();
    if (_sub != null) return; // 期间有人抢先重订：让最后一次赢
    _listen();
  }

  /// 已经打过"放弃重建"那句日志没有（每次新订阅重置，见 [_listen]）。
  bool _gaveUpLogged = false;

  /// 当前有多少个 SpectrumView 在用这份数据（播放栏 + 特效设置页预览会同时要）。
  int _holders = 0;

  /// 申请使用频谱数据：多处同时需要时**不会互相掐掉** ——
  /// 之前是哪个视图先 dispose 就 stop，另一个还开着的频谱就再也不动了。
  void acquire() {
    _holders++;
    start();
  }

  /// 归还使用权：最后一个使用者释放时才真正停掉原生采集（省电）。
  void release() {
    if (_holders > 0) _holders--;
    if (_holders == 0) stop();
  }

  /// 启动捕获：Dart 端 listen 触发原生 Visualizer 创建。
  /// 仅在「播放中且频谱开关开启」时调用，暂停/关闭时 stop 释放。
  void start() {
    if (_sub != null) return;
    _listen();
  }

  /// 真正建立订阅（`start()` 与换场重订阅共用同一条路，别抄第二份）。
  void _listen() {
    // 新订阅 = 还没收到过任何一帧：看门狗的"最近一帧"清零。
    // ⚠️ 只清帧、不清自愈节流账（见 SpectrumWatchdog.reset 的注释）。
    _watch.reset();
    _sub = _channel.receiveBroadcastStream(_targetPlayerId).listen(
      (data) {
        if (data is Int32List) {
          _watch.markFrame(); // ★ 这一帧真的来了：断流判定立刻回活
          bars.value = _fftToBars(data);
          bass.value = _bassEnergy(data);
          melody.value = _melodyEnergy();
        }
      },
      onError: (Object e) => stop(),
      cancelOnError: true,
    );
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _watch.reset(); // 停采集不是"断流"：stalled 跟着 _sub 一起归零
    // 归零持有数：掉线（原生报错 → onError）时如果留着计数 >0，最后一个使用者
    // 释放也停不掉、后续 acquire 又让计数只增不减，频谱就再也起不来了。
    // 正常路径（release 到 0）走到这里时本来就是 0，归零无害。
    _holders = 0;
    bars.value = const [];
    bass.value = 0;
    melody.value = 0;
  }

  /// 旋律能量：中高频段（柱 8~31，人声/旋律所在）平均，随歌曲旋律起伏。
  /// 复用最近一帧降采样柱高（见 _fftToBars 的 _raw），不额外分配。
  double _melodyEnergy() {
    const lo = 8, hi = 32;
    var sum = 0.0;
    var cnt = 0;
    for (var b = lo; b < hi && b < barCount; b++) {
      sum += _raw[b];
      cnt++;
    }
    return cnt == 0 ? 0.0 : (sum / cnt).clamp(0.0, 1.0);
  }

  /// 低频能量：取前 ~20% bin（跳过 DC 直流），平均幅度归一化。
  /// 鼓点/贝斯集中在低频，用它能得到贴合节拍的脉动信号。
  double _bassEnergy(Int32List mags) {
    final binCount = mags.length;
    if (binCount <= 2) return 0;
    final n = math.max(2, (binCount * 0.2).floor());
    var sum = 0.0;
    for (var i = 1; i < n; i++) {
      sum += mags[i] / 181.0; // 与 _fftToBars 相同的幅度归一化
    }
    return (sum / (n - 1)).clamp(0.0, 1.0);
  }

  /// FFT 频域 → barCount(37) 根柱子：FFT 对称，取前一半有效 bins，按对数刻度分频段
  /// （低频段窄、高频段宽，贴近人耳感知），每段取最大值作柱高。
  List<double> _fftToBars(Int32List mags) {
    final binCount = mags.length; // 幅度点数量 = captureSize/2（含 DC）
    if (binCount <= 1) return const [];
    final raw = _raw; // 复用实例缓冲，循环内每根柱子都会重新赋值，无需清零
    // 跳过 bin[0]（DC 直流分量，恒定值会把第一根柱子顶满不动），映射到 1..binCount-1
    final usable = (binCount - 1) * 0.5; // 只用前一半 bin（约 0~11kHz），更高频音乐能量近零
    for (var b = 0; b < barCount; b++) {
      final lo = 1 + (math.pow(b / barCount, 1.6) * usable).floor();
      final hi = 1 +
          (math.pow((b + 1) / barCount, 1.6) * usable)
              .floor()
              .clamp(lo + 1, binCount);
      var max = 0.0;
      for (var i = lo; i < hi; i++) {
        final v = mags[i] / 181.0; // 幅度理论最大 sqrt(128²+128²)≈181
        if (v > max) max = v;
      }
      raw[b] = max;
    }
    // 每柱 min-max 归一化：柱高 = 能量在「近期峰谷区间」内的相对位置。
    // 稳定信号沉底、爆发冲顶，频段各自活跃；根治高频能量稳定导致的恒满格下不去。
    // out 必须新分配：ValueNotifier 用引用相等判断，复用同一个 List 会因引用不变而不再通知。
    final out = List<double>.filled(barCount, 0);
    for (var b = 0; b < barCount; b++) {
      final r = raw[b];
      final peak = _peaks[b];
      final valley = _valleys[b];
      if (r > peak) {
        _peaks[b] = r; // 峰值：上行瞬时保持
      } else {
        _peaks[b] = peak + (r - peak) * 0.05; // 峰值：下行慢落
      }
      if (r < valley) {
        _valleys[b] = r; // 谷值：下行瞬时保持
      } else {
        _valleys[b] = valley + (r - valley) * 0.02; // 谷值：上行慢升
      }
      final range = _peaks[b] - _valleys[b];
      final v = range < 0.005 ? 0.0 : ((r - _valleys[b]) / range).clamp(0.0, 1.0);
      out[b] = math.pow(v, 1.5).toDouble();
    }
    return out;
  }
}
