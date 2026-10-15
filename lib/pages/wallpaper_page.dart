/// 左页：背景壁纸管理（相册选图、原图存储、透明度调节、列表管理）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../app_config.dart';
import '../widgets/glass_panel.dart';
import '../widgets/row_turn_scroll.dart';

class WallpaperPage extends StatefulWidget {
  const WallpaperPage({super.key});

  @override
  State<WallpaperPage> createState() => _WallpaperPageState();
}

class _WallpaperPageState extends State<WallpaperPage> {
  final ImagePicker _picker = ImagePicker();
  List<String> _wallpapers = []; // 已上传壁纸的绝对路径
  late double _opacity = AppConfig.instance.wallpaperOpacity;
  String? _lastWallpaperPath; // 上次已知的壁纸路径（判断配置变化要不要重扫目录）

  @override
  void initState() {
    super.initState();
    AppConfig.instance.addListener(_onConfigChanged);
    _loadWallpapers();
  }

  @override
  void dispose() {
    AppConfig.instance.removeListener(_onConfigChanged);
    super.dispose();
  }

  /// 配置变化（如视觉方案把壁纸放回「已上传壁纸」）后重扫列表，让新壁纸即时出现。
  /// AppConfig 是全局通知器（主题色/字体/特效滑杆每次变化都会通知），只有壁纸路径
  /// 真的变了才需要重扫目录 —— 否则换个主题也要 listSync + 每文件 statSync 一遍。
  void _onConfigChanged() {
    final p = AppConfig.instance.wallpaperPath;
    if (p == _lastWallpaperPath) return;
    _lastWallpaperPath = p;
    _loadWallpapers();
  }

  Future<Directory> _wpDir() async {
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/wallpapers');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return dir;
  }

  Future<void> _loadWallpapers() async {
    final dir = await _wpDir();
    // 每个文件只 statSync 一次：原实现在比较器里每比较一对都要 statSync 两次，
    // N 个壁纸就是 O(N log N) 次同步系统调用（全在 UI 线程上）。
    final entries = <(File, DateTime)>[
      for (final f in dir.listSync().whereType<File>())
        (f, f.statSync().modified),
    ]..sort((a, b) => b.$2.compareTo(a.$2));
    _lastWallpaperPath = AppConfig.instance.wallpaperPath;
    if (mounted) {
      setState(() => _wallpapers = [for (final e in entries) e.$1.path]);
    }
  }

  Future<void> _pickWallpaper() async {
    final x = await _picker.pickImage(
      source: ImageSource.gallery,
      imageQuality: null, // null = 不压缩，保留原图
      requestFullMetadata: false,
    );
    if (x == null) return;
    // 保留原扩展名，支持 png/jpg/jpeg/webp/gif/bmp 等
    var ext = 'jpg';
    final dot = x.path.lastIndexOf('.');
    if (dot != -1 && x.path.length - dot <= 6) {
      ext = x.path.substring(dot + 1).toLowerCase();
    }
    final dir = await _wpDir();
    final dest = '${dir.path}/wp_${DateTime.now().millisecondsSinceEpoch}.$ext';
    // 直接复制原图字节，不重新编码，画质零减损
    await x.saveTo(dest);
    await AppConfig.instance.setWallpaperPath(dest);
    await _loadWallpapers();
  }

  Future<void> _deleteWallpaper(String path) async {
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
              const Text('删除壁纸',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 12),
              const Text('确定删除这张壁纸吗？',
                  style: TextStyle(color: Colors.white70, fontSize: 14)),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: Colors.white70),
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(foregroundColor: Theme.of(context).colorScheme.primary),
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
    try {
      File(path).deleteSync();
    } catch (_) {
      // 文件被占用/权限不足：不能静默当成功，否则用户看到「删掉了」，
      // 下次进这一页它又冒出来。
      _toast('删除失败：文件可能正被占用，请稍后重试');
      return;
    }
    if (AppConfig.instance.wallpaperPath == path) {
      await AppConfig.instance.setWallpaperPath(null);
    }
    await _loadWallpapers();
    _toast('已删除壁纸');
  }

  Future<void> _resetBackground() async {
    await AppConfig.instance.setWallpaperPath(null);
    _toast('已恢复默认背景');
  }

  /// 一键保存全部「已上传壁纸」到系统相册（Pictures/MuBox）。
  /// 相册已有同名则跳过；当前壁纸（含用视觉方案恢复回来的壁纸）也一并保存。
  Future<void> _saveAllToGallery() async {
    const ch = MethodChannel('com.mubox.mu_box_phone/gallery');
    final set = <String>{..._wallpapers};
    final cur = AppConfig.instance.wallpaperPath;
    if (cur != null && File(cur).existsSync()) set.add(cur);
    if (set.isEmpty) {
      _toast('没有已上传的壁纸');
      return;
    }
    var saved = 0, skip = 0, fail = 0;
    for (final p in set) {
      final name = p.split(RegExp(r'[/\\]')).last;
      try {
        final uri = await ch.invokeMethod<String>('saveImage', {'src': p, 'name': name});
        if (uri != null) {
          saved++;
        } else {
          skip++; // 相册已有同名 → 跳过
        }
      } catch (_) {
        fail++;
      }
    }
    _toast(
      '已保存 $saved 张到相册'
      '${skip > 0 ? '，跳过 $skip 张（已存在）' : ''}'
      '${fail > 0 ? '，失败 $fail 张' : ''}',
    );
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: AppConfig.instance,
        builder: (context, _) {
          final config = AppConfig.instance;
          final primary = Theme.of(context).colorScheme.primary;
          final hasCurrent = config.wallpaperPath != null && File(config.wallpaperPath!).existsSync();
          // 这一页的内容高度**不是常数**：有「已上传壁纸」时底下会多出
          // 缩略图横条 + 「一键保存全部…」按钮（约 +280），在一屏放不下的机型上
          // 原先锁死 physics ⇒ 最下面那半截被视口静默裁掉、永远滑不出来。
          // 与歌单页同一处理：解锁滚动 + 「滑到底继续上滑 → 翻到下行」
          // （判定在 `lib/row_turn.dart`，接线在 `lib/widgets/row_turn_scroll.dart`，
          // 歌单页/壁纸页/设置页共用同一套 —— 手势开始时已经在底才可能翻页）。
          final list = ListView(
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 180),
            children: [
              const Text('壁纸',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              const Text('从手机相册选择高清壁纸，原图存储、不压缩画质与分辨率',
                  style: TextStyle(fontSize: 12, color: Colors.white38)),
              const SizedBox(height: 16),
              // 当前壁纸预览
              ClipRRect(
                borderRadius: BorderRadius.circular(14),
                child: Container(
                  height: 200,
                  color: const Color(0x22FFFFFF),
                  child: hasCurrent
                      ? Image.file(
                          File(config.wallpaperPath!),
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                          cacheWidth: (MediaQuery.of(context).size.width *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                        )
                      : Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(Icons.wallpaper, size: 40, color: Colors.white38),
                              const SizedBox(height: 8),
                              const Text('尚未设置壁纸', style: TextStyle(color: Colors.white54)),
                            ],
                          ),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              // 壁纸设置区块：选图按钮 + 透明度 + 恢复默认，收进一张卡片
              SurfaceCard(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.photo_library_outlined),
                        label: const Text('从相册选择壁纸'),
                        onPressed: _pickWallpaper,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const Text('透明度', style: TextStyle(color: Colors.white70, fontSize: 14)),
                        Expanded(
                          child: Slider(
                            value: _opacity,
                            min: 0.15,
                            max: 0.7,
                            activeColor: primary,
                            inactiveColor: Colors.white12,
                            // 拖动期间仅局部刷新，松手才持久化并更新全局背景，避免拖动卡顿
                            onChanged: (v) => setState(() => _opacity = v),
                            onChangeEnd: (v) => AppConfig.instance.setWallpaperOpacity(v),
                          ),
                        ),
                        Text('${(_opacity * 100).round()}%',
                            style: const TextStyle(color: Colors.white54, fontSize: 12)),
                      ],
                    ),
                    const SizedBox(height: 4),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        icon: const Icon(Icons.restart_alt),
                        label: const Text('恢复默认背景'),
                        onPressed: _resetBackground,
                      ),
                    ),
                  ],
                ),
              ),
              if (_wallpapers.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Text('已上传壁纸',
                    style: TextStyle(fontWeight: FontWeight.w600, color: Colors.white70, fontSize: 14)),
                const SizedBox(height: 10),
                SurfaceCard(
                  padding: const EdgeInsets.all(12),
                  child: SizedBox(
                    height: 120,
                    child: ListView.separated(
                      scrollDirection: Axis.horizontal,
                      itemCount: _wallpapers.length,
                      separatorBuilder: (_, _) => const SizedBox(width: 10),
                      itemBuilder: (context, i) {
                        final p = _wallpapers[i];
                        final isCurrent = p == config.wallpaperPath;
                        return GestureDetector(
                          onTap: () => AppConfig.instance.setWallpaperPath(p),
                          onLongPress: () => _deleteWallpaper(p),
                          child: Container(
                            width: 80,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: isCurrent ? primary : Colors.white24,
                                width: isCurrent ? 2 : 1,
                              ),
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(
                                File(p),
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                                // 按缩略图显示尺寸解码并缓存，避免每次切页都全分辨率重解高清原图而闪烁
                                cacheWidth: (80 * MediaQuery.of(context).devicePixelRatio).round(),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                const Text('点击切换壁纸 · 长按删除', style: TextStyle(fontSize: 11, color: Colors.white38)),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.download_outlined),
                    label: const Text('一键保存全部已上传壁纸到相册'),
                    onPressed: _saveAllToGallery,
                  ),
                ),
              ],
            ],
          );
          return RowTurnScroll(child: list);
        },
      ),
    );
  }
}
