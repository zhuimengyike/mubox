/// 曲库搜索：**一份**弹层 + **一个**开弹层的入口，给两处共用。
///
/// 1. 歌单详情页右上角那颗放大镜（tooltip「搜索当前歌单」）—— 传当前歌单的歌；
/// 2. 根页面右下角那颗悬浮按钮（`search_fab`）—— 传 `Library.instance.songsOf(kAllSongs)`
///    （**必须过私密过滤**：这是唯一一个从任意页面直接开搜索的入口）。
///
/// ⚠️ 搜索语义（歌名 / 歌手二选一 + 子串匹配）**一个字都没动**：弹层是从
/// `playlists_page.dart` 的私有 `_SongSearchSheet` 原样搬过来的，只多了可传的 [title]。
/// 要改搜索语义是另一单，别在这儿顺手改。
library;

import 'package:flutter/material.dart';

import '../library_data.dart';
import '../models.dart';
import 'glass_panel.dart';

/// 搜索弹层的锚点（测试用；字面量与 `test/song_search_sheet_test.dart` 一致）。
const ValueKey<String> kSongSearchSheetKey = ValueKey<String>('song_search_sheet');

/// 右下角悬浮搜索按钮的锚点。
const ValueKey<String> kSearchFabKey = ValueKey<String>('search_fab');

// ───────────────────────── 悬浮按钮几何（真机/测试实测口径） ─────────────────────────

/// 按钮边长（**圆角正方形**）：48 = Material 最小可点尺寸，也是播放栏那颗播放键的
/// 视觉重量级；再小手指不好点，再大就会压到播放栏上方的空白。
const double kSearchFabSize = 48;

/// 圆角：播放栏 / 队列浮层是 16，这颗按钮小一圈，用 14 才不显"太圆"。
const double kSearchFabRadius = 14;

/// 右边距：与播放栏的 `Positioned(right: 10)` **同一列**（对齐才不显得斜）。
const double kSearchFabRight = 10;

/// 与播放栏**顶边**之间的空隙。
const double kSearchFabGap = 10;

/// 距屏幕底边的距离 = 播放栏占位 + 空隙。
///
/// ⚠️ 依据（`test/song_search_sheet_test.dart` 的 ★5 实测，不是拍的）：
/// `player_bar.dart` 的 `_PlayerBarState._barHeight = 116` 是**播放栏连同它自己的
/// 8px 底边距**占掉的整块高度（队列浮层就是按 `bottom: 8 + _barHeight = 124` 贴在
/// 播放栏顶边上的）⇒ 播放栏顶边距屏幕底边 = 116。
/// 本常量再留 [kSearchFabGap] ⇒ 按钮**整颗**都在播放栏上方，与进度条 / 上一首 /
/// 播放 / 下一首 / 收藏 / A-B / 倍速 / 队列**零重叠**（★5 用真 `PlayerBar` 量真矩形）。
/// ★5 还钉着"播放栏哪天长高了这里必须红"，所以这个数不会悄悄过期。
const double kSearchFabBottom = 116 + kSearchFabGap;

/// 右下角悬浮搜索按钮：圆角正方形 + 本 App 的玻璃质感（**不是** Material 的
/// `FloatingActionButton` 造型 —— 那个是圆形/大圆角 + 实心底色 + elevation，
/// 放在这条播放栏上方跟周围格格不入）。
///
/// 显隐不在这里判断：由根页面用 `ValueListenableBuilder` 包着
/// `AppConfig.instance.searchFabEnabled` 决定它**在不在树上**（见 `root_page.dart`）。
class SearchFab extends StatelessWidget {
  const SearchFab({super.key, required this.onTap, this.tooltip = '搜索曲库'});

  final VoidCallback onTap;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        key: kSearchFabKey,
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: kSearchFabSize,
          height: kSearchFabSize,
          // 玻璃质感与弹层/播放栏同源（`GlassPanel` = 半透明白 + 背景模糊 + 白边框），
          // 只是半径按小方块调小一号、模糊也收一点（小面积上 20 的模糊会糊成一团灰）。
          child: GlassPanel(
            borderRadius: BorderRadius.circular(kSearchFabRadius),
            blur: 14,
            child: const Center(
              child: Icon(Icons.search, size: 22, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

/// 弹层：顶部标题 + 关闭，下面搜索框 + 歌名/歌手紧凑切换 + 结果列表，点结果直接播放。
///
/// ⚠️ **私有 `_SongSearchSheet` 的原样搬迁**（`playlists_page.dart` 里那份已删），
/// 唯一的改动 = 标题从写死的「搜索当前歌单」变成入参 [title]。
class SongSearchSheet extends StatefulWidget {
  /// 要搜的集合（歌单详情页传当前歌单、全局搜索传 `songsOf(kAllSongs)`）。
  final List<Song> songs;

  /// 弹层标题（歌单页「搜索当前歌单」/ 全局「搜索曲库」）。
  final String title;

  /// 点结果回调：参数是它在 [songs] 里的下标（与原来一致）。
  final ValueChanged<int> onPlay;

  const SongSearchSheet({
    super.key,
    required this.songs,
    required this.title,
    required this.onPlay,
  });

  @override
  State<SongSearchSheet> createState() => _SongSearchSheetState();
}

class _SongSearchSheetState extends State<SongSearchSheet> {
  final TextEditingController _ctrl = TextEditingController();
  int _mode = 0; // 0 歌名 / 1 歌手

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  List<Song> get _shown {
    final q = _ctrl.text.trim().toLowerCase();
    if (q.isEmpty) return widget.songs;
    if (_mode == 0) {
      return widget.songs
          .where((s) =>
              Library.instance.displayTitle(s).toLowerCase().contains(q))
          .toList();
    }
    return widget.songs.where((s) => s.artist.toLowerCase().contains(q)).toList();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final shown = _shown;
    return SafeArea(
      child: SizedBox(
        key: kSongSearchSheetKey,
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题行
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 2),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        size: 18, color: Colors.white54),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // 副标题
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Text(
                '共 ${widget.songs.length} 首 · 点歌曲播放',
                style: const TextStyle(fontSize: 12, color: Colors.white38),
              ),
            ),
            // 搜索框 + 歌名/歌手（紧凑相邻）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _ctrl,
                    onChanged: (_) => setState(() {}),
                    textInputAction: TextInputAction.search,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: '搜索歌曲名…',
                      hintStyle:
                          const TextStyle(fontSize: 13, color: Colors.white38),
                      prefixIcon: const Icon(Icons.search,
                          size: 18, color: Colors.white54),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.06),
                      contentPadding:
                          const EdgeInsets.symmetric(vertical: 10),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(color: Colors.white12),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: primary, width: 1.2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: SegmentedButton<int>(
                      style: SegmentedButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        selectedBackgroundColor: primary,
                        foregroundColor: Colors.white54,
                        selectedForegroundColor: Colors.white,
                        side: const BorderSide(color: Colors.white24),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      segments: const [
                        ButtonSegment(value: 0, label: Text('歌名')),
                        ButtonSegment(value: 1, label: Text('歌手')),
                      ],
                      selected: {_mode},
                      onSelectionChanged: (s) =>
                          setState(() => _mode = s.first),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 20),
            // 结果列表
            Expanded(
              child: shown.isEmpty
                  ? const Center(
                      child: Text(
                        '没有匹配的歌曲',
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                  : ListView.builder(
                      itemCount: shown.length,
                      itemBuilder: (context, i) {
                        final s = shown[i];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.music_note,
                              color: Colors.white38, size: 18),
                          title: Text(
                            Library.instance.displayTitle(s),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Colors.white, fontSize: 14),
                          ),
                          subtitle: _mode == 1 && s.artist.isNotEmpty
                              ? Text(s.artist,
                                  style: const TextStyle(
                                      color: Colors.white38, fontSize: 11))
                              : null,
                          trailing: Text(s.durationText,
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 12)),
                          onTap: () =>
                              widget.onPlay(widget.songs.indexOf(s)),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 弹出搜索面板：**两处入口唯一的那条路**（歌单详情页 / 根页面右下角按钮）。
///
/// 形状与原来歌单页的 `_glassSheet(scrollControlled: true, …)` 逐项相同：
/// 透明背景 + 顶部圆角 20 的毛玻璃 + `SafeArea` + 75% 屏高的 [SongSearchSheet]。
///
/// 返回被点中结果在 [songs] 里的下标；关闭 / 取消返回 null。
Future<int?> showSongSearchSheet(
  BuildContext context, {
  required List<Song> songs,
  required String title,
}) {
  return showModalBottomSheet<int>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (ctx) => GlassPanel(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        child: SongSearchSheet(
          songs: songs,
          title: title,
          onPlay: (i) => Navigator.pop(ctx, i),
        ),
      ),
    ),
  );
}

/// 全局搜索（「搜整个曲库」）要搜的集合。
///
/// ⚠️ 单独抽成函数是为了**只有这一处**决定"全局搜索搜什么"：必须过私密过滤
/// （`songsOf(kAllSongs)`），⛔ 不许改成 `Library.instance.songs` —— 那会把私密歌
/// 从任意页面暴露出来（本项目硬规矩：任何"往界面外/公共面暴露"的路径都要过私密过滤）。
List<Song> globalSearchSongs() => Library.instance.songsOf(kAllSongs);

/// 全局搜索弹层的标题。
const String kGlobalSearchTitle = '搜索曲库';

/// 歌单详情页那条入口用的标题（**逐字符不变**）。
const String kPlaylistSearchTitle = '搜索当前歌单';
