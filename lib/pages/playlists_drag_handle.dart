part of 'playlists_page.dart';

/// 拖拽手柄：2 排 × 3 个白色小点，长按后上下滑动调整歌曲顺序；单击无反应。
class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    Widget dot() => Container(
      width: 4,
      height: 4,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white54,
      ),
    );
    Widget row() => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot(),
        const SizedBox(width: 4),
        dot(),
        const SizedBox(width: 4),
        dot(),
      ],
    );
    // 命中区域（80×56）：ReorderableDragStartListener 是 deferToChild 命中，
    // Container 不带底色时只有白点本身可点，实际热区小得几乎按不中。
    // 加透明底色让整块都可命中，白点居中视觉不变。
    return Container(
      width: 80,
      height: 56,
      color: Colors.transparent,
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [row(), const SizedBox(height: 4), row()],
      ),
    );
  }
}

/// 调整歌单顺序的底部弹层：拖拽手柄上下拖动排序。
/// 「全部歌曲」固定第一，只列出并排序自建歌单。
class _ReorderPlaylistsSheet extends StatefulWidget {
  const _ReorderPlaylistsSheet();

  @override
  State<_ReorderPlaylistsSheet> createState() => _ReorderPlaylistsSheetState();
}

class _ReorderPlaylistsSheetState extends State<_ReorderPlaylistsSheet> {
  @override
  Widget build(BuildContext context) {
    final names = Library.instance.playlists.keys.toList();
    final primary = Theme.of(context).colorScheme.primary;
    return SafeArea(
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '调整歌单顺序',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(
                      Icons.close,
                      size: 18,
                      color: Colors.white54,
                    ),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '按住右侧手柄上下拖动排序',
                style: TextStyle(fontSize: 12, color: Colors.white38),
              ),
            ),
            Expanded(
              child: names.isEmpty
                  ? const Center(
                      child: Text(
                        '还没有自建歌单',
                        style: TextStyle(color: Colors.white38),
                      ),
                    )
                  : ReorderableListView.builder(
                      buildDefaultDragHandles: false,
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                      itemCount: names.length,
                      onReorderItem: (o, n) {
                        Library.instance.reorderPlaylists(o, n); // 已改内存并 notify
                        setState(() {}); // 本弹层按新顺序重建
                      },
                      itemBuilder: (context, i) {
                        final n = names[i];
                        return Padding(
                          key: ValueKey(n),
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Container(
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.white10),
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: ListTile(
                                    leading: Icon(
                                      Icons.queue_music,
                                      color: primary,
                                    ),
                                    title: Text(
                                      n,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        color: Colors.white,
                                      ),
                                    ),
                                    subtitle: Text(
                                      '${Library.instance.songCountOf(n)} 首',
                                      style: const TextStyle(
                                        fontSize: 11,
                                        color: Colors.white38,
                                      ),
                                    ),
                                  ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: ReorderableDragStartListener(
                                    index: i,
                                    child: const _DragHandle(),
                                  ),
                                ),
                              ],
                            ),
                          ),
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

