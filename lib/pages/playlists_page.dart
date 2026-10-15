/// 中间页：默认页显示歌单方框（2 列网格），点开进入歌单详情；
/// 详情左上角返回箭头 + 展开按钮，左侧抽屉列出全部歌单可切换。
library;

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

import '../app_config.dart';
import '../artwork.dart';
import '../library_data.dart';
import '../models.dart';
import '../player_service.dart';
import '../smooth_route.dart';
import '../theme.dart';
import '../widgets/glass_panel.dart';
import '../widgets/input_dialog.dart';
import '../widgets/row_turn_scroll.dart';
import '../widgets/song_artwork.dart';
import '../widgets/song_search_sheet.dart';
import 'artwork_crop_page.dart';
import 'library_group_page.dart';

part 'playlists_pick_sheet.dart';
part 'playlists_drag_handle.dart';

/// 存一首歌的图标，**并把通知栏那一份 metadata 重推一次**（§4b(1) 的修复）。
///
/// 放在模块级、`playerService` 当参数传，是为了让这条修复**能被测试直接驱动**
/// （`PlaylistsPage` 整棵 widget 树在 `flutter test` 里起不来：选图要走相册）。
/// 页面里的 [_saveArtwork] 只是把全局 `playerService` 接进来 —— 真实现走的就是
/// 这里，不是另抄一份逻辑。
Future<void> saveArtwork(Song song, Uint8List bytes, PlayerService? player) async {
  await ArtworkStore.save(song, bytes);
  refreshArtworkIfCurrent(song, player);
}

/// 图标变了之后重推通知栏 metadata；**改的不是当前播放那首时什么都不做**。
///
/// ⚠️ 通知栏挂的是当前曲：这时候重推等于拿别的歌的 artUri 去覆盖它
/// （与 `library_data.dart` 里「改非当前曲不许动通知栏」同一条规矩）。
void refreshArtworkIfCurrent(Song song, PlayerService? player) {
  if (player == null) return;
  if (player.current?.id != song.id) return;
  player.refreshMediaItem();
}

class PlaylistsPage extends StatefulWidget {
  const PlaylistsPage({super.key, this.onDetailChanged});

  /// 进入/退出歌单详情时回调（根页面据此决定是否允许左右翻页）
  final ValueChanged<bool>? onDetailChanged;

  @override
  State<PlaylistsPage> createState() => PlaylistsPageState();
}

class PlaylistsPageState extends State<PlaylistsPage> {
  Library get _lib => Library.instance;
  PlayerService get _player => playerService!;

  /// 选歌曲图标用（参数组合与壁纸页一致，实机验证过可用）。
  final ImagePicker _picker = ImagePicker();

  /// null = 默认歌单网格视图；非 null = 该歌单的详情视图
  String? _selected;
  bool _drawerOpen = false;

  /// 多选模式下已勾选的歌曲 id 集合；空 = 未进入多选
  final Set<int> _multiSelected = {};
  bool get _multiSelecting => _multiSelected.isNotEmpty;

  void _toggleDrawer() => setState(() => _drawerOpen = !_drawerOpen);

  /// 处理系统返回（侧滑/返回键）：优先关抽屉 → 退出多选 → 退出歌单详情。
  /// 返回 true 表示已处理；false 表示已在默认歌单网格，交给上层页面导航。
  bool handleBack() {
    if (_drawerOpen) {
      setState(() => _drawerOpen = false);
      return true;
    }
    if (_multiSelecting) {
      _exitMultiSelect();
      return true;
    }
    if (_selected != null) {
      _select(null);
      return true;
    }
    return false;
  }

  /// 切换歌单视图，并同步通知根页面：详情页要禁止左右翻页
  void _select(String? name) {
    _exitMultiSelect();
    setState(() => _selected = name);
    widget.onDetailChanged?.call(name != null);
  }

  @override
  void dispose() {
    super.dispose();
  }

  /// 当前歌单内搜索：弹出「搜索当前歌单」毛玻璃面板（参考批量挑选面板样式）。
  /// 覆盖在歌单上、不另开页面；点结果直接播放。
  ///
  /// ⚠️ 面板本体已抽成公共组件 `widgets/song_search_sheet.dart`（根页面右下角那颗
  /// 悬浮按钮走同一个 [showSongSearchSheet]，**同一套搜索代码，不写第二份**）。
  /// 这一条入口的行为**逐项不变**：还是传当前歌单的歌、标题还是「搜索当前歌单」。
  Future<void> _enterSearch(List<Song> songs) async {
    if (songs.isEmpty) {
      _toast('这个歌单还没有歌曲');
      return;
    }
    final idx = await showSongSearchSheet(
      context,
      songs: songs,
      title: kPlaylistSearchTitle,
    );
    if (idx != null && idx >= 0 && idx < songs.length) {
      await _playSong(songs, idx);
    }
  }

  /// 退出多选模式（清空勾选）
  void _exitMultiSelect() {
    if (_multiSelected.isEmpty) return;
    setState(() => _multiSelected.clear());
  }

  /// 点歌曲进入/切换多选
  void _toggleMultiSelect(Song s) {
    setState(() {
      if (!_multiSelected.remove(s.id)) _multiSelected.add(s.id);
    });
  }

  /// 毛玻璃底部弹层：透明背景 + GlassPanel，与播放队列同款质感。
  /// 所有底部弹层统一走这里，替换原来的黑底。
  Future<T?> _glassSheet<T>({
    required WidgetBuilder builder,
    bool scrollControlled = false,
  }) {
    return showModalBottomSheet<T>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: scrollControlled,
      builder: (ctx) => GlassPanel(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: SafeArea(child: builder(ctx)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // 歌单数据变化 + 播放状态变化（切歌/播放中当前曲高亮）+ 布局设置变化都要刷新
      // + 歌曲图标变化（ArtworkStore 自己的轻量版本号，别走 Library 的通知：
      //   那会连带把曲库分组缓存全部重算）
      listenable: Listenable.merge([
        _lib,
        _player.changeNotifier,
        AppConfig.instance,
        ArtworkStore.revision,
      ]),
      builder: (context, _) {
        if (_lib.loading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (_lib.permDenied) return _buildPermDenied();
        if (_selected == null) return _buildGrid();
        return _buildDetail();
      },
    );
  }

  // ==================== 授权页 ====================
  Widget _buildPermDenied() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.music_off, size: 56),
            const SizedBox(height: 16),
            const Text('需要「音乐和音频」权限才能读取本地歌曲'),
            const SizedBox(height: 16),
            FilledButton(onPressed: _lib.retry, child: const Text('重新授权')),
          ],
        ),
      ),
    );
  }

  // ==================== 默认页：歌单列表 / 网格 ====================
  Widget _buildGrid() {
    final names = [kAllSongs, kLikes, ..._lib.playlists.keys];
    final columns = AppConfig.instance.playlistColumns;
    final listStyle = columns == 1; // 1 = 长方形横条（一行一个）
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                const Text(
                  'Mu Box',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.album),
                  tooltip: '专辑 · 歌手',
                  onPressed: _openLibraryGroups,
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  tooltip: '新建歌单',
                  onPressed: _createPlaylist,
                ),
              ],
            ),
          ),
          // 歌单多到超出一屏时这里必须真的能滚 —— 原先锁成 NeverScrollableScrollPhysics，
          // 视口把下面的行**静默裁掉**，最后几张卡永远滑不出来、也点不到（而手指上滑
          // 被外层垂直 PageView 吃掉，变成翻到下行）。解锁滚动的代价是内层会吃掉垂直
          // 手势，所以「上滑去下行」按同一套判定补回来（`lib/row_turn.dart` +
          // `lib/widgets/row_turn_scroll.dart`，三个页面共用，⛔ 别在这页再写一份）：
          // **手势开始时已经在底部**才可能翻页；不在底部 ⇒ 这一次滑动只负责滚到底，
          // 拖多远都不翻，要翻得再滑一次。
          // ⚠️ 内容装得下时行为与原先逐像素一致：ClampingScrollPhysics 在
          // min==max 时 shouldAcceptUserOffset 为假 ⇒ 不注册拖拽识别器 ⇒ 手势照旧落给外层。
          Expanded(
            child: RowTurnScroll(
              child: listStyle
                  ? ListView.builder(
                      physics: const ClampingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 220),
                      itemCount: names.length,
                      itemBuilder: (context, i) => _buildPlaylistRow(names[i]),
                    )
                  : GridView.builder(
                      physics: const ClampingScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 220),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 1.25,
                      ),
                      itemCount: names.length,
                      itemBuilder: (context, i) => _buildPlaylistCard(names[i]),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaylistCard(String name) {
    final primary = context.accent;
    final count = _lib.songCountOf(name);
    return GestureDetector(
      onTap: () => _select(name),
      onLongPress:
          name == kAllSongs || name == kLikes
          ? null
          : () => _showPlaylistMenu(name),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          // 主题色沿对角线渐隐：左上浓 → 左下到右上对角线的「浅」→ 右下无
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              primary.withValues(alpha: 0.34),
              primary.withValues(alpha: 0.12),
              Colors.transparent,
            ],
            stops: const [0.0, 0.5, 1.0],
          ),
          border: Border.all(color: Colors.white12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              name == kAllSongs
                  ? Icons.library_music
                  : (name == kLikes ? Icons.favorite : Icons.queue_music),
              color: primary,
              size: 22,
            ),
            const Spacer(),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              count == 0 ? '空歌单' : '$count 首',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  /// 长方形横条歌单（一行一个）：图标 + 名称 + 歌曲数，横向排布。
  Widget _buildPlaylistRow(String name) {
    final primary = context.accent;
    final count = _lib.songCountOf(name);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: () => _select(name),
        onLongPress:
          name == kAllSongs || name == kLikes
          ? null
          : () => _showPlaylistMenu(name),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            // 主题色自左向右渐隐，到中间即消失（右半无主题色）
            gradient: LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                primary.withValues(alpha: 0.30),
                Colors.transparent,
                Colors.transparent,
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
            border: Border.all(color: Colors.white12),
          ),
          child: Row(
            children: [
              Icon(
                name == kAllSongs
                  ? Icons.library_music
                  : (name == kLikes ? Icons.favorite : Icons.queue_music),
                color: primary,
                size: 22,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
              Text(
                count == 0 ? '空歌单' : '$count 首',
                style: const TextStyle(fontSize: 12, color: Colors.white54),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ==================== 歌单详情页 ====================
  Widget _buildDetail() {
    final name = _selected!;
    final songs = _lib.songsOf(name);
    return SafeArea(
      child: Stack(
        children: [
          Column(
            children: [
              _buildDetailHeader(name, songs),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: SurfaceCard(child: _buildSongList(name, songs)),
                ),
              ),
            ],
          ),
          _buildDrawer(),
        ],
      ),
    );
  }

  /// 顶部搜索栏：毛玻璃，输入框 + (歌名/歌手 与输入框同宽横铺，对齐)。聚焦弹键盘。
  Widget _buildSongList(String name, List<Song> songs) {
    final primary = Theme.of(context).colorScheme.primary;
    if (songs.isEmpty) {
      return Center(
        child: Text(
          _lib.songs.isEmpty ? '没有扫描到音乐\n（把歌曲导入手机后在「音乐」里可见）' : '这个歌单还是空的',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white38),
        ),
      );
    }
    // ReorderableListView：每首歌尾部带拖拽手柄（2 排 × 3 个白点），
    // 长按手柄后上下滑动调整播放顺序；多选模式下隐藏手柄，只做勾选。
    return ReorderableListView.builder(
      buildDefaultDragHandles: false,
      // 底部多留空白，最后几首能滑到播放栏上方不被挡住
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 220),
      itemCount: songs.length,
      // 拖拽代理用半透明白面板模拟毛玻璃（不用 BackdropFilter：
      // 部分设备 Impeller 引擎对 BackdropFilter 有渲染 bug 会出红色块，
      // 且拖拽代理放 Overlay 里模糊整屏耗性能）。视觉上依然是毛玻璃质感。
      // 注意：proxy 悬浮在 Overlay 上，脱离了 Scaffold 的 Material 环境，
      // 而列表项里有 ListTile（强制要求 Material 祖先），必须包一层透明
      // Material，否则拖拽一开始就整块红屏（No Material widget found）。
      proxyDecorator: (child, index, animation) {
        // 绑定拖拽动画：进入拖拽淡入、松手收尾淡出，结束更顺滑不突兀
        final a = CurvedAnimation(parent: animation, curve: Curves.easeInOut);
        return FadeTransition(
          opacity: a,
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.35),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: Colors.white24),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: child,
            ),
          ),
        );
      },
      onReorderItem: (o, n) {
        // 用 id 落盘，而不是索引：songs 已过滤掉私密歌，索引和 allOrder/歌单 id
        // 列表并不对应，按索引重排会挪错歌。
        if (o < 0 || o >= songs.length) return;
        final movedId = songs[o].id;
        final beforeId = n < songs.length ? songs[n].id : null;
        _lib.reorderSongsById(name, movedId, beforeId);
      },
      itemBuilder: (context, i) {
        final s = songs[i];
        final isCurrent = _player.current?.id == s.id && _player.isPlaying;
        final checked = _multiSelected.contains(s.id);
        final tile = ListTile(
          // 多选模式下：已选中的行淡色背景 + 勾选图标；未选中正常音乐图标。
          // 有图标（用户传的 / 拉取的封面）时优先显示 1:1 圆角小图：正在播放的套一圈
          // 主题色描边当播放指示，多选模式仍然让位给勾选圈。
          leading: _multiSelecting
              ? Icon(
                  checked ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: checked ? primary : Colors.white38,
                )
              : ArtworkStore.has(s)
                  ? SongArtwork(
                      song: s,
                      size: 28,
                      ringColor: isCurrent ? primary : null,
                    )
                  : isCurrent
                      ? _EqBars(color: primary)
                      : const Icon(Icons.music_note, color: Colors.white38),
          title: Text(
            _lib.displayTitle(s),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: isCurrent ? primary : Colors.white,
              fontSize: 14,
              fontWeight: checked ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
          trailing: _multiSelecting
              ? Text(
                  s.durationText,
                  style: const TextStyle(color: Colors.white38, fontSize: 12),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      s.durationText,
                      style: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(
                        Icons.more_vert,
                        color: Colors.white38,
                        size: 18,
                      ),
                      tooltip: '更多',
                      onPressed: () => _showSongMenu(s, songs),
                    ),
                  ],
                ),
          onTap: _multiSelecting
              ? () => _toggleMultiSelect(s)
              : () => _playSong(songs, i),
          // 长按进入多选并选中该首（普通模式）；多选模式下长按也切换勾选
          onLongPress: () {
            if (!_multiSelecting) {
              setState(() => _multiSelected.add(s.id));
            } else {
              _toggleMultiSelect(s);
            }
          },
        );
        return Column(
          key: ValueKey(s.id),
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Expanded(child: tile),
                // 拖拽手柄放在 ListTile 外面，与整行的多选长按互不冲突。
                // 用即时拖拽（而非延迟长按）：手指按下白点后一移动就进入拖拽，
                // 不会因为长按期间手抖超过触摸容差而被取消变成列表滚动。
                if (!_multiSelecting && name != kLikes)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ReorderableDragStartListener(
                      index: i,
                      child: const _DragHandle(),
                    ),
                  ),
              ],
            ),
            const Divider(height: 1, color: Colors.white10),
          ],
        );
      },
    );
  }

  Widget _buildDetailHeader(String name, List<Song> songs) {
    // 多选模式：操作栏（已选N首 + 全选 + 移动/移除 + 退出）
    if (_multiSelecting) return _buildMultiSelectBar(name, songs);
    final compactBtn = IconButton.styleFrom(
      minimumSize: const Size(40, 34),
      padding: EdgeInsets.zero,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 16, 4),
      child: Row(
        children: [
          // 左上角竖排两枚按钮：返回箭头 + 展开/收起
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                style: compactBtn,
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                tooltip: '返回默认页面',
                onPressed: () => _select(null),
              ),
              IconButton(
                style: compactBtn,
                icon: Icon(
                  _drawerOpen ? Icons.menu_open : Icons.menu,
                  color: Colors.white,
                ),
                tooltip: _drawerOpen ? '收起' : '展开',
                onPressed: _toggleDrawer,
              ),
            ],
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${songs.length} 首',
                  style: const TextStyle(fontSize: 12, color: Colors.white54),
                ),
              ],
            ),
          ),
          // 右上角搜索：进入当前歌单内搜索（顶部搜索栏 + 下方结果列表）
          IconButton(
            style: compactBtn,
            icon: const Icon(Icons.search, color: Colors.white),
            tooltip: '搜索当前歌单',
            onPressed: () => _enterSearch(songs),
          ),
          if (name != kAllSongs)
            IconButton(
              style: compactBtn,
              icon: Icon(Icons.add, color: Colors.white),
              tooltip: '从其他歌单批量添加歌曲',
              onPressed: () => _batchAddFromPlaylists(name),
            ),
        ],
      ),
    );
  }

  /// 多选模式操作栏：取消 + 已选N首 + 全选/取消全选 + 移动 + 移除（全部歌曲无移除）
  Widget _buildMultiSelectBar(String name, List<Song> songs) {
    final allPicked =
        songs.isNotEmpty && songs.every((s) => _multiSelected.contains(s.id));
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 16, 4),
      child: Row(
        children: [
          IconButton(
            style: IconButton.styleFrom(
              minimumSize: const Size(40, 34),
              padding: EdgeInsets.zero,
            ),
            icon: const Icon(Icons.close, color: Colors.white),
            tooltip: '退出多选',
            onPressed: _exitMultiSelect,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              '已选 ${_multiSelected.length} 首',
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          TextButton(
            onPressed: songs.isEmpty
                ? null
                : () => setState(() {
                    if (allPicked) {
                      _multiSelected.clear();
                    } else {
                      _multiSelected.addAll(songs.map((s) => s.id));
                    }
                  }),
            child: Text(
              allPicked ? '取消全选' : '全选',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          // 移动到其他歌单（全部歌曲里移动 = 加入目标歌单，也显示此按钮）
          TextButton.icon(
            onPressed: _multiSelected.isEmpty
                ? null
                : () => _multiMove(name, songs),
            icon: const Icon(Icons.drive_file_move_outline, size: 16),
            label: const Text('移动', style: TextStyle(fontSize: 13)),
            style: TextButton.styleFrom(foregroundColor: Colors.white),
          ),
          // 批量移除当前歌单（自建歌单从歌单移除）
          if (name != kAllSongs)
            TextButton.icon(
              onPressed: _multiSelected.isEmpty
                  ? null
                  : () => _multiRemove(name, songs),
              icon: const Icon(Icons.delete_outline, size: 16),
              label: const Text('移除', style: TextStyle(fontSize: 13)),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
          // 批量删除歌曲（「全部歌曲」：删内部副本，彻底移除）
          if (name == kAllSongs)
            TextButton.icon(
              onPressed: _multiSelected.isEmpty
                  ? null
                  : () => _multiDelete(songs),
              icon: const Icon(Icons.delete_forever_outlined, size: 16),
              label: const Text('删除', style: TextStyle(fontSize: 13)),
              style: TextButton.styleFrom(foregroundColor: Colors.white),
            ),
        ],
      ),
    );
  }

  /// 多选移动：选目标歌单，把已勾选歌曲移过去。
  /// 自建歌单来源：移出当前歌单并加入目标（目标=全部歌曲时等价于只从当前移除）；
  /// 全部歌曲来源：全部歌曲本就含所有歌，"移动" = 加入目标歌单，无需移除。
  Future<void> _multiMove(String name, List<Song> songs) async {
    final picked = songs.where((s) => _multiSelected.contains(s.id)).toList();
    // 目标歌单：来源是全部歌曲时只能选自建歌单；否则是全部歌曲 + 其他自建歌单
    final targets = name == kAllSongs
        ? _lib.playlists.keys.toList()
        : [kAllSongs, ..._lib.playlists.keys.where((n) => n != name)];
    if (targets.isEmpty) {
      _toast('没有可移动到的歌单');
      return;
    }
    final target = await _glassSheet<String>(
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '移动到哪个歌单？',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          for (final n in targets)
            ListTile(
              title: Text(n, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, n),
            ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    if (name == kAllSongs || name == kLikes) {
      // 「全部歌曲」「喜欢」都是虚拟歌单（没有自己的 id 列表）：只做「加入目标歌单」。
      // 原先「喜欢」会走到下面的 move 分支，往 playlists 表里写进一个幽灵「喜欢」
      // 键，网格里就出现两个「喜欢」而且没有删除入口。
      final added = await _lib.addSongsToPlaylist(target, picked);
      if (!mounted) return;
      _exitMultiSelect();
      _toast(added > 0 ? '已将 ${picked.length} 首加入「$target」' : '这些歌曲已在歌单中');
      return;
    }
    if (target == kAllSongs) {
      // 移到全部歌曲 = 从当前歌单移除（全部歌曲不需要真正加入，它本就包含全部）
      final removed = await _lib.removeSongsFromPlaylist(
        name,
        picked.map((s) => s.id).toSet(),
      );
      if (!mounted) return;
      _exitMultiSelect();
      _toast(removed > 0 ? '已从「$name」移除 $removed 首' : '这些歌曲不在该歌单中');
      return;
    }
    await _lib.moveSongsToPlaylist(
      name,
      target,
      picked.map((s) => s.id).toSet(),
    );
    if (!mounted) return;
    _exitMultiSelect();
    _toast('已移动 ${picked.length} 首到「$target」');
  }

  /// 多选移除：从当前歌单批量移除（仅自建歌单可用）
  Future<void> _multiRemove(String name, List<Song> songs) async {
    final picked = songs.where((s) => _multiSelected.contains(s.id)).toList();
    if (picked.isEmpty) return;
    if (name == kLikes) {
      // 「喜欢」没有自己的 id 列表：移除 = 取消收藏。原先调 remove 恒返回 0，
      // 只 toast 一句「这些歌曲不在该歌单中」，看着像按钮坏了。
      for (final s in picked) {
        await _lib.toggleFav(s, value: false);
      }
      if (!mounted) return;
      _exitMultiSelect();
      _toast('已取消收藏 ${picked.length} 首');
      return;
    }
    final removed = await _lib.removeSongsFromPlaylist(
      name,
      picked.map((s) => s.id).toSet(),
    );
    if (!mounted) return;
    _exitMultiSelect();
    _toast(removed > 0 ? '已从「$name」移除 $removed 首' : '这些歌曲不在该歌单中');
  }

  // ==================== 歌单内搜索（顶部搜索栏） ====================
  /// 顶部搜索栏：输入框（聚焦弹键盘）+ 歌名/歌手二选一；回车收起键盘。
  // ==================== 左侧抽屉 ====================
  Widget _buildDrawer() {
    final size = MediaQuery.sizeOf(context);
    // 宽度取屏宽 40%：太窄（原 2/7）会把歌单名挤成竖排换行，加宽后名字横向完整显示
    final width = size.width * 0.40;
    final primary = Theme.of(context).colorScheme.primary;
    final names = [kAllSongs, kLikes, ..._lib.playlists.keys];
    return Stack(
      children: [
        // 半透明遮罩：点击收起抽屉（关闭时忽略点击，让下方页面可操作）
        Positioned.fill(
          child: IgnorePointer(
            ignoring: !_drawerOpen,
            child: GestureDetector(
              onTap: _toggleDrawer,
              child: AnimatedOpacity(
                opacity: _drawerOpen ? 0.5 : 0.0,
                duration: const Duration(milliseconds: 250),
                child: Container(color: Colors.black),
              ),
            ),
          ),
        ),
        // 抽屉面板
        AnimatedPositioned(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          left: _drawerOpen ? 0 : -width,
          top: 0,
          bottom: 0,
          width: width,
          child: ClipRRect(
            borderRadius: const BorderRadius.horizontal(
              right: Radius.circular(20),
            ),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 20, sigmaY: 20),
              child: Container(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: const BorderRadius.horizontal(
                    right: Radius.circular(20),
                  ),
                  border: Border.all(color: Colors.white12),
                ),
                child: SafeArea(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(4, 8, 16, 8),
                        child: Row(
                          children: [
                            IconButton(
                              icon: Icon(Icons.menu_open, color: Colors.white),
                              tooltip: '收起',
                              onPressed: _toggleDrawer,
                            ),
                            const Text(
                              '全部歌单',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const Divider(height: 1, color: Colors.white10),
                      Expanded(
                        child: ListView(
                          children: [
                            for (final n in names)
                              ListTile(
                                selected: n == _selected,
                                leading: Icon(
                                  n == kAllSongs
                                      ? Icons.library_music
                                      : (n == kLikes
                                          ? Icons.favorite
                                          : Icons.queue_music),
                                  color: n == _selected
                                      ? primary
                                      : Colors.white54,
                                ),
                                title: Text(
                                  n,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: n == _selected
                                        ? primary
                                        : Colors.white,
                                    fontWeight: n == _selected
                                        ? FontWeight.w600
                                        : FontWeight.normal,
                                  ),
                                ),
                                trailing: Text(
                                  '${_lib.songCountOf(n)}',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 12,
                                  ),
                                ),
                                // 切换歌单不自动收起抽屉
                                onTap: () => _select(n),
                              ),
                          ],
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.home_outlined),
                            label: const Text('返回默认页面'),
                            onPressed: () {
                              _select(null);
                              setState(() => _drawerOpen = false);
                            },
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ==================== 歌单 / 歌曲操作 ====================
  /// 进「专辑 · 歌手」浏览页（独立路由，自带壁纸/氛围层，与其他页同一套顺滑转场）
  Future<void> _openLibraryGroups() async {
    await Navigator.push(context, smoothPageRoute(const LibraryGroupPage()));
  }

  Future<void> _createPlaylist() async {
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => const TextInputDialog(title: '新建歌单', hint: '请输入歌单名称'),
    );
    if (name == null || name.isEmpty) return;
    if (!_lib.createPlaylist(name)) {
      _toast('该歌单名称已存在');
      return;
    }
    _toast('已创建歌单「$name」'); // 新建后留在默认网格页，不自动进入
  }

  /// 长按歌单弹出的操作菜单：调整顺序 / 删除。
  Future<void> _showPlaylistMenu(String name) async {
    final action = await _glassSheet<String>(
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          ListTile(
            leading: const Icon(Icons.swap_vert, color: Colors.white70),
            title: const Text('调整顺序', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(ctx, 'reorder'),
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline, color: Colors.white70),
            title: const Text('删除歌单', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(ctx, 'delete'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (action) {
      case 'reorder':
        await _openReorderSheet();
      case 'delete':
        await _confirmDelete(name);
    }
  }

  /// 调整歌单顺序的底部弹层：拖拽手柄上下拖动，「全部歌曲」固定第一不参与。
  Future<void> _openReorderSheet() async {
    await _glassSheet<void>(
      scrollControlled: true,
      builder: (ctx) => const _ReorderPlaylistsSheet(),
    );
  }

  Future<void> _confirmDelete(String name) async {
    if (name == kAllSongs) {
      _toast('「全部歌曲」不可删除');
      return;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassPanel(
          borderRadius: BorderRadius.circular(20),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '确认删除',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '确定删除歌单「$name」吗？\n（歌单中的歌曲不会被删除）',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Theme.of(context).colorScheme.primary,
                    ),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    await _lib.deletePlaylist(name);
    if (!mounted) return; // await 期间页面可能已经销毁
    if (_selected == name) _select(null);
  }

  Future<void> _playSong(List<Song> songs, int i) async {
    // 队列标题用当前歌单名（含「全部歌曲」），重启后队列浮层顶部仍能看到来源
    await _player.playQueue(songs, i, title: _selected ?? kAllSongs);
  }

  Future<void> _addToPlaylist(Song song) async {
    final names = _lib.playlists.keys.toList();
    if (names.isEmpty) {
      _toast('还没有歌单，请先新建');
      return;
    }
    final target = await _glassSheet<String>(
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '添加到歌单',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          for (final n in names)
            ListTile(
              title: Text(n, style: const TextStyle(color: Colors.white)),
              onTap: () => Navigator.pop(ctx, n),
            ),
        ],
      ),
    );
    if (target == null) return;
    final ok = await _lib.addToPlaylist(target, song);
    _toast(ok ? '已添加到歌单' : '该歌曲已在歌单中');
  }

  Future<void> _editTitle(Song song) async {
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => TextInputDialog(
        title: '编辑歌名',
        hint: '歌曲名称',
        initialValue: _lib.displayTitle(song),
        confirmLabel: '保存',
      ),
    );
    if (newTitle == null || newTitle.isEmpty) return;
    await _lib.editTitle(song, newTitle);
  }

  Future<void> _deleteLyrics(Song song) async {
    await _lib.deleteLyrics(song);
    _toast('已删除歌词');
  }

  Future<void> _deleteArtwork(Song song) async {
    await ArtworkStore.remove(song);
    refreshArtworkIfCurrent(song, _player);
    _toast('已删除歌曲图标');
  }

  /// 「设置歌曲图标」：相册选图 → 正方形裁剪页 → 存进封面缓存（512 见方）。
  ///
  /// 取消选图 / 取消裁剪都**静默返回** —— 用户主动放弃不是错误，别弹提示。
  /// 存的是裁剪后的字节，不存原图：相册里几 MB 的大图不会进 App 缓存。
  Future<void> _setArtwork(Song song) async {
    final picked = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: null, // 不压缩，裁剪时才有像素可用
      requestFullMetadata: false, // 不索要照片元数据权限（与壁纸页同一套参数）
    );
    if (picked == null || !mounted) return;
    final bytes = await Navigator.push<Uint8List>(
      context,
      smoothPageRoute(ArtworkCropPage(imagePath: picked.path)),
    );
    if (bytes == null || bytes.isEmpty || !mounted) return;
    await _saveArtwork(song, bytes);
    if (!mounted) return;
    _toast('已设置歌曲图标');
  }

  /// [saveArtwork] 的页面接线：存完图标立刻把通知栏那一份 metadata 重推一次
  /// （真正干活的是模块级的 `saveArtwork` / `refreshArtworkIfCurrent`，
  /// 那两个是公开的，测试直接驱动它们）。
  Future<void> _saveArtwork(Song song, Uint8List bytes) =>
      saveArtwork(song, bytes, _player);

  Future<void> _showSongMenu(Song song, List<Song> songs) async {
    final inPlaylist =
        _selected != kAllSongs &&
        (_lib.playlists[_selected] ?? []).contains(song.id);
    final action = await _glassSheet<String>(
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            title: Text(
              _lib.displayTitle(song),
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
            dense: true,
          ),
          ListTile(
            leading: const Icon(Icons.play_arrow, color: Colors.white70),
            title: const Text('播放', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(ctx, 'play'),
          ),
          ListTile(
            leading: Icon(
              _lib.isFav(song) ? Icons.favorite : Icons.favorite_border,
              color: Colors.white70,
            ),
            title: Text(
              _lib.isFav(song) ? '取消收藏' : '收藏',
              style: const TextStyle(color: Colors.white),
            ),
            onTap: () => Navigator.pop(ctx, 'fav'),
          ),
          ListTile(
            leading: const Icon(Icons.playlist_add, color: Colors.white70),
            title: const Text('添加到歌单', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(ctx, 'add'),
          ),
          if (inPlaylist)
            ListTile(
              leading: const Icon(Icons.playlist_remove, color: Colors.white70),
              title: const Text(
                '从当前歌单移除',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(ctx, 'remove'),
            ),
          ListTile(
            leading: const Icon(Icons.edit_outlined, color: Colors.white70),
            title: const Text('编辑歌名', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(ctx, 'edit'),
          ),
          ListTile(
            leading: const Icon(
              Icons.add_photo_alternate_outlined,
              color: Colors.white70,
            ),
            title: const Text(
              '设置歌曲图标',
              style: TextStyle(color: Colors.white),
            ),
            onTap: () => Navigator.pop(ctx, 'setArtwork'),
          ),
          ListTile(
            leading: const Icon(Icons.lyrics_outlined, color: Colors.white70),
            title: const Text('删除歌词', style: TextStyle(color: Colors.white)),
            onTap: () => Navigator.pop(ctx, 'deleteLyrics'),
          ),
          // 只有确实有图标才给「删除」—— 没图标也摆一项，点了还弹「已删除」，是在骗人
          if (ArtworkStore.has(song))
            ListTile(
              leading: const Icon(
                Icons.image_not_supported_outlined,
                color: Colors.white70,
              ),
              title: const Text(
                '删除歌曲图标',
                style: TextStyle(color: Colors.white),
              ),
              onTap: () => Navigator.pop(ctx, 'deleteArtwork'),
            ),
        ],
      ),
    );
    switch (action) {
      case 'play':
        final i = songs.indexOf(song);
        await _playSong(songs, i < 0 ? 0 : i);
      case 'add':
        await _addToPlaylist(song);
      case 'remove':
        if (_selected != null) await _lib.removeFromPlaylist(_selected!, song);
      case 'fav':
        await _lib.toggleFav(song);
        _toast(_lib.isFav(song) ? '已收藏，可在「喜欢」歌单看' : '已取消收藏');
      case 'edit':
        await _editTitle(song);
      case 'setArtwork':
        await _setArtwork(song);
      case 'deleteLyrics':
        await _deleteLyrics(song);
      case 'deleteArtwork':
        await _deleteArtwork(song);
    }
  }

  /// 从其他歌单批量挑歌加入当前歌单：
  /// 1. 弹出源歌单选择（列出「全部歌曲」+ 除当前外的全部自建歌单）
  /// 2. 在源歌单内多选歌曲（可全选 / 搜索）
  /// 3. 确认后批量加入当前歌单（已在歌单中的自动跳过）
  Future<void> _batchAddFromPlaylists(String currentName) async {
    // 源歌单：全部歌曲（含所有歌）+ 其他自建歌单
    final candidates = [
      kAllSongs,
      ..._lib.playlists.keys.where((n) => n != currentName),
    ];
    if (candidates.isEmpty) {
      _toast('没有可挑选的歌单');
      return;
    }
    final source = await _glassSheet<String>(
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.all(12),
            child: Text(
              '从哪个歌单挑选歌曲？',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          for (final n in candidates)
            ListTile(
              title: Text(n, style: const TextStyle(color: Colors.white)),
              subtitle: Text(
                '${_lib.songCountOf(n)} 首',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
              onTap: () => Navigator.pop(ctx, n),
            ),
        ],
      ),
    );
    if (source == null || !mounted) return;
    final srcSongs = _lib.songsOf(source);
    if (srcSongs.isEmpty) {
      _toast('「$source」里还没有歌曲');
      return;
    }

    // 多选面板：全选 + 过滤已在本歌单的歌曲标记 + 确认加入
    final picked = await _glassSheet<Set<int>>(
      scrollControlled: true,
      builder: (ctx) => _PickSongsSheet(source: source, songs: srcSongs),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final selected = srcSongs.where((s) => picked.contains(s.id)).toList();
    if (selected.isEmpty) return;
    final added = await _lib.addSongsToPlaylist(currentName, selected);
    if (!mounted) return;
    _toast(added > 0 ? '已从「$source」添加 $added 首' : '这些歌曲已在歌单中');
  }

  /// 批量删除歌曲（「全部歌曲」）：确认后删内部副本 + 从库移除。
  Future<void> _multiDelete(List<Song> songs) async {
    final picked = songs.where((s) => _multiSelected.contains(s.id)).toList();
    if (picked.isEmpty) return;
    final ok = await _confirmDeleteSongs(picked.length);
    if (ok != true || !mounted) return;
    await _lib.deleteSongs(picked.map((s) => s.id).toSet());
    if (!mounted) return;
    _exitMultiSelect();
    _toast('已删除 ${picked.length} 首');
  }

  /// 删除确认弹窗：说明会删 App 内部副本、不动手机原文件。
  Future<bool?> _confirmDeleteSongs(int count) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassPanel(
          borderRadius: BorderRadius.circular(20),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '确认删除',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '删除这 $count 首歌吗？\n（只删 App 内部副本，手机上的原文件保留）',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                    ),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(milliseconds: 1500),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }
}

// 说明：拖拽改用 ReorderableDragStartListener（即时激活，移动即拖），
// 不再用延迟长按激活——延迟期间手指轻微移动就会超触摸阈值导致拖拽被取消。

/// 正在播放指示：5 根小长方形随相位上下跳动（均衡器动效）。
/// 替换歌单列表正在播放那首歌 leading 位置的静态 graphic_eq 图标。
class _EqBars extends StatefulWidget {
  final Color color;
  const _EqBars({required this.color});

  @override
  State<_EqBars> createState() => _EqBarsState();
}

class _EqBarsState extends State<_EqBars>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c;

  @override
  void initState() {
    super.initState();
    _c = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: AnimatedBuilder(
          animation: _c,
          builder: (context, _) {
            final t = _c.value;
            return Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: List.generate(5, (i) {
                final h =
                    4.0 + (math.sin(t * 2 * math.pi + i * 0.9) * 0.5 + 0.5) * 9.0;
                return Container(
                  width: 2.6,
                  height: h,
                  margin: const EdgeInsets.symmetric(horizontal: 1.0),
                  decoration: BoxDecoration(
                    color: widget.color,
                    borderRadius: BorderRadius.circular(1.3),
                  ),
                );
              }),
            );
          },
        ),
      ),
    );
  }
}
