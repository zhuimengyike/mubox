/// A-B 片段循环的**纯数据 + 纯判定**：练一句、只听副歌时用。
///
/// 刻意不 import 任何东西（连 flutter 都不碰）：打点顺序、越界、B 落在 A 之前
/// 这些边界最容易出 bug，抽成纯数据才能用纯 Dart 单测一条条钉住。
/// 播放器只在「该不该绕回」这一个问题上问它，具体怎么 seek 是 player_service 的事。
library;

/// A-B 循环状态。三态：未打点 → 只有 A → A、B 都有且 B 在 A 之后（生效）。
class AbLoop {
  /// A 点（片段起点）；null = 还没打
  final Duration? a;

  /// B 点（片段终点）；null = 还没打
  final Duration? b;

  const AbLoop({this.a, this.b});

  /// 空态（未打点）
  static const AbLoop none = AbLoop();

  /// 是否已打 A 点
  bool get hasA => a != null;

  /// 是否正在循环：两个点都有，且 B 严格在 A 之后
  bool get active => a != null && b != null && b! > a!;

  /// 播放到 [pos] 时该不该绕回 A 点。未生效恒定返回 false。
  bool shouldWrap(Duration pos) => active && pos >= b!;

  /// 打 A 点（以 [pos] 为起点）。
  /// 若已存在 B 点且它落在新 A 之后 → 保留（区间仍然有效，用户是在微调起点）；
  /// 落在新 A 之前或等于 → B 作废，否则会留下「终点在起点前面」的无效区间。
  AbLoop markA(Duration pos) => AbLoop(a: pos, b: (b != null && b! > pos) ? b : null);

  /// 打 B 点（以 [pos] 为终点）。
  /// 还没打 A 点就先补一个 A = 0（从头循环到这儿），这样直接点「打 B」也能得到
  /// 一段可用区间；[pos] 不晚于起点则打点无效，原样返回（交给调用方提示用户）。
  AbLoop markB(Duration pos) {
    final start = a ?? Duration.zero;
    if (pos <= start) return this;
    return AbLoop(a: start, b: pos);
  }

  /// 区间在整首歌里的起止比例（0~1），给进度条画高亮带用；
  /// 未生效、总长为 0、或算出来是个空区间时返回 null（调用方就不用画了）。
  (double, double)? fractions(Duration total) {
    if (!active || total <= Duration.zero) return null;
    final f = total.inMilliseconds.toDouble();
    final l = (a!.inMilliseconds / f).clamp(0.0, 1.0);
    final r = (b!.inMilliseconds / f).clamp(0.0, 1.0);
    return r > l ? (l, r) : null;
  }

  /// 给界面显示的一句话（如 `0:12 → 0:35`）；未打点时返回空串。
  String get label {
    if (!hasA) return '';
    final left = _fmt(a!);
    if (b == null) return 'A $left';
    return '$left → ${_fmt(b!)}';
  }

  static String _fmt(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  @override
  bool operator ==(Object other) =>
      other is AbLoop && other.a == a && other.b == b;

  @override
  int get hashCode => Object.hash(a, b);
}
