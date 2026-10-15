/// 「专辑 · 歌手」浏览页：把曲库按专辑或歌手分组，点分组进该组的歌曲列表。
///
/// 刻意**独立成一页**、而不是把专辑/歌手当成伪歌单混进歌单页的分类里：
/// 歌单页那一整套「重命名 / 删除 / 拖拽排序 / 批量移动」都是围着**自建歌单**转的，
/// 混进去就得在每个分支都记得排除它们，漏一处就会冒出「专辑能被重命名」这种 bug。
/// 分组计算本身是纯函数，见 `library_core.dart` 的 [groupByAlbum] / [groupByArtist]。
///
/// 私密歌不出现在这里：分组用的是 `Library.songsByAlbum/songsByArtist`，
/// 内部按和歌单列表同一套规则过滤。
library;

import 'package:flutter/material.dart';

import '../library_core.dart';
import '../library_data.dart';
import '../models.dart';
import '../player_service.dart';
import '../widgets/ambient_layer.dart';
import '../widgets/glass_panel.dart';
import '../widgets/wallpaper_layer.dart';

class LibraryGroupPage extends StatefulWidget {
  const LibraryGroupPage({super.key});

  @override
  State<LibraryGroupPage> createState() => _LibraryGroupPageState();
}

class _LibraryGroupPageState extends State<LibraryGroupPage> {
  Library get _lib => Library.instance;
  PlayerService get _player => playerService!;

  /// 0 = 按专辑，1 = 按歌手
  int _tab = 0;

  /// 当前打开的分组名；null = 停在分组墙上。
  /// 只存名字、不存 SongGroup 快照：刷新音乐库后分组会重建，
  /// 存快照会拿着过期的歌曲列表去播。
  String? _groupName;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      // 曲库变化（刷新/删歌）+ 播放状态变化（当前曲高亮）都要刷新
      listenable: Listenable.merge([_lib, _player.changeNotifier]),
      builder: (context, _) {
        final primary = Theme.of(context).colorScheme.primary;
        // 一次 build 只分组一次（分组是 O(N log N)，别在下层反复取 getter）
        final groups = _tab == 0 ? _lib.songsByAlbum : _lib.songsByArtist;
        final group = _groupName == null ? null : _find(groups, _groupName!);
        // 打开着的分组没了（歌被删 / 标签变了）：整页当回到分组墙，不留空白页。
        // 刻意不在这里 setState —— build 里触发重建会打架；显示以数据为准即可。
        return PopScope(
          // 正在看某个分组的歌曲列表时，先吃掉这次返回、退回分组墙
          canPop: group == null,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _groupName = null);
          },
          child: Scaffold(
            backgroundColor: Colors.transparent,
            resizeToAvoidBottomInset: false,
            body: Stack(
              children: [
                const Positioned.fill(child: WallpaperLayer()),
                const Positioned.fill(child: AmbientLayer(isPreview: true)),
                SafeArea(
                  child: Column(
                    children: [
                      _header(group, primary),
                      Expanded(
                        child: group != null
                            ? _songList(group, primary)
                            : Column(
                                children: [
                                  _segments(primary),
                                  Expanded(child: _groupGrid(groups, primary)),
                                ],
                              ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  static SongGroup? _find(List<SongGroup> groups, String name) {
    for (final g in groups) {
      if (g.name == name) return g;
    }
    return null;
  }

  void _back() {
    if (_groupName != null) {
      setState(() => _groupName = null);
      return;
    }
    Navigator.pop(context);
  }

  Future<void> _play(List<Song> songs, int i) =>
      _player.playQueue(songs, i, title: _groupName ?? '');

  // ==================== 顶栏 ====================
  Widget _header(SongGroup? group, Color primary) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 16, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: '返回',
            onPressed: _back,
          ),
          Expanded(
            child: Text(
              group?.name ?? (_tab == 0 ? '专辑' : '歌手'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          if (group != null)
            Text(
              '${group.songs.length} 首',
              style: const TextStyle(fontSize: 12, color: Colors.white54),
            ),
        ],
      ),
    );
  }

  /// 专辑 / 歌手两档切换（只在分组墙上出现）
  Widget _segments(Color primary) {
    Widget seg(String label, int value) {
      final on = _tab == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _tab = value),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 9),
            decoration: BoxDecoration(
              color: on ? primary.withValues(alpha: 0.22) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: on
                    ? primary.withValues(alpha: 0.50)
                    : Colors.white12,
              ),
            ),
            child: Center(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: on ? Colors.white : Colors.white60,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Row(
        children: [
          seg('专辑', 0),
          const SizedBox(width: 10),
          seg('歌手', 1),
        ],
      ),
    );
  }

  // ==================== 分组墙 ====================
  Widget _groupGrid(List<SongGroup> groups, Color primary) {
    if (groups.isEmpty) {
      return const Center(
        child: Text('曲库里还没有歌曲', style: TextStyle(color: Colors.white38)),
      );
    }
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 220),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.25,
      ),
      itemCount: groups.length,
      itemBuilder: (context, i) => _groupCard(groups[i], primary),
    );
  }

  /// 分组卡片：沿用歌单卡片的「主题色对角渐隐 + 白字」样式，保持同一套观感
  Widget _groupCard(SongGroup g, Color primary) {
    return GestureDetector(
      onTap: () => setState(() => _groupName = g.name),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
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
            Icon(_tab == 0 ? Icons.album : Icons.person, color: primary, size: 22),
            const Spacer(),
            Text(
              g.name,
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
              '${g.songs.length} 首',
              style: const TextStyle(fontSize: 11, color: Colors.white54),
            ),
          ],
        ),
      ),
    );
  }

  // ==================== 分组内的歌曲列表 ====================
  Widget _songList(SongGroup group, Color primary) {
    final songs = group.songs;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: SurfaceCard(
        child: ListView.builder(
          // 底部多留空白，最后几首能滑到播放栏上方不被挡住
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 220),
          itemCount: songs.length,
          itemBuilder: (context, i) {
            final s = songs[i];
            final isCurrent = _player.current?.id == s.id && _player.isPlaying;
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  leading: Icon(
                    isCurrent ? Icons.graphic_eq : Icons.music_note,
                    color: isCurrent ? primary : Colors.white38,
                  ),
                  title: Text(
                    _lib.displayTitle(s),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isCurrent ? primary : Colors.white,
                      fontSize: 14,
                    ),
                  ),
                  trailing: Text(
                    s.durationText,
                    style: const TextStyle(
                      color: Colors.white38,
                      fontSize: 12,
                    ),
                  ),
                  onTap: () => _play(songs, i),
                ),
                const Divider(height: 1, color: Colors.white10),
              ],
            );
          },
        ),
      ),
    );
  }
}
