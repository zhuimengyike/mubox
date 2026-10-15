part of 'playlists_page.dart';

/// 批量挑选歌曲的底部弹层：歌单标题 + 全选/取消全选 + 搜索过滤 + 多选列表 + 确认。
class _PickSongsSheet extends StatefulWidget {
  const _PickSongsSheet({required this.source, required this.songs});

  final String source;
  final List<Song> songs;

  @override
  State<_PickSongsSheet> createState() => _PickSongsSheetState();
}

class _PickSongsSheetState extends State<_PickSongsSheet> {
  final Set<int> _picked = {}; // 已勾选的歌曲 id
  final TextEditingController _searchCtrl = TextEditingController();
  List<Song> get _shown {
    final q = _searchCtrl.text.trim();
    if (q.isEmpty) return widget.songs;
    return widget.songs
        .where(
          (s) => Library.instance
              .displayTitle(s)
              .toLowerCase()
              .contains(q.toLowerCase()),
        )
        .toList();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  bool get _allPicked =>
      _shown.isNotEmpty && _shown.every((s) => _picked.contains(s.id));

  void _toggleAll() {
    setState(() {
      if (_allPicked) {
        for (final s in _shown) {
          _picked.remove(s.id);
        }
      } else {
        for (final s in _shown) {
          _picked.add(s.id);
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final shown = _shown;
    return SafeArea(
      // 固定高度：弹层始终占 75% 屏高，标题/搜索框稳定在顶部，不因过滤结果变少而下沉
      child: SizedBox(
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
                      '从「${widget.source}」挑选',
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
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
            // 统计副标题：候选总数 + 已选数，形成「标题 → 统计 → 搜索」的层次
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Text(
                '共 ${widget.songs.length} 首 · 已选 ${_picked.length} 首',
                style: const TextStyle(fontSize: 12, color: Colors.white38),
              ),
            ),
            // 搜索框 + 全选
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(fontSize: 13),
                      decoration: InputDecoration(
                        isDense: true,
                        hintText: '搜索歌曲名…',
                        hintStyle: const TextStyle(
                          fontSize: 13,
                          color: Colors.white38,
                        ),
                        prefixIcon: const Icon(
                          Icons.search,
                          size: 18,
                          color: Colors.white54,
                        ),
                        filled: true,
                        fillColor: Colors.white.withValues(alpha: 0.06),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                        ),
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
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: shown.isEmpty ? null : _toggleAll,
                    child: Text(
                      _allPicked ? '取消全选' : '全选',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 20),
            // 歌曲多选列表：占满剩余空间，结果再少也固定区域、不收缩
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
                        final checked = _picked.contains(s.id);
                        return CheckboxListTile(
                          dense: true,
                          value: checked,
                          activeColor: primary,
                          controlAffinity: ListTileControlAffinity.leading,
                          onChanged: (v) => setState(() {
                            if (v == true) {
                              _picked.add(s.id);
                            } else {
                              _picked.remove(s.id);
                            }
                          }),
                          title: Text(
                            Library.instance.displayTitle(s),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              color: checked ? Colors.white : Colors.white70,
                              fontWeight: checked
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                          subtitle: Text(
                            s.durationText,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white38,
                            ),
                          ),
                        );
                      },
                    ),
            ),
            // 确认按钮
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _picked.isEmpty
                      ? null
                      : () => Navigator.pop(context, Set.of(_picked)),
                  child: Text(
                    _picked.isEmpty ? '还没选择歌曲' : '加入当前歌单（${_picked.length} 首）',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

