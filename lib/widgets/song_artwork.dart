/// 歌曲图标（1:1 圆角小图）：歌单列表项与底部播放栏共用的一块。
///
/// 只负责「这首歌有图标」那一种情况；没图标时**由调用方决定不渲染**
/// （列表项要保持原来的音符/律动/勾选圈三种表现，播放栏要保持不占位）。
library;

import 'package:flutter/material.dart';

import '../artwork.dart';
import '../models.dart';

class SongArtwork extends StatelessWidget {
  const SongArtwork({
    super.key,
    required this.song,
    required this.size,
    this.radius = 8,
    this.ringColor,
    this.ringWidth = 2,
  });

  final Song song;

  /// 逻辑像素边长（正方形）。
  final double size;

  /// 圆角（与项目其它小卡片一致）。
  final double radius;

  /// 正在播放时的描边色（null = 不描边）。
  final Color? ringColor;

  final double ringWidth;

  @override
  Widget build(BuildContext context) {
    final file = ArtworkStore.fileFor(song);
    // 调进来时上层已经问过 has()，这里只是兜底：真没有就什么都不画
    if (file == null) return const SizedBox.shrink();
    // 按屏幕像素密度换算解码尺寸：列表可能有几百行，按原图解码会直接把内存打满
    final px = (size * MediaQuery.devicePixelRatioOf(context)).round();
    final ring = ringColor;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(radius),
            child: Image.file(
              file,
              // ⚠️ key 里必须带 revision：换图标时**文件路径没变**，而 FileImage 的
              // 相等性只看路径，Flutter 会认定 provider 没变、不重新解码，屏幕上会一直
              // 挂着旧图。换 key = 换 Element = 重新解析一次（配合 ArtworkStore 里的
              // evict，两件事缺一不可）。
              key: ValueKey('art-${song.id}-${ArtworkStore.revision.value}'),
              width: size,
              height: size,
              fit: BoxFit.cover,
              cacheWidth: px,
              cacheHeight: px,
              gaplessPlayback: true,
              // 文件坏了/被清了：安静地不画，别甩一块红色报错方块到列表里
              errorBuilder: (context, error, stack) => const SizedBox.shrink(),
            ),
          ),
          // 正在播放：在图片外圈补一道主题色描边（原来那三种 leading 表现里的
          // 「播放指示」不丢）。画在图片之上、占的还是同一块 size×size 的盒子，
          // 所以列表项与播放栏的布局不会因为这个描边变胖。
          if (ring != null)
            IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(radius),
                  border: Border.all(color: ring, width: ringWidth),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
