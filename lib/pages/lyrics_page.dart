/// 下页：歌词。
///
/// 页面结构：顶部歌名 + 占满剩余空间的歌词区。歌词区里有一条「隐形基准线」
/// （在歌词区正中间，不画出来），歌词滚动经过这条线时会明显放大变亮；
/// 当前播放行随进度自动滚动到这条线。长按歌词弹出校准面板：以当前歌词为基准，
/// 每次相对挪一档（提前/延后）反复累积，调整音频与歌词的时间偏移（对不齐时用户
/// 点几下即可）。手动滑动偏离同步后，左右两侧浮现两个按钮：左边回到正在播放的
/// 歌词，右边从当前歌词处开始播放。
/// 一行词都没有时（「纯音乐」/「暂无歌词」）长按那块空白区，直接进「终极」面板
/// 导入 .lrc 或手写补词 —— 歌词列表长按入口在空列表上是不存在的。
library;

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app_config.dart';
import '../library_data.dart';
import '../lrc.dart';
import '../models.dart';
import '../player_service.dart';
import '../store.dart';
import '../sub_lyrics.dart';
import '../widgets/glass_panel.dart';

class LyricsPage extends StatefulWidget {
  const LyricsPage({super.key, this.viewKey});

  /// 歌词视图的 key：根页面在收到系统返回（侧滑/返回键）时，用它先问一句
  /// 「编辑模式要不要吃掉这次返回」（见 [LyricViewState.handleBack]）。
  /// ⚠️ **不能**改成让歌词页自己挂 PopScope —— 歌词页不是独立路由，它和根页面
  /// 注册在同一条 ModalRoute 上，一次侧滑会把两个回调都跑一遍（双双触发）。
  final GlobalKey<LyricViewState>? viewKey;

  @override
  State<LyricsPage> createState() => _LyricsPageState();
}

class _LyricsPageState extends State<LyricsPage> {
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        // 这一层只用来读「当前歌曲 / 歌名」：跟随低频 changeNotifier 即可。
        // 原先跟 500ms 的位置 tick，会把整页（标题 + 歌词列表容器）每 0.5 秒重建。
        listenable: playerService!.changeNotifier,
        builder: (context, _) {
          final song = playerService!.current;
          final title = song == null ? '' : Library.instance.displayTitle(song);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 歌名固定在顶部
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                child: Text(
                  title,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              // 歌词区占满剩余空间，一页能显示更多歌词
              Expanded(child: LyricView(key: widget.viewKey, song: song)),
            ],
          );
        },
      ),
    );
  }
}

/// 歌词视图：加载当前歌曲同目录下的 `.lrc`，随播放进度高亮当前行并滚动到
/// 隐形基准线。支持长按弹出面板校准时间偏移。
///
/// 公开（而非 `_LyricView`）是为了让根页面能用 `GlobalKey<LyricViewState>`
/// 调它的 [LyricViewState.handleBack]，与 `PlaylistsPage.handleBack` 同一套做法。
class LyricView extends StatefulWidget {
  final Song? song;
  const LyricView({super.key, required this.song});

  @override
  State<LyricView> createState() => LyricViewState();
}

class LyricViewState extends State<LyricView> {
  // 每行基准高度（逻辑像素）。实际行高 = 基准 × 歌词字号倍数：字号调大时行距
  // 同步变宽，不会把字挤在一起；子歌词（译文）的小字也塞得进同一行。
  static const double _baseLineH = 44;
  double get _lineH => _baseLineH * AppConfig.instance.lyricScale;

  final ScrollController _scroll = ScrollController();
  List<LyricLine> _lines = [];
  /// 子歌词（译文）：与 [_lines] 按索引对齐，越界即该行没有子歌词
  List<String> _subs = [];
  bool _loading = true;
  String? _loadedPath; // 已加载歌词对应的歌曲路径，避免重复加载
  int _lastIndex = -1; // 上次「正在播放」的行号，变化时才触发自动滚动
  /// 基准线对准的行号（= 高亮行），**歌词列表唯一的重建源**。
  ///
  /// 原先列表直接监听 `_scroll` + 播放 tick：滚动时每一帧 offset 都在变，
  /// 整列可见歌词（约 20 行）就跟着每帧重建一次 —— 这是全页最贵的一处重复构建。
  /// 现在只有「对准的行号真的换了」才通知（每约 44px 一次），重建次数降一个量级。
  final ValueNotifier<int> _focusIndex = ValueNotifier<int>(0);
  // 校准点列表（每首歌单独保存）：单点 = 整曲统一偏移（校准·基础）。
  // 偏移语义：歌词显示时间 = 播放时间 - 偏移；正 = 歌词显示偏晚(延后)，负 = 偏早(提前)。
  List<CalibrationPoint> _calib = [];
  // 歌词分段（进阶/终极）：一段一段标记起止行 + 起止音频时间，段内歌词行被重新铺时，
  // 用于纠正这段在整首歌里的漂移；未标注的行保留原始时间戳。
  List<LyricSegment> _segs = [];
  // 每行歌词的有效显示时间（毫秒）：无段 = 原始时间戳；有段 = 段覆盖后的时间。
  List<int> _lineTimes = [];
  bool _desynced = false; // 用户手动滑动过歌词（偏离同步），显示左右按钮
  // 自由编辑歌词（在歌词页逐行改/插/删）：进入时复制 (时间, 文本) 副本。
  bool _editMode = false;
  String? _editSongPath; // 当前编辑稿对应的歌曲路径（切歌时用来作废这份编辑）
  /// 编辑稿：每行 = (时间毫秒, 原文, 子歌词/译文)
  List<(int, String, String)> _edit = [];

  @override
  void initState() {
    super.initState();
    // 歌词字号是独立参数（AppConfig.lyricFontScale）：自己听配置变化重绘即可。
    // 那条设置路径刻意不 bump rebuild（避免拖滑块时每帧重建整个 MaterialApp）。
    AppConfig.instance.addListener(_onConfigChanged);
    // 两个监听源分开挂（原先 merge 成一个 Listenable 直接喂给列表）：
    // 滚动只管「高亮行」，播放 tick 只管「自动滚过去」，各自都不重建整列。
    _scroll.addListener(_onScroll);
    playerService!.notifier.addListener(_onPlaybackTick);
    _load();
  }

  void _onConfigChanged() {
    if (!mounted) return;
    setState(() {});
    // 字号变了 → 行高跟着变 → 同一个 offset 对准的行号也变了，重算一次高亮行
    _onScroll();
  }

  @override
  void didUpdateWidget(covariant LyricView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.song?.filePath != widget.song?.filePath) _load();
  }

  @override
  void dispose() {
    AppConfig.instance.removeListener(_onConfigChanged);
    _scroll.removeListener(_onScroll);
    playerService!.notifier.removeListener(_onPlaybackTick);
    _focusIndex.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 滚动位置变了：只更新「基准线对准的行」。
  /// 同一行内滚动（44px 以内）不通知 —— 这就是本页省下来的那部分重建。
  void _onScroll() {
    if (_lines.isEmpty || !_scroll.hasClients) return;
    final idx = (_scroll.offset / _lineH).round().clamp(0, _lines.length - 1);
    if (idx != _focusIndex.value) _focusIndex.value = idx;
  }

  /// 播放进度 tick（500ms）：只干一件事 —— 「正在播放的行」变了就滚过去。
  /// 刻意不在这里重建列表：滚动到位后会由 [_onScroll] 更新高亮行。
  void _onPlaybackTick() {
    if (!mounted || _editMode || _loading || _lines.isEmpty) return;
    // 用户手动翻过歌词（[_desynced]）：**别再把他拽回播放行**。
    // 原实现每跨一句就 animateTo 回当前行，于是左右两颗按钮形同虚设 ——
    // 想往下看看后头的词根本停不住。要恢复同步就点左边的「回到正在播放」（[_resync]）。
    if (_desynced) return;
    final idx = _indexAt(playerService!.pos);
    if (idx == _lastIndex) return;
    // 还没上屏（首帧前 / 页面未挂载）：这次先不动 _lastIndex，等下一拍再定位，
    // 否则「标记成已对齐但没滚」会让这一行永远滚不过去。
    if (!_scroll.hasClients) return;
    final firstLocate = _lastIndex < 0 && idx >= 0;
    _lastIndex = idx;
    final target = (idx < 0 ? 0 : idx) * _lineH;
    if (firstLocate) {
      _scroll.jumpTo(target); // 首次定位瞬间到位，别从第一行一路扫过去
    } else {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// 时间轴变了（换词 / 改校准 / 改分段）：下一帧按当前播放位置重新对齐并滚动。
  /// 这些改动之后 `_lastIndex` 被置成 -1，但暂停时没有 tick 来推动，
  /// 所以必须在这里补一次 post-frame 定位（布局上屏后再算，避免用旧行高）。
  void _realignSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _onPlaybackTick();
      _onScroll();
    });
  }

  Future<void> _load() async {
    final song = widget.song;
    _loadedPath = song?.filePath;
    _lastIndex = -1;
    _calib = [];
    _segs = [];
    _lineTimes = [];
    _subs = [];
    _desynced = false;
    if (song == null) {
      setState(() {
        _lines = [];
        _loading = false;
      });
      _focusIndex.value = 0;
      return;
    }
    setState(() {
      _lines = [];
      _loading = true;
    });
    // 四份数据互不依赖，并行读：串行要 4 次 IO 往返（每次都重新解析一次文档目录），
    // 切歌时这段延迟直接体现在「歌词空白」的时长上。
    final (lines, subs, calib, segs) = await (
      Lrc.load(song),
      SubLyricsStore.load(song),
      Store.loadCalibrationFor(song.filePath),
      Store.loadSegmentsFor(song.filePath),
    ).wait;
    if (!mounted || _loadedPath != song.filePath) return;
    setState(() {
      _lines = lines;
      _subs = subs;
      _calib = calib;
      _segs = segs;
      _computeLineTimes();
      _loading = false;
    });
    _focusIndex.value = 0;
    // 歌词刚换完：等这一帧上屏后定位一次（暂停状态下没有 tick，不补这一下就不滚动）
    _realignSoon();
  }

  /// 计算每行歌词的有效显示时间：全局连续时间轴（见 models.computeLineTimes）。
  /// 段覆盖精确、段与段之间/首尾按锚点插值或平移，保证单调连续、无断层。
  void _computeLineTimes() {
    final n = _lines.length;
    final orig = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      orig[i] = _lines[i].time.inMilliseconds;
    }
    _lineTimes = computeLineTimes(orig, _segs);
  }

  /// 标记/取消纯音乐：标记后清掉之前为它存下的缓存歌词与导入的自定义歌词。
  Future<void> _toggleInstrumental() async {
    final song = widget.song;
    if (song == null) return;
    await Library.instance.markInstrumental(song,
        value: !Library.instance.isInstrumental(song));
    if (mounted) setState(() {});
  }

  /// 二分查找「歌词显示时间 <= pos」的行号（未到第一行返回 -1）。
  /// 段覆盖时直接用播放时间匹配（段标的就是绝对时间轴）；否则用 播放时间 - 偏移。
  int _indexAt(Duration pos) {
    if (_lineTimes.isEmpty) return -1;
    final target = _segs.isNotEmpty
        ? pos.inMilliseconds
        : pos.inMilliseconds -
            calibrationOffsetAt(_calib, pos.inMilliseconds).round();
    var lo = 0, hi = _lineTimes.length - 1, ans = -1;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (_lineTimes[mid] <= target) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 隐形基准线当前对准的行号（即高亮行）。
  int _focusIndexAtScroll() {
    if (!_scroll.hasClients) return 0;
    final idx = (_scroll.offset / _lineH).round();
    return idx.clamp(0, _lines.length - 1);
  }

  // ---- 长按校准：先选「基础/进阶/终极」，再进对应面板，实时预览并保存 ----

  /// 长按歌词入口：选择三种校准方式。
  Future<void> _openCalibChooser() async {
    final song = widget.song;
    if (song == null || _lines.isEmpty) return;
    final hasImported = await ImportedLyricsStore.has(song);
    if (!mounted) return;
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => GlassPanel(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 歌词字号排在校准之前：它最常调，而且拖的时候能实时看到效果
              _lyricSizeRow(),
              const Divider(color: Colors.white12, height: 1),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 14, 16, 4),
                child: Text(
                  '歌词校准',
                  style: TextStyle(
                      fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
                ),
              ),
              ListTile(
                leading: const Icon(Icons.tune, color: Colors.white70),
                title: const Text('校准·基础', style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                  '整首歌统一微调时间偏移',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onTap: () => Navigator.pop(ctx, 'basic'),
              ),
              ListTile(
                leading: const Icon(Icons.linear_scale, color: Colors.white70),
                title: const Text('校准·进阶', style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                  '分段打点：把歌词按段对齐到音频时间，重建歌词时间轴',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onTap: () => Navigator.pop(ctx, 'advanced'),
              ),
              ListTile(
                leading: const Icon(Icons.upload_file, color: Colors.white70),
                title: const Text('校准·终极', style: TextStyle(color: Colors.white)),
                subtitle: Text(
                  hasImported ? '已导入自定义歌词（可换来源后逐段校准）' : '导入/手写歌词后逐段校准',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                onTap: () => Navigator.pop(ctx, 'ultimate'),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case 'basic':
        await _openBasicSheet();
        break;
      case 'advanced':
        await _openSegCalib();
        break;
      case 'ultimate':
        await _openUltimateFlow();
        break;
    }
  }

  /// 弹层顶部的「歌词字号」：**默认跟随主题字号**；一旦拖过滑块就变成独立值，
  /// 之后不再随主题字号变化（右侧 ⟳ 一键恢复跟随）。
  /// 只影响歌词与子歌词，不碰全局字号。
  Widget _lyricSizeRow() {
    final cfg = AppConfig.instance;
    return ListenableBuilder(
      listenable: cfg,
      builder: (context, _) {
        final following = cfg.lyricFontScale == null;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 6, 4),
          child: Row(
            children: [
              const Icon(Icons.format_size, color: Colors.white70, size: 20),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('歌词字号',
                      style: TextStyle(color: Colors.white, fontSize: 14)),
                  Text(
                    following ? '跟随主题字号' : '独立（不随主题变）',
                    style: const TextStyle(color: Colors.white54, fontSize: 11),
                  ),
                ],
              ),
              Expanded(
                child: Slider(
                  value: cfg.lyricScale.clamp(0.8, 1.6).toDouble(),
                  min: 0.8,
                  max: 1.6,
                  divisions: 16,
                  activeColor: Theme.of(context).colorScheme.primary,
                  inactiveColor: Colors.white12,
                  onChanged: (v) =>
                      cfg.setLyricFontScale(double.parse(v.toStringAsFixed(2))),
                ),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: '恢复跟随主题字号',
                icon: Icon(Icons.sync,
                    color: following ? Colors.white24 : Colors.white70,
                    size: 18),
                onPressed: following ? null : () => cfg.setLyricFontScale(null),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 校准·基础：整曲统一偏移，以「当前对齐」为基准一档档相对挪、反复累积。
  Future<void> _openBasicSheet() async {
    final song = widget.song;
    if (song == null || _lines.isEmpty) return;
    // 初始值 = 当前播放位置处的有效偏移，打开时预览不跳变
    final initial =
        calibrationOffsetAt(_calib, playerService!.pos.inMilliseconds).round();
    final original = _calib;
    final result = await showModalBottomSheet<int>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _CalibrateSheet(
        initialOffsetMs: initial,
        title: '校准·基础',
        subtitle: '整首歌统一时间偏移；以当前对齐为基准，每次相对挪一档、反复累积',
        onChanged: (ms) {
          if (mounted) setState(() => _calib = [CalibrationPoint(0, ms)]);
        },
      ),
    );
    if (!mounted) return;
    if (result == null) {
      // 取消：恢复原校准
      setState(() => _calib = original);
    } else if (result != initial) {
      // 确认且确实改动过：用单点校准覆盖（保持进阶段位不被无谓清掉）
      setState(() {
        _calib = [CalibrationPoint(0, result)];
        _lastIndex = -1; // 重新按新偏移对齐
      });
      _realignSoon();
      await Store.saveCalibrationFor(song.filePath, [CalibrationPoint(0, result)]);
      // 明确提示已应用，避免"高亮没立刻跳=没生效"的误解（暂停时歌词是离散行，未跨句边界不跳）
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          result >= 0
              ? '已应用：歌词延后 ${(result / 1000).toStringAsFixed(2)} 秒，播放时验证'
              : '已应用：歌词提前 ${(-result / 1000).toStringAsFixed(2)} 秒，播放时验证',
        ),
        duration: const Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ));
    } else {
      // 加档又减回原值：onChanged 期间内存里的 _calib 已被预览改过，而磁盘没变，
      // 这里恢复基准值，避免内存与磁盘不一致。
      setState(() => _calib = original);
    }
  }

  /// 校准·进阶 / 终极共同的「逐段校准」：打开分段面板，实时预览，最终确认保存。
  /// [allowLyricsEdit] 为 true（终极）时，面板内提供「导入 .lrc / 编辑歌词」；
  /// 点击后关闭面板 → 执行导入/编辑 → 重新载入歌词 → 再回到面板，形成闭环。
  /// 进阶用原词、不显示导入/编辑入口。
  Future<void> _openSegCalib({bool allowLyricsEdit = false}) async {
    final song = widget.song;
    if (song == null) return;
    if (_lines.isEmpty && !allowLyricsEdit) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('没有歌词行，请先用「终极」导入或编辑歌词'),
        behavior: SnackBarBehavior.floating,
      ));
      return;
    }
    while (true) {
      final original = _segs;
      final result = await showModalBottomSheet<Object>(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (ctx) => _SegSheet(
          song: song,
          lines: _lines,
          segments: _segs,
          allowLyricsEdit: allowLyricsEdit,
          onChanged: (segs) {
            if (mounted) {
              setState(() {
                _segs = segs;
                _computeLineTimes();
                _lastIndex = -1; // 重新按新段时间轴对齐
              });
              _realignSoon();
            }
          },
        ),
      );
      if (!mounted) return;
      if (result == 'import') {
        final ok = await _importLrc();
        if (!ok) return; // 取消/失败：结束
        await _clearCalibs(song);
        await _load();
        if (!mounted) return; // 期间退出页面：不要再用失效的 context 推面板
        continue; // 重开面板
      } else if (result == 'edit') {
        // 进入歌曲页编辑歌词；保存后 _saveEdit 会自动回到面板
        _enterEdit();
        return;
      } else if (result == true) {
        // 最终确认：当前即确定版，落盘；之后不再逐项提示改过哪些/偏移多少。
        await Store.saveSegmentsFor(song.filePath, _segs);
        return;
      } else {
        // 关闭：恢复原段
        setState(() {
          _segs = original;
          _computeLineTimes();
          _lastIndex = -1;
        });
        _realignSoon();
        return;
      }
    }
  }

  /// 校准·终极：直接进入逐段校准面板（默认用原本歌词），面板内可导入/编辑歌词。
  Future<void> _openUltimateFlow() async {
    final song = widget.song;
    if (song == null) return;
    await _openSegCalib(allowLyricsEdit: true);
  }

  /// 导入 .lrc 文件（UTF-8，允许带时间戳或纯文本）。成功返回 true。
  Future<bool> _importLrc() async {
    final song = widget.song;
    if (song == null) return false;
    try {
      final files = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['lrc', 'txt'],
      );
      if (files.isEmpty) return false;
      final f = files.single;
      String? text;
      try {
        text = utf8.decode(await f.readAsBytes());
      } on FormatException {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('文件不是 UTF-8 编码（GBK 等旧编码暂不支持），请在电脑上另存为 UTF-8 后重试'),
            behavior: SnackBarBehavior.floating,
          ));
        }
        return false;
      }
      final usable = Lrc.parse(text).isNotEmpty || Lrc.parsePlain(text).isNotEmpty;
      if (!usable) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('该文件没有可用的歌词内容'),
            behavior: SnackBarBehavior.floating,
          ));
        }
        return false;
      }
      await ImportedLyricsStore.save(song, text);
      return true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('导入失败：$e'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return false;
    }
  }

  /// 换歌词后清空旧的**分段**校准。
  ///
  /// 分段是按「歌词行号」(startIdx/endIdx) 标的 —— 歌词行一变就全对不上，
  /// 必须清掉，否则会把整段歌词铺到错误的音频区间里。
  Future<void> _clearSegments(Song song) async {
    if (_segs.isEmpty) return;
    _segs = [];
    await Store.saveSegmentsFor(song.filePath, []);
  }

  /// 换了一整份新歌词：连整曲/多点**时间**偏移一起清。
  Future<void> _clearCalibs(Song song) async {
    _segs = [];
    _calib = [];
    await Store.saveSegmentsFor(song.filePath, []);
    await Store.saveCalibrationFor(song.filePath, []);
  }

  // ---- 自由编辑歌词（在歌词页逐行改/插/删，保存为自定义歌词）----

  /// 进编辑前记下的滚动位置：取消编辑要回到原处。
  /// 编辑模式整棵替换掉歌词列表（ListView 连同 ScrollPosition 一起销毁，offset 归 0），
  /// 不补这一下的现象是「改到第 40 句点取消，直接弹回第一句」，而且高亮行还停在老地方、
  /// 已经跑出屏幕外，看着像歌词乱了。
  double? _editScrollOffset;

  /// 进编辑。**一行词都没有时也允许**（「纯音乐」误标 / 拉词没拉到）：起一行空白让
  /// 用户粘/敲进去就有词了。原实现 `if (_lines.isEmpty) return` 会让空状态那条路径里
  /// 的「编辑歌词」变成一颗点了没反应的死按钮。
  void _enterEdit() {
    if (widget.song == null) return;
    _editScrollOffset = _scroll.hasClients ? _scroll.offset : null;
    setState(() {
      _edit = [
        for (var i = 0; i < _lines.length; i++)
          (
            _lines[i].time.inMilliseconds,
            _lines[i].text,
            i < _subs.length ? _subs[i] : '',
          ),
      ];
      if (_edit.isEmpty) _edit = [(0, '', '')]; // 空稿：先给一行空白起头
      _editSongPath = widget.song?.filePath; // 记住这份编辑稿属于哪首歌
      _editMode = true;
    });
  }

  void _exitEdit() {
    if (!mounted) return;
    setState(() => _editMode = false);
    final off = _editScrollOffset;
    _editScrollOffset = null;
    if (off == null) return;
    // 新列表要等这一帧布局完才会把 controller 挂回去，所以放 post-frame
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      _scroll.jumpTo(off.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  /// 编辑歌词时侧滑返回：退出编辑并**回到「校准·终极」面板**（而不是退出歌词页）。
  Future<void> _backToSegSheet() async {
    _exitEdit();
    if (!mounted) return;
    await _openSegCalib(allowLyricsEdit: true);
  }

  /// 系统返回（侧滑/返回键）的入口，由根页面的 `_handleBack()` 调用。
  /// 编辑模式下**吃掉**这次返回（丢掉编辑稿 → 回到「校准·终极」面板，用户本来就是
  /// 从那儿进来编辑的）；不编辑时返回 false，根页面照常回默认歌单页。
  bool handleBack() {
    if (!_editMode) return false;
    _backToSegSheet();
    return true;
  }

  /// 通用单行输入弹窗：改原文 / 改子歌词共用同一套外观。
  Future<String?> _promptText({
    required String title,
    required String hint,
    required String initial,
  }) async {
    final ctrl = TextEditingController(text: initial);
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassPanel(
          borderRadius: BorderRadius.circular(20),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                title,
                style: const TextStyle(
                    fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                decoration: InputDecoration(hintText: hint),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消', style: TextStyle(color: Colors.white70)),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, ctrl.text.trim()),
                    child: const Text('确定'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    // ⚠️ 不能在这里立刻 dispose：showDialog 的 future 在 Navigator.pop 的那一刻就完成，
    // 而弹窗还在播退场动画、TextField 仍挂在 controller 上 —— 立刻释放会撞上
    // ChangeNotifier「dispose 时还有依赖」的断言（本项目 widgets/input_dialog.dart
    // 头部专门记过这条坑）。延迟一秒，稳过退场动画再释放。
    Future<void>.delayed(const Duration(seconds: 1), ctrl.dispose);
    return r;
  }

  Future<void> _editLine(int i) async {
    final r = await _promptText(
      title: '修改歌词',
      hint: '这一句歌词',
      initial: _edit[i].$2,
    );
    if (r == null || !mounted) return;
    setState(() => _edit[i] = (_edit[i].$1, r, _edit[i].$3));
  }

  /// 给这一行加/改子歌词（译文）：显示在原文正下方、小一号。
  /// 清空即取消这一行的子歌词。App 不做翻译，写什么随你。
  Future<void> _editSub(int i) async {
    final r = await _promptText(
      title: '子歌词（译文）',
      hint: '这一句的译文；清空 = 这行不要子歌词',
      initial: _edit[i].$3,
    );
    if (r == null || !mounted) return;
    setState(() => _edit[i] = (_edit[i].$1, _edit[i].$2, r));
  }

  void _insertLine(int i) {
    if (!mounted) return;
    // 新行取两个邻居的时间中点：原实现恒插 (0,'')，保存时被写成 [0:00.00]，
    // Lrc.parse 按时间排序后这一句会跳到整首歌词的最前面。
    final prev = _edit[i].$1;
    final next = i + 1 < _edit.length ? _edit[i + 1].$1 : 0;
    final t = (prev > 0 && next > prev) ? (prev + next) ~/ 2 : prev + 500;
    setState(() => _edit.insert(i + 1, (t, '', '')));
  }

  void _deleteLine(int i) {
    if (!mounted) return;
    setState(() => _edit.removeAt(i));
  }

  /// 保存编辑后的歌词：有时间戳则按 LRC 生成，否则纯文本行；存为自定义歌词（覆盖）。
  Future<void> _saveEdit() async {
    final song = widget.song;
    if (song == null) return;
    // 编辑期间切歌（播放栏一直可见，点下一曲即可触发）时这份编辑稿属于上一首，
    // 继续保存会把 A 歌的歌词写进 B 歌、并清掉 B 歌的校准，直接丢弃并退出编辑。
    if (_editSongPath != song.filePath) {
      setState(() => _editMode = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('歌曲已切换，本次歌词编辑已丢弃'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }
    final withTime = _edit.any((e) => e.$1 > 0);
    final buf = StringBuffer();
    for (final (ms, txt, _) in _edit) {
      final t = txt.trim();
      if (t.isEmpty) continue;
      if (withTime) {
        buf.writeln('${_fmtLrcTime(ms)}$t');
      } else {
        buf.writeln(t);
      }
    }
    await ImportedLyricsStore.save(song, buf.toString());
    // 子歌词单独存一份：与主歌词分开，重拉在线歌词不会带走手写的译文。
    // ⚠️ 必须按「有文字的行」过滤：上面写主歌词时跳过了空文本行，而 Lrc.parse /
    // parsePlain 同样只认非空行 —— 这里若按 _edit 的全量下标写，空行之后的每一句
    // 译文都会错位挂到上一句上。编辑页「在开头加一行」造的正是这种空行。
    await SubLyricsStore.save(song, [
      for (final e in _edit)
        if (e.$2.trim().isNotEmpty) e.$3,
    ]);
    // 分段是按歌词行号标的 → 行变了必须清；而整曲/多点的时间偏移与文字无关，
    // 改个错别字不该把它一起抹掉（原实现两样都清、还不提示）。
    final hadSegs = _segs.isNotEmpty;
    await _clearSegments(song);
    await _load();
    if (mounted) setState(() => _editMode = false);
    if (mounted && hadSegs) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('歌词已保存；分段校准因歌词行变化已重置，整曲偏移保留'),
        duration: Duration(seconds: 3),
        behavior: SnackBarBehavior.floating,
      ));
    }
    // 编辑保存后自动进入逐段校准（终极闭环，面板内仍可导入/编辑）
    if (mounted && _lines.isNotEmpty) await _openSegCalib(allowLyricsEdit: true);
  }

  String _fmtLrcTime(int ms) {
    final a = ms < 0 ? 0 : ms;
    final s = a ~/ 1000;
    return '[${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}.${(a % 1000) ~/ 10}]';
  }

  Widget _buildEditLyrics() {
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 12, 0),
            child: Row(
              children: [
                const Expanded(
                  child: Text(
                    '编辑歌词',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white),
                  ),
                ),
                TextButton(onPressed: _saveEdit, child: const Text('保存', style: TextStyle(color: Colors.white))),
                TextButton(onPressed: _exitEdit, child: const Text('取消', style: TextStyle(color: Colors.white70))),
              ],
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Text(
              '点歌词文修改文字；右端「↵」给这句加子歌词（译文）、「＋」在下方插一行、「✕」删本行；「保存」后变为自定义歌词',
              style: TextStyle(fontSize: 11, color: Colors.white38),
            ),
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  visualDensity: VisualDensity.compact,
                  foregroundColor: Colors.white70,
                ),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('在开头加一行（空行）', style: TextStyle(fontSize: 12)),
                onPressed: () => setState(() => _edit.insert(0, (0, '', ''))),
              ),
            ),
          ),
          const SizedBox(height: 2),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 4, 8, 200),
              itemCount: _edit.length,
              itemBuilder: (context, i) {
                final empty = _edit[i].$2.trim().isEmpty;
                final sub = _edit[i].$3;
                final hasSub = sub.trim().isNotEmpty;
                return Row(
                  children: [
                    Expanded(
                      child: GestureDetector(
                        onTap: () => _editLine(i),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 10),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                empty ? '（空白，点击输入）' : _edit[i].$2,
                                style: TextStyle(
                                  fontSize: 15,
                                  color: empty ? Colors.white38 : Colors.white,
                                ),
                              ),
                              // 子歌词挂在原文正下方：一眼看出哪几行已经有译文
                              if (hasSub)
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Text(
                                    sub,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      color: Colors.white54,
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    // 「↵」= 给这一行加/改子歌词；已有译文时图标亮成主题色
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: Icon(
                        Icons.keyboard_return,
                        color: hasSub
                            ? Theme.of(context).colorScheme.primary
                            : Colors.white38,
                        size: 18,
                      ),
                      tooltip: '加子歌词（译文）',
                      onPressed: () => _editSub(i),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.add_circle_outline, color: Colors.white38, size: 18),
                      tooltip: '插入一行',
                      onPressed: () => _insertLine(i),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close, color: Colors.white38, size: 18),
                      tooltip: '删除本行',
                      onPressed: () => _deleteLine(i),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 左边按钮：回到正在播放的歌词处（重新对齐）。
  void _resync() {
    final idx = _indexAt(playerService!.pos);
    // 已经对齐到这一行：记下来，免得下一拍 tick 又 animateTo 一次（白跑一趟动画）
    _lastIndex = idx;
    if (_scroll.hasClients) {
      _scroll.animateTo(
        (idx < 0 ? 0 : idx) * _lineH,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
    setState(() => _desynced = false);
  }

  /// 右边按钮：从当前对准的歌词处开始播放。
  void _playFromCurrent() {
    final fi = _focusIndexAtScroll();
    if (fi < 0 || fi >= _lines.length) return;
    // 用段覆盖后的显示时间（无段时 _lineTimes 即原始时间）。
    final base =
        fi < _lineTimes.length ? _lineTimes[fi] : _lines[fi].time.inMilliseconds;
    // 无段时高亮判定用的是「播放时间 - 校准偏移」（见 _indexAt），所以音频轴上要
    // seek 到 base + 偏移，否则偏移为正时点完会立刻回退到前一行。
    final t =
        _segs.isNotEmpty ? base : base + calibrationOffsetAt(_calib, base).round();
    playerService!.seek(Duration(milliseconds: t < 0 ? 0 : t));
    if (!playerService!.isPlaying) playerService!.toggle();
    setState(() => _desynced = false);
  }

  @override
  Widget build(BuildContext context) {
    if (_editMode) {
      // 编辑模式下的返回由 **根页面**统一处理（见 handleBack：吃掉这次返回并弹回
      // 「校准·终极」面板）。这里刻意不挂 PopScope —— 歌词页与根页面在同一条
      // ModalRoute 上，两个 PopScope 会被一次侧滑同时触发，反而把歌词页 pop 掉。
      return _buildEditLyrics();
    }
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 26,
          height: 26,
          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white54),
        ),
      );
    }

    if (_lines.isEmpty) {
      final song = widget.song;
      final instrumental = song != null && Library.instance.isInstrumental(song);
      // 没有歌词行时这棵子树里没有歌词列表，原有的长按入口（挂在 ListView 上）
      // 根本无处可长按 —— 于是「没词 / 被误标成纯音乐」的用户完全没有入口
      // 手动补词。这里自己挂一个：opaque 让整块空白区（Center 撑满歌词区）都算数，
      // 不是只有文字那一行能按。没有歌词行时逐行校准没有意义，直接进「终极」面板
      // （面板内提供「导入 .lrc / 编辑歌词」）—— 用户此刻唯一想要的就是把词弄进来。
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onLongPress: song == null ? null : _openUltimateFlow,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(instrumental ? '纯音乐' : '暂无歌词',
                  style: const TextStyle(fontSize: 18, color: Colors.white70)),
              const SizedBox(height: 8),
              if (song != null) ...[
                TextButton(
                  onPressed: _toggleInstrumental,
                  child: Text(instrumental ? '取消纯音乐标记' : '标记为纯音乐',
                      style: const TextStyle(fontSize: 13)),
                ),
                // 看不见的手势没人会去猜，补一句淡色提示
                const Text('长按可编辑歌词 / 导入 .lrc',
                    style: TextStyle(fontSize: 12, color: Colors.white24)),
              ] else
                // 没有歌曲上下文时点不动（长按入口拿不到 song）：告诉他词从哪来
                const Text('把 .lrc 放在歌曲同目录即可显示',
                    style: TextStyle(fontSize: 12, color: Colors.white24)),
            ],
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        // 隐形基准线固定在歌词区正中间
        final focusY = constraints.maxHeight / 2;
        // 列表只在「基准线对准的行」变化时重建（见 _focusIndex 的说明）；
        // 自动滚动/高亮判定都搬到了 _onPlaybackTick 里，build 不再有副作用。
        return ValueListenableBuilder<int>(
          valueListenable: _focusIndex,
          builder: (context, focusIndex, _) {
            return Stack(
              children: [
                NotificationListener<ScrollNotification>(
                  onNotification: (n) {
                    // 用户手指拖动（非程序化滚动）视为手动滑动，浮现左右按钮
                    if (n is ScrollStartNotification && n.dragDetails != null) {
                      if (!_desynced) setState(() => _desynced = true);
                    }
                    return false;
                  },
                  child: GestureDetector(
                    onLongPress: _openCalibChooser,
                    // 歌词字号自己算（含独立字号）：这里屏蔽全局文字缩放，
                    // 否则「主题字号 × 歌词独立字号」会被叠乘两次。
                    child: MediaQuery.withNoTextScaling(
                      child: ListView.builder(
                        controller: _scroll,
                        // 上下各留空间，让对准基准线的那行正好停在 focusY 处
                        padding: EdgeInsets.only(
                          top: focusY - _lineH / 2,
                          bottom: constraints.maxHeight - focusY - _lineH / 2,
                        ),
                        itemExtent: _lineH,
                        itemCount: _lines.length,
                        itemBuilder: (context, i) {
                          final active = i == focusIndex;
                          final scale = AppConfig.instance.lyricScale;
                          final sub = i < _subs.length ? _subs[i] : '';
                          return Center(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _lines[i].text,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: (active ? 19 : 15) * scale,
                                      fontWeight: active
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                      color: active
                                          ? Colors.white
                                          : Colors.white.withValues(alpha: 0.45),
                                    ),
                                  ),
                                  // 子歌词（译文）：原文正下方，小一号、更淡
                                  if (sub.trim().isNotEmpty)
                                    Padding(
                                      padding: EdgeInsets.only(top: 1 * scale),
                                      child: Text(
                                        sub,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        textAlign: TextAlign.center,
                                        style: TextStyle(
                                          fontSize:
                                              (active ? 12.5 : 11.5) * scale,
                                          color: Colors.white.withValues(
                                              alpha: active ? 0.80 : 0.34),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ),
                // 左边：回到正在播放的歌词
                if (_desynced)
                  Positioned(
                    left: 10,
                    top: focusY - 20,
                    child: _SideButton(
                      icon: Icons.my_location,
                      onTap: _resync,
                    ),
                  ),
                // 右边：从当前歌词处播放
                if (_desynced)
                  Positioned(
                    right: 10,
                    top: focusY - 20,
                    child: _SideButton(
                      icon: Icons.play_arrow,
                      onTap: _playFromCurrent,
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

/// 歌词区左右两侧的圆形按钮。
class _SideButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _SideButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.14),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white, size: 20),
        ),
      ),
    );
  }
}

/// 歌词校准面板：以当前对齐为基准，每次相对挪一档（提前/延后）反复累积。
/// 确定返回最终累计偏移（毫秒），取消返回 null。
class _CalibrateSheet extends StatefulWidget {
  final int initialOffsetMs;
  final ValueChanged<int> onChanged;
  final String title;
  final String subtitle;
  const _CalibrateSheet({
    required this.initialOffsetMs,
    required this.onChanged,
    this.title = '校准·基础',
    this.subtitle = '以当前歌词为基准，每次相对挪一档、反复累积；不够就多按几次',
  });

  @override
  State<_CalibrateSheet> createState() => _CalibrateSheetState();
}

class _CalibrateSheetState extends State<_CalibrateSheet> {
  static const List<double> _steps = [0.1, 0.25, 0.5, 1.0, 2.0, 5.0];
  // 防御上限 ±1 小时：远超实际使用范围，只防连点/误触累积出荒谬值（不是需求上限，
  // 用户要的是「一档档相对累积」，交互本身不做限制）。
  static const int _clampMs = 3600000;

  late int _currentMs; // 当前累计偏移：正=延后(歌词变晚)，负=提前(歌词变早)
  double _stepSec = 0.5; // 每次相对挪动的档位（秒）

  @override
  void initState() {
    super.initState();
    _currentMs = widget.initialOffsetMs; // 打开时「当前对齐」即基准，从它出发相对挪
  }

  /// 相对当前再挪一步。later=true=延后(正偏移)，false=提前(负偏移)。
  void _adjust(bool later) {
    final step = (_stepSec * 1000).round();
    _currentMs = (_currentMs + (later ? step : -step)).clamp(-_clampMs, _clampMs);
    _emit();
  }

  void _emit() {
    widget.onChanged(_currentMs); // 实时预览：歌词页立即反映
    setState(() {});
  }

  String _fmtSec(double s) =>
      s == s.roundToDouble() ? s.toStringAsFixed(1) : s.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final String label;
    if (_currentMs > 0) {
      label = '歌词延后 ${_fmtSec(_currentMs / 1000)} 秒';
    } else if (_currentMs < 0) {
      label = '歌词提前 ${_fmtSec(-_currentMs / 1000)} 秒';
    } else {
      label = '当前未调整';
    }

    return GlassPanel(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                widget.title,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 15, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.white54),
              ),
              const SizedBox(height: 12),
              // 当前累计进度
              Text(
                label,
                textAlign: TextAlign.center,
                style: TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w600, color: primary),
              ),
              const SizedBox(height: 12),
              // 每次微调档位
              Wrap(
                alignment: WrapAlignment.center,
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final s in _steps)
                    ChoiceChip(
                      label: Text('${_fmtSec(s)} 秒',
                          style: const TextStyle(fontSize: 12)),
                      selected: _stepSec == s,
                      visualDensity: VisualDensity.compact,
                      onSelected: (_) => setState(() => _stepSec = s),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              // 相对当前：左提前(更早)，右延后(更晚)
              Row(
                children: [
                  Expanded(
                    child: _NudgeButton(
                      icon: Icons.fast_rewind,
                      label: '歌词提前',
                      onTap: () => _adjust(false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _NudgeButton(
                      icon: Icons.fast_forward,
                      label: '歌词延后',
                      onTap: () => _adjust(true),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Row(
                children: [
                  Expanded(
                    child: TextButton(
                      onPressed: () => Navigator.pop(context),
                      child:
                          const Text('取消', style: TextStyle(color: Colors.white70)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, _currentMs),
                      child: const Text('确定'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 校准面板里「提前/延后」一档一档挪的按钮。
class _NudgeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _NudgeButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white.withValues(alpha: 0.08),
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 22),
              const SizedBox(height: 6),
              Text(label,
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ],
          ),
        ),
      ),
    );
  }
}

/// 逐段校准面板（进阶/终极共用）：把歌词按「段」对齐到音频时间，重建时间轴。
/// - 上方：可播放/暂停、±0.1s（及 ±5s 快速定位）的进度条；
/// - 中下：可滑动歌词列表，基准线高亮行 = 当前选行；
/// - 成对打点：先「设为段开始」（高亮行 + 当前时间），再「设为段结束」成段；
/// - 段可视化标记（起始/结束/段内着色）+「最终确认」锁定。
/// 实时预览（onChanged 透传给歌词页）；「最终确认」返回 true，关闭返回 null。
class _SegSheet extends StatefulWidget {
  final Song song;
  final List<LyricLine> lines;
  final List<LyricSegment> segments;
  final ValueChanged<List<LyricSegment>> onChanged;
  // 终极模式为 true：面板内额外提供「导入 .lrc / 编辑歌词」入口。
  final bool allowLyricsEdit;
  const _SegSheet({
    required this.song,
    required this.lines,
    required this.segments,
    required this.onChanged,
    this.allowLyricsEdit = false,
  });

  @override
  State<_SegSheet> createState() => _SegSheetState();
}

class _SegSheetState extends State<_SegSheet> {
  // 行高跟随歌词字号（与歌词页保持一致），字号调大时面板里也不会挤
  double get _lineH => 44 * AppConfig.instance.lyricScale;
  final ScrollController _scroll = ScrollController();
  late List<LyricSegment> _segs;
  int? _pendingStartIdx;
  int? _pendingStartMs;

  // 编辑/预览：预览 = 歌词随歌曲滚动看效果
  bool _preview = false;
  // 前后跳秒档位（毫秒），可改：0.1s / 1s / 3s
  int _jumpStepMs = 100;
  // 白色基准线：可显示/隐藏、可自由调整上下位置
  bool _baselineVisible = true;
  double _baselineRatio = 0.62;
  int _previewLast = -1; // 预览时上一高亮行，避免反复滚动

  @override
  void initState() {
    super.initState();
    _segs = [...widget.segments]
      ..sort((a, b) => a.startIdx.compareTo(b.startIdx));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  int _focusIndex() {
    if (!_scroll.hasClients || widget.lines.isEmpty) return 0;
    return (_scroll.offset / _lineH).round().clamp(0, widget.lines.length - 1);
  }

  void _emit() {
    widget.onChanged([..._segs]);
    setState(() {});
  }

  void _setStart() {
    if (widget.lines.isEmpty) return;
    _pendingStartIdx = _focusIndex();
    _pendingStartMs = playerService!.pos.inMilliseconds;
    setState(() {});
  }

  void _setEnd() {
    final sidx = _pendingStartIdx;
    if (sidx == null) return;
    final eidx = _focusIndex();
    if (eidx < sidx) {
      // 结束行早于开始行时这段是无效区间（computeLineTimes 会算出空段），
      // 但锚点仍会生效导致预览跳变，直接拒绝并说明原因。
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('段结束不能早于开始：请把基准线移到开始行之后再打点'),
          behavior: SnackBarBehavior.floating,
        ));
      }
      return;
    }
    // 同一个开始行只保留一段：原实现允许重复添加，而删除按钮按起点只删第一条，
    // 用户按一次 ✕ 会「没反应」。这里先清掉同起点的旧段再写入。
    _segs.removeWhere((s) => s.startIdx == sidx);
    _segs.add(LyricSegment(
      sidx,
      eidx,
      _pendingStartMs ?? playerService!.pos.inMilliseconds,
      playerService!.pos.inMilliseconds,
    ));
    _pendingStartIdx = null;
    _pendingStartMs = null;
    _emit();
  }

  /// 计算段覆盖后的行显示时间（供预览跟随）。
  List<int> _lineTimes() {
    final n = widget.lines.length;
    final orig = List<int>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      orig[i] = widget.lines[i].time.inMilliseconds;
    }
    return computeLineTimes(orig, _segs);
  }

  /// 预览：当前播放时间对应的歌词行（用段时间轴，无段则原始）。
  int _previewIndex() {
    final times = _lineTimes();
    if (times.isEmpty) return 0;
    final target = playerService!.pos.inMilliseconds;
    var lo = 0, hi = times.length - 1, ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) ~/ 2;
      if (times[mid] <= target) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// 删除「以 idx 为起点」的段（同起点的重复段一并清掉，避免按了没反应）。
  void _removeSegByStart(int idx) {
    final before = _segs.length;
    _segs.removeWhere((s) => s.startIdx == idx);
    if (_segs.length != before) _emit();
  }

  /// 删除「以 idx 为终点」的段。
  void _removeSegByEnd(int idx) {
    final i = _segs.indexWhere((s) => s.endIdx == idx);
    if (i >= 0) {
      _segs.removeAt(i);
      _emit();
    }
  }

  void _jumpMs(int deltaMs) {
    final next = playerService!.pos + Duration(milliseconds: deltaMs);
    playerService!.seek(next < Duration.zero ? Duration.zero : next);
  }

  bool _inSeg(int idx) => _segs.any((s) => s.contains(idx));
  bool _isSegStart(int idx) => _segs.any((s) => s.startIdx == idx);
  bool _isSegEnd(int idx) => _segs.any((s) => s.endIdx == idx);

  String _fmtMs(int ms) {
    final sign = ms < 0 ? '-' : '';
    final a = ms.abs();
    final s = a ~/ 1000;
    return '$sign${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}.${(a % 1000) ~/ 100}';
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    // 弹层里的 MediaQuery 常丢失顶部安全区，改从系统视图直接取状态栏高度。
    final topPad = MediaQueryData.fromView(
            WidgetsBinding.instance.platformDispatcher.views.first)
        .padding
        .top;
    return GlassPanel(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: EdgeInsets.fromLTRB(20, 16 + topPad, 20, 10),
          child: Column(
            children: [
              // 顶部：标题 + 编辑/预览 + 段数 + 最终确认 + 关闭（现代暗色玻璃）
              Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 10),
                    decoration: BoxDecoration(
                      color: primary,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(color: primary.withValues(alpha: 0.5), blurRadius: 8),
                      ],
                    ),
                  ),
                  const Expanded(
                    child: Text(
                      '逐段校准',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  // 编辑/预览
                  SegmentedButton<bool>(
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 10),
                      selectedBackgroundColor: primary,
                      foregroundColor: Colors.white54,
                      selectedForegroundColor: Colors.white,
                      side: const BorderSide(color: Colors.white24),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    segments: const [
                      ButtonSegment(
                        value: false,
                        icon: Icon(Icons.brush_outlined, size: 16),
                        label: Text('编辑'),
                      ),
                      ButtonSegment(
                        value: true,
                        icon: Icon(Icons.play_arrow_outlined, size: 16),
                        label: Text('预览'),
                      ),
                    ],
                    selected: {_preview},
                    onSelectionChanged: (s) => setState(() {
                      _preview = s.first;
                      _previewLast = -1;
                    }),
                  ),
                  const SizedBox(width: 12),
                  Text('${_segs.length} 段',
                      style: const TextStyle(color: Colors.white54, fontSize: 12)),
                  const SizedBox(width: 14),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                    ),
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text(
                      '最终确认',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: 6),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.close, color: Colors.white38, size: 22),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              _buildProgressBar(primary),
              const SizedBox(height: 2),
              if (!_preview) _buildSegActions(primary),
              const SizedBox(height: 8),
              Expanded(child: _buildLyricList(primary)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProgressBar(Color primary) {
    return ListenableBuilder(
      listenable: playerService!.notifier,
      builder: (context, _) {
        final pos = playerService!.pos;
        final dur = playerService!.dur;
        final total = dur.inMilliseconds;
        final value =
            total > 0 ? (pos.inMilliseconds / total).clamp(0.0, 1.0) : 0.0;
        return Column(
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
                // ⚠️ 歌曲进度条 = **纯白**，刻意不跟主题色。
                //    与播放栏那条进度条同一套口径。
                //    本面板里的设置类控件（下面的 ChoiceChip、Switch、
                //    基准线滑杆）**仍然吃主题色** —— 那是刻意的分工：
                //    「播放控件 + 歌曲进度条 = 白；选择器/装饰 = 主题色」。
                activeTrackColor: Colors.white,
                inactiveTrackColor: Colors.white12,
                thumbColor: Colors.white,
              ),
              child: Slider(
                value: value,
                onChanged: (v) => playerService!
                    .seek(Duration(milliseconds: (v * total).round())),
              ),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.replay, color: Colors.white54, size: 22),
                  onPressed: () => _jumpMs(-_jumpStepMs),
                ),
                // ⚠️ 播放/暂停 = **裸字形 + 纯白**，刻意不跟主题色。
                //    早先用的是 Material 那两个 **circle 版**播放/暂停
                //    字形（`Icons.*_circle_*`）染 primary —— 那是全 app 最后一处
                //    「主题色实心圆盘 + 挖空符号」。现在按同一条产品规则统一：
                //    「播放/暂停控件一律裸字形 + 白」，与播放栏那颗
                //    （`player_bar.dart`）同一套写法、同一个 iconSize = 34。
                //    ⛔ 别改回 circle 版：有一条颜色测试的 ★7 会红。
                //    ⚠️ 本注释**刻意不把那两个常量名拼出来** —— 那条断言是**原样扫源码文本**
                //    （注释也算），拼出来它自己就会红。
                IconButton(
                  visualDensity: VisualDensity.compact,
                  iconSize: 34,
                  icon: Icon(
                    playerService!.isPlaying
                        ? Icons.pause
                        : Icons.play_arrow,
                    color: Colors.white,
                  ),
                  onPressed: playerService!.toggle,
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.forward, color: Colors.white54, size: 22),
                  onPressed: () => _jumpMs(_jumpStepMs),
                ),
                const SizedBox(width: 10),
                Text(
                  '${_fmtMs(pos.inMilliseconds)} / ${_fmtMs(dur.inMilliseconds)}',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final step in const [(100, '0.1s'), (1000, '1s'), (3000, '3s')])
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Text(step.$2, style: const TextStyle(fontSize: 11)),
                      selected: _jumpStepMs == step.$1,
                      visualDensity: VisualDensity.compact,
                      labelStyle: TextStyle(
                        color: _jumpStepMs == step.$1
                            ? Colors.white
                            : Colors.white54,
                      ),
                      backgroundColor: Colors.white12,
                      selectedColor: primary,
                      onSelected: (_) => setState(() => _jumpStepMs = step.$1),
                    ),
                  ),
              ],
            ),
          ],
        );
      },
    );
  }

  Widget _buildSegActions(Color primary) {
    final pending = _pendingStartIdx != null;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor: primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                icon: const Icon(Icons.radio_button_checked, size: 17),
                label: Text(
                  pending
                      ? '已设段开始  ${_fmtMs(_pendingStartMs ?? 0)}'
                      : '设为段开始',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                // 没有歌词行时打点无从下手（_setStart 也只是空转）→ 直接置灰，
                // 别让用户点了没反应（空状态现在能进这个面板了）
                onPressed: widget.lines.isEmpty ? null : _setStart,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                style: FilledButton.styleFrom(
                  backgroundColor:
                      pending ? primary : Colors.white.withValues(alpha: 0.08),
                  foregroundColor: pending ? Colors.white : Colors.white54,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  disabledBackgroundColor: Colors.white.withValues(alpha: 0.05),
                ),
                icon: const Icon(Icons.stop, size: 17),
                label: Text(
                  pending ? '设为段结束' : '先设段开始',
                  style: const TextStyle(fontSize: 13),
                ),
                onPressed: pending ? _setEnd : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          pending
              ? '滑动歌词到这段结尾那句，再点「设为段结束」'
              : '滑动歌词到某句对准基准线，播放到该句开始唱时点「设为段开始」',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: Colors.white38, height: 1.4),
        ),
        const SizedBox(height: 10),
        // 白色基准线：可加入/删除（开关）+ 自由移动（滑块调位置）
        Row(
          children: [
            const Icon(Icons.horizontal_rule, color: Colors.white38, size: 16),
            const SizedBox(width: 6),
            const Text('基准线', style: TextStyle(fontSize: 12, color: Colors.white54)),
            const SizedBox(width: 4),
            Switch(
              value: _baselineVisible,
              activeThumbColor: primary,
              onChanged: (v) => setState(() => _baselineVisible = v),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Slider(
                value: _baselineRatio,
                activeColor: primary,
                inactiveColor: Colors.white12,
                onChanged: (v) => setState(() => _baselineRatio = v),
              ),
            ),
          ],
        ),
        // 终极：面板内提供「导入 .lrc / 编辑歌词」（pop 特殊结果交给父处理）
        if (widget.allowLyricsEdit) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: _outlinePill(
                  Icons.upload_file,
                  '导入 .lrc',
                  () => Navigator.pop(context, 'import'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _outlinePill(
                  Icons.edit_note,
                  '编辑歌词',
                  () => Navigator.pop(context, 'edit'),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 次级圆角按钮（导入/编辑歌词，白描边）。
  Widget _outlinePill(IconData icon, String label, VoidCallback onTap) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white70,
        side: const BorderSide(color: Colors.white24),
        padding: const EdgeInsets.symmetric(vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      icon: Icon(icon, size: 18),
      label: Text(label, style: const TextStyle(fontSize: 13)),
      onPressed: onTap,
    );
  }

  Widget _buildLyricList(Color primary) {
    final lines = widget.lines;
    if (lines.isEmpty) {
      // 面板内空词提示：用户已经在「终极」面板里，就在下面那两颗按钮上，
      // 别再叫他「长按歌词」（他正是因为按不到歌词才进来的，那是死循环文案）。
      return Center(
        child: Text(
          widget.allowLyricsEdit
              ? '没有歌词行：用下方「导入 .lrc」或「编辑歌词」补上'
              : '没有歌词行，请先用「终极」导入或编辑歌词',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, c) {
        final focusY = c.maxHeight * _baselineRatio.clamp(0.05, 0.92);
        return Stack(
          children: [
            // 基准线：可显示/隐藏
            if (_baselineVisible)
              Positioned(
                top: focusY - 1,
                left: 0,
                right: 0,
                height: 2,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        Colors.white.withValues(alpha: 0),
                        Colors.white.withValues(alpha: 0.6),
                        Colors.white.withValues(alpha: 0),
                      ],
                    ),
                  ),
                ),
              ),
            ListenableBuilder(
              listenable: playerService!.notifier,
              builder: (context, _) {
                // 编辑=用户滑动选行为高亮行；预览=随播放进度的高亮行
                final active = _preview ? _previewIndex() : _focusIndex();
                // 预览：跟随歌曲自动滚动到基准线
                if (_preview && active != _previewLast) {
                  _previewLast = active;
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!_scroll.hasClients) return;
                    final target = (active * _lineH)
                        .clamp(0.0, _scroll.position.maxScrollExtent);
                    _scroll.animateTo(
                      target,
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                    );
                  });
                }
                return ListView.builder(
                  controller: _scroll,
                  padding: EdgeInsets.only(
                    // 小屏/分屏下可用高度可能小于基准线预留，clamp 成非负：
                    // 负 padding 会直接触发 RenderSliverPadding 的断言。
                    top: (focusY - _lineH / 2).clamp(0.0, double.infinity),
                    bottom: (c.maxHeight - focusY - _lineH / 2)
                        .clamp(0.0, double.infinity),
                  ),
                  itemExtent: _lineH,
                  itemCount: lines.length,
                  itemBuilder: (context, i) {
                    final isActive = i == active;
                    final inSeg = _inSeg(i);
                    final isStart = _isSegStart(i);
                    final isEnd = _isSegEnd(i);
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      color: isActive
                          ? primary.withValues(alpha: 0.12)
                          : (inSeg
                              ? primary.withValues(alpha: 0.05)
                              : Colors.transparent),
                      child: Row(
                        children: [
                          // 左端标记（白色，不随主题色）
                          SizedBox(
                            width: 40,
                            child: isStart
                                ? const Icon(Icons.play_arrow,
                                    color: Colors.white, size: 16)
                                : isEnd
                                    ? const Icon(Icons.stop,
                                        color: Colors.white, size: 14)
                                    : null,
                          ),
                          Expanded(
                            child: Text(
                              lines[i].text,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: isActive ? 19 : 15,
                                fontWeight: isActive
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: isActive
                                    ? Colors.white
                                    : Colors.white
                                        .withValues(alpha: inSeg ? 0.9 : 0.5),
                              ),
                            ),
                          ),
                          // 右端删除键（白色）：编辑态、段起/终点行显示
                          SizedBox(
                            width: 40,
                            child: (!_preview && isStart)
                                ? _delBtn(() => _removeSegByStart(i))
                                : (!_preview && isEnd)
                                    ? _delBtn(() => _removeSegByEnd(i))
                                    : null,
                          ),
                        ],
                      ),
                    );
                  },
                );
              },
            ),
          ],
        );
      },
    );
  }

  /// 白色小删除按钮（不随主题色）。
  Widget _delBtn(VoidCallback onTap) {
    return Center(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: Container(
          padding: const EdgeInsets.all(3),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white54),
          ),
          child: const Icon(Icons.close, color: Colors.white, size: 13),
        ),
      ),
    );
  }
}
