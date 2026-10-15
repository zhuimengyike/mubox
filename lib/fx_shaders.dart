/// 片段着色器（GLSL / GPU 特效）集中管理：预加载 + 跨帧复用 + 失败静默回退。
///
/// 单独一个文件的原因：Skia 后端下着色器要在**运行时编译**，开销不小；官方文档
/// 明确建议「动画开始前预缓存 FragmentProgram」并且「跨帧复用同一个 FragmentShader
/// 实例，而不是每帧新建」。这里就负责这两件事。
///
/// 设计原则是**渐进增强**：加载失败 / 平台不支持时对应的 getter 返回 null，调用方
/// 自动退回原来的纯路径绘制实现 —— 特效不会消失、也不会崩。
///
/// 排查：日志统一用 `FxShaders:` 前缀（ASCII，release 下 logcat 可查；
/// 中文关键词在 logcat 里会被转义，过滤不到 —— 这个坑踩过一次）。
library;

import 'dart:ui';

import 'package:flutter/foundation.dart';

class FxShaders {
  FxShaders._();

  /// 着色器就绪（或确认不可用）时自增，画布据此重建一次，
  /// 让特效从「路径实现」切到「GPU 实现」。
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static FragmentShader? _aurora;
  static FragmentShader? _orb;
  static FragmentShader? _water;
  static bool _loading = false;
  static bool _loaded = false;

  /// 极光着色器；未就绪或不可用时为 null（调用方回退路径版）。
  static FragmentShader? get aurora => _aurora;

  /// 能量球着色器；未就绪或不可用时为 null（调用方回退路径版）。
  static FragmentShader? get orb => _orb;

  /// 水面焦散着色器；未就绪或不可用时为 null（调用方回退纯路径实现）。
  static FragmentShader? get water => _water;

  /// 启动后尽早调用一次：预编译并常驻，避免第一次切到该特效时卡一下。
  /// 幂等，可重复调用。
  static Future<void> preload() async {
    if (_loading || _loaded) return;
    _loading = true;
    try {
      _aurora = await _load('shaders/aurora.frag', 'aurora');
      _orb = await _load('shaders/orb.frag', 'orb');
      _water = await _load('shaders/water.frag', 'water');
    } finally {
      _loading = false;
      _loaded = true;
      revision.value++;
    }
  }

  /// 加载单个着色器：失败只影响它自己（返回 null），不牵连其它特效。
  static Future<FragmentShader?> _load(String asset, String tag) async {
    try {
      final program = await FragmentProgram.fromAsset(asset);
      debugPrint('FxShaders: $tag program loaded OK');
      return program.fragmentShader();
    } catch (e) {
      debugPrint('FxShaders: $tag load FAILED -> path fallback: $e');
      return null;
    }
  }
}
