/// 歌曲图标「正方形裁剪」的纯几何：取景框 ↔ 原图像素坐标的换算。
///
/// 刻意独立成一个文件、且**不碰 Widget/引擎**（只用 dart:ui 的 Size/Offset/Rect
/// 这几个值对象），于是这些边界条件——图不能露底、缩放上下限、导出区域不能越出
/// 原图——都能在 `test/artwork_crop_test.dart` 里逐条跑，不用真机拖手指去试。
/// 界面与导出在 `pages/artwork_crop_page.dart`。
library;

import 'dart:ui';

/// 导出图标的边长（像素）。
/// 列表缩略图 28 / 播放栏 42 / 锁屏通知大图都够用，再大只是白占空间。
const int kArtworkSide = 512;

/// 裁剪页里原图解码的最长边上限。
/// 相册里 4000x4000 的图整张解码出来是 64MB 位图，先缩到 2048（约 16MB）再画；
/// 目标是 512 的输出，2048 的源在 4 倍放大以内都不糊。
const int kArtworkMaxDecodeSide = 2048;

/// 最大放大倍数（相对「铺满」）。再往里放只剩马赛克，也给不出更多像素。
const double kArtworkMaxZoom = 6;

/// 让原图铺满正方形取景框的基础缩放：**短边**刚好等于取景框边长。
/// 缩放值 = 原图像素 → 取景框逻辑像素的倍率。
double cropCoverScale(Size imageSize, double viewSide) {
  final short = imageSize.width < imageSize.height
      ? imageSize.width
      : imageSize.height;
  // 退化输入（解不出尺寸 / 还没布局）：返回 1 而不是 0 或 Infinity，
  // 否则上层一除就出 NaN，画面上是整块空白。
  if (short <= 0 || viewSide <= 0 || !short.isFinite || !viewSide.isFinite) {
    return 1;
  }
  return viewSide / short;
}

/// 单轴夹取：显示长度 [disp] 盖住取景框 [view] 时，偏移落在 [view-disp, 0]。
double cropClampAxis(double v, double disp, double view) {
  final lo = view - disp;
  // disp < view（理论上到不了，scale 下限就是铺满）：居中留白，也不越界
  if (lo >= 0) return lo / 2;
  return v.clamp(lo, 0.0);
}

/// 把偏移夹回「原图始终盖住取景框」的范围。
/// 偏移 = 原图左上角在取景框坐标系里的位置，所以上界恒为 0、下界是负的溢出量。
Offset cropClampOffset(
  Offset offset,
  Size imageSize,
  double scale,
  double viewSide,
) {
  return Offset(
    cropClampAxis(offset.dx, imageSize.width * scale, viewSide),
    cropClampAxis(offset.dy, imageSize.height * scale, viewSide),
  );
}

/// 取景框里看到的那块原图区域（原图像素坐标）—— 导出时给 drawImageRect 的 src。
/// 取景框是正方形，所以这块源区也一定是正方形（导出图不被拉伸）。
Rect cropSourceRect(Offset offset, double scale, double viewSide) {
  final s = scale > 0 ? scale : 1.0;
  return Rect.fromLTWH(-offset.dx / s, -offset.dy / s, viewSide / s, viewSide / s);
}

/// 裁剪状态：原图按 [scale] 缩放后，左上角放在取景框坐标系的 [offset] 处。
///
/// 不可变；手势每帧产出一个新实例（见 [applyGesture]）。所有构造出来的实例
/// 都已经夹在合法范围内，所以「导出」那一步不需要再做任何边界判断。
class CropState {
  const CropState({
    required this.imageSize,
    required this.viewSide,
    required this.scale,
    required this.offset,
  });

  /// 初始状态：铺满 + 居中（横图看中间，不是看左上角）。
  factory CropState.initial(Size imageSize, double viewSide) {
    final scale = cropCoverScale(imageSize, viewSide);
    final centered = Offset(
      (viewSide - imageSize.width * scale) / 2,
      (viewSide - imageSize.height * scale) / 2,
    );
    return CropState(
      imageSize: imageSize,
      viewSide: viewSide,
      scale: scale,
      offset: cropClampOffset(centered, imageSize, scale, viewSide),
    );
  }

  /// 原图像素尺寸（已解码那张图的实际尺寸，解码时可能被缩过）。
  final Size imageSize;

  /// 取景框边长（逻辑像素，正方形）。
  final double viewSide;

  /// 缩放倍率：原图像素 → 取景框逻辑像素。
  final double scale;

  /// 原图左上角在取景框坐标系里的位置（取景框左上角为原点）。
  final Offset offset;

  /// 最小缩放 = 铺满（再小就露白底）。
  double get minScale => cropCoverScale(imageSize, viewSide);

  /// 最大缩放。
  double get maxScale => minScale * kArtworkMaxZoom;

  /// 取景框里看到的原图区域（导出用 src）。
  Rect get sourceRect => cropSourceRect(offset, scale, viewSide);

  /// 一次手势位移/捏合的结果。
  ///
  /// [startFocal]/[startOffset]/[startScale] 是手势开始（或换手指重新锚定）那一刻的
  /// 快照，[focal] 是当前焦点，[scaleFactor] 是**相对手势起点**的累计倍率
  /// （单指拖动时恒为 1）。
  ///
  /// 焦点下的那个原图像素在缩放前后钉在原地——单指平移能逐像素跟手也是这条的
  /// 推论：倍率不变时它化简成「偏移 += 手指位移」。
  CropState applyGesture({
    required double startScale,
    required Offset startOffset,
    required Offset startFocal,
    required Offset focal,
    required double scaleFactor,
  }) {
    final ss = startScale > 0 ? startScale : minScale;
    final bounded = (ss * scaleFactor).clamp(minScale, maxScale);
    final anchor = (startFocal - startOffset) / ss; // 焦点下的原图像素
    return CropState(
      imageSize: imageSize,
      viewSide: viewSide,
      scale: bounded,
      offset: cropClampOffset(
        focal - anchor * bounded,
        imageSize,
        bounded,
        viewSide,
      ),
    );
  }

  /// 再夹一次（松手时兜底）。
  ///
  /// 拖动过程中每帧就已经夹紧了，所以松手时通常什么都不变——**刻意不做回弹动画、
  /// 也不做惯性滑动**：图片永远不会离开取景框，也就没有「弹回来」这回事。
  CropState clamped() {
    final s = scale.clamp(minScale, maxScale);
    return CropState(
      imageSize: imageSize,
      viewSide: viewSide,
      scale: s,
      offset: cropClampOffset(offset, imageSize, s, viewSide),
    );
  }
}
