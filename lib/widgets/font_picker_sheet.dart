/// 字体样式选择弹层：扫描本机字体文件、逐行预览、点击切换 App 内部字体。
///
/// 字体用 FontLoader 动态加载（读文件字节注册 family），切换后写 AppConfig 持久化，
/// theme 的 fontFamily 指向该 family，全局文本即时生效，不随手机系统字体变化。
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_config.dart';
import '../widgets/glass_panel.dart';

/// 打开字体选择弹层（毛玻璃底部弹层）。
Future<void> showFontPicker(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.72,
      child: const FontPickerSheet(),
    ),
  );
}

/// 一个扫描到的字体：文件路径 + 显示名 + 加载后的 family（未加载为 null）。
class _FontItem {
  final String path;
  final String name;
  String? family;
  _FontItem({required this.path, required this.name});
}

class FontPickerSheet extends StatefulWidget {
  const FontPickerSheet({super.key});
  @override
  State<FontPickerSheet> createState() => _FontPickerSheetState();
}

class _FontPickerSheetState extends State<FontPickerSheet> {
  static const List<String> _exts = ['.ttf', '.otf', '.ttc'];
  final List<_FontItem> _systemFonts = []; // 系统自带（/system/fonts）
  final List<_FontItem> _userFonts = []; // 用户下载（Download / 主题商店等）
  bool _scanning = false;
  int _group = 0; // 当前分组：0 系统自带 / 1 用户下载
  String _current = AppConfig.instance.fontFamily; // 当前生效 family
  String? _loadingPath; // 正在加载的字体路径
  int _seq = 0; // family 序号（保证每次加载 family 唯一）

  /// 扫描本机字体目录，分两组：
  /// 系统自带（/system/fonts，只读） + 用户下载（Download / Documents / 主题商店）。
  Future<void> _scan() async {
    setState(() => _scanning = true);
    const systemDirs = ['/system/fonts']; // 系统字体（只读，通常可读）
    const userDirs = [
      '/storage/emulated/0/Download', // 通用下载目录
      '/storage/emulated/0/Documents',
      '/storage/emulated/0/fonts',
      '/storage/emulated/0/MIUI/theme/.data/content/fonts', // MIUI 主题商店字体
      '/storage/emulated/0/Huawei/Themes', // 华为主题字体
    ];

    Future<Set<String>> collect(List<String> dirs) async {
      final found = <String>{};
      for (final d in dirs) {
        final dir = Directory(d);
        if (!await dir.exists()) continue;
        try {
          await for (final e in dir.list(recursive: true, followLinks: false)) {
            if (e is! File) continue;
            final p = e.path.toLowerCase();
            if (_exts.any((x) => p.endsWith(x))) found.add(e.path);
          }
        } catch (_) {
          // 无权限/目录异常：跳过该目录继续扫别的
        }
      }
      return found;
    }

    final sysPaths = await collect(systemDirs);
    final userPaths = await collect(userDirs);

    // 保留已加载过的 family 映射（按路径），避免重复加载后预览丢失
    final oldFamily = {
      for (final it in [..._systemFonts, ..._userFonts]) it.path: it.family,
    };
    setState(() {
      _systemFonts
        ..clear()
        ..addAll(_toItems(sysPaths, oldFamily));
      _userFonts
        ..clear()
        ..addAll(_toItems(userPaths, oldFamily));
      _scanning = false;
    });
  }

  /// 路径集合 → 排序后的字体项列表（继承已加载的 family）。
  List<_FontItem> _toItems(Set<String> paths, Map<String, String?> oldFamily) {
    final sorted = paths.toList()..sort();
    return sorted.map((p) {
      final name = p.split('/').last;
      return _FontItem(path: p, name: name)..family = oldFamily[p];
    }).toList();
  }

  /// 加载字体文件并应用到 App。
  Future<void> _apply(_FontItem item) async {
    setState(() => _loadingPath = item.path);
    final family = 'MuBoxFont${_seq++}';
    try {
      final bytes = await File(item.path).readAsBytes();
      final loader = FontLoader(family)
        ..addFont(Future.value(ByteData.view(bytes.buffer)));
      await loader.load();
      item.family = family;
      await AppConfig.instance.setCustomFont(family, item.path);
      if (!mounted) return;
      setState(() {
        _current = family;
        _loadingPath = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingPath = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('字体加载失败：$e'),
          behavior: SnackBarBehavior.floating,
        ),
      );
    }
  }

  /// 恢复系统默认字体。
  Future<void> _reset() async {
    await AppConfig.instance.setCustomFont('', null);
    if (mounted) setState(() => _current = '');
  }

  @override
  Widget build(BuildContext context) {
    return GlassPanel(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 标题栏
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 12, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text(
                      '字体样式',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white70),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // 扫描 + 恢复默认
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: FilledButton.icon(
                      icon: Icon(
                        _scanning ? Icons.hourglass_top : Icons.folder_open,
                      ),
                      label: Text(_scanning ? '扫描中…' : '扫描本机字体'),
                      onPressed: _scanning ? null : _scan,
                    ),
                  ),
                  const SizedBox(width: 10),
                  OutlinedButton(
                    onPressed: _current.isEmpty ? null : _reset,
                    child: const Text('恢复默认'),
                  ),
                ],
              ),
            ),
            // 分组切换按钮：系统自带 / 用户下载
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(child: _groupButton('系统自带', 0)),
                  const SizedBox(width: 10),
                  Expanded(child: _groupButton('用户下载', 1)),
                ],
              ),
            ),
            // 字体列表 / 空提示（只显示当前分组）
            Expanded(
              child: _groupFonts.isEmpty
                  ? const Center(
                      child: Text(
                        '点击上方扫描本机字体\n（系统字体 / 下载目录）',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 12, color: Colors.white38),
                      ),
                    )
                  : ListView(
                      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                      children: [for (final it in _groupFonts) _fontRow(it)],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  /// 当前分组字体列表。
  List<_FontItem> get _groupFonts => _group == 0 ? _systemFonts : _userFonts;

  /// 分组切换按钮（系统自带 / 用户下载）。
  Widget _groupButton(String label, int g) {
    final selected = _group == g;
    final primary = Theme.of(context).colorScheme.primary;
    return OutlinedButton(
      style: OutlinedButton.styleFrom(
        backgroundColor: selected
            ? primary.withValues(alpha: 0.18)
            : Colors.transparent,
        foregroundColor: selected ? primary : Colors.white70,
        side: BorderSide(color: selected ? primary : Colors.white24),
        padding: const EdgeInsets.symmetric(vertical: 10),
      ),
      onPressed: () => setState(() => _group = g),
      child: Text(label),
    );
  }

  Widget _fontRow(_FontItem item) {
    final selected = item.family != null && item.family == _current;
    final loading = _loadingPath == item.path;
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: loading ? null : () => _apply(item),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: selected
              ? primary.withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? primary : Colors.white12),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.name,
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                  const SizedBox(height: 4),
                  // 预览：已加载用真实字体，未加载用默认字体
                  Text(
                    '字体预览 0123 永字 ABC',
                    style: TextStyle(
                      fontFamily: item.family,
                      fontSize: 17,
                      color: selected ? primary : Colors.white,
                    ),
                  ),
                ],
              ),
            ),
            if (loading)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else if (selected)
              const Icon(Icons.check, color: Colors.white, size: 18),
          ],
        ),
      ),
    );
  }
}
