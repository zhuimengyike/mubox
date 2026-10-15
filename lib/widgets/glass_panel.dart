/// 通用毛玻璃面板：半透明白 + 背景模糊，与播放队列浮层同款质感。
/// 所有弹层（底部弹层 / 对话框）都套这个，避免黑底突兀。
library;

import 'dart:ui';

import 'package:flutter/material.dart';

class GlassPanel extends StatelessWidget {
  const GlassPanel({
    super.key,
    required this.child,
    this.borderRadius,
    this.blur = 20,
    this.padding,
  });

  final Widget child;
  final BorderRadius? borderRadius;
  final double blur;
  final EdgeInsetsGeometry? padding;

  @override
  Widget build(BuildContext context) {
    final r = borderRadius ?? BorderRadius.circular(16);
    // 阴影放在 ClipRRect 外层：ClipRRect 会裁掉阴影，放外层才能让玻璃"浮"起来。
    return Container(
      decoration: BoxDecoration(
        borderRadius: r,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.16),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
          child: Container(
            padding: padding,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.08),
              borderRadius: r,
              border: Border.all(color: Colors.white12),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// 轻量卡片：半透明白 + 圆角 + 边框，不模糊（比 GlassPanel 省性能、省电）。
/// 用于页面内容区块，让内容浮在背景（壁纸/氛围层）之上，形成清晰的层次。
class SurfaceCard extends StatelessWidget {
  const SurfaceCard({
    super.key,
    required this.child,
    this.padding,
    this.radius = 14,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    // 内容卡片不加阴影：列表里密集排列时阴影会堆成灰斑，显"脏"。
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: Container(
        padding: padding,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: Colors.white12),
        ),
        child: child,
      ),
    );
  }
}
