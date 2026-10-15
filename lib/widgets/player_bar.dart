/// 底部玻璃播放栏：顶部频谱，左半歌曲信息+进度条，右半控制按钮；
/// 「队列」按钮在页面之上、右下角展开队列浮层（勾选参与循环 / 移除 / 切模式）。
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_config.dart';
import '../artwork.dart';
import '../bg_hint.dart';
import '../library_data.dart';
import '../models.dart';
import '../player_service.dart';
import '../queue_scroll.dart';
import 'glass_panel.dart';
import 'song_artwork.dart';
import 'spectrum.dart';

class PlayerBar extends StatefulWidget {
  const PlayerBar({super.key});

  @override
  State<PlayerBar> createState() => _PlayerBarState();
}

class _PlayerBarState extends State<PlayerBar> {
  static const double _barHeight = 116; // 播放栏主体高度（含底部间距，面板定位用）
  static const double _panelHeight = 320; // 队列浮层高度
  static const double _panelWidth = 300; // 队列浮层宽度（右下角小面板，不铺满底部）
  static const List<double> _speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]; // 倍速档位

  /// 队列列表**底部留白**。列表自己的 `padding` 用的就是它 —— 只此一处，别再写第二个字面量。
  static const double _queueListBottomPad = 4;

  bool _panelOpen = false;

  /// 队列列表的滚动控制。**只**服务于「打开浮层时把当前曲滚进视口」这一件事，
  /// 不参与别处的滚动逻辑。
  final ScrollController _queueScroll = ScrollController();

  /// 拖动进度条时的本地比例（null = 没在拖）。
  ///
  /// 原先 `onChanged` 直接调 `player.seek()`：一次拖动 = 几十帧 = 几十次跨进程
  /// 原生调用（MediaPlayer.seekTo），在大文件上会明显拖手。现在拖动期间只更新
  /// 这个本地值（进度条和时间文字都跟着走），**松手才下发一次真正的 seek**。
  double? _dragValue;

  /// 开始拖动时是哪首歌。手指还没松就切了歌（自动下一曲 / 点队列）时，
  /// 这份拖动值属于上一首、必须作废 —— 否则进度条会**冻在旧位置**不再跟播放走。
  int? _dragSongId;

  /// 这次拖动是否仍然有效（还在同一首歌上）。
  bool _dragValidFor(PlayerService player) =>
      _dragValue != null && _dragSongId == player.current?.id;

  @override
  void initState() {
    super.initState();
    playerService!.lastError.addListener(_onPlayError);
    // 首次播放的一次性「后台运行」引导：挂低频的 changeNotifier
    // （播放位置的高频 tick 只走 notifier，不会变成每帧回调）。
    playerService!.changeNotifier.addListener(_onPlaybackChanged);
  }

  @override
  void dispose() {
    playerService!.lastError.removeListener(_onPlayError);
    playerService!.changeNotifier.removeListener(_onPlaybackChanged);
    _queueScroll.dispose();
    super.dispose();
  }

  /// 开/关队列浮层；**开**的时候顺带把当前曲滚进视口。
  ///
  /// 三个入口（「队列 / 收起」按钮、面板右上角的 ✕、点外部遮罩）都走这里 ——
  /// 漏一个就会出现「从那个入口打开就看不到当前曲」。
  void _setPanelOpen(bool open) {
    setState(() => _panelOpen = open);
    if (!open) return;
    // 列表**一直在树上**（浮层只是 `AnimatedPositioned` 平移 + `Opacity`），
    // 所以这一帧之后它的 `ScrollPosition` 已经带着真实几何 ⇒ 直接量，不用等动画。
    WidgetsBinding.instance.addPostFrameCallback((_) => _revealCurrentInQueue());
  }

  /// 量出队列**单行的像素高度**。
  ///
  /// 队列里每一行都是**同一棵子树**（同一个 `ListTile` + 同一个 `Checkbox`/`IconButton`，
  /// 歌名固定 `maxLines: 1`）⇒ 行高一致，于是两条恒等式同时成立：
  /// ```
  /// 内容总高 = itemCount × 行高 + 底部留白
  /// 内容总高 = maxScrollExtent + viewportDimension     // 可滚动时的定义
  /// ```
  /// 相减即得行高 —— **刻意不写死常量**：主题字号 / 视觉密度 / Checkbox 的
  /// `materialTapTargetSize` 一变，这里自动跟着变，不会像魔法数那样悄悄骗人。
  ///
  /// ⚠️ 当前曲那一行多一条 3px 的**左**边框（`_buildQueuePanel` 里的高亮 `Container`），
  /// 只改宽度不改高度 ⇒ 行高仍然一致（实测：40 首、`maxScrollExtent=1759`、
  /// `viewportDimension=165` ⇒ `(1759+165-4)/40 = 48.0`，当前曲那行也在内）。
  double _queueRowExtent(ScrollPosition p, int itemCount) =>
      (p.maxScrollExtent + p.viewportDimension - _queueListBottomPad) / itemCount;

  /// 把当前曲滚进队列列表的视口。
  ///
  /// 「该滚到第几像素 / 要不要滚」的判定**全在纯函数** [queueScrollTarget] 里
  /// （`lib/queue_scroll.dart`，穷举单测在 `test/queue_scroll_test.dart`）；
  /// 这里只负责把真几何喂给它，并把结果落到 `ScrollController` 上。
  ///
  /// 「当前曲已经完整可见 ⇒ 一个像素都不动」这条语义也归那个函数，不在这里重写一遍。
  void _revealCurrentInQueue() {
    if (!mounted || !_panelOpen) return;
    if (!_queueScroll.hasClients) return; // 队列为空时列表整棵不在树上
    final player = playerService!;
    final queue = player.queueList;
    final idx = queue.indexWhere((s) => s.id == player.current?.id);
    if (idx < 0) return;
    final p = _queueScroll.position;
    final target = queueScrollTarget(
      index: idx,
      itemCount: queue.length,
      rowExtent: _queueRowExtent(p, queue.length),
      viewportExtent: p.viewportDimension,
      currentOffset: p.pixels,
      maxScrollExtent: p.maxScrollExtent,
    );
    if (target == null) return;
    // `jumpTo` 而不是 `animateTo`：浮层自己已经在做 250ms 入场位移，
    // 再叠一层滚动动画只会更晃；而且瞬时定位让测试里没有待跑完的动画。
    _queueScroll.jumpTo(target);
  }

  /// 播放/暂停等状态变化：只在「真的开始播了」那一刻查一次后台运行引导。
  /// 已经提示过时第一行就早退，之后每次播放零开销。
  void _onPlaybackChanged() {
    if (playerService!.isPlaying) _maybeShowBgHint();
  }

  /// 「允许后台运行 / 忽略电池优化」的一次性引导：**第一次真正开始播放后**
  /// 弹一次。规则在 `lib/bg_hint.dart`（纯逻辑 + 真值表单测）。
  ///
  /// ⚠️ 弹之前就把 `bgHintShown` **落盘**：点了「去设置」、直接划掉、
  /// 甚至提示因为页面不在而没弹出来，都算「提示过了」—— 否则要么每次播放都弹
  /// （烦人），要么「不点也永久置位」这条落不了地。
  ///
  /// 查权限是异步的，期间可能又切了一次播放状态，所以用 [_bgHintBusy] 挡重入。
  bool _bgHintBusy = false;

  Future<void> _maybeShowBgHint() async {
    if (_bgHintBusy || AppConfig.instance.bgHintShown) return;
    _bgHintBusy = true;
    try {
      final bool granted;
      try {
        granted = (await Permission.ignoreBatteryOptimizations.status).isGranted;
      } catch (e) {
        // 查不动（插件未就绪等）：这次什么都不做，也**不置位** ——
        // 没弹过就不该算「提示过了」，下次播放再试。
        debugPrint('MuBox 后台运行引导：查权限失败 $e');
        return;
      }
      if (!shouldShowBgHint(
        alreadyShown: AppConfig.instance.bgHintShown,
        granted: granted,
      )) {
        return;
      }
      await AppConfig.instance.setBgHintShown(true);
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          SnackBar(
            content: const Text('想让 Mu Box 锁屏后继续放？给一次「后台运行」权限，否则息屏一会儿可能被系统停掉'),
            duration: const Duration(seconds: 6),
            behavior: SnackBarBehavior.floating,
            action: SnackBarAction(
              label: '去设置',
              onPressed: () => Permission.ignoreBatteryOptimizations.request(),
            ),
          ),
        );
    } finally {
      _bgHintBusy = false;
    }
  }

  /// 播放失败（文件损坏 / 被删 / 解码不了）弹一条说明。
  /// 以前只有一句 debugPrint，用户看到的就是「点了没反应、也没声音」。
  void _onPlayError() {
    final msg = playerService!.lastError.value;
    if (msg == null || !mounted) return;
    playerService!.lastError.value = null; // 取走即清，避免重建时重复弹
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 4),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  /// A-B 打点：三态循环（打 A → 打 B → 清除），结果用 SnackBar 说清楚。
  ///
  /// ⚠️ 第一次点它时把那句「第三下清除」**并进同一条** SnackBar（并把停留时间拉长到
  /// 读得完）—— ⛔ **不许再弹第二条**：上面那句 `clearSnackBars()` 会把前一条抹掉，
  /// 两条会互相盖。也⛔ **不要重复**已经说过的「再点一下打 B 点」。
  /// 「说过没有」靠 [AppConfig.abHintShown] 落盘（同 `bgHintShown` 的样板）。
  void _tapAb() {
    final first = !AppConfig.instance.abHintShown;
    final msg = playerService!.cycleAbLoop();
    // 只在这一下**真的打上了 A 点**时才补那句 —— 别在「先放一首歌再打点」
    // 或「已重置」这类结果后面挂一句文不对题的「第三下清除」。
    final showThird = first && playerService!.ab.hasA;
    if (first) {
      // fire-and-forget：弹提示不该 await 一次写盘
      AppConfig.instance.setAbHintShown(true);
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(showThird ? '$msg · 第三下清除' : msg),
          duration: Duration(milliseconds: showThird ? 3200 : 1800),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final player = playerService!;
    final lib = Library.instance;
    final hasSong = player.current != null;
    final primary = Theme.of(context).colorScheme.primary;
    final hasProgress = hasSong && player.dur.inMilliseconds > 0;
    final ab = player.ab;
    // 手指还按着、且仍然是同一首歌 → 用本地拖动值（拖动跟手，不受 500ms tick 影响）；
    // 否则一律以播放器的真实位置为准（换歌后陈旧的拖动值就此作废）。
    final drag = _dragValidFor(player) ? _dragValue : null;
    final progress = drag ??
        (hasProgress
            ? (player.pos.inMilliseconds / player.dur.inMilliseconds)
                .clamp(0.0, 1.0)
            : 0.0);
    // 时间文字也跟着拖动走，否则「拖了但数字不动」看着像没反应
    final shownMs = drag != null
        ? (drag * player.dur.inMilliseconds).round()
        : player.pos.inMilliseconds;
    // A-B 区间在进度条上的位置（未生效时为 null，什么都不画）
    final abFrac = hasProgress ? ab.fractions(player.dur) : null;

    // 这个 Stack 铺满全屏：浮层向上弹出超出播放栏区域后，
    // 仍能正确接收点击；若只包住播放栏那一点高度，弹层上面的点击会穿透到下层页面。
    return Stack(
      fit: StackFit.expand,
      children: [
        // 全屏透明遮罩：队列展开时点外部任意位置收起（关闭时不接收点击，让下层正常交互）
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_panelOpen,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _setPanelOpen(false),
            ),
          ),
        ),
        // ---- 播放队列浮层：右下角小面板，玻璃半透明 ----
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          right: 10,
          bottom: _panelOpen
              ? 8 + _barHeight
              : 8 + _barHeight - _panelHeight - 40,
          width: math.min(MediaQuery.sizeOf(context).width - 20, _panelWidth),
          height: _panelHeight,
          child: IgnorePointer(
            ignoring: !_panelOpen,
            child: Opacity(
              opacity: _panelOpen ? 1 : 0,
              child: _buildQueuePanel(player, primary),
            ),
          ),
        ),
        // ---- 播放栏主体（最上层，盖住遮罩，保证展开时也能操作播放） ----
        Positioned(
          left: 10,
          right: 10,
          bottom: 8,
          child: Material(
            color: Colors.transparent,
            elevation: 3,
            shadowColor: Colors.black,
            borderRadius: BorderRadius.circular(16),
            clipBehavior: Clip.antiAlias,
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
              child: Container(
                padding: const EdgeInsets.fromLTRB(14, 2, 6, 6),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white12),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 频谱用 RepaintBoundary 隔离：它每帧重绘，避免连带播放栏其它部分一起重绘
                    RepaintBoundary(
                      child: SpectrumView(active: player.isPlaying, height: 26),
                    ),
                    Row(
                      children: [
                        // 歌曲图标：**有图标才插这一块**（不占位、不放占位音符），
                        // 没图标时这棵子树与改动前逐像素一致。
                        // ⚠️ 必须待在**这一层**（与左列并排），别塞进下一层那行歌名里：
                        // 歌名行原本只有约 20 高，42 的图会把它撑到 42、左列跟着长高
                        // 二十来像素，整条播放栏就变高了。放这一层的高度是
                        // max(42, 原高)，而原高至少是右边控制键那一行（≥48），
                        // 所以布局与改动前完全一致。
                        if (hasSong && ArtworkStore.has(player.current!))
                          Padding(
                            padding: const EdgeInsets.only(right: 10),
                            child: SongArtwork(
                              song: player.current!,
                              size: 42,
                              radius: 10,
                            ),
                          ),
                        // ---- 左半：歌曲信息 + 进度条 ----
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      hasSong
                                          ? lib.displayTitle(player.current!)
                                          : '未在播放',
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                  if (hasSong)
                                    IconButton(
                                      visualDensity: VisualDensity.compact,
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      icon: Icon(
                                        lib.isFav(player.current!)
                                            ? Icons.favorite
                                            : Icons.favorite_border,
                                        size: 18,
                                        color: lib.isFav(player.current!)
                                            ? Colors.white
                                            : Colors.white38,
                                      ),
                                      tooltip: '收藏/取消收藏',
                                      onPressed: () =>
                                          lib.toggleFav(player.current!),
                                    ),
                                  if (hasSong)
                                    Text(
                                      '${fmtMs(shownMs)}/${player.current!.durationText}',
                                      style: const TextStyle(
                                        fontSize: 10,
                                        color: Colors.white38,
                                      ),
                                    ),
                                ],
                              ),
                              SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 2,
                                  // 自定义轨道：只在 A-B 区间上多叠一条高亮带，
                                  // 没打点/没生效时绘制结果与默认轨道逐像素一致。
                                  trackShape: _AbTrackShape(abFrac: abFrac),
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 5,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 12,
                                  ),
                                ),
                                child: Slider(
                                  value: progress,
                                  onChangeStart: hasProgress
                                      ? (v) => setState(() {
                                            _dragValue = v;
                                            _dragSongId = player.current?.id;
                                          })
                                      : null,
                                  onChanged: hasProgress
                                      ? (v) => setState(() {
                                            _dragValue = v;
                                            _dragSongId = player.current?.id;
                                          })
                                      : null,
                                  // 松手才真正 seek（见 _dragValue 的说明）
                                  onChangeEnd: hasProgress
                                      ? (v) {
                                          final ms =
                                              (v * player.dur.inMilliseconds)
                                                  .round();
                                          setState(() {
                                            _dragValue = null;
                                            _dragSongId = null;
                                          });
                                          player.seek(
                                            Duration(milliseconds: ms),
                                          );
                                        }
                                      : null,
                                  // ⚠️ 已播那一段 = **纯白**，刻意不跟主题色
                                  //    （原来是 primary）—— 产品要求是「不要再随着
                                  //    主题色了」。`inactiveColor` 的
                                  //    white12 本来就不是主题色，保持原样没动。
                                  //    只改这一处 ⇒ 滑块圆点与按下光晕会一起变白：
                                  //    框架侧 `slider.dart:917` 的 `thumbColor =
                                  //    widget.thumbColor ?? widget.activeColor ?? …`、
                                  //    `:876-881` 的 `effectiveOverlayColor()` 同样
                                  //    `widget.activeColor?.withOpacity(0.12)`。
                                  activeColor: Colors.white,
                                  inactiveColor: Colors.white12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // ---- 右半：控制按钮 + 队列展开 ----
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(
                                    Icons.skip_previous,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                  onPressed: hasSong
                                      ? player.skipToPrevious
                                      : null,
                                ),
                                // ⚠️ 播放/暂停 = **裸字形 + 纯白**，刻意不跟主题色。
                                //    原来是 `*_circle_filled` 染 primary —— 那是「主题色实心
                                //    圆盘 + 挖空的符号」，产品要求是「没有底色、
                                //    本身白色」，与左右两颗跳过键同色。⛔ 别改回 primary。
                                IconButton(
                                  // ⚠️ 34 是**看过真机前后图之后定**的
                                  //    （40 → 34：裸三角看着嫌大，要小一点）。
                                  //    只改这个数：**字形与颜色一个都没动**。
                                  //    ⛔ 改它必须同步改颜色测试里的
                                  //    finder（`w.iconSize == 34`）与金标 `_kBeforeGlyphBox`。
                                  iconSize: 34,
                                  padding: EdgeInsets.zero,
                                  icon: Icon(
                                    player.isPlaying
                                        ? Icons.pause
                                        : Icons.play_arrow,
                                    color: Colors.white,
                                  ),
                                  onPressed: player.toggle,
                                ),
                                IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(
                                    Icons.skip_next,
                                    color: Colors.white,
                                    size: 26,
                                  ),
                                  onPressed: hasSong ? player.skipToNext : null,
                                ),
                              ],
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // A-B 片段循环：一个按钮三态循环（打 A → 打 B → 清除），
                                // 生效时进度条上会多一条高亮带，按钮也跟着点亮。
                                // 外面包一层 Tooltip：这颗按钮**没有 tooltip 参数**，
                                // 而「三下清除」这条只靠 SnackBar 说一次，忘了就没处查。
                                Tooltip(
                                  message: 'A-B 片段循环：点一下打 A 点、再点一下打 B 点、第三下清除',
                                  child: TextButton.icon(
                                    style: TextButton.styleFrom(
                                      visualDensity: VisualDensity.compact,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      minimumSize: Size.zero,
                                      tapTargetSize:
                                          MaterialTapTargetSize.shrinkWrap,
                                    ),
                                    icon: Icon(
                                      ab.active
                                          ? Icons.repeat_on
                                          : Icons.repeat,
                                      size: 16,
                                      color: ab.active
                                          ? primary
                                          : (ab.hasA
                                                ? Colors.white70
                                                : Colors.white54),
                                    ),
                                    label: Text(
                                      ab.active
                                          ? 'A-B'
                                          : (ab.hasA ? '打 B' : 'A-B'),
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: ab.active
                                            ? primary
                                            : (ab.hasA
                                                  ? Colors.white70
                                                  : Colors.white54),
                                      ),
                                    ),
                                    onPressed: hasSong ? _tapAb : null,
                                  ),
                                ),
                                // 倍速：点开选播放速度，非 1.0 时高亮显示当前倍率
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  icon: Icon(
                                    Icons.speed,
                                    size: 16,
                                    color: player.speed == 1.0
                                        ? Colors.white54
                                        : primary,
                                  ),
                                  label: Text(
                                    _speedText(player.speed),
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: player.speed == 1.0
                                          ? Colors.white54
                                          : primary,
                                    ),
                                  ),
                                  onPressed: _showSpeedSheet,
                                ),
                                // 队列：靠右，点开/收起右下角队列浮层
                                TextButton.icon(
                                  style: TextButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                    ),
                                    minimumSize: Size.zero,
                                    tapTargetSize:
                                        MaterialTapTargetSize.shrinkWrap,
                                  ),
                                  icon: Icon(
                                    _panelOpen
                                        ? Icons.expand_more
                                        : Icons.queue_music,
                                    size: 16,
                                    color: Colors.white54,
                                  ),
                                  label: Text(
                                    _panelOpen ? '收起' : '队列',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      color: Colors.white54,
                                    ),
                                  ),
                                  onPressed: () => _setPanelOpen(!_panelOpen),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 倍速文本：1.0 显示「倍速」，其余显示如「1.5x」。
  String _speedText(double s) {
    if (s == 1.0) return '倍速';
    final t = s == s.roundToDouble() ? '${s.round()}' : '$s';
    return '${t}x';
  }
  /// 弹出倍速选择（底部玻璃面板），选中后应用到播放器。
  Future<void> _showSpeedSheet() async {
    final player = playerService!;
    final v = await showModalBottomSheet<double>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        final primary = Theme.of(ctx).colorScheme.primary;
        return GlassPanel(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: Text(
                    '播放倍速',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                for (final s in _speeds)
                  ListTile(
                    dense: true,
                    title: Text(
                      s == 1.0 ? '1x' : _speedText(s),
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                    trailing: player.speed == s
                        ? Icon(Icons.check, color: primary, size: 18)
                        : null,
                    onTap: () => Navigator.pop(ctx, s),
                  ),
              ],
            ),
          ),
        );
      },
    );
    if (v != null) await player.setSpeed(v);
  }

  Widget _buildQueuePanel(PlayerService player, Color primary) {
    final lib = Library.instance;
    final queue = player.queueList;
    return Material(
      color: Colors.transparent,
      elevation: 3,
      shadowColor: Colors.black,
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: Colors.white12),
          ),
          child: Column(
            children: [
              // 标题行 + 关闭按钮（操作提示挂在标题下面，**一点额外高度都不占**）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            player.queueSourceName.isEmpty
                                ? '播放队列 · ${queue.length} 首'
                                : '${player.queueSourceName} · ${queue.length} 首',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                          const SizedBox(height: 2),
                          // ★ 操作提示：**从页脚挪进标题这一格**，不再占任何额外高度。
                          //
                          // 为什么不直接删：它是下面两颗控件的**唯一文字说明** ——
                          // 勾选框（参与循环）和减号（从队列移除）**都没有文字标签**，
                          // 删了新手只能靠试。
                          // 为什么挪得进：这一格的高度由右边的关闭按钮（compact
                          // IconButton，40px）撑着，标题那行 14px 只用掉 ~20px，
                          // **下面本来就空着 ~20px**。提示（9px 一行）塞进这块空白即可，
                          // 整行高度仍是 40 ⇒ 头部总高与改动前**逐像素相同**。
                          // 而原来它单独占页脚 27px（padding 4+8 + 一行 14），浮层总高固定
                          // 320 ⇒ 那 27px 全是从列表嘴里抢的，正是**当前播放那一行被列表
                          // 视口裁掉 5px** 的直接原因（量法见交付报告）。
                          Text(
                            '勾选 = 参与循环播放；点右侧图标 = 从队列移除',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 9,
                              height: 1.0,
                              color: Colors.white38,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.close,
                        size: 18,
                        color: Colors.white54,
                      ),
                      tooltip: '关闭',
                      onPressed: () => _setPanelOpen(false),
                    ),
                  ],
                ),
              ),
              // 播放模式：三个 chip 平分一行
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    for (final m in const [
                      ['list', '列表循环'],
                      ['single', '单曲循环'],
                      ['shuffle', '随机播放'],
                    ])
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 3),
                          child: ChoiceChip(
                            label: Text(
                              m[1],
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 10,
                                color: player.mode == m[0]
                                    ? Colors.white
                                    : Colors.white60,
                              ),
                            ),
                            selected: player.mode == m[0],
                            visualDensity: VisualDensity.compact,
                            selectedColor: primary,
                            onSelected: (_) => player.setMode(m[0]),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // 历史播放：开关（开=换成历史列表，关=恢复当前歌单；保留播放模式）
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Row(
                  children: [
                    const Icon(Icons.history, color: Colors.white54, size: 16),
                    const SizedBox(width: 6),
                    const Expanded(
                      child: Text(
                        '历史播放',
                        style: TextStyle(fontSize: 12, color: Colors.white),
                      ),
                    ),
                    Switch(
                      value: player.historyMode,
                      activeThumbColor: primary,
                      onChanged: (_) => player.toggleHistoryMode(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: Colors.white10),
              // 队列列表：勾选参与循环，可移除
              Expanded(
                child: queue.isEmpty
                    ? const Center(
                        child: Text(
                          '队列为空，去歌单里点一首歌吧',
                          style: TextStyle(color: Colors.white38, fontSize: 12),
                        ),
                      )
                    // ★ 底部渐隐：列表比面板高时，最下面那一行会被面板下边缘**切一半**
                    //    （露出半截字、半截勾选框），看着像画坏了 —— 这里让最下面 ~20px
                    //    渐隐："下面还有"的暗示还在，但不会再出现半截字。
                    //
                    //    为什么非要有它：面板总高固定 320，列表装不满整行是常态；
                    //    上一版（把提示留在页脚）是"当前播放那一行被切 5px"，
                    //    只把高度还给列表、不处理边缘的话，**同一个毛病会挪到下一行去**
                    //    （实测：当前行完整了，第 4 行改成被切 27px）。
                    //    修的是"切"这件事本身，不是某一行。
                    //    纯视觉、独立可删：去掉这层 ShaderMask 就回到"直接裁"。
                    : ShaderMask(
                        shaderCallback: (rect) => const LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                          ],
                          stops: [0.0, 0.87, 1.0],
                        ).createShader(rect),
                        blendMode: BlendMode.dstIn,
                        child: ListView.builder(
                          controller: _queueScroll,
                          itemCount: queue.length,
                          // 底部留 4px 收边：滚到底时最后一项不贴着浮层圆角
                          padding: const EdgeInsets.only(
                            bottom: _queueListBottomPad,
                          ),
                          itemBuilder: (context, i) {
                            final s = queue[i];
                            final isCurrent = s.id == player.current?.id;
                            // ★ 当前播放项整行高亮：底色 + 左侧 3px 竖条。
                            //    原来只有 primary 文字 + 加粗 —— 在玻璃底上几乎看不出，
                            //    而且它常常正好落在列表底部、只有半行。
                            //
                            //    ⚠️ **必须用 Container 包**（画在浮层自己的内容层里），
                            //    **不能用 `ListTile.tileColor` / `shape`** —— 那两样画在
                            //    Material 的 ink 层上，位置在浮层自己的 `BackdropFilter`
                            //    **之前** ⇒ 会被一起糊掉：实测底色变成一团虚光、
                            //    左侧竖条完全看不见。
                            return Container(
                              decoration: isCurrent
                                  ? BoxDecoration(
                                      color: primary.withValues(alpha: 0.18),
                                      border: Border(
                                        left: BorderSide(
                                          color: primary,
                                          width: 3,
                                        ),
                                      ),
                                    )
                                  : null,
                              child: ListTile(
                                dense: true,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                leading: Checkbox(
                                  value: player.loopEnabled(s),
                                  activeColor: primary,
                                  onChanged: (v) =>
                                      player.setLoopEnabled(s, v ?? true),
                                ),
                                title: Text(
                                  lib.displayTitle(s),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: isCurrent ? primary : Colors.white,
                                    fontWeight: isCurrent
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                                // 点击队列项直接切到这首歌播放
                                onTap: () => player.playAt(i),
                                trailing: IconButton(
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(
                                    Icons.remove_circle_outline,
                                    size: 18,
                                    color: Colors.white38,
                                  ),
                                  tooltip: '从队列移除',
                                  onPressed: () => player.removeFromQueue(s),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
              ),
              // 操作提示已经挪到标题区（见上面那段注释），页脚这一整块（27px）省给列表 ——
              // 少的就是「当前播放那一行被视口裁掉」的那几个像素。
            ],
          ),
        ),
      ),
    );
  }
}

/// 进度条轨道：在默认圆角轨道之上，给 A-B 循环区间叠一条半透明高亮带。
///
/// 为什么不直接在进度条上盖一个 Positioned 色块：Slider 的轨道两端各有一段内缩
/// （等于「滑块半径 / 光晕半径」里较大的那个），硬算内缩量会在换主题、改 trackHeight
/// 时对不齐。这里直接问父类要 [getPreferredRect] —— 与轨道用的是同一个矩形，
/// 天然像素级贴合。`abFrac` 为 null（没打点 / 区间无效）时不画任何东西，
/// 绘制结果与默认轨道**逐像素一致**。
class _AbTrackShape extends RoundedRectSliderTrackShape {
  /// A、B 两点在整首歌里的比例（0~1）；null = 不画高亮带
  final (double, double)? abFrac;

  const _AbTrackShape({this.abFrac});

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    super.paint(
      context,
      offset,
      parentBox: parentBox,
      sliderTheme: sliderTheme,
      enableAnimation: enableAnimation,
      textDirection: textDirection,
      thumbCenter: thumbCenter,
      secondaryOffset: secondaryOffset,
      isDiscrete: isDiscrete,
      isEnabled: isEnabled,
      additionalActiveTrackHeight: additionalActiveTrackHeight,
    );
    final f = abFrac;
    if (f == null) return;
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.width <= 0) return;
    // 上下各撑出去 4px，让这条带子在 2px 细轨道上也看得见
    final band = RRect.fromLTRBR(
      rect.left + rect.width * f.$1,
      rect.top - 4,
      rect.left + rect.width * f.$2,
      rect.bottom + 4,
      const Radius.circular(3),
    );
    context.canvas.drawRRect(
      band,
      Paint()..color = Colors.white.withValues(alpha: 0.22),
    );
  }
}
