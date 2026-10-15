/// 根页面：六页二维导航（3 列 × 2 行）+ 底部玻璃播放栏。
///
/// 外层垂直 PageView 管「上下滑」切换行：上行 = 主页面，下行 = 附属页
/// （享受/歌词/自定义）。上行内层水平 PageView 管「左右滑」切列；下行内层锁左右滑。
/// 页面内容不滚动（NeverScrollable），垂直手势全部让给翻页，避免手势打架。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_config.dart';
import '../artwork.dart';
import '../library_data.dart';
import '../player_service.dart';
import '../visual_presets.dart';
import '../widgets/ambient_layer.dart';
import '../widgets/player_bar.dart';
import '../widgets/song_search_sheet.dart';
import '../widgets/wallpaper_layer.dart';
import 'custom_page.dart';
import 'enjoy_page.dart';
import 'lyrics_page.dart';
import 'playlists_page.dart';
import 'settings_page.dart';
import 'wallpaper_page.dart';

class RootPage extends StatefulWidget {
  const RootPage({super.key});

  @override
  State<RootPage> createState() => _RootPageState();
}

class _RootPageState extends State<RootPage> {
  // 外层：垂直 2 行（上行/下行），初始在上行
  final PageController _rowCtrl = PageController();
  // 上行内层：水平 3 列，初始在中间歌单列
  final PageController _topColCtrl = PageController(initialPage: 1);
  // 下行内层：水平 3 列，锁左右滑，仅跟随上行切列
  final PageController _bottomColCtrl = PageController(initialPage: 1);
  // 进入歌单详情后禁止翻页，返回默认页恢复
  bool _detailActive = false;
  // 歌单页句柄：把系统返回转交给它（关抽屉 / 退出多选 / 退出详情）
  final GlobalKey<PlaylistsPageState> _playlistsKey =
      GlobalKey<PlaylistsPageState>();
  // 歌词页句柄：正在编辑歌词时，把系统返回转交给它（吃掉返回 → 回到校准面板）
  final GlobalKey<LyricViewState> _lyricsKey = GlobalKey<LyricViewState>();
  // 上次返回时间：2 秒内连续两次返回才真正退出 App
  DateTime? _lastBack;
  // 当前行/列：同步「享受页激活」给壁纸层（享受页 = 下行第 0 列，壁纸用原图亮度）
  int _row = 0;
  int _col = 1;
  // 播放栏的重建源（播放位置 tick + 音乐库变化 + 歌曲图标变化）：提到字段里建一次复用，
  // 避免每次 build 新建 merge 导致监听反复解绑/重绑（播放栏每 500ms 重建一次）。
  late final Listenable _playerBarSources = Listenable.merge([
    playerService?.notifier,
    Library.instance,
    ArtworkStore.revision,
  ]);

  @override
  void initState() {
    super.initState();
    Library.instance.init();
  }

  @override
  void dispose() {
    _rowCtrl.dispose();
    _topColCtrl.dispose();
    _bottomColCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        // 键盘弹出时不压缩 body：壁纸、氛围层、播放栏保持全屏不动（对话框会自动顶到键盘上方）
        resizeToAvoidBottomInset: false,
        body: Stack(
          children: [
            // 全局背景层 + 氛围特效层：合成进一个 RepaintBoundary，
            // 保存「视觉方案」时从这里截取享受页竖版缩略图（只含壁纸+特效，不含播放栏）。
            Positioned.fill(
              child: RepaintBoundary(
                key: VisualPresets.shotKey,
                child: const Stack(
                  fit: StackFit.expand,
                  // ⚠️ 这一处是**唯一的真背景**：暂停时冻结动画省电，再播放立刻恢复
                  // （U0）。其余 7 处 AmbientLayer 都是特效预览/次要页面，不能冻结 ——
                  // 用户经常「暂停着调特效」，预览死了会被当成特效坏了。
                  children: [WallpaperLayer(), AmbientLayer(freezeOnPause: true)],
                ),
              ),
            ),
            // 外层垂直 PageView：上下滑切换上行/下行
            PageView(
              controller: _rowCtrl,
              scrollDirection: Axis.vertical,
              // 保持上下两行都存活，下行才能随时跟随上行切列
              allowImplicitScrolling: true,
              physics: (_detailActive || _lyricsLocked)
                  ? const NeverScrollableScrollPhysics()
                  : const _LoosePagePhysics(),
              onPageChanged: (r) {
                setState(() => _row = r);
                _syncEnjoy();
              },
              children: [
                // 上行：左右滑切列
                PageView.builder(
                  controller: _topColCtrl,
                  physics: _detailActive
                      ? const NeverScrollableScrollPhysics()
                      : const _LoosePagePhysics(),
                  onPageChanged: (c) {
                    setState(() => _col = c);
                    _syncEnjoy();
                    // 下行跟随同列；未挂载时跳过（allowImplicitScrolling 下基本总已挂载）
                    if (_bottomColCtrl.hasClients) _bottomColCtrl.jumpToPage(c);
                  },
                  itemCount: 3,
                  itemBuilder: (_, c) => _topPage(c),
                ),
                // 下行：锁左右滑（physics 恒为 NeverScrollable）
                PageView.builder(
                  controller: _bottomColCtrl,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: 3,
                  itemBuilder: (_, c) => _bottomPage(c),
                ),
              ],
            ),
            // 右下角搜索悬浮按钮（`search_fab` 开关，缺省关 ⇒ 这棵树整个不存在）。
            //
            // 位置：右下角、**播放栏正上方**（偏移量与实测依据见
            // `widgets/song_search_sheet.dart` 的 `kSearchFabBottom`）。
            // ⚠️ 必须放在**播放栏那一层之前**入栈：这样队列浮层与播放栏都画在它上面 ——
            // 队列一展开就把它整个盖住（也就不会抢浮层右上角那颗 ✕），收起时又完全不挡
            // （浮层收起时那层 `IgnorePointer` 是 ignoring 的，点击照落到这颗按钮上）。
            Positioned(
              right: kSearchFabRight,
              bottom: kSearchFabBottom,
              child: ValueListenableBuilder<bool>(
                // ⚠️ 独立 ValueNotifier（照 `AppConfig.enjoyActive` 先例）：切这个开关
                // 只重建这一颗按钮，⛔ 不走 `_bumpRebuild()`（那会整棵 MaterialApp 重建）。
                valueListenable: AppConfig.instance.searchFabEnabled,
                builder: (context, on, _) {
                  // 关了 = 现在的界面（连子树都不建）；享受页刻意留白，也不显示。
                  if (!on || _enjoyPage) return const SizedBox.shrink();
                  return SearchFab(
                    onTap: _openGlobalSearch,
                    tooltip: kGlobalSearchTitle,
                  );
                },
              ),
            ),
            // 底部玻璃播放栏：全屏 Stack 承载，队列浮层向上弹出也能正确接收点击
            Positioned.fill(
              child: ListenableBuilder(
                listenable: _playerBarSources,
                builder: (context, _) => PlayerBar(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 上行第 c 列的页面。
  Widget _topPage(int c) => switch (c) {
    0 => const WallpaperPage(),
    1 => PlaylistsPage(
      key: _playlistsKey,
      onDetailChanged: (v) => setState(() => _detailActive = v),
    ),
    _ => const SettingsPage(),
  };

  /// 下行第 c 列的页面。
  Widget _bottomPage(int c) => switch (c) {
    0 => const EnjoyPage(),
    1 => LyricsPage(viewKey: _lyricsKey),
    _ => const CustomPage(),
  };

  /// 歌词页（下行中列）激活时锁定上下翻页：歌词页里上滑不再回歌单，
  /// 回歌单改走手机系统侧滑返回（PopScope 已处理）。其余页不受影响。
  bool get _lyricsLocked => _row == 1 && _col == 1;

  /// 享受页（下行左列）激活中。壁纸层按它换亮度，右下角那颗搜索悬浮按钮按它隐藏
  /// —— 那一页是**刻意留白**的纯视觉页，多一颗按钮就破功了（六个页面里只有它不给）。
  bool get _enjoyPage => _row == 1 && _col == 0;

  /// 同步「享受页激活」状态给壁纸层：享受页 = 下行第 0 列，该页壁纸用原图亮度。
  void _syncEnjoy() {
    AppConfig.instance.enjoyActive.value = _enjoyPage;
  }

  /// 右下角悬浮按钮：**直接进搜索界面**，搜的是**整个曲库**。
  ///
  /// 与歌单详情页那颗放大镜共用同一个弹层（`showSongSearchSheet`），区别只有两处：
  /// 传的是 `globalSearchSongs()`（= `songsOf(kAllSongs)`，**已过滤私密歌**）、
  /// 标题是「搜索曲库」。点结果直接播放，队列标题用「全部歌曲」。
  Future<void> _openGlobalSearch() async {
    final songs = globalSearchSongs();
    if (songs.isEmpty) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(
          const SnackBar(
            content: Text('曲库还没有歌曲'),
            duration: Duration(milliseconds: 1500),
            behavior: SnackBarBehavior.floating,
          ),
        );
      return;
    }
    final idx = await showSongSearchSheet(
      context,
      songs: songs,
      title: kGlobalSearchTitle,
    );
    if (!mounted) return; // await 期间页面可能已经销毁
    if (idx == null || idx < 0 || idx >= songs.length) return;
    await playerService!.playQueue(songs, idx, title: kAllSongs);
  }

  /// 系统返回（侧滑/返回键）：先让歌词页处理（正在编辑歌词 → 吃掉返回、回到校准
  /// 面板），再让歌单页处理自己的返回（抽屉/多选/详情），最后回默认歌单页
  /// （上行中列）；已在默认页则走「两次返回退出」。
  void _handleBack() {
    if (_lyricsKey.currentState?.handleBack() ?? false) return;
    if (_playlistsKey.currentState?.handleBack() ?? false) return;
    final row = _rowCtrl.hasClients ? (_rowCtrl.page ?? 0).round() : 0;
    final col = _topColCtrl.hasClients ? (_topColCtrl.page ?? 1).round() : 1;
    if (row != 0) {
      _rowCtrl.animateToPage(
        0,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    if (col != 1) {
      _topColCtrl.animateToPage(
        1,
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    _maybeExitApp();
  }

  /// 已在默认歌单页：2 秒内连续两次返回才退出，第一次只给提醒。
  void _maybeExitApp() {
    final now = DateTime.now();
    final last = _lastBack;
    _lastBack = now;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      SystemNavigator.pop();
      return;
    }
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        const SnackBar(
          content: Text('再滑一次退出 Mu Box'),
          duration: Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

/// 更宽松的翻页物理：相比 PageView 默认的“拖过半页才翻页”，
/// 松开时只要带一点速度，拖过约 1/3 页就会翻过去，左右/上下滑更顺手。
/// 方向无关，水平/垂直 PageView 均适用。
class _LoosePagePhysics extends PageScrollPhysics {
  const _LoosePagePhysics({super.parent});

  @override
  _LoosePagePhysics applyTo(ScrollPhysics? ancestor) =>
      _LoosePagePhysics(parent: buildParent(ancestor));

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    // 越界回弹交给父物理处理
    if ((velocity <= 0.0 && position.pixels <= position.minScrollExtent) ||
        (velocity >= 0.0 && position.pixels >= position.maxScrollExtent)) {
      return super.createBallisticSimulation(position, velocity);
    }
    final tolerance = toleranceFor(position);
    // 带速度时给页偏移量加 0.3（默认 0.5）：轻轻一拖就能翻过去
    var page = position.pixels / position.viewportDimension;
    if (velocity < -tolerance.velocity) {
      page -= 0.3;
    } else if (velocity > tolerance.velocity) {
      page += 0.3;
    }
    final pages = position.maxScrollExtent / position.viewportDimension;
    page = page.roundToDouble().clamp(0.0, pages);
    final target = page * position.viewportDimension;
    if (target != position.pixels) {
      return ScrollSpringSimulation(
        spring,
        position.pixels,
        target,
        velocity,
        tolerance: tolerance,
      );
    }
    return null;
  }
}
