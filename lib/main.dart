/// Mu Box — 手机版本地音乐播放器。
///
/// 功能：扫描手机本地音乐、歌单管理、三种播放模式、进度控制、
/// 频谱动画、多套主题色、字体缩放、背景壁纸、通知栏媒体控制。
/// 纯本地播放，无联网。
library;

import 'dart:async';
import 'dart:io';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_config.dart';
import 'backup_service.dart';
import 'pages/permission_intro_page.dart';
import 'pages/root_page.dart';
import 'player_service.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 锁定竖屏：app 不随手机横置而旋转
  await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  await AudioService.init(
    builder: () {
      playerService = PlayerService();
      return playerService!;
    },
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.mubox.mu_box_phone.channel.audio',
      androidNotificationChannelName: 'Mu Box 播放',
      androidNotificationOngoing: true,
      androidStopForegroundOnPause: true,
    ),
  );
  // 上次「恢复备份」若在写设置的中途被打断（进程被系统回收 / 断电），先把设置回滚回去。
  // 必须在 AppConfig.load() **之前** —— 否则读到的就是那份被清空 / 写了一半的 prefs。
  // 没有残留时它只做一次 exists 检查，正常启动的开销可以忽略（H7）。
  await BackupService.recoverInterruptedRestore();
  await AppConfig.load();
  // 恢复上次自定义字体（若已保存）——需在 runApp 前加载，theme 才能用上该字体；
  // 预解码壁纸进缓存，让壁纸背景与氛围特效同时出现，消除壁纸晚一帧的闪。
  // 两者都只读 AppConfig 已加载的数据、互不依赖，并行执行缩短启动等待。
  // 超时兜底：壁纸存的是原始字节（用户可能选了几十 MB 的大图），解码慢或文件损坏
  // 时不能把 runApp 永远挡在门外；超时后照常进入，Image.file 稍后自行解码。
  await Future.wait([
    _loadCustomFont(),
    _precacheWallpaper().timeout(const Duration(seconds: 3), onTimeout: () {}),
  ]);
  runApp(const MuBoxApp());
}

/// 恢复上次保存的自定义字体：读字体文件字节 → FontLoader 注册 → theme 用该 family。
Future<void> _loadCustomFont() async {
  final path = AppConfig.instance.fontPath;
  final family = AppConfig.instance.fontFamily;
  if (path == null || family.isEmpty) return;
  final f = File(path);
  if (!f.existsSync()) return;
  try {
    final bytes = await f.readAsBytes();
    final loader = FontLoader(family)
      ..addFont(Future.value(ByteData.view(bytes.buffer)));
    await loader.load();
  } catch (_) {
    // 字体文件损坏/被删：忽略，回退默认字体
  }
}

/// 预加载壁纸：resolve 一次并等待解码完成，之后 WallpaperLayer 直接命中缓存立即显示。
Future<void> _precacheWallpaper() async {
  final p = AppConfig.instance.wallpaperPath;
  if (p == null) return;
  final f = File(p);
  if (!f.existsSync()) return;
  final completer = Completer<void>();
  final stream = FileImage(f).resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener(
    (info, sync) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    },
    onError: (e, s) {
      stream.removeListener(listener);
      if (!completer.isCompleted) completer.complete();
    },
  );
  stream.addListener(listener);
  await completer.future;
}

class MuBoxApp extends StatelessWidget {
  const MuBoxApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 监听全局配置：主题色 / 字体变化时即时重建整个应用
    return ListenableBuilder(
      // 只跟随「需要重建整个 App」的配置（主题色/字体/字号/引导完成状态）。
      // 原先监听整个 AppConfig：拖动壁纸透明度、特效数量等连续参数时每帧都会
      // 重建 MaterialApp、重算 ThemeData 并触发主题补间，是整机最贵的一处重复构建。
      listenable: AppConfig.instance.rebuildRevision,
      builder: (context, _) => MaterialApp(
        title: 'Mu Box',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(AppConfig.instance),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(AppConfig.instance.fontScale),
          ),
          child: child!,
        ),
        home: AppConfig.instance.onboarded ? const RootPage() : const PermissionIntroPage(),
      ),
    );
  }
}
