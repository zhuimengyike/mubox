/// 歌曲图标裁剪页：正方形取景框，单指拖动平移、双指捏合缩放，导出 512 见方的图片字节。
///
/// 入参 = 相册选中的图片路径（image_picker 给的临时文件），出参 = `Navigator.pop`
/// 带回的 `Uint8List`（用户取消 / 直接返回是 null）。真正的存储由调用方走
/// `ArtworkStore.save(song, bytes)` —— 这一页不碰曲库。
///
/// 几何换算全在 `artwork_crop.dart`（纯函数、有单测）：取景框 ↔ 原图像素矩形、
/// 缩放上下限、边界夹紧。这一页只负责解码、画、收手势。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../artwork_crop.dart';
import '../theme.dart';
import '../widgets/wallpaper_layer.dart';

class ArtworkCropPage extends StatefulWidget {
  const ArtworkCropPage({super.key, required this.imagePath});

  /// 待裁剪的图片文件路径。
  final String imagePath;

  @override
  State<ArtworkCropPage> createState() => _ArtworkCropPageState();
}

class _ArtworkCropPageState extends State<ArtworkCropPage> {
  ui.Image? _image; // 已按 kArtworkMaxDecodeSide 缩过的原图（画与导出都用它）
  CropState? _crop;
  bool _failed = false; // 解码失败（格式不支持 / 文件被清了）
  bool _busy = false; // 正在导出，防连点

  // 手势起点快照（换手指时 Flutter 会重新触发 onScaleStart，正好重新锚定）
  double _startScale = 1;
  Offset _startOffset = Offset.zero;
  Offset _startFocal = Offset.zero;

  Size get _imageSize =>
      Size(_image!.width.toDouble(), _image!.height.toDouble());

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _image?.dispose(); // 2048 边长上限下这是十几 MB 的位图，别等 GC
    super.dispose();
  }

  /// 解码相册选中的图。
  ///
  /// 先让引擎只读文件头报出原始尺寸，据此算出「缩到多小」再解码 —— 相册里
  /// 4000x4000 的图整张解码出来是 64MB 位图，低端机上直接 OOM。目标是 512 的
  /// 输出，源留 [kArtworkMaxDecodeSide] 足够。
  /// 走 `PaintingBinding.instantiateImageCodecWithSize`：buffer 由它负责释放
  /// （手动 `ImmutableBuffer.dispose()` 二次释放会在 debug 下断言失败）。
  Future<void> _load() async {
    ui.Image? decoded;
    try {
      final bytes = await File(widget.imagePath).readAsBytes();
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec = await PaintingBinding.instance.instantiateImageCodecWithSize(
        buffer,
        // 只给长边设目标：另一边留 null 时引擎按原比例算（两个都设会把图拉变形）
        getTargetSize: (int w, int h) => w >= h
            ? ui.TargetImageSize(width: math.min(w, kArtworkMaxDecodeSide))
            : ui.TargetImageSize(height: math.min(h, kArtworkMaxDecodeSide)),
      );
      try {
        final frame = await codec.getNextFrame();
        decoded = frame.image;
      } finally {
        codec.dispose();
      }
    } catch (_) {
      decoded?.dispose();
      if (mounted) setState(() => _failed = true);
      return;
    }
    final image = decoded;
    if (!mounted) {
      image.dispose();
      return;
    }
    setState(() {
      _image = image;
      _crop = null; // 交给 build 按实际取景框尺寸建一次（见 _cropFor）
    });
  }

  /// 取景框边长确定后才能算「铺满缩放」，所以状态在这里懒建一次。
  /// 首帧/转屏时重建（转屏后取景框尺寸变了，旧的缩放不再成立）。
  /// 不在 build 里 setState：这个值本次 build 立刻要用，重建没有意义。
  CropState _cropFor(double side) {
    final c = _crop;
    if (c == null || c.viewSide != side || c.imageSize != _imageSize) {
      return _crop = CropState.initial(_imageSize, side);
    }
    return c;
  }

  void _onScaleStart(Offset focal) {
    final c = _crop;
    if (c == null) return;
    _startScale = c.scale;
    _startOffset = c.offset;
    _startFocal = focal;
  }

  void _onScaleUpdate(Offset focal, double scaleFactor) {
    final c = _crop;
    if (c == null) return;
    setState(() {
      _crop = c.applyGesture(
        startScale: _startScale,
        startOffset: _startOffset,
        startFocal: _startFocal,
        focal: focal,
        scaleFactor: scaleFactor,
      );
    });
  }

  void _onScaleEnd() {
    final c = _crop;
    if (c == null) return;
    // 拖动时每帧已经夹紧了，这里只兜一层底；刻意不做惯性滑动
    setState(() => _crop = c.clamped());
  }

  /// 把取景框区域重绘成 [kArtworkSide] 见方的字节，带回上一页。
  Future<void> _done() async {
    final image = _image;
    final crop = _crop;
    if (image == null || crop == null || _busy) return;
    setState(() => _busy = true);
    try {
      final bytes = await _exportSquare(image, crop);
      if (!mounted) return;
      if (bytes == null || bytes.isEmpty) {
        setState(() => _busy = false);
        _toast('生成图标失败，请重试');
        return;
      }
      Navigator.pop(context, bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() => _busy = false);
      _toast('生成图标失败：${e.toString().split('\n').first}');
    }
  }

  /// 取景框那块源区 → 512x512 位图 → PNG 字节。
  ///
  /// ⚠️ 存进封面缓存时文件名仍是 `.jpg`（既有命名规则不能动，否则已有的在线封面
  /// 全部失效），内容是 PNG —— `dart:ui` 只能编码 png/rawRgba，为它引
  /// `package:image` 不划算。**后缀名不参与解码**：Flutter 的 `Image` 与安卓通知栏
  /// 的 `BitmapFactory` 都按内容嗅探，所以安全。别改成按扩展名挑解码器。
  Future<Uint8List?> _exportSquare(ui.Image image, CropState crop) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawImageRect(
      image,
      crop.sourceRect,
      Rect.fromLTWH(
        0,
        0,
        kArtworkSide.toDouble(),
        kArtworkSide.toDouble(),
      ),
      Paint()
        ..filterQuality = FilterQuality.high
        ..isAntiAlias = true,
    );
    final picture = recorder.endRecording();
    try {
      final out = await picture.toImage(kArtworkSide, kArtworkSide);
      try {
        final data = await out.toByteData(format: ui.ImageByteFormat.png);
        if (data == null) return null;
        return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      } finally {
        out.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(milliseconds: 1800),
          behavior: SnackBarBehavior.floating,
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          const Positioned.fill(child: WallpaperLayer()),
          // 压暗背景：判断裁剪效果时，花哨的壁纸是干扰
          Positioned.fill(
            child: ColoredBox(color: Colors.black.withValues(alpha: 0.78)),
          ),
          SafeArea(
            child: Column(
              children: [
                _header(context),
                Expanded(child: _body()),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
                  child: Text(
                    _failed
                        ? '这张图读不出来，换一张试试'
                        : '单指拖动平移 · 双指捏合缩放',
                    style: const TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
            onPressed: _busy ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          const Spacer(),
          const Text(
            '设置歌曲图标',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const Spacer(),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: context.accent),
            onPressed: (_image == null || _busy) ? null : _done,
            child: _busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('完成'),
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_failed) {
      return const Center(
        child: Icon(Icons.broken_image_outlined, size: 48, color: Colors.white24),
      );
    }
    if (_image == null) {
      return const Center(child: CircularProgressIndicator());
    }
    // 手势层铺满整块区域（不只是取景框内），焦点再换算到取景框坐标系：
    // 手指从压暗处按下去也能拖。
    return LayoutBuilder(
      builder: (context, c) {
        final side = math.max(
          60.0,
          math.min(c.maxWidth - 40, c.maxHeight - 24),
        );
        final origin = Offset((c.maxWidth - side) / 2, (c.maxHeight - side) / 2);
        final crop = _cropFor(side);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) => _onScaleStart(d.localFocalPoint - origin),
          onScaleUpdate: (d) =>
              _onScaleUpdate(d.localFocalPoint - origin, d.scale),
          onScaleEnd: (d) => _onScaleEnd(),
          child: CustomPaint(
            size: Size.infinite,
            painter: _CropPainter(
              image: _image!,
              crop: crop,
              view: origin & Size.square(side),
              frameColor: context.accent,
            ),
          ),
        );
      },
    );
  }
}

/// 画「原图 + 取景框外压暗 + 取景框边框」。
///
/// 不裁剪图片本身：框外留着可见（压暗）比直接切掉更好瞄 —— 用户能看出自己在
/// 整张图的哪个位置。真正切掉的是导出那一步（`drawImageRect` 只取 sourceRect）。
class _CropPainter extends CustomPainter {
  const _CropPainter({
    required this.image,
    required this.crop,
    required this.view,
    required this.frameColor,
  });

  final ui.Image image;
  final CropState crop;
  final Rect view;
  final Color frameColor;

  @override
  void paint(Canvas canvas, Size size) {
    // 原图按 crop 的缩放/偏移落到取景框坐标系里（偏移原点是取景框左上角）
    final dst = Rect.fromLTWH(
      view.left + crop.offset.dx,
      view.top + crop.offset.dy,
      image.width * crop.scale,
      image.height * crop.scale,
    );
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      dst,
      Paint()
        ..filterQuality = FilterQuality.medium
        ..isAntiAlias = true,
    );
    // 框外压暗：整块区域减掉取景框，一次画完
    final mask = Path.combine(
      PathOperation.difference,
      Path()..addRect(Offset.zero & size),
      Path()..addRect(view),
    );
    canvas.drawPath(mask, Paint()..color = Colors.black.withValues(alpha: 0.6));
    canvas.drawRect(
      view,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = frameColor.withValues(alpha: 0.9),
    );
  }

  // 状态是不可变对象、手势每帧换一个新实例，所以比较实例就够（不做回弹/惯性，
  // 没有任何「帧间相同却需要重画」的情况）。
  @override
  bool shouldRepaint(_CropPainter old) =>
      old.image != image ||
      old.crop != crop ||
      old.view != view ||
      old.frameColor != frameColor;
}
