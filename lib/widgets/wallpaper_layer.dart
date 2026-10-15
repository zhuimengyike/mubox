/// 全局背景层：深色底 + 半透明壁纸（原图高清显示，不缩放画质）。
library;

import 'dart:io';

import 'package:flutter/material.dart';

import '../app_config.dart';
import '../spectrum_engine.dart';
import '../theme.dart';

class WallpaperLayer extends StatelessWidget {
  const WallpaperLayer({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([AppConfig.instance, AppConfig.instance.enjoyActive]),
      builder: (context, _) {
        final config = AppConfig.instance;
        final primary = context.accent;
        final p = config.wallpaperPath;
        final hasImage = p != null && File(p).existsSync();
        // 享受页（纯视觉欣赏页）用原图亮度显示壁纸，其余页面用可调透明度。
        final bright = config.enjoyActive.value ? 1.0 : config.wallpaperOpacity;
        // 享受页保持原图纯净，其余页面叠主题色光晕，给深色底一个"色彩重心"。
        final glowAlpha = config.enjoyActive.value ? 0.0 : 0.06;
        return Container(
          color: kBgColor,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 把整张壁纸大图包进 RepaintBoundary：它是一次性解码后基本不变的静态层，
              // 让背景氛围层每帧全屏重绘、以及播放时 bass 叠加层的重建，都只会把这张
              // 已缓存的纹理往上叠合成，而不会每帧把 2K 壁纸重新栅格化一遍。
              // 之前它和氛围层共用同一个外层 RepaintBoundary，氛围层一重绘就连带整张
              // 壁纸重画，导致「正常划拉都一卡一卡」。
              if (hasImage)
                RepaintBoundary(
                  child: Opacity(
                    opacity: bright,
                    child: Image.file(
                      File(p),
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.high,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),
                ),
              // 主题色光晕：从左上角漫开的柔光，让画面不再纯黑白灰
              _themeGlow(primary, glowAlpha),
              // 鼓点呼吸：bass 强时壁纸整体微微提亮，弱时回落（柔光叠加，不遮内容）。
              if (hasImage)
                ListenableBuilder(
                  listenable: SpectrumEngine.instance.bass,
                  builder: (context, _) {
                    final b = SpectrumEngine.instance.bass.value;
                    return IgnorePointer(
                      child: Container(
                        color: Colors.white.withValues(alpha: (b * 0.10).clamp(0.0, 0.10)),
                      ),
                    );
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  /// 主题色背景光晕：给深色底叠一层局部的主题色柔光，给画面一点色彩倾向。
  /// 重心放中下部、半径收小，只在中部泛开一小团，顶部与四周保持干净，
  /// 避免铺满全屏「感染」整页；用 TweenAnimationBuilder 平滑过渡消除切换闪烁。
  Widget _themeGlow(Color primary, double alpha) {
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: alpha),
      duration: const Duration(milliseconds: 300),
      builder: (context, a, _) {
        if (a <= 0.001) return const SizedBox.shrink();
        return IgnorePointer(
          child: Container(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: const Alignment(0.0, 0.3),
                radius: 0.85,
                colors: [
                  primary.withValues(alpha: a),
                  primary.withValues(alpha: a * 0.35),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
        );
      },
    );
  }
}
