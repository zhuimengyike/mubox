/// 首次启动权限引导页：引导开启「读取本地音乐」与「通知栏控制」权限。
library;

import 'package:flutter/material.dart';
// `PlatformException` / `MissingPluginException` 只从这里导出（`material.dart`
// 不 re-export 它们）—— `_grant()` 里那三处 `on … catch` 用得到。
import 'package:flutter/services.dart';
import 'package:on_audio_query/on_audio_query.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_config.dart';
import '../theme.dart';
import '../widgets/glass_panel.dart';

class PermissionIntroPage extends StatefulWidget {
  const PermissionIntroPage({super.key});

  @override
  State<PermissionIntroPage> createState() => _PermissionIntroPageState();
}

class _PermissionIntroPageState extends State<PermissionIntroPage> {
  bool _busy = false;
  bool _attempted = false; // 是否点过授权（决定是否显示「去系统设置」）
  bool _mediaGranted = false;
  bool _notifGranted = false;
  bool _recordGranted = false;

  /// 逐个请求必要权限；音乐库权限拿到后即进入主界面，通知为可选推荐。
  ///
  /// ⚠️ **三处都必须各自兜住平台异常**，这是**首启引导页** —— 抛出去就是
  /// 「卡在引导页进不去 App」，严重度高于别处的同类问题：
  /// 这三句都在 `_busy = true` **之后**、`setState(_busy = false)` **之前**，
  /// 任何一句抛了，下面那段 `setState` 就永远不执行 ⇒
  /// 按钮**永久停在「授权中…」且被禁用**（`onPressed: _busy ? null : _grant`），
  /// 用户点不动、退不出、也进不了主界面（`setOnboarded(true)` 在后面）。
  ///
  /// 收紧到 `PlatformException` / `MissingPluginException`（照
  /// `settings_page.dart` 的形状）：要吞的是【平台通道挂了】这种外部环境问题；
  /// `Error` 子类照旧冒出来 —— 那是我们自己的编程错误，别藏。
  ///
  /// ⚠️ 与 `custom_page.dart` 那两处**刻意宽兜底**的区别：那里的兜底方向是
  /// 「少显示一条提示」（安全默许，收紧的代价是崩溃）；这里的方向是
  /// **「整页卡死、用户进不去 App」**，收紧的代价只是把编程错误暴露出来 ⇒ 该窄。
  Future<void> _grant() async {
    setState(() {
      _busy = true;
      _attempted = true;
    });
    var media = false;
    var notifGranted = false;
    var recordGranted = false;
    // 三处**各自**兜底：一处挂了不该拖死另外两处，也不该把整页卡住。
    try {
      media = await OnAudioQuery().permissionsRequest();
    } on PlatformException catch (e) {
      debugPrint('MuBox 首启引导：请求音乐库权限失败 $e');
    } on MissingPluginException catch (e) {
      debugPrint('MuBox 首启引导：请求音乐库权限失败（插件未就绪）$e');
    }
    try {
      notifGranted = (await Permission.notification.request()).isGranted;
    } on PlatformException catch (e) {
      debugPrint('MuBox 首启引导：请求通知权限失败 $e');
    } on MissingPluginException catch (e) {
      debugPrint('MuBox 首启引导：请求通知权限失败（插件未就绪）$e');
    }
    // 律动频谱（Visualizer）在 Android 12+ 需要录音权限才能读播放波形；
    // 不开也能正常听歌，只是播放栏的频谱/波形/环形等律动特效会读不到数据。
    try {
      recordGranted = (await Permission.microphone.request()).isGranted;
    } on PlatformException catch (e) {
      debugPrint('MuBox 首启引导：请求麦克风权限失败 $e');
    } on MissingPluginException catch (e) {
      debugPrint('MuBox 首启引导：请求麦克风权限失败（插件未就绪）$e');
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _mediaGranted = media;
      _notifGranted = notifGranted;
      _recordGranted = recordGranted;
    });
    if (media) {
      // 触发 MaterialApp 重建，home 从引导页切到主界面
      await AppConfig.instance.setOnboarded(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Scaffold(
      backgroundColor: kBgColor,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              const Icon(Icons.music_note, size: 64, color: Colors.white70),
              const SizedBox(height: 16),
              const Text('欢迎使用 Mu Box',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.white)),
              const SizedBox(height: 8),
              const Text('首次使用需要开启几个权限，才能扫描本地音乐、在通知栏控制播放',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.white54)),
              const SizedBox(height: 28),
              _permItem(context, Icons.library_music_outlined, '读取本地音乐（必需）',
                  '扫描手机里的歌曲，建立你的音乐库', _mediaGranted, primary),
              const SizedBox(height: 12),
              _permItem(context, Icons.notifications_outlined, '通知栏控制（可选）',
                  '在锁屏/通知栏显示播放卡片方便切歌；不开也能正常听歌', _notifGranted, primary),
              const SizedBox(height: 12),
              _permItem(context, Icons.graphic_eq, '律动频谱（可选）',
                  '播放栏随音乐跳动的频谱/波形等特效需要录音权限；不开则律动特效无数据', _recordGranted, primary),
              const Spacer(),
              if (_attempted && !_mediaGranted && !_busy)
                const Padding(
                  padding: EdgeInsets.only(bottom: 6),
                  child: Text('音乐权限未开启时无法扫描歌曲，请先授权',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: Colors.orangeAccent)),
                ),
              FilledButton.icon(
                icon: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.verified_user_outlined),
                label: Text(_busy ? '授权中…' : '开启权限'),
                onPressed: _busy ? null : _grant,
              ),
              if (_attempted && !_mediaGranted && !_busy)
                TextButton(
                  // ⚠️ 这里**也要兜住**：`openAppSettings()` 同样走原生通道，
                  // 抛出去就是未捕获异步异常 —— 而这是「去系统设置」**唯一的退路**，
                  // 用户点了没反应就彻底没路了。
                  onPressed: () async {
                    try {
                      await openAppSettings();
                    } on PlatformException catch (e) {
                      debugPrint('MuBox 首启引导：打开系统设置失败 $e');
                    } on MissingPluginException catch (e) {
                      debugPrint('MuBox 首启引导：打开系统设置失败（插件未就绪）$e');
                    }
                  },
                  child: const Text('去系统设置手动开启'),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// 单项权限：图标 + 标题说明 + 右侧勾/圈状态。
  Widget _permItem(BuildContext context, IconData icon, String title, String desc,
      bool granted, Color primary) {
    return SurfaceCard(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Row(
        children: [
          Icon(icon, color: primary, size: 26),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.white)),
                const SizedBox(height: 2),
                Text(desc, style: const TextStyle(fontSize: 11, color: Colors.white38)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Icon(
            granted ? Icons.check_circle : Icons.circle_outlined,
            color: granted ? primary : Colors.white24,
            size: 20,
          ),
        ],
      ),
    );
  }
}
