/// 私密区域页：通过系统指纹 / 锁屏密码进入，存放私密歌曲。
/// 布局参考歌单页：列表展示私密歌曲，可播放 / 移出 / 添加歌曲。
/// 私密歌曲在公共歌单里被过滤隐藏，只有进入本页才能看到。
library;

import 'package:flutter/material.dart';

import '../library_data.dart';
import '../models.dart';
import '../player_service.dart';
import '../private_auth.dart';
import '../store.dart';
import '../widgets/ambient_layer.dart';
import '../widgets/glass_panel.dart';
import '../widgets/wallpaper_layer.dart';

class PrivateAreaPage extends StatefulWidget {
  const PrivateAreaPage({super.key});

  @override
  State<PrivateAreaPage> createState() => _PrivateAreaPageState();
}

class _PrivateAreaPageState extends State<PrivateAreaPage> {
  bool _unlocked = false;
  bool _busy = false;
  bool _skipPrivate = true; // 备份忽略私密歌曲（默认开启）

  @override
  void initState() {
    super.initState();
    _loadSkip();
    _unlock();
  }

  Future<void> _loadSkip() async {
    final v = await Store.loadBackupSkipPrivate();
    if (mounted) setState(() => _skipPrivate = v);
  }

  Future<void> _setSkip(bool v) async {
    setState(() => _skipPrivate = v);
    await Store.saveBackupSkipPrivate(v);
    if (mounted) _toast(v ? '备份时将忽略私密区域歌曲' : '备份将包含私密区域歌曲');
  }

  Future<void> _unlock() async {
    if (_busy) return;
    setState(() => _busy = true);
    final ok = await PrivateAuth.authenticate();
    if (!mounted) return;
    setState(() {
      _unlocked = ok;
      _busy = false;
    });
    // 取消 / 验证失败 / 设备没设锁屏密码都返回 false，界面只会停在「已锁定」，
    // 没有任何反馈时用户会以为功能坏了——补一条提示引导重试。
    if (!ok) _toast('验证未通过或已取消，可点「验证进入」重试');
  }

  void _play(List<Song> songs, int i) {
    playerService!.playQueue(songs, i, title: '私密区域');
  }

  /// 从可见歌曲里挑歌加入私密区域（多选）。
  Future<void> _addSongs() async {
    final lib = Library.instance;
    final candidates = lib.songsOf(kAllSongs).where((s) => !lib.isPrivate(s)).toList();
    if (candidates.isEmpty) {
      _toast('没有可添加的歌曲');
      return;
    }
    // 弹层的 MediaQuery 会把顶部 viewPadding 移除成 0（状态栏那一段），导致
    // 标题/全选被状态栏盖住；这里从外层页面拿到真实状态栏高度传进去，把内容顶下来。
    final topInset = MediaQuery.viewPaddingOf(context).top;
    final picked = await showModalBottomSheet<Set<int>>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => _PickSongsSheet(songs: candidates, topInset: topInset),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    final selected = candidates.where((s) => picked.contains(s.id)).toList();
    for (final s in selected) {
      await lib.setPrivate(s, value: true);
    }
    _toast('已加入私密区域 ${selected.length} 首');
  }

  Future<void> _remove(Song s) async {
    await Library.instance.setPrivate(s, value: false);
    if (mounted) _toast('已移出私密区域');
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 背景：全局壁纸 + 氛围特效（跟其它页面一致，清晰不糊）
          const Stack(
            fit: StackFit.expand,
            // 非全局真背景（次要页面）⇒ 不参与暂停冻结，观感与改动前一致
            children: [WallpaperLayer(), AmbientLayer(isPreview: true)],
          ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(),
                  const SizedBox(height: 12),
                  if (!_unlocked) _lockedView() else _content(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header() {
    return Row(
      children: [
        IconButton(
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.arrow_back, color: Colors.white70),
          onPressed: () => Navigator.pop(context),
        ),
        const SizedBox(width: 6),
        const Expanded(
          child: Text(
            '私密区域',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        ),
        if (_unlocked)
          IconButton(
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.lock, color: Colors.white54, size: 20),
            tooltip: '锁定',
            onPressed: () => setState(() => _unlocked = false),
          ),
      ],
    );
  }

  Widget _lockedView() {
    final primary = Theme.of(context).colorScheme.primary;
    return Expanded(
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 92,
              height: 92,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: primary.withValues(alpha: 0.14),
                border: Border.all(color: primary.withValues(alpha: 0.45)),
              ),
              child: Icon(Icons.lock_outline, color: primary, size: 42),
            ),
            const SizedBox(height: 18),
            const Text(
              '私密区域已锁定',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.white),
            ),
            const SizedBox(height: 8),
            const Text(
              '用锁屏密码验证身份后进入',
              style: TextStyle(fontSize: 13, color: Colors.white54),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                backgroundColor: primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 26, vertical: 13),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
              ),
              icon: Icon(_busy ? Icons.hourglass_top : Icons.fingerprint, size: 20),
              label: Text(_busy ? '验证中…' : '验证进入'),
              onPressed: _busy ? null : _unlock,
            ),
          ],
        ),
      ),
    );
  }

  Widget _content() {
    final lib = Library.instance;
    return Expanded(
      child: ListenableBuilder(
        listenable: lib,
        builder: (context, _) {
          final private = lib.privateSongs;
          return Column(
            children: [
              // 顶部：备份忽略私密开关 + 添加歌曲
              Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        const Icon(Icons.security, color: Colors.white54, size: 16),
                        const SizedBox(width: 6),
                        const Expanded(
                          child: Text(
                            '备份时忽略私密区域',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: Colors.white70),
                          ),
                        ),
                        Switch(
                          value: _skipPrivate,
                          activeThumbColor: Theme.of(context).colorScheme.primary,
                          onChanged: _setSkip,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white24),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                    ),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('添加歌曲', style: TextStyle(fontSize: 13)),
                    onPressed: _addSongs,
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Expanded(
                child: private.isEmpty
                    ? const Center(
                        child: Text(
                          '私密区域是空的\n点右上角「添加歌曲」把不想公开的歌放进来',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.white38, fontSize: 13),
                        ),
                      )
                    : SurfaceCardAreaList(songs: private, onPlay: _play, onRemove: _remove),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 私密歌曲列表：参考歌单详情的歌曲行，每首可播放、可移出私密区域。
class SurfaceCardAreaList extends StatelessWidget {
  final List<Song> songs;
  final void Function(List<Song>, int) onPlay;
  final Future<void> Function(Song) onRemove;
  const SurfaceCardAreaList({super.key, required this.songs, required this.onPlay, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return SurfaceCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        itemCount: songs.length,
        itemBuilder: (context, i) {
          final s = songs[i];
          final isCurrent = playerService!.current?.id == s.id;
          return ListTile(
            dense: true,
            leading: Icon(
              isCurrent ? Icons.graphic_eq : Icons.music_note,
              color: isCurrent ? primary : Colors.white38,
            ),
            title: Text(
              Library.instance.displayTitle(s),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: isCurrent ? primary : Colors.white, fontSize: 14),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s.durationText, style: const TextStyle(color: Colors.white38, fontSize: 12)),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.lock_open, color: Colors.white38, size: 18),
                  tooltip: '移出私密区域',
                  onPressed: () => onRemove(s),
                ),
              ],
            ),
            onTap: () => onPlay(songs, i),
          );
        },
      ),
    );
  }
}

/// 从可见歌曲里多选（复选，含全选），确认返回选中的歌曲 id 集合。
class _PickSongsSheet extends StatefulWidget {
  final List<Song> songs;
  final double topInset; // 外层页面拿到的状态栏高度（弹层里 MediaQuery 会把它归零）
  const _PickSongsSheet({required this.songs, required this.topInset});

  @override
  State<_PickSongsSheet> createState() => _PickSongsSheetState();
}

class _PickSongsSheetState extends State<_PickSongsSheet> {
  final Set<int> _sel = {};

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final all = widget.songs.map((s) => s.id).toSet();
    final allPicked = all.isNotEmpty && _sel.containsAll(all);
    return GlassPanel(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.only(top: widget.topInset),
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 8, 0),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('添加到私密区域',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white)),
                  ),
                  TextButton(
                    onPressed: () => setState(() {
                      if (allPicked) {
                        _sel.clear();
                      } else {
                        _sel.addAll(all);
                      }
                    }),
                    child: Text(allPicked ? '取消全选' : '全选',
                        style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Colors.white10),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final s in widget.songs)
                    CheckboxListTile(
                      dense: true,
                      value: _sel.contains(s.id),
                      activeColor: primary,
                      title: Text(
                        Library.instance.displayTitle(s),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white, fontSize: 13),
                      ),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          _sel.add(s.id);
                        } else {
                          _sel.remove(s.id);
                        }
                      }),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 6, 16, 10),
              child: Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('取消', style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: _sel.isEmpty ? null : () => Navigator.pop(context, _sel),
                      child: Text('加入 (${_sel.length})'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }
}
