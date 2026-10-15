/// 歌曲图标裁剪的纯几何单测：`lib/artwork_crop.dart`。
///
/// 这组用例存在的理由：拖拽与缩放的边界（图不能露底、缩放上下限、导出区域不能
/// 越出原图）在真机上要靠手指一格格试，而错法的后果是「导出的图标带黑边」
/// 或者「拖到边上画面突然一跳」。全是纯换算，直接跑。
library;

import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:mu_box_phone/artwork_crop.dart';

void main() {
  const view = 300.0; // 取景框边长（逻辑像素）
  const landscape = Size(4000, 3000); // 横图
  const portrait = Size(1200, 4000); // 竖图
  const square = Size(1500, 1500); // 方图

  group('铺满缩放', () {
    test('横图按短边（高）铺满', () {
      expect(cropCoverScale(landscape, view), closeTo(view / 3000, 1e-12));
    });

    test('竖图按短边（宽）铺满', () {
      expect(cropCoverScale(portrait, view), closeTo(view / 1200, 1e-12));
    });

    test('方图两边同倍率', () {
      final s = cropCoverScale(square, view);
      expect(s, closeTo(view / 1500, 1e-12));
      expect(square.width * s, closeTo(view, 1e-9));
      expect(square.height * s, closeTo(view, 1e-9));
    });

    test('退化输入不产生 0 / Infinity / NaN', () {
      for (final s in [
        cropCoverScale(Size.zero, view),
        cropCoverScale(landscape, 0),
        cropCoverScale(const Size(double.infinity, 10), view),
      ]) {
        expect(s.isFinite, isTrue);
        expect(s, greaterThan(0));
      }
    });
  });

  group('初始状态', () {
    test('横图居中：取景框正对图片中心', () {
      final st = CropState.initial(landscape, view);
      expect(st.sourceRect.center.dx, closeTo(2000, 1e-9));
      expect(st.sourceRect.center.dy, closeTo(1500, 1e-9));
    });

    test('铺满那一刻：短边方向正好等于整张图（不多不少）', () {
      final st = CropState.initial(landscape, view);
      expect(st.sourceRect.height, closeTo(3000, 1e-9)); // 高 = 整张
      expect(st.sourceRect.width, closeTo(3000, 1e-9)); // 正方形取景
      expect(st.scale, closeTo(st.minScale, 1e-12));
    });

    test('竖图铺满时取景框覆盖整个宽度', () {
      final st = CropState.initial(portrait, view);
      expect(st.sourceRect.left, closeTo(0, 1e-9));
      expect(st.sourceRect.right, closeTo(1200, 1e-9));
    });
  });

  group('单指拖动', () {
    test('未触边界时逐像素跟手', () {
      final st = CropState.initial(landscape, view);
      final moved = st.applyGesture(
        startScale: st.scale,
        startOffset: st.offset,
        startFocal: const Offset(100, 150),
        focal: const Offset(130, 150),
        scaleFactor: 1,
      );
      expect(moved.scale, closeTo(st.scale, 1e-12));
      expect(moved.offset.dx, closeTo(st.offset.dx + 30, 1e-9));
      expect(moved.offset.dy, closeTo(st.offset.dy, 1e-9));
    });

    test('拖到右边界就停住，不露白底', () {
      final st = CropState.initial(landscape, view);
      final moved = st.applyGesture(
        startScale: st.scale,
        startOffset: st.offset,
        startFocal: const Offset(10, 150),
        focal: const Offset(9999, 150),
        scaleFactor: 1,
      );
      expect(moved.offset.dx, closeTo(0, 1e-9));
      expect(moved.sourceRect.left, closeTo(0, 1e-9));
    });

    test('拖到左边界：看到的是图片最右边', () {
      final st = CropState.initial(landscape, view);
      final moved = st.applyGesture(
        startScale: st.scale,
        startOffset: st.offset,
        startFocal: const Offset(290, 150),
        focal: const Offset(-9999, 150),
        scaleFactor: 1,
      );
      expect(moved.sourceRect.right, closeTo(landscape.width, 1e-9));
    });

    test('竖图上下拖到边界', () {
      final st = CropState.initial(portrait, view);
      final top = st.applyGesture(
        startScale: st.scale,
        startOffset: st.offset,
        startFocal: const Offset(150, 10),
        focal: const Offset(150, 9999),
        scaleFactor: 1,
      );
      expect(top.sourceRect.top, closeTo(0, 1e-9));
      final bottom = st.applyGesture(
        startScale: st.scale,
        startOffset: st.offset,
        startFocal: const Offset(150, 290),
        focal: const Offset(150, -9999),
        scaleFactor: 1,
      );
      expect(bottom.sourceRect.bottom, closeTo(portrait.height, 1e-9));
    });
  });

  group('双指缩放', () {
    test('焦点下的原图点钉在原地', () {
      final st = CropState.initial(landscape, view);
      const focal = Offset(view / 2, view / 2);
      final before = st.sourceRect.center;
      final zoomed = st.applyGesture(
        startScale: st.scale,
        startOffset: st.offset,
        startFocal: focal,
        focal: focal,
        scaleFactor: 2,
      );
      expect(zoomed.scale, closeTo(st.scale * 2, 1e-12));
      expect(zoomed.sourceRect.center.dx, closeTo(before.dx, 1e-9));
      expect(zoomed.sourceRect.center.dy, closeTo(before.dy, 1e-9));
      expect(zoomed.sourceRect.width, closeTo(1500, 1e-9)); // 源区边长减半
    });

    test('缩小到铺满就停住（不会露出取景框外的空白）', () {
      final st = CropState.initial(landscape, view);
      final out = st.applyGesture(
        startScale: st.scale,
        startOffset: st.offset,
        startFocal: const Offset(150, 150),
        focal: const Offset(150, 150),
        scaleFactor: 0.05,
      );
      expect(out.scale, closeTo(st.minScale, 1e-12));
      expect(out.sourceRect.width, closeTo(3000, 1e-9));
    });

    test('放大到上限就停住', () {
      final st = CropState.initial(landscape, view);
      final out = st.applyGesture(
        startScale: st.scale,
        startOffset: st.offset,
        startFocal: const Offset(150, 150),
        focal: const Offset(150, 150),
        scaleFactor: 1000,
      );
      expect(out.scale, closeTo(st.minScale * kArtworkMaxZoom, 1e-9));
      expect(out.maxScale / out.minScale, closeTo(kArtworkMaxZoom, 1e-12));
    });

    test('startScale 为 0（异常快照）不会算出 NaN/Infinity', () {
      final st = CropState.initial(landscape, view);
      final out = st.applyGesture(
        startScale: 0,
        startOffset: Offset.zero,
        startFocal: const Offset(150, 150),
        focal: const Offset(150, 150),
        scaleFactor: 2,
      );
      expect(out.scale.isFinite, isTrue);
      expect(out.offset.dx.isFinite, isTrue);
      expect(out.offset.dy.isFinite, isTrue);
    });
  });

  group('松手兜底', () {
    test('已经夹紧的状态再夹一次不变（可重复调用）', () {
      final st = CropState.initial(portrait, view);
      final a = st.clamped();
      final b = a.clamped();
      expect(a.scale, closeTo(b.scale, 1e-12));
      expect(a.offset.dx, closeTo(b.offset.dx, 1e-12));
      expect(a.offset.dy, closeTo(b.offset.dy, 1e-12));
    });
  });

  group('导出区域（drawImageRect 的 src）', () {
    test('永远是正方形', () {
      final st = CropState.initial(landscape, view);
      expect(st.sourceRect.width, closeTo(st.sourceRect.height, 1e-12));
    });

    test('右下钳制的单轴也给居中值', () {
      expect(cropClampAxis(-5, 100, 300), closeTo(100, 1e-9));
      expect(cropClampAxis(500, 100, 300), closeTo(100, 1e-9));
    });

    test('随机手势 800 次：源区永不越出原图、图永远盖住取景框', () {
      final rnd = math.Random(20260923);
      for (final img in [landscape, portrait, square, const Size(2048, 1536)]) {
        var st = CropState.initial(img, view);
        for (var i = 0; i < 200; i++) {
          st = st.applyGesture(
            startScale: st.scale,
            startOffset: st.offset,
            startFocal: Offset(
              rnd.nextDouble() * view,
              rnd.nextDouble() * view,
            ),
            focal: Offset(rnd.nextDouble() * view, rnd.nextDouble() * view),
            scaleFactor: 0.2 + rnd.nextDouble() * 12, // 含越界的倍率
          );
          final r = st.sourceRect;
          expect(r.left, greaterThanOrEqualTo(-1e-6), reason: '$img 第 $i 次');
          expect(r.top, greaterThanOrEqualTo(-1e-6), reason: '$img 第 $i 次');
          expect(
            r.right,
            lessThanOrEqualTo(img.width + 1e-6),
            reason: '$img 第 $i 次',
          );
          expect(
            r.bottom,
            lessThanOrEqualTo(img.height + 1e-6),
            reason: '$img 第 $i 次',
          );
          expect(r.width, closeTo(r.height, 1e-9), reason: '$img 第 $i 次');
          // 缩放夹紧 → 显示尺寸恒 ≥ 取景框（不露底）
          expect(
            img.width * st.scale,
            greaterThanOrEqualTo(view - 1e-6),
            reason: '$img 第 $i 次',
          );
          expect(
            img.height * st.scale,
            greaterThanOrEqualTo(view - 1e-6),
            reason: '$img 第 $i 次',
          );
          expect(st.scale, greaterThanOrEqualTo(st.minScale - 1e-9));
          expect(st.scale, lessThanOrEqualTo(st.maxScale + 1e-9));
          expect(st.offset.dx, lessThanOrEqualTo(1e-6));
          expect(st.offset.dy, lessThanOrEqualTo(1e-6));
        }
      }
    });
  });
}
