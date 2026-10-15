/// 视觉方案：把当前整套视觉配置（壁纸 / 主题色 / 视觉·氛围·律动·边框四区特效与参数）
/// 固化为可回放的方案，每套自动配一张享受页竖版缩略图；支持长按删除 / 多选批量删除，
/// 并随备份 zip 一起导出/恢复。
///
/// 存储：`docs/visual_presets/<id>.json`（配置）+ `<id>.png`（竖版缩略图）+ `<id>.wall`（壁纸备份），
/// id 用毫秒时间戳字符串。保存时会把当前壁纸复制一份进方案目录；应用方案时若壁纸已在
/// 「已上传壁纸」被删，会用这份备份把它找回并放回壁纸页列表；两边都没有才回默认背景。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:path_provider/path_provider.dart';

import 'app_config.dart';
import 'theme.dart';

/// 一套视觉方案的运行时摘要（完整字段存在 `<id>.json` 里，缩略图为 `<id>.png`）。
class VisualPreset {
  const VisualPreset({
    required this.id,
    required this.name,
    required this.thumbPath,
  });

  final String id;
  final String name;

  /// 缩略图文件绝对路径（`<docs>/visual_presets/<id>.png`）
  final String thumbPath;
}

class VisualPresets extends ChangeNotifier {
  VisualPresets._();

  static final VisualPresets instance = VisualPresets._();

  /// 根页面截图用的 RepaintBoundary key：root_page 用它包住「壁纸+特效」两层，
  /// 保存方案时从它截取享受页竖版缩略图（不含底部播放栏）。
  static final GlobalKey shotKey = GlobalKey();

  /// 已加载的方案摘要列表（按创建时间新→旧）
  List<VisualPreset> presets = [];

  Future<Directory> _dir() async {
    final docs = await getApplicationDocumentsDirectory();
    final d = Directory('${docs.path}/visual_presets');
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 重新扫描磁盘，刷新方案列表；顺带清掉「没有对应方案」的孤儿缩略图 / 壁纸备份。
  /// 孤儿来自老版本删除逻辑漏删 .wall（壁纸备份，单个最大可达数 MB），
  /// 这里每次刷新补一次清理，避免垃圾长期占空间。
  Future<void> refresh() async {
    final dir = await _dir();
    final files = dir.listSync().whereType<File>().toList();
    final jsonFiles = [for (final f in files) if (f.path.endsWith('.json')) f];
    // 以「.json 文件是否存在」判断方案在不在：解析失败的方案也算存在，免得误删它的图
    final liveIds = <String>{for (final f in jsonFiles) _stemOf(f.path)};
    final list = <VisualPreset>[];
    for (final f in jsonFiles) {
      final idStem = _stemOf(f.path);
      try {
        final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
        list.add(VisualPreset(
          id: (m['id'] as String?) ?? idStem,
          name: (m['name'] as String?) ?? '未命名方案',
          thumbPath: '${dir.path}/$idStem.png',
        ));
      } catch (_) {
        // 单个方案损坏跳过，不影响其余方案
      }
    }
    for (final f in files) {
      final name = f.path.split(Platform.pathSeparator).last;
      final dot = name.lastIndexOf('.');
      if (dot <= 0) continue;
      final ext = name.substring(dot);
      if (ext != '.png' && ext != '.wall') continue;
      if (liveIds.contains(name.substring(0, dot))) continue;
      try {
        await f.delete(); // 无主文件（方案已删）：删掉腾空间
      } catch (_) {}
    }
    list.sort((a, b) => b.id.compareTo(a.id)); // id 是毫秒时间戳，新→旧
    presets = list;
    notifyListeners();
  }

  /// 保存当前整套视觉配置为新方案：截取缩略图 + 写配置 json。
  /// 返回新方案 id；截图或写盘失败返回 null。
  Future<String?> saveCurrent({required String name}) async {
    final cfg = AppConfig.instance;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final dir = await _dir();
    final png = await _capture();
    final data = <String, dynamic>{
      'id': id,
      'name': name,
      'theme_index': cfg.themeIndex,
      'wallpaper_path': cfg.wallpaperPath,
      'wallpaper_opacity': cfg.wallpaperOpacity,
      'font_scale': cfg.fontScale,
      // 歌词独立字号：null = 跟随主题字号（老方案文件没这个键，恢复时同样回落到跟随）
      'lyric_font_scale': cfg.lyricFontScale,
      'font_family': cfg.fontFamily,
      'font_path': cfg.fontPath,
      'heart_enabled': cfg.heartEnabled,
      'visual_effect': cfg.visualEffect,
      // 视觉图层表（同一特效叠了几层、各是哪层）：不存的话恢复方案只换回一个特效，
      // 「三颗牵手爱心」这种配置就丢了。老方案文件没这个键 → 恢复时走旧的单选字段。
      'visual_layers': [for (final l in cfg.visualLayers) l.toJson()],
      'rain_enabled': cfg.rainEnabled,
      'ambient_effect': cfg.ambientEffect,
      'spectrum_enabled': cfg.spectrumEnabled,
      'rhythm_effect': cfg.rhythmEffect,
      'edge_enabled': cfg.edgeEnabled,
      'edge_effect': cfg.edgeEffect,
      // 每个特效的专属参数（数量/速度/大小…）：整套一起存，恢复时整套覆盖。
      // 老方案文件没这个键 → 恢复时保留当前参数不动。
      'fx_params': cfg.fxParams,
      // 调色板快照：`fx_params` 里的 `*.tint` 存的是**稳定槽位**，而自定义主题色
      // 增删会让槽位漂移（删中间一个后面全体前移、新建的复用空号）。存下当时的
      // 调色板，恢复时才能校验每个槽位还是不是原来那套色（见 apply）。
      'custom_themes': cfg.customThemes.map(accentSchemeToJson).toList(),
      'hidden_default_themes': cfg.hiddenDefaultThemes.toList(),
    };
    // 也把壁纸复制一份进方案目录（否则删除壁纸后方案恢复找不到）。
    // 这样换壁纸/删壁纸后，应用旧方案仍能找回当时的壁纸。
    final srcWp = cfg.wallpaperPath;
    if (srcWp != null && srcWp.isNotEmpty && File(srcWp).existsSync()) {
      try {
        final copy = '${dir.path}/$id.wall';
        await File(srcWp).copy(copy);
        data['wallpaper_copy'] = copy;
      } catch (_) {}
    }
    try {
      await File('${dir.path}/$id.json').writeAsString(jsonEncode(data));
      if (png != null) {
        await File('${dir.path}/$id.png').writeAsBytes(png);
      }
    } catch (_) {
      return null;
    }
    await refresh();
    return id;
  }

  /// 应用某套方案：把配置写回 AppConfig（覆盖当前视觉）。
  /// 若方案的壁纸已从「已上传壁纸」删除，会用方案内备份把它重新放回 wallpapers/，
  /// 让它回到「已上传壁纸」列表（可再点/长按管理、一键保存到相册）。
  /// 返回 true 表示壁纸是从方案备份里找回的；两边都没有则回默认背景。
  Future<bool> apply(String id) async {
    final dir = await _dir();
    final f = File('${dir.path}/$id.json');
    if (!await f.exists()) return false;
    final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    final cfg = AppConfig.instance;
    await cfg.setThemeIndex(_int(m, 'theme_index') ?? cfg.themeIndex);
    // 壁纸：优先仍在「已上传壁纸」列表的原图；原图被删则用方案内备份找回，
    // 并复制一份回 wallpapers/，让它重新出现在「已上传壁纸」、可再次保存到相册。
    final wp = m['wallpaper_path'] as String?;
    final wcopy = m['wallpaper_copy'] as String?;
    final wpExists = wp != null && wp.isNotEmpty && File(wp).existsSync();
    final wcopyExists =
        wcopy != null && wcopy.isNotEmpty && File(wcopy).existsSync();
    var restored = false;
    if (wpExists) {
      await cfg.setWallpaperPath(wp);
    } else if (wcopyExists) {
      final docs = await getApplicationDocumentsDirectory();
      final wpDir = Directory('${docs.path}/wallpapers');
      if (!wpDir.existsSync()) wpDir.createSync(recursive: true);
      final ext = _extOfPath(wp);
      final dest = '${wpDir.path}/wp_preset_$id.$ext';
      try {
        await File(wcopy).copy(dest); // 同名覆盖，重复应用同一方案不会堆积副本
        restored = true;
        await cfg.setWallpaperPath(dest);
      } catch (_) {
        // 复制失败则直接引用方案内备份（至少当前壁纸能显示）
        await cfg.setWallpaperPath(wcopy);
      }
    } else {
      await cfg.setWallpaperPath(null); // 壁纸没了 → 默认背景
    }
    await cfg.setWallpaperOpacity(
        _dbl(m, 'wallpaper_opacity') ?? cfg.wallpaperOpacity);
    await cfg.setFontScale(_dbl(m, 'font_scale') ?? cfg.fontScale);
    // 没有这个键（老方案）→ 传 null → 恢复成「跟随主题字号」
    await cfg.setLyricFontScale(_dbl(m, 'lyric_font_scale'));
    await cfg.setCustomFont(
        m['font_family'] as String? ?? '', m['font_path'] as String?);
    await cfg.setHeartEnabled(_bool(m, 'heart_enabled') ?? cfg.heartEnabled);
    // 视觉图层表：新方案整套覆盖；老方案（没有这个键）走旧的单选字段，
    // 把**当前选中的那一层**换成它 —— 老方案恢复出来的画面与改动前一致。
    if (!await cfg.applyVisualLayers(m['visual_layers'])) {
      await cfg.setVisualEffect(_int(m, 'visual_effect') ?? cfg.visualEffect);
    }
    await cfg.setRainEnabled(_bool(m, 'rain_enabled') ?? cfg.rainEnabled);
    await cfg.setAmbientEffect(_int(m, 'ambient_effect') ?? cfg.ambientEffect);
    await cfg.setSpectrumEnabled(
        _bool(m, 'spectrum_enabled') ?? cfg.spectrumEnabled);
    await cfg.setRhythmEffect(_int(m, 'rhythm_effect') ?? cfg.rhythmEffect);
    await cfg.setEdgeEnabled(_bool(m, 'edge_enabled') ?? cfg.edgeEnabled);
    await cfg.setEdgeEffect(_int(m, 'edge_effect') ?? cfg.edgeEffect);
    // 特效专属参数：整套覆盖；老方案（没有 fx_params 键）保持当前参数不动
    final rawFx = m['fx_params'];
    // 颜色槽位校验：`*.tint` 指向自定义色（槽位 ≥ kDefaultThemeCount）时，先和方案
    // 存下的调色板快照比一比 —— 删过/换过自定义色会让槽位漂到**另一套色**上，
    // 不校验就会静默串色（不越界，所以不会自动回落主题）。对不上就回落「跟随主题」：
    // 宁可不染色，也不给用户一个说不清来历的颜色。老方案没快照 → 不动，保持原行为。
    if (rawFx is Map) {
      final snap = (m['custom_themes'] as List?) ?? const [];
      final cur = AppConfig.instance.customThemes;
      for (final k in rawFx.keys.whereType<String>().toList()) {
        if (!k.endsWith('.tint')) continue;
        final v = rawFx[k];
        if (v is! num) continue;
        final slot = v.round() - kDefaultThemeCount;
        if (slot < 0) continue; // 跟随主题 / 内置主题色 / 氛围色调：槽位本身稳定
        if (snap.isEmpty) continue; // 老方案没带调色板快照：无从校验，保持原样
        final same = slot < snap.length &&
            slot < cur.length &&
            jsonEncode(snap[slot]) == jsonEncode(accentSchemeToJson(cur[slot]));
        if (!same) rawFx[k] = -1;
      }
    }
    await cfg.applyFxParams(rawFx is Map ? rawFx.cast<String, dynamic>() : null);
    return restored;
  }

  /// 批量删除方案（配置 json + 缩略图 + 壁纸备份一起删）。
  /// **.wall 必须一起删**：它是保存方案时复制的整套壁纸副本（单个可达数 MB），
  /// 老版本漏删它，方案删掉后文件永远留在目录里（纯垃圾）。
  Future<void> delete(Set<String> ids) async {
    final dir = await _dir();
    for (final id in ids) {
      for (final suffix in ['.json', '.png', '.wall']) {
        final f = File('${dir.path}/$id$suffix');
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    await refresh();
  }

  /// 截取「享受页」竖版缩略图：临时把壁纸切到享受页原图亮度，等一帧后从 shotKey 的
  /// RepaintBoundary 出图（只含壁纸+特效，不含播放栏），截完恢复原亮度。
  Future<Uint8List?> _capture() async {
    final cfg = AppConfig.instance;
    final was = cfg.enjoyActive.value;
    if (!was) cfg.enjoyActive.value = true; // 享受页：壁纸原图亮度
    try {
      await WidgetsBinding.instance.endOfFrame; // 等壁纸层按新亮度重绘完
      final boundary = shotKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) return null;
      final image = await boundary.toImage(pixelRatio: 1.0);
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return bytes?.buffer.asUint8List();
    } catch (_) {
      return null;
    } finally {
      cfg.enjoyActive.value = was;
    }
  }
}

/// 取 `.json` 文件名的 id 部分（`<id>.json` → `<id>`）。
String _stemOf(String path) {
  final name = path.split(Platform.pathSeparator).last;
  return name.substring(0, name.length - '.json'.length);
}

int? _int(Map<String, dynamic> m, String k) =>
    m[k] is int ? m[k] as int : null;
double? _dbl(Map<String, dynamic> m, String k) =>
    m[k] is num ? (m[k] as num).toDouble() : null;
bool? _bool(Map<String, dynamic> m, String k) =>
    m[k] is bool ? m[k] as bool : null;

/// 从（可能已删除的）原壁纸路径里取扩展名，用于给找回的壁纸命名；取不到用 jpg。
String _extOfPath(String? path) {
  if (path == null) return 'jpg';
  final dot = path.lastIndexOf('.');
  if (dot != -1 && path.length - dot <= 6) {
    final e = path.substring(dot + 1).toLowerCase();
    if (e.isNotEmpty && RegExp(r'^[a-z0-9]+$').hasMatch(e)) return e;
  }
  return 'jpg';
}
