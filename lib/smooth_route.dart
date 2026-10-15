/// 顺滑页面过渡：淡入 + 底部轻微上滑，进入/退出都走柔和曲线。
/// 用于「下载歌曲 / 视觉方案 / 私密区域」等隐藏页，替换生硬的默认转场。
library;

import 'package:flutter/material.dart';

Route<T> smoothPageRoute<T>(Widget page, {bool opaque = true}) {
  return PageRouteBuilder<T>(
    opaque: opaque,
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 240),
    pageBuilder: (context, animation, secondaryAnimation) => page,
    transitionsBuilder: (context, animation, secondaryAnimation, child) {
      // 用 drive(CurveTween) 代替每次 build 新建的 CurvedAnimation：后者是需要
      // 手动 dispose 的 Animation 对象（Flutter 3.24+ 会报泄漏），drive 返回轻量
      // 派生且行为一致（退出改用同一缓动的反向，240ms 内肉眼无差）。
      final curved = CurveTween(curve: Curves.easeOutCubic);
      return FadeTransition(
        opacity: animation.drive(curved),
        child: SlideTransition(
          position: animation.drive(
            Tween<Offset>(begin: const Offset(0, 0.04), end: Offset.zero)
                .chain(curved),
          ),
          child: child,
        ),
      );
    },
  );
}
