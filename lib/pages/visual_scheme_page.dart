/// 视觉方案管理页：保存当前整套视觉配置为可回放的方案，网格展示每套的享受页缩略图；
/// 点方案整套应用，长按进入多选批量删除；缩略图一排可切 2~4 个。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../app_config.dart';
import '../visual_presets.dart';
import '../widgets/ambient_layer.dart';
import '../widgets/glass_panel.dart';
import '../widgets/input_dialog.dart';
import '../widgets/wallpaper_layer.dart';

class VisualSchemePage extends StatefulWidget {
  const VisualSchemePage({super.key});

  @override
  State<VisualSchemePage> createState() => _VisualSchemePageState();
}

class _VisualSchemePageState extends State<VisualSchemePage> {
  /// 多选模式下已勾选的方案 id 集合；空 = 未进入多选
  final Set<String> _multiSelected = {};
  bool _saving = false;
  bool get _multiSelecting => _multiSelected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    VisualPresets.instance.refresh();
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return PopScope(
      // 多选中拦截系统返回：先退出多选，而不是直接退出页面
      canPop: !_multiSelecting,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _exitMultiSelect();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: ListenableBuilder(
          listenable: Listenable.merge([
            VisualPresets.instance,
            AppConfig.instance,
          ]),
          builder: (context, _) {
            return Stack(
              children: [
                const Positioned.fill(child: WallpaperLayer()),
                const Positioned.fill(child: AmbientLayer(isPreview: true)),
                SafeArea(
                  child: Column(
                    children: [
                      _header(),
                      _multiSelecting ? _multiBar() : _toolbar(primary),
                      Expanded(child: _grid(primary)),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 顶部标题栏：返回键 + 标题。
  Widget _header() {
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
              '视觉方案',
              style: const TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
          ),
          Text(
            '${VisualPresets.instance.presets.length} 套',
            style: const TextStyle(color: Colors.white54, fontSize: 13),
          ),
        ],
      ),
    );
  }

  /// 普通模式工具栏：保存按钮 + 缩略图列数切换 + 说明。
  Widget _toolbar(Color primary) {
    final cfg = AppConfig.instance;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          FilledButton.icon(
            icon: Icon(_saving ? Icons.hourglass_top : Icons.add_photo_alternate_outlined),
            label: Text(_saving ? '保存中…' : '保存当前视觉方案'),
            onPressed: _saving ? null : _save,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Text(
                '缩略图一排',
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
              const Spacer(),
              SegmentedButton<int>(
                style: SegmentedButton.styleFrom(
                  foregroundColor: Colors.white,
                  selectedForegroundColor: Colors.black,
                  selectedBackgroundColor: primary,
                  side: const BorderSide(color: Colors.white24),
                  textStyle: const TextStyle(fontSize: 12),
                ),
                showSelectedIcon: false,
                segments: const [
                  ButtonSegment(value: 2, label: Text('2')),
                  ButtonSegment(value: 3, label: Text('3')),
                  ButtonSegment(value: 4, label: Text('4')),
                ],
                selected: {cfg.presetGridColumns.clamp(2, 4)},
                onSelectionChanged: (s) =>
                    AppConfig.instance.setPresetGridColumns(s.first),
              ),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            '点方案整套应用；长按缩略图可多选/删除；每次保存自动截一张享受页缩略图',
            style: TextStyle(fontSize: 11, color: Colors.white38),
          ),
        ],
      ),
    );
  }

  /// 多选操作栏：关闭 × 已选 N 全选 删除。
  Widget _multiBar() {
    final allPicked = VisualPresets.instance.presets.isNotEmpty &&
        VisualPresets.instance.presets
            .every((p) => _multiSelected.contains(p.id));
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: SurfaceCard(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.close, color: Colors.white54, size: 20),
              tooltip: '退出多选',
              onPressed: _exitMultiSelect,
            ),
            Text(
              '已选 ${_multiSelected.length}',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            const Spacer(),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: Colors.white70),
              onPressed: () => _toggleAll(!allPicked),
              child: Text(allPicked ? '取消全选' : '全选'),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除'),
              onPressed: _multiDelete,
            ),
          ],
        ),
      ),
    );
  }

  /// 方案网格：竖版缩略图卡片（长按进多选）。
  Widget _grid(Color primary) {
    final presets = VisualPresets.instance.presets;
    if (presets.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '还没有视觉方案\n点上方「保存当前视觉方案」，把此刻的壁纸、主题、特效都存下来',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white38, fontSize: 13),
          ),
        ),
      );
    }
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: AppConfig.instance.presetGridColumns.clamp(2, 4),
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.46, // 竖版长条
      ),
      itemCount: presets.length,
      itemBuilder: (context, i) {
        final p = presets[i];
        final selected = _multiSelected.contains(p.id);
        return GestureDetector(
          onTap: () => _onTap(p),
          onLongPress: () => _toggle(p.id),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: selected ? primary : Colors.white24,
                width: selected ? 2 : 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Image.file(
                    File(p.thumbPath),
                    fit: BoxFit.cover,
                    gaplessPlayback: true,
                    // 按「当前列数对应的缩略图显示宽度」解码并缓存：写死 140 在 2 列时
                    // 会被放大发虚、4 列时又白解码大图
                    cacheWidth: ((MediaQuery.sizeOf(context).width /
                                AppConfig.instance.presetGridColumns.clamp(2, 4)) *
                            dpr)
                        .round(),
                    errorBuilder: (_, _, _) => Container(
                      color: Colors.black26,
                      child: const Icon(Icons.image_outlined,
                          color: Colors.white38),
                    ),
                  ),
                  // 底部名字条
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 4),
                      color: Colors.black54,
                      child: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  // 多选勾选角标
                  if (selected)
                    Align(
                      alignment: Alignment.topRight,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.check_circle, color: primary, size: 20),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---- 交互 ----

  void _back() {
    if (_multiSelecting) {
      _exitMultiSelect();
    } else {
      Navigator.pop(context);
    }
  }

  /// 点方案：普通模式整套应用；多选模式下做勾选切换。
  Future<void> _onTap(VisualPreset p) async {
    if (_multiSelecting) {
      _toggle(p.id);
      return;
    }
    final restored = await VisualPresets.instance.apply(p.id);
    _toast(restored
        ? '已切换到「${p.name}」，壁纸已放回「已上传壁纸」'
        : '已切换到「${p.name}」');
  }

  void _toggle(String id) {
    setState(() {
      if (!_multiSelected.remove(id)) _multiSelected.add(id);
    });
  }

  void _exitMultiSelect() {
    if (_multiSelected.isEmpty) return;
    setState(() => _multiSelected.clear());
  }

  void _toggleAll(bool pick) {
    setState(() {
      if (pick) {
        _multiSelected.addAll(
            VisualPresets.instance.presets.map((p) => p.id));
      } else {
        _multiSelected.clear();
      }
    });
  }

  /// 保存当前整套视觉方案：先弹输入框命名，再存配置 + 截图。
  Future<void> _save() async {
    if (_saving) return;
    final name = await showDialog<String>(
      context: context,
      builder: (_) => TextInputDialog(
        title: '保存视觉方案',
        hint: '给这套方案起个名字',
        initialValue: '方案 ${VisualPresets.instance.presets.length + 1}',
        confirmLabel: '保存',
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _saving = true);
    final id = await VisualPresets.instance.saveCurrent(name: name);
    if (mounted) {
      setState(() => _saving = false);
      _toast(id != null ? '已保存「$name」' : '保存失败，请重试');
    }
  }

  /// 批量删除方案：确认后删 json + 缩略图。
  Future<void> _multiDelete() async {
    if (_multiSelected.isEmpty) return;
    final ok = await _confirmDelete(_multiSelected.length);
    if (ok != true || !mounted) return;
    // 传副本：delete 内部逐项 await 删文件，期间网格仍可交互，直接传「活的」选中集合
    // 会被 _toggle/_toggleAll 改掉 → ConcurrentModificationError，删一半中断。
    await VisualPresets.instance.delete(Set.of(_multiSelected));
    _exitMultiSelect();
    _toast('已删除');
  }

  /// 删除确认弹窗：毛玻璃，与歌单批量删除同款。
  Future<bool?> _confirmDelete(int count) {
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
                '删除视觉方案',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '删除这 $count 套方案吗？',
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
