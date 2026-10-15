/// 右页：设置（字体大小 / 主题色 / 动效开关 / 音乐库）。
library;

import 'dart:io';

import 'package:flutter/material.dart';
// `PlatformException` / `MissingPluginException` 只从这里导出（`material.dart`
// 不 re-export 它们）—— 下面两处 `on … catch` 用得到。
import 'package:flutter/services.dart';

import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../app_config.dart';
import '../backup_service.dart';
import '../diagnostic_pack.dart';
import '../export_plan.dart';
import '../export_service.dart';
import '../library_data.dart';
import '../player_service.dart';
import '../smooth_route.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets/custom_color_sheet.dart';
import '../widgets/font_picker_sheet.dart';
import '../widgets/glass_panel.dart';
import '../widgets/row_turn_scroll.dart';
import 'equalizer_page.dart';
import 'private_area_page.dart';
import 'sound_effects_page.dart';
import 'visual_scheme_page.dart';

/// 字体档位（倍数）
const List<double> kFontScales = [0.9, 1.0, 1.15, 1.3];
const List<String> kFontLabels = ['小', '标准', '大', '特大'];

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _themeExpanded = false; // 主题色区块：默认收起
  bool _musicExpanded = false; // 音乐区块（库存/音效/导出/搜索）：默认收起
  bool _dataExpanded = false; // 数据区块（视觉方案/备份）：默认收起
  bool _batteryOptimized = false; // 是否已允许忽略电池优化
  bool _backingUp = false; // 数据备份进行中
  bool _restoring = false; // 数据恢复进行中
  bool _exporting = false; // 导出歌曲进行中
  int _exportToken = 0; // 导出任务令牌：自增即让正在跑的循环退出（「取消」按钮用，与备份打包同一套）
  final CancelToken _backupCancel = CancelToken(); // 备份打包的取消标志（传给 createBackup）
  bool _diagnosing = false; // 导出诊断包进行中
  int _exported = 0; // 已处理数（进度用：写进去的和「已是最新」跳过的都算处理过）
  int _targetTotal = 0; // 本次导出总数
  // 三笔账（真写入 / 已是最新 / 失败）：末尾文案由它拼（`export_plan.dart`，纯逻辑）
  final ExportTally _exportTally = ExportTally();

  @override
  void initState() {
    super.initState();
    _checkBattery();
  }

  /// 查一次「忽略电池优化」授权状态。
  ///
  /// ⚠️ **必须兜住平台异常**：`permission_handler` 的查询要走原生通道，
  /// 通道不可用（插件没起来 / 平台不支持）时会抛
  /// `PlatformException` 或 `MissingPluginException`。这里是 `initState` 里
  /// fire-and-forget 调的，没人 await ⇒ 抛出去就是**未捕获异步异常**
  /// （用户看到的是「点了设置、什么都没发生」）。
  ///
  /// ⚠️ **刻意只吞这两类平台异常，不写 `catch (e)`**：`Error` 子类
  /// （`StateError` / `TypeError` / `NoSuchMethodError`…）是**我们自己的编程错误**，
  /// 吞掉等于把证据藏起来 —— 这个形状的亏吃过一次：一个
  /// `NoSuchMethodError` 被宽 catch 咽掉，**伪装成「0 漏出」的假绿**。
  /// 写法照 `lib/eq_engine.dart` 的 `_call`（那支才是本仓库更该扩散的写法）。
  ///
  /// 处置照 `pages/custom_page.dart` 的 `_checkMic`：**静默、不弹任何 UI**；
  /// 日志前缀用 ASCII `MuBox`（中文关键词在 logcat 里可能被转义过滤不到）。
  Future<void> _checkBattery() async {
    try {
      final st = await Permission.ignoreBatteryOptimizations.status;
      if (mounted) setState(() => _batteryOptimized = st.isGranted);
    } on PlatformException catch (e) {
      debugPrint('MuBox 后台播放：查电池优化状态失败 $e');
    } on MissingPluginException catch (e) {
      debugPrint('MuBox 后台播放：查电池优化状态失败（插件未就绪）$e');
    }
  }

  /// 导出诊断包：一份给**用户自己**排查用的 zip（曲库索引 + 设置 + info.txt）。
  ///
  /// ⚠️ 曲库索引那份过私密过滤（与备份线同一个闸门：`sanitizeBackupPrefs` +
  /// `Store.decodeSongs/encodeSongs`）；`prefs.json` 是给用户自己看的**全量**设置
  /// —— UI 上必须写明「可能含私密歌信息，只给自己看」（见下面那颗按钮的说明）。
  Future<void> _exportDiagnostic() async {
    if (_diagnosing) return;
    setState(() => _diagnosing = true);
    try {
      final docs = await getApplicationDocumentsDirectory();
      final sp = await SharedPreferences.getInstance();
      // 诊断包里那份设置与备份包里那份**同一个口径**（不过滤、同一条读 key 的路），
      // 于是「诊断包里看到的 = 备份里带的」，不会两处描述打架。
      final prefs = BackupService.readPrefsRaw(sp);
      // 曲库索引走**和备份同一条闸门**：诊断包要的是真东西（用户自己排查），
      // 但私密歌的**记录**不该以明文出门 —— 拿到 zip 的人能数出有几首私密歌、
      // 叫什么名字（判定与 `backup_service._addSongsJson` 完全同一套）。
      final marks = BackupService.privateMarksFor(
        await Store.loadBackupSkipPrivate(),
      );
      final songsFile = File('${docs.path}/songs.json');
      var songsJson = '{}';
      var songsMissing = false;
      if (await songsFile.exists()) {
        songsJson = await BackupService.filteredSongsJson(
          await songsFile.readAsString(),
          marks,
        );
      } else {
        songsMissing = true; // 索引还没落盘（首次启动就导出）：如实写进 info
      }
      final musicDir = Directory('${docs.path}/music');
      var musicFiles = 0;
      if (await musicDir.exists()) {
        await for (final e in musicDir.list(followLinks: false)) {
          if (e is File) musicFiles++;
        }
      }
      final created = DateTime.now();
      final stamp = created.millisecondsSinceEpoch;
      final ver = parseAppVersion(Platform.resolvedExecutable);
      final info = buildDiagnosticInfo(
        appVersion: ver.version,
        buildNumber: ver.build,
        // ⚠️ 与文件名同一个时刻：分成两次取时钟（上面还有一串 await）会跨毫秒，
        //    于是 zip 里写的时间与文件名上的时间戳对不上。
        exportedAt: created,
        songCount: Library.instance.songs.length,
        musicFileCount: musicFiles,
      );
      final zip = await BackupService.writeZip(
        dir: await getTemporaryDirectory(),
        fileName: diagnosticZipName(stamp),
        files: buildDiagnosticFiles(
          songsJson: songsJson,
          prefsJson: encodeDiagnosticPrefs(prefs),
          infoText: info,
        ),
      );
      var cleanupNote = '';
      try {
        final saved = await BackupService.saveToDocuments(
          src: zip,
          name: diagnosticZipName(stamp),
        );
        if (mounted) {
          final head = songsMissing ? '（注意：曲库索引还没生成，包里没有 songs.json）' : '';
          cleanupNote = '$head${saveResultText(saved)}';
        }
      } finally {
        // 临时 zip 用完就删（**精确到这一个路径**）：`Documents/MuBox/` 里
        // 那份已经是独立副本，cache 里没有必要再留一份。
        // ⚠️ 删不掉要**并进同一句提示**（失败不许静默）：留着就是又一份看不见的僵尸。
        //    单独再弹一条会把上面那句「已保存到 …」顶掉，所以是拼接不是第二条。
        try {
          final f = File(zip);
          if (f.existsSync()) f.deleteSync();
        } catch (e) {
          if (cleanupNote.isNotEmpty) {
            cleanupNote = '$cleanupNote（App 内临时文件没删掉：$e）';
          }
        }
      }
      if (mounted && cleanupNote.isNotEmpty) _showSnack(cleanupNote);
    } catch (e) {
      if (mounted) _showSnack('导出诊断包失败：$e');
    } finally {
      if (mounted) setState(() => _diagnosing = false);
    }
  }

  /// 展示顺序的内置主题色槽位：可见的（未被隐藏的）默认色。
  List<int> _gridIndices() {
    final cfg = AppConfig.instance;
    final defaults = <int>[
      for (var i = 0; i < kDefaultThemeCount; i++)
        if (!cfg.hiddenDefaultThemes.contains(i)) i,
    ];
    if (_themeExpanded) return defaults;
    // 收起：最多 7 个 + 末尾展开按钮；若当前选中的内置色不在前 7，补到第 7 位
    if (defaults.length <= 7) return defaults;
    final sel = cfg.themeIndex;
    final shown = defaults.take(7).toList();
    if (sel < kDefaultThemeCount && !shown.contains(sel)) shown[6] = sel;
    return shown;
  }

  /// 稳定槽位 → 主题方案（内置或自定义）。
  AccentScheme _schemeAt(int idx) => idx < kDefaultThemeCount
      ? kAccentSchemes[idx]
      : AppConfig.instance.customThemes[idx - kDefaultThemeCount];

  /// 下拉进入私密区域（push 全屏页，返回后复位手势状态）。
  Future<void> _enterPrivateArea() async {
    await Navigator.push(
      context,
      smoothPageRoute(const PrivateAreaPage()),
    );
  }

  /// 数据备份：生成 zip → **先复制到公共 Documents/MuBox/** → 再调起系统分享。
  ///
  /// ⚠️ 顺序是刻意的：**先落公共目录**，保证「用户拿得出来」这件事必定发生
  /// （原先只弹分享面板，面板里只有「发给某个 App」、没有「保存到文件」，
  /// 用户实际拿不出备份）；分享是附加动作，失败也不该把已经保存好的那份说成没保存。
  ///
  /// 取消：`_backupCancel`（`createBackup` 在每个 zip 条目之间看一次）——
  /// 半成品 zip 与临时 `mubox_prefs.json` 都由这条路径清掉，**不留僵尸**。
  Future<void> _backupNow() async {
    if (_backingUp) return;
    _backupCancel.begin(); // 令牌换新（上一趟的取消状态作废）
    setState(() => _backingUp = true);
    var zipPath = '';
    var keepZip = false; // 分享面板可能还在用它 ⇒ 成功/取消都不删这一份
    var cleanupNote = ''; // 这次要弹给用户的那句话（删除失败时在 finally 里追加）
    try {
      zipPath = await BackupService.createBackup(cancel: _backupCancel);
      final saved = await BackupService.saveToDocuments(
        src: zipPath,
        name: zipPath.split(RegExp(r'[/\\]')).last,
      );
      // 保存成功先报路径（**人能看懂的路径**，原生不回路径、由 Dart 侧拼）
      cleanupNote = saveResultText(saved);
      if (mounted) _showSnack(cleanupNote);
      keepZip = true;
    } on CancellationException {
      cleanupNote = '已取消备份（未保存到 Documents）';
      if (mounted) _showSnack(cleanupNote);
    } catch (e) {
      // 失败要如实报错，⛔ 不许静默：`SAVE_DOC_FAILED` 也走这条
      // （最常见是覆写**别的 App 建的**同名条目被系统拒）
      cleanupNote = '备份失败：$e';
      if (mounted) _showSnack(cleanupNote);
    } finally {
      if (zipPath.isNotEmpty && !keepZip) {
        // 取消 / 失败：删掉半成品 zip（**精确到这一个路径**，不是通配删目录）。
        // ⚠️ 删不掉要**并进同一句提示**，⛔ 不许静默、也不许另弹一条把失败原因顶掉。
        try {
          final f = File(zipPath);
          if (f.existsSync()) f.deleteSync();
        } catch (e) {
          if (mounted) _showSnack('$cleanupNote（App 内临时文件也没删掉：$e）');
        }
      }
      if (mounted) setState(() => _backingUp = false);
    }
    if (!keepZip) return;
    // 分享放最后（保持既有行为，用户可能想发给别人）。
    // ⚠️ 分享抛错**不许**把上面已经成功的保存说成失败：备份文件还在、
    //    保存到 Documents 的那份也在，只是「发给别人」这一步没成。
    try {
      await SharePlus.instance.share(
        ShareParams(
          files: [XFile(zipPath)],
          text: 'Mu Box 数据备份（换机时用它恢复）',
        ),
      );
    } catch (e) {
      if (mounted) _showSnack('备份已保存，但分享没起来：$e');
    }
  }

  /// 取消正在进行的备份（打包循环下一轮即退出，半成品被删）。
  void _stopBackup() {
    _backupCancel.cancel();
  }

  /// 数据恢复：选 zip → 确认 → 恢复 → 提示。
  Future<void> _restoreNow() async {
    if (_restoring) return;
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['zip'],
    );
    if (files.isEmpty) return;
    final path = files.single.path;
    if (path == null) return;
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassPanel(
          borderRadius: BorderRadius.circular(20),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '确认恢复',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                '恢复将覆盖当前全部歌单、设置、壁纸、主题、歌词、封面与 App 内的音频副本。\n建议先备份当前数据再恢复。继续吗？',
                style: TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('恢复'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true) return;
    setState(() => _restoring = true);
    try {
      await BackupService.restoreFromZip(path);
      if (mounted) _showSnack('恢复完成');
    } catch (e) {
      if (mounted) _showSnack('恢复失败：$e');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context)
      ..removeCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg)));
  }

  /// 自定义睡眠定时：弹窗输入分钟数（如 20 / 90 / 120），确认后开始倒计时。
  Future<void> _openCustomSleepTimer() async {
    final ctrl = TextEditingController();
    final minutes = await showDialog<double>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义睡眠定时'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(hintText: '输入分钟数，如 20 / 90 / 120'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消', style: TextStyle(color: Colors.white70)),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, double.tryParse(ctrl.text)),
            child: const Text('开始'),
          ),
        ],
      ),
    );
    ctrl.dispose();
    if (minutes == null || minutes <= 0) {
      _showSnack('请输入大于 0 的分钟数');
      return;
    }
    if (minutes > 600) {
      _showSnack('睡眠定时最长 600 分钟');
      return;
    }
    playerService?.startSleepTimer(Duration(minutes: minutes.round()));
  }

  /// 刷新音乐库入口：权限被拒时扫描会静默失败（界面直接回到「共 0 首」），
  /// 原先没有任何提示，用户会以为刷新坏了，这里补一条可见反馈。
  Future<void> _refreshLibrary() async {
    final r = await Library.instance.refresh();
    if (!mounted) return;
    if (r.cancelled) {
      // 取消：如实报「已取消：完成 X/Y」，且明确说清「这次什么都没写进去」
      _showSnack('已取消：完成 ${r.completed}/${r.total} 首（已入库的照旧保留，本次未改动索引）');
    } else if (Library.instance.permDenied) {
      _showSnack('未获得音乐权限，请到系统设置里开启「音乐和音频」后重试');
    } else {
      _showSnack('音乐库已刷新，共 ${Library.instance.songs.length} 首');
    }
  }

  /// 取消正在进行的「刷新音乐库 / 扫描导入」（扫描循环下一轮即退出）。
  ///
  /// ⚠️ 只对**手动刷新**那条路生效（`refresh()` 是本页发起的）；
  /// 启动扫描 / 恢复备份那条路不看这个标志。
  void _stopRefreshLibrary() {
    libraryScanCancel.cancel();
    _showSnack('已请求停止扫描，正在收尾…');
  }

  /// 把 App 内所有歌曲复制一份到手机公共 Music/MuBox，方便拷电脑/手动管理。
  /// ⚠️ **私密歌不导出**：导出的目标是手机公共目录，谁都能看见 ——
  /// 直接用 `Library.songs` 会把私密歌一起拷出去（与备份线「默认忽略私密歌」的
  /// 约定相反）。这里走 `songsOf(kAllSongs)`，它按和歌单列表同一套规则过滤私密歌。
  ///
  /// 原生会先比对 size+sha256，**内容一致就原地不动**并回 `unchanged`
  /// ⇒ 这里必须分开数「真写入」与「已是最新」（`_exportTally`）。
  /// 一律 `_exported++` 的话，会报「已导出 40/40 首」而实际只写了 1 个。
  Future<void> _exportAll() async {
    if (_exporting) return;
    final all = Library.instance.songsOf(kAllSongs);
    final targets = all
        .where((s) => s.filePath.isNotEmpty && File(s.filePath).existsSync())
        .toList();
    if (targets.isEmpty) {
      _showSnack('没有可导出的歌曲');
      return;
    }
    final token = ++_exportToken; // 本次任务令牌：点「取消」后循环下一轮即退出
    setState(() {
      _exporting = true;
      _exported = 0;
      _targetTotal = targets.length;
      _exportTally.begin(targets.length);
    });
    for (final s in targets) {
      // 取消检查放在**每首之前**：被叫停的那一首一个字节都还没写，
      // 已经导出的照旧留在 Music/MuBox（那是完整文件，不是半成品）。
      if (!mounted || token != _exportToken) break;
      try {
        final r = await ExportService.exportSong(s);
        // ⚠️ 只有**真的写了**才算「导出」；`unchanged` 是「已是最新」，另记一笔。
        // 两笔账必须分开，否则又回到「N/N 其实只写了 1 个」那种对不上的文案。
        _exportTally.addResult(written: r.written);
      } catch (e) {
        _exportTally.addFailure(e);
      }
      _exported++; // 进度：写进去的和跳过的都算处理过
      if (mounted) setState(() {});
    }
    final cancelled = token != _exportToken;
    if (!mounted) return;
    if (cancelled) {
      // 取消：如实报「已取消：完成 X/Y」，计数取**实际处理过**的那笔账
      _showSnack('已取消：完成 ${_exportTally.done}/$_targetTotal 首');
    } else {
      _showSnack(exportSummary(_exportTally));
    }
    setState(() => _exporting = false);
  }

  /// 取消正在进行的「导出全部歌曲到手机」（令牌失效，循环下一轮退出）。
  void _stopExport() {
    _exportToken++;
    setState(() => _exporting = false);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListenableBuilder(
        listenable: Listenable.merge([
          AppConfig.instance,
          Library.instance,
          if (playerService != null) playerService!.changeNotifier,
        ]),
        builder: (context, _) {
          final config = AppConfig.instance;
          final indices = _gridIndices();
          // 「滑到底再上滑 → 翻到自定义页」三处共用同一套判定
          // （`lib/row_turn.dart` + `lib/widgets/row_turn_scroll.dart`，⛔ 别在这页再写一份）。
          // ★ 语义：**一次滑动只干一件事** —— 手指按下时已经在底部 ⇒
          // 这一次滑动才可能翻页；不在底部 ⇒ 这一次滑动只负责滚到底，拖多远都不翻，
          // 要翻得再滑一次。「累积溢出 > 50px 就翻」的旧判定会在往下滚、刚到底、手指还没抬
          // 时误翻页。
          // 私密区域仍由顶部「点击进入」触发（不用下拉手势，避免误触）。
          return RowTurnScroll(
            child: ListView(
              // 可滚动：内容超屏时能滑到底看到最后卡片
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 200),
              children: [
                const Text(
                  'Mu Box 手机版',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white38,
                    letterSpacing: 1.5,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '设置',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 24),
                // 顶部：点击进入私密区域（轻量入口，不做下拉手势避免误触）
                InkWell(
                  onTap: _enterPrivateArea,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        const Icon(Icons.lock_outline,
                            color: Colors.white38, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          '点击进入私密区域',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.6)),
                        ),
                        const Spacer(),
                        const Icon(Icons.chevron_right,
                            color: Colors.white38, size: 18),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                _sectionCard(
                  context,
                  '字体大小',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: SegmentedButton<double>(
                              segments: [
                                for (var i = 0; i < kFontScales.length; i++)
                                  ButtonSegment(
                                    value: kFontScales[i],
                                    label: Text(kFontLabels[i]),
                                  ),
                              ],
                              selected: {config.fontScale},
                              onSelectionChanged: (s) =>
                                  config.setFontScale(s.first),
                            ),
                          ),
                          const SizedBox(width: 8),
                          // 自定义字体：小按钮，放在字体大小后面
                          OutlinedButton(
                            style: OutlinedButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              foregroundColor: Colors.white70,
                              side: const BorderSide(color: Colors.white24),
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                            ),
                            onPressed: () => showFontPicker(context),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.text_fields, size: 15),
                                const SizedBox(width: 4),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(maxWidth: 88),
                                  child: Text(
                                    config.fontFamily.isEmpty
                                        ? '自定义'
                                        : (config.fontPath ?? '').split('/').last,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 11),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _sectionCard(
                  context,
                  '歌单布局',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 1, label: Text('长方形')),
                          ButtonSegment(value: 2, label: Text('2 列')),
                          ButtonSegment(value: 3, label: Text('3 列')),
                          ButtonSegment(value: 4, label: Text('4 列')),
                        ],
                        selected: {config.playlistColumns},
                        onSelectionChanged: (s) =>
                            config.setPlaylistColumns(s.first),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // 主题色：收起时一行 8 格（7 圆球 + 末尾展开按钮），展开时 8 列网格
                // + 下方「自定义主题色」区（新建/删除）与「一键恢复默认」按钮
                _sectionTitle(context, '主题色'),
                const SizedBox(height: 8),
                SurfaceCard(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      GridView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        gridDelegate:
                            const SliverGridDelegateWithFixedCrossAxisCount(
                              crossAxisCount: 8,
                              mainAxisSpacing: 10,
                              crossAxisSpacing: 10,
                            ),
                        itemCount: indices.length + (_themeExpanded ? 0 : 1),
                        itemBuilder: (context, i) {
                          // 收起时末尾格是展开按钮
                          if (!_themeExpanded && i == indices.length) {
                            return _expandDot();
                          }
                          return _colorDot(indices[i]);
                        },
                      ),
                      if (_themeExpanded) ...[
                        const SizedBox(height: 14),
                        const Divider(color: Colors.white12, height: 1),
                        const SizedBox(height: 12),
                        _buildCustomThemes(),
                        const SizedBox(height: 14),
                        _buildRestoreDefaultButton(),
                        const SizedBox(height: 14),
                        _collapseButton(
                          '收起主题色',
                          () => setState(() => _themeExpanded = false),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // 音乐区块：折叠/展开，内含「库存 / 音效 / 导出 / 搜索」四个子功能
                _sectionTitle(context, '音乐'),
                const SizedBox(height: 8),
                SurfaceCard(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InkWell(
                        onTap: () =>
                            setState(() => _musicExpanded = !_musicExpanded),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Row(
                            children: [
                              const Icon(
                                Icons.music_note_outlined,
                                color: Colors.white70,
                                size: 20,
                              ),
                              const SizedBox(width: 10),
                              const Text(
                                '音乐',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const Spacer(),
                              Icon(
                                _musicExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                color: Colors.white54,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_musicExpanded) ...[
                        const Divider(color: Colors.white12, height: 1),
                        const SizedBox(height: 14),
                        // 库存：扫描/刷新音乐库
                        _subTitle('库存'),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          icon: Icon(
                            Library.instance.loading
                                ? Icons.hourglass_top
                                : Icons.refresh,
                          ),
                          label: Text(
                            Library.instance.loading
                                ? '正在扫描音乐库…（点此停止）'
                                : '刷新音乐库（共 ${Library.instance.songs.length} 首）',
                          ),
                          // 扫描中也能点：这一次点击 = 叫停（取消标志位，见 library_data）
                          onPressed: Library.instance.loading
                              ? _stopRefreshLibrary
                              : _refreshLibrary,
                        ),
                        const SizedBox(height: 18),
                        // 音效：均衡器（挂在正在播放的音频会话上，先放一首歌才可调）
                        _subTitle('音效'),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          icon: const Icon(Icons.equalizer),
                          label: const Text('均衡器'),
                          onPressed: () => Navigator.push(
                            context,
                            smoothPageRoute(const EqualizerPage()),
                          ),
                        ),
                        const SizedBox(height: 10),
                        // 音效增强：低音 + 响度（同样挂播放会话）+ 音量淡入淡出 + 交叉淡变
                        FilledButton.icon(
                          icon: const Icon(Icons.speaker),
                          label: const Text('低音 · 响度 · 淡入淡出'),
                          onPressed: () => Navigator.push(
                            context,
                            smoothPageRoute(const SoundEffectsPage()),
                          ),
                        ),
                        const SizedBox(height: 18),
                        // 导出：把 App 内的歌复制一份到手机 Music/MuBox（拷电脑/迁移用）
                        _subTitle('导出'),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          icon: const Icon(Icons.output_outlined),
                          label: Text(
                            _exporting
                                ? '导出中… $_exported/$_targetTotal 首（点此取消）'
                                : '导出全部歌曲到手机',
                          ),
                          // 导出中也能点：这一次点击 = 取消（令牌失效，循环下一轮退出）
                          onPressed: _exporting ? _stopExport : _exportAll,
                        ),
                        const SizedBox(height: 18),
                        // 搜索：右下角悬浮搜索按钮（点开 = 搜整个曲库）
                        _subTitle('搜索'),
                        const SizedBox(height: 8),
                        ValueListenableBuilder<bool>(
                          // ⚠️ 独立 ValueNotifier（照 AppConfig.enjoyActive 先例）：切这个开关
                          //    只重建这一行，⛔ 绝不许 _bumpRebuild()（那会整棵 MaterialApp 重建）
                          valueListenable: AppConfig.instance.searchFabEnabled,
                          builder: (context, on, _) => Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  '右下角搜索按钮',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              Switch(
                                // 测试锚点，别改（与 test 里的字面量一致）
                                key: const ValueKey<String>('switch_search_fab'),
                                value: on,
                                activeThumbColor:
                                    Theme.of(context).colorScheme.primary,
                                onChanged: (v) =>
                                    AppConfig.instance.setSearchFabEnabled(v),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 6),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // 「数据」折叠区块：视觉方案 + 数据备份（减少设置页拥挤）
                _sectionTitle(context, '数据'),
                const SizedBox(height: 8),
                SurfaceCard(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      InkWell(
                        onTap: () =>
                            setState(() => _dataExpanded = !_dataExpanded),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          child: Row(
                            children: [
                              const Icon(Icons.inventory_2_outlined,
                                  color: Colors.white70, size: 20),
                              const SizedBox(width: 10),
                              const Text(
                                '数据',
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.white,
                                ),
                              ),
                              const Spacer(),
                              Icon(
                                _dataExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                color: Colors.white54,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (_dataExpanded) ...[
                        const Divider(color: Colors.white12, height: 1),
                        const SizedBox(height: 14),
                        // 视觉方案
                        FilledButton.icon(
                          icon: const Icon(Icons.palette_outlined),
                          label: const Text('保存 / 管理视觉方案'),
                          onPressed: () => Navigator.push(
                            context,
                            smoothPageRoute(const VisualSchemePage()),
                          ),
                        ),
                        const SizedBox(height: 18),
                        // 数据备份（可取消：打包中再点一次 = 取消，半成品 zip 会被删）
                        FilledButton.icon(
                          icon: const Icon(Icons.save_alt_outlined),
                          label: Text(
                            _backingUp ? '备份中…（点此取消）' : '备份（导出 zip）',
                          ),
                          onPressed: _backingUp ? _stopBackup : _backupNow,
                        ),
                        const SizedBox(height: 8),
                        // 诊断包：给用户自己排查用（内容 = 曲库索引 + 设置 + info.txt）
                        FilledButton.icon(
                          icon: const Icon(Icons.bug_report_outlined),
                          label: Text(
                            _diagnosing ? '正在导出诊断包…' : '导出诊断包',
                          ),
                          onPressed: _diagnosing ? null : _exportDiagnostic,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          '⚠️ 诊断包（diagnostic_*.zip）= 完整设置 + 曲库索引 + info.txt，'
                          '含完整设置与曲库索引、可能包含私密歌信息，只给自己看；'
                          '要发给别人的请用上面的「备份（导出 zip）」',
                          style: TextStyle(fontSize: 11, color: Colors.orangeAccent),
                        ),
                        FilledButton.icon(
                          icon: const Icon(Icons.settings_backup_restore),
                          label: Text(_restoring ? '恢复中…' : '从备份恢复'),
                          onPressed: _restoring ? null : _restoreNow,
                        ),
                        const SizedBox(height: 6),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                // 睡眠定时：到点自动暂停播放
                _sectionCard(
                  context,
                  '睡眠定时',
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (playerService?.sleepActive ?? false)
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                const Icon(
                                  Icons.bedtime_outlined,
                                  color: Colors.white70,
                                  size: 18,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '剩余 ${_fmtSleep(playerService!.sleepRemaining)} 后自动暂停',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 10),
                            OutlinedButton.icon(
                              icon: const Icon(Icons.close),
                              label: const Text('取消定时'),
                              onPressed: () => playerService?.cancelSleepTimer(),
                            ),
                          ],
                        )
                      else ...[
                        SegmentedButton<int>(
                          // 选中填充走系统主题色（primary），形状/交互与上方「字体大小」一致。
                          // 睡眠定时是「点击即启动」的瞬时动作，不保持选中态，故允许空选择。
                          style: SegmentedButton.styleFrom(
                            selectedBackgroundColor:
                                Theme.of(context).colorScheme.primary,
                            selectedForegroundColor: Colors.white,
                          ),
                          emptySelectionAllowed: true,
                          segments: [
                            for (final m in const [15, 30, 45, 60])
                              ButtonSegment(value: m, label: Text('$m 分')),
                          ],
                          selected: const {},
                          onSelectionChanged: (s) => playerService
                              ?.startSleepTimer(Duration(minutes: s.first)),
                        ),
                        const SizedBox(height: 8),
                        // 自定义时长：手动输入分钟数
                        OutlinedButton.icon(
                          icon: const Icon(Icons.tune),
                          label: const Text('自定义…'),
                          onPressed: _openCustomSleepTimer,
                        ),
                      ],
                    ],
                  ),
                ),
                // 后台播放：未授权时显示，授权后自动隐藏（权限已开就不用再占位置）
                if (!_batteryOptimized) ...[
                  const SizedBox(height: 20),
                  _sectionCard(
                    context,
                    '后台播放',
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          '锁屏/切后台后持续播放。部分手机（小米、华为等）需允许后台运行或忽略电池优化，否则锁屏一会儿可能被系统停掉。',
                          style: TextStyle(fontSize: 11, color: Colors.white38),
                        ),
                        const SizedBox(height: 10),
                        FilledButton.icon(
                          style: FilledButton.styleFrom(
                            backgroundColor: Theme.of(
                              context,
                            ).colorScheme.primary,
                            foregroundColor: Colors.white,
                          ),
                          icon: const Icon(Icons.battery_saver),
                          label: const Text('允许后台播放（忽略电池优化）'),
                          onPressed: () async {
                            // 同 `_checkBattery`：通道不可用会抛（`PlatformException` /
                            // `MissingPluginException`），不许让它变成未捕获异步异常。
                            // ⚠️ 同样**只吞平台异常**，不写 `catch (e)` ——
                            // `Error` 是编程错误，吞掉就是把证据藏起来。
                            // 抛了就静默 —— **不加任何新 UI、不改观感**。
                            try {
                              await Permission.ignoreBatteryOptimizations
                                  .request();
                            } on PlatformException catch (e) {
                              debugPrint('MuBox 后台播放：请求忽略电池优化失败 $e');
                            } on MissingPluginException catch (e) {
                              debugPrint('MuBox 后台播放：请求忽略电池优化失败（插件未就绪）$e');
                            }
                            await _checkBattery();
                          },
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String t) => Text(
    t,
    style: const TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w600,
      color: Colors.white70,
    ),
  );

  /// 区块卡片：标题 + 轻量玻璃卡片包裹内容，形成「标题 → 卡片 → 内容」的层次。
  Widget _sectionCard(BuildContext context, String title, Widget child) =>
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(context, title),
          const SizedBox(height: 8),
          SurfaceCard(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: child,
          ),
        ],
      );

  /// 单个主题色圆球（选中时白边 + 对勾）；长按删除（内置色隐藏、自定义色移除）。
  Widget _colorDot(int idx) {
    final selected = AppConfig.instance.themeIndex == idx;
    return GestureDetector(
      onTap: () => AppConfig.instance.setThemeIndex(idx),
      onLongPress: () => _deleteTheme(idx),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: _schemeAt(idx).primary,
          border: Border.all(
            color: selected ? Colors.white : Colors.white24,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? const Icon(Icons.check, color: Colors.white, size: 20)
            : null,
      ),
    );
  }

  /// 收起状态第 8 格：展开按钮（圆球样式，加号表示还有更多颜色）。
  Widget _expandDot() {
    return GestureDetector(
      onTap: () => setState(() => _themeExpanded = true),
      child: Container(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.white.withValues(alpha: 0.08),
          border: Border.all(color: Colors.white24),
        ),
        child: const Icon(Icons.add, color: Colors.white70, size: 20),
      ),
    );
  }

  Widget _collapseButton(String label, VoidCallback onTap) => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      style: FilledButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.black,
      ),
      onPressed: onTap,
      icon: const Icon(Icons.expand_less),
      label: Text(label),
    ),
  );

  /// 自定义主题色区：标题 + 新建按钮 + 每套自建色的可删除条目。
  Widget _buildCustomThemes() {
    final cfg = AppConfig.instance;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Text(
              '自定义主题色',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: Colors.white60,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _createCustomTheme,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('新建'),
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(context).colorScheme.primary,
              ),
            ),
          ],
        ),
        for (var ci = 0; ci < cfg.customThemes.length; ci++)
          _customThemeRow(kDefaultThemeCount + ci, cfg.customThemes[ci]),
      ],
    );
  }

  /// 单个自定义主题色条目：色块 + 名称 + 选中标记 + 删除按钮。
  Widget _customThemeRow(int idx, AccentScheme scheme) {
    final selected = AppConfig.instance.themeIndex == idx;
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      onTap: () => AppConfig.instance.setThemeIndex(idx),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected
              ? primary.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? primary : Colors.white12,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 26,
              height: 26,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [scheme.primary, scheme.light],
                ),
                border: Border.all(color: Colors.white24),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                scheme.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white70,
                  fontSize: 14,
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check, color: Colors.white, size: 18),
            IconButton(
              icon: const Icon(Icons.delete_outline,
                  color: Colors.white54, size: 20),
              tooltip: '删除',
              onPressed: () => _deleteTheme(idx),
            ),
          ],
        ),
      ),
    );
  }

  /// 一键恢复默认：显示全部 40 套内置色（保留自定义）。
  Widget _buildRestoreDefaultButton() => SizedBox(
    width: double.infinity,
    child: FilledButton.icon(
      onPressed: () => AppConfig.instance.restoreDefaultThemes(),
      style: FilledButton.styleFrom(
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Colors.black,
      ),
      icon: const Icon(Icons.restore),
      label: const Text('恢复默认主题色'),
    ),
  );

  /// 打开自定义主题色选择器并保存新主题。
  Future<void> _createCustomTheme() async {
    final scheme = await showCustomColorPicker(context);
    if (scheme == null || !mounted) return;
    await AppConfig.instance.addCustomTheme(scheme);
    if (mounted) setState(() => _themeExpanded = true);
  }

  /// 删除主题色（确认弹窗）：内置色隐藏、自定义色移除。
  Future<void> _deleteTheme(int idx) async {
    final scheme = _schemeAt(idx);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        child: GlassPanel(
          borderRadius: BorderRadius.circular(20),
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '删除主题色',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                '确定删除主题色「${scheme.name}」吗？',
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white70,
                    ),
                    onPressed: () => Navigator.pop(ctx, false),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                    ),
                    onPressed: () => Navigator.pop(ctx, true),
                    child: const Text('删除'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await AppConfig.instance.removeThemeAt(idx);
  }

  /// 音乐区块内的子分类标题（库存/音效/导出/搜索）。
  Widget _subTitle(String t) => Text(
    t,
    style: const TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: Colors.white60,
    ),
  );

  /// 睡眠定时剩余时间格式化（MM:SS 或 H:MM:SS）。
  String _fmtSleep(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }
}
