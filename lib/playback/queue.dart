/// 播放队列的**纯逻辑**（零 Flutter / 零插件依赖，可纯 Dart 单测）。
///
/// 队列是一等公民：插入 / 移除 / 移动 / 清空（保留当前）
/// / 追加、随机序固定种子、能落盘、重启后原样还在。这些判定**全是下标算术与排列**，
/// 真机上极难试（要手指拖、要杀进程、要听是不是同一首），所以整块抽到这儿来，
/// `player_service.dart` 只负责「照结果动播放器」和「落盘」。
///
/// 三条硬性质（都有单测逐条钉死）：
///
/// 1. **[QueueState.currentIndex] 永远指向「正在播的那首歌」** —— 移除它前面的歌、
///    移动它、清空（保留当前）之后，它都还指同一首。指错了轻则进度条对不上，
///    重则 `playAt(index)` 直接把用户正在听的歌换掉。
/// 2. **随机序由种子决定，不靠 Timer / 系统随机** —— 同一个种子出同一个排列，
///    所以「下一首 → 上一首」能精确回到**同一首**（旧实现每次 `Random()` 现抽，
///    回退就漂走了），重启后也能接着走。
/// 3. **落盘 / 读回逐项等价** —— 队列按 `filePath` 存（刷新曲库后 MediaStore id 会变，
///    路径稳定），读不回来时一律返回 null，让调用方保留磁盘上的原值。
///
/// ⚠️ 本文件**不许 import Flutter / 任何插件**（只许 `dart:math`），否则又测不了。
library;

import 'dart:math';

/// 队列快照：一串歌曲引用（`Song` 的某个稳定身份，本仓用 `filePath`）+ 当前曲下标 +
/// 来源名。**纯数据**，每个改队列的函数都返回**新实例**，绝不原地改（便于单测和回滚）。
///
/// [refs] 里**允许重复**（同一首歌可以在队列里出现两次，比如「下一首播放」），
/// 所以下标永远按位置算，不做任何「按歌去重」的假设。
class QueueState {
  final List<String> refs;

  /// 当前曲在 [refs] 里的下标；**-1 = 队列空 / 没有当前曲**。
  /// 构造时会被夹进 `[-1, refs.length - 1]`，只有两种取值合法。
  final int index;

  /// 队列来源名（歌单名 /「全部歌曲」/ 单曲名…），显示在队列浮层标题上。
  final String sourceName;

  QueueState({
    required List<String> refs,
    required int index,
    this.sourceName = '',
  })  : refs = List<String>.unmodifiable(refs),
        index = _clampIndex(index, refs.length);

  /// 空队列（没有当前曲）。取 [currentIndex] 得 -1，[current] 得 null。
  static final QueueState empty = QueueState(refs: const [], index: -1);

  /// 当前曲的引用；空队列时为 null。
  String? get current =>
      (index >= 0 && index < refs.length) ? refs[index] : null;

  int get length => refs.length;

  bool get isEmpty => refs.isEmpty;

  /// `refs[index]`（越界由 [index] 的夹紧保证不会发生，这里只是防御性写法）。
  int get currentIndex => (index >= 0 && index < refs.length) ? index : -1;

  QueueState _copy({List<String>? refs, int? index, String? sourceName}) =>
      QueueState(
        refs: refs ?? this.refs,
        index: index ?? this.index,
        sourceName: sourceName ?? this.sourceName,
      );

  @override
  bool operator ==(Object other) =>
      other is QueueState &&
      other.index == index &&
      other.sourceName == sourceName &&
      _listEq(other.refs, refs);

  @override
  int get hashCode => Object.hash(Object.hashAll(refs), index, sourceName);

  @override
  String toString() => 'QueueState(${refs.length} 首, index=$index, '
      'source=$sourceName)';
}

/// 把 [i] 夹成 `[-1, len - 1]`：小于 0（含空队列）一律 -1，其余夹到最后一个。
int _clampIndex(int i, int len) {
  if (len <= 0 || i < 0) return -1;
  return i > len - 1 ? len - 1 : i;
}

bool _listEq(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 队列的增删改：**每个函数都是纯函数**（入参不变，返回新 [QueueState]）。
///
/// 所有「按引用删 / 移动」的操作都只管 [QueueState.refs]，**不碰当前曲是哪一首**：
/// 当前曲是按位置记的，所以下面每一步都顺手把 [QueueState.index] 修到同一首歌上
/// —— 这是这个文件最要紧的一条不变量（见文件头）。
abstract final class QueueOps {
  /// 用一整批歌换掉队列，当前曲指向 [startAt]（越界会夹进范围）。
  /// `playQueue(歌单, 点第 i 首)` 走这个。
  ///
  /// ⚠️ **负数 / 空队列一律 -1（没有当前曲）**，不是夹成 0。夹成 0 的话
  /// 「没点中任何一首」会变成「放第一首」，而越界的正数夹到最后一首是**原实现**
  /// 的行为（`playAt` 里 `i % length` 那种算法），两种取整方向本来就不一样。
  static QueueState push(
    List<String> refs,
    int startAt, {
    String title = '',
  }) =>
      QueueState(
        refs: List<String>.of(refs),
        index: _clampIndex(startAt, refs.length),
        sourceName: title,
      );

  /// 往队列末尾追加一批歌（跨歌单追加）。**当前曲不动**；队列原本为空时不动下标
  /// （仍是 -1，交给调用方决定要不要开播）。
  static QueueState append(QueueState q, List<String> refs) {
    if (refs.isEmpty) return q;
    return q._copy(refs: [...q.refs, ...refs]);
  }

  /// 在 [at] 处插入一首（`下一首播放`）。[at] 越界夹进 `[0, length]`。
  ///
  /// ⚠️ 插在**当前曲的位置之前或之上**时，当前曲的下标要跟着 +1 —— 否则
  /// 「下一首播放」会把正在听的那首挤到下一格，界面高亮当场错位。
  /// 原本没有当前曲（空队列）时，插进来的这首就**成为**当前曲（下标 0）——
  /// 不然队列里明明有歌、却谁也点不动（`current` 是 null）。
  static QueueState insertAt(QueueState q, int at, String ref) {
    final pos = at < 0 ? 0 : (at > q.refs.length ? q.refs.length : at);
    final refs = [...q.refs]..insert(pos, ref);
    var idx = q.index;
    if (idx < 0) {
      idx = 0;
    } else if (pos <= idx) {
      idx++;
    }
    return q._copy(refs: refs, index: idx);
  }

  /// 把 [ref] 插到当前曲的**后面一位**（`下一首播放`）。
  /// 空队列时退化成「放进队列并成为当前曲」。
  static QueueState insertNext(QueueState q, String ref) =>
      q.index < 0 ? insertAt(q, 0, ref) : insertAt(q, q.index + 1, ref);

  /// 移除第 [i] 首。返回新队列；[i] 越界就原样返回。
  ///
  /// 三种情形（下标必须各自修对）：
  /// - 删的是当前曲**之前**的 → 当前曲下标 -1（还是同一首歌）；
  /// - 删的是当前曲**本身** → 让**后一首**顶上（原本就是最后一首则落到新的最后一首）；
  /// - 删的是当前曲**之后**的 → 下标不动。
  ///
  /// 删完队列空了 → 当前曲消失（index = -1）。
  static QueueState removeAt(QueueState q, int i) {
    if (i < 0 || i >= q.refs.length) return q;
    final refs = [...q.refs]..removeAt(i);
    if (refs.isEmpty) {
      return QueueState(refs: const [], index: -1, sourceName: q.sourceName);
    }
    var idx = q.index;
    if (idx >= 0) {
      if (i < idx) {
        idx--;
      } else if (i == idx) {
        // 后一首顶上；原本是最后一首时 _clampIndex 会把我夹回新的最后一首
        // （= 队列走到尾就绕回开头，与列表循环的行为一致）
        idx = _clampIndex(i, refs.length);
      }
    }
    return q._copy(refs: refs, index: idx);
  }

  /// 移除第一首引用等于 [ref] 的歌；队列里没有它时原样返回。
  static QueueState removeRef(QueueState q, String ref) {
    final i = q.refs.indexOf(ref);
    return i < 0 ? q : removeAt(q, i);
  }

  /// 把第 [from] 首移到第 [to] 位（拖拽排序）。
  /// 越界或原地不动时原样返回；当前曲跟着走，**它还是同一首歌**。
  ///
  /// 语义按「先摘出来、再插进新位置」：`[A,B,C]` 把 0 移到 2 得 `[B,C,A]`
  /// （与 `ReorderableListView.onReorder` 的约定一致）。
  static QueueState moveTo(QueueState q, int from, int to) {
    final n = q.refs.length;
    if (n == 0 || from < 0 || from >= n || to < 0 || to >= n || from == to) {
      return q;
    }
    final refs = [...q.refs];
    final moved = refs.removeAt(from);
    refs.insert(to, moved);
    var idx = q.index;
    if (idx >= 0) {
      if (idx == from) {
        idx = to; // 拖的就是正在播的那首
      } else if (from < idx && to >= idx) {
        idx--; // 被拖的歌从当前曲前面挪到了它后面
      } else if (from > idx && to <= idx) {
        idx++; // 从后面挪到了前面
      }
    }
    return q._copy(refs: refs, index: idx);
  }

  /// 拖拽一个「相对位移」[delta]（正 = 往后拖）。UI 只拿到位移时用这个。
  static QueueState moveBy(QueueState q, int from, int delta) =>
      moveTo(q, from, from + delta);

  /// 清空队列，但**保留当前曲**（它变成队列里唯一一首，下标 0）。
  /// 队列本来就空 / 没有当前曲时返回空队列（来源名照旧留着）。
  static QueueState clearKeepingCurrent(QueueState q) {
    final c = q.current;
    if (c == null) {
      return QueueState(refs: const [], index: -1, sourceName: q.sourceName);
    }
    return QueueState(refs: [c], index: 0, sourceName: q.sourceName);
  }

  /// 清空整个队列（当前曲一起没）。来源名保留，界面标题不会突然变空。
  static QueueState clearAll(QueueState q) =>
      QueueState(refs: const [], index: -1, sourceName: q.sourceName);

  /// 换一个来源名（切歌单 / 切历史模式时标题跟着换）。
  static QueueState rename(QueueState q, String title) =>
      q._copy(sourceName: title);
}

/// 随机播放的**固定种子**序：把 `0..length-1` 用一个种子洗成一条固定排列，
/// 之后「下一首 / 上一首」就是在这条排列上前后走，不再每次现抽。
///
/// 为什么必须这么做（「随机模式下拉回上一首要能回到**同一首**」）：
/// 原实现是 `next` 现抽一个随机下标、`prev` 再抽一个 —— 两条独立随机，
/// 回退必然漂到别处（n 首队列里回到同一首的概率只有 1/n）。
class ShuffleOrder {
  /// 洗牌种子。同一个种子 + 同一个长度 ⇒ 逐项相同的排列。
  final int seed;

  /// 固定排列：`perm[i]` = 序列里第 i 个该播的**队列下标**。
  final List<int> perm;

  /// 排列上的游标（`perm` 的下标）；-1 = 还没定位过。
  int cursor;

  ShuffleOrder._(this.seed, this.perm, this.cursor);

  /// 为 [length] 首歌建一条固定随机序（[cursor] 传 -1 表示稍后按当前曲定位）。
  factory ShuffleOrder.create(int length, int seed, {int cursor = -1}) =>
      ShuffleOrder._(seed, _shuffleIndices(length, seed), cursor);

  int get length => perm.length;

  /// 游标指的队列下标；未定位 / 空序列时 null。
  int? get current =>
      (cursor >= 0 && cursor < perm.length) ? perm[cursor] : null;

  /// 从 [from] 出发往前走 [step] 步，跳过 [excluded] 里的下标。
  ///
  /// 走不出去时**原地不动**（返回 [from]），与「排除名单覆盖其余全部歌」的原行为一致
  /// —— 原实现此时退化成「除当前曲外随便一首」，两首歌的队列里那还是原地不动。
  int step(int from, int step, {Set<int> excluded = const {}}) {
    if (perm.isEmpty) return from;
    final start = perm.indexOf(from);
    if (start < 0) return from; // 当前曲不在排列里（队列换过了）→ 交给调用方重建
    for (var k = 1; k <= perm.length; k++) {
      final c = ((start + step * k) % perm.length + perm.length) % perm.length;
      final i = perm[c];
      if (!excluded.contains(i)) {
        cursor = c;
        return i;
      }
    }
    return from; // 其余全被排除：留在原地，别乱跳
  }

  /// 定位到队列下标 [from]（点某一首 / 从会话恢复时用）。
  /// [from] 不在排列里就返回 false，调用方据此重建排列。
  bool seekTo(int from) {
    final i = perm.indexOf(from);
    if (i < 0) return false;
    cursor = i;
    return true;
  }
}

/// 把一个种子洗成 `0..length-1` 的一条固定排列（Fisher–Yates，从后往前换）。
///
/// ⚠️ 别改成 `List.shuffle(Random(seed))`：那条路依赖 Dart SDK 里随机源的实现，
/// 「同一种子同一排列」虽然是它的承诺，但升级 SDK 后**排列可能整体变样**，
/// 而这里要的是「我自己的、可复现的、改动看得见」的排列 —— 手写循环才留得住证据。
List<int> _shuffleIndices(int length, int seed) {
  final perm = [for (var i = 0; i < length; i++) i];
  if (length <= 1) return perm;
  final rng = Random(seed);
  for (var i = length - 1; i >= 1; i--) {
    final j = rng.nextInt(i + 1);
    final t = perm[i];
    perm[i] = perm[j];
    perm[j] = t;
  }
  return perm;
}

/// 队列的落盘编解码（**纯函数**，文件读写留给 `store.dart`）。
///
/// 存 `filePath` 而不是歌曲 id：刷新曲库后 MediaStore 的 id 会变，路径稳定
/// —— 与「播放历史」「歌词校准」「私密名单」是同一套身份约定。
abstract final class QueueCodec {
  /// 队列文件里出现的键。读侧**一个都不许改成必需**（见 [decode]）。
  static const String kPaths = 'paths';
  static const String kIndex = 'index';
  static const String kTitle = 'title';
  static const String kMode = 'mode';
  static const String kSeed = 'seed';
  static const String kCursor = 'cursor';

  /// 队列 → 落盘用的 Map（`jsonEncode` 直接吃）。
  ///
  /// 没传的字段**不写进 JSON**（别塞 null）：读侧就少一层类型判断，而老文件天然
  /// 就是「没这几个键」的形状。
  static Map<String, Object?> encode(
    QueueState q, {
    String? mode,
    int? seed,
    int? cursor,
  }) {
    final out = <String, Object?>{
      kPaths: List<String>.of(q.refs),
      kIndex: q.index,
      kTitle: q.sourceName,
    };
    if (mode != null) out[kMode] = mode;
    if (seed != null) out[kSeed] = seed;
    if (cursor != null) out[kCursor] = cursor;
    return out;
  }

  /// 落盘 Map → 队列。**读不回来一律返回 null**，调用方据此保留磁盘上的原值
  /// （绝不允许「读坏 → 当空 → 下次写盘把空值固化」，那是本项目丢数据的标准剧本）。
  ///
  /// 向后可读的三条（改这个函数前先看 `test/queue_persist_test.dart`）：
  /// - `paths` 缺失 / 不是数组 → null；
  /// - `index` 缺失 / 不是整数 → -1（没有当前曲），**不是** null：
  ///   队列还在就先留着，别把整条队列判成坏的；
  /// - 元素不是字符串的**逐项跳过**（老文件里混进数字不能拖垮整条队列）。
  static QueueState? decode(Object? raw) {
    if (raw is! Map) return null;
    final rawPaths = raw[kPaths];
    if (rawPaths is! List) return null;
    final refs = <String>[
      for (final e in rawPaths)
        if (e is String) e,
    ];
    final rawIndex = raw[kIndex];
    final index = rawIndex is int ? rawIndex : -1;
    final rawTitle = raw[kTitle];
    return QueueState(
      refs: refs,
      index: index,
      sourceName: rawTitle is String ? rawTitle : '',
    );
  }

  /// 从落盘 Map 里取播放模式；没有 / 类型不对 → null（调用方保留当前模式）。
  static String? modeOf(Object? raw) {
    if (raw is! Map) return null;
    final v = raw[kMode];
    return v is String ? v : null;
  }

  /// 从落盘 Map 里取随机种子；没有 / 类型不对 → null（调用方重新摇一个）。
  static int? seedOf(Object? raw) {
    if (raw is! Map) return null;
    final v = raw[kSeed];
    return v is int ? v : null;
  }

  /// 从落盘 Map 里取随机游标；没有 / 类型不对 → null。
  static int? cursorOf(Object? raw) {
    if (raw is! Map) return null;
    final v = raw[kCursor];
    return v is int ? v : null;
  }
}
