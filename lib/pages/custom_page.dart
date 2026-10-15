/// 下页：自定义特效（深度自定义背景动效）。
///
/// **两级结构**（把四大区块折叠一下，每个区块单独开一页）：
/// * **一级 = 特效目录**（[group] 为空，嵌在根页面下行的那一格）：只列
///   **四个区的入口卡**（视觉 / 律动 / 氛围 / 边框），每张卡上是这个区的当前状态
///   与区总开关；点卡进这个区的专属页。
/// * **二级 = 区页面**（[group] 非空，`push` 出来的独立一页）：只渲染那一个区，
///   并**自带壁纸 + 氛围层预览**（不然 push 出来是黑底）。
///
/// 一级页**故意不铺自己的背景** —— 它嵌在根页面的 Stack 里，铺了会盖住真背景。
///
/// 区页面里点任意一张特效卡 → 进该特效的**专属设置页**（`effect_page.dart`），
/// 参数由 `effect_catalog.dart` 的参数表生成，每个特效各不相同。
///
/// 每个区一个总开关、区内动效互斥（选中一个其余自动让位），
/// 卡片右上角的对勾 = 当前正在用的那个。
library;

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import '../app_config.dart';
import '../effect_catalog.dart';
import '../smooth_route.dart';
import '../widgets/ambient_layer.dart';
import '../widgets/glass_panel.dart';
import '../widgets/layer_stepper.dart';
import '../widgets/wallpaper_layer.dart';
import 'effect_page.dart';

class CustomPage extends StatefulWidget {
  const CustomPage({super.key, this.group});

  /// 非空 = 这是**某个区的专属页**（二级页）：只渲染这一个区，自带预览背景。
  /// 空 = 特效目录（一级页）：四张入口卡。⚠️ `root_page.dart` 传的就是空。
  final String? group;

  @override
  State<CustomPage> createState() => _CustomPageState();
}

class _CustomPageState extends State<CustomPage> {
  /// 录音权限是否就绪：律动频谱（原生 Visualizer）依赖它。有些 ROM 会把这类敏感权限
  /// 反复回收（表现为「律动又没了」），所以这里主动查一次并在缺失时给一键授权入口。
  bool _micOk = true;

  @override
  void initState() {
    super.initState();
    _checkMic();
  }

  /// 查麦克风权限 —— **这里刻意保留宽兜底 `catch (_)`，别"顺手修好"它**。
  ///
  /// 与设置页那两处（`settings_page.dart` 的 `_checkBattery` / 按钮）**不同**：
  /// 那两处吞掉 `Error` 会把「编程错误」藏起来，所以要收紧成
  /// `on PlatformException` + `on MissingPluginException`；**这里反过来**。
  ///
  /// 为什么这里宽是对的：
  /// 1. [_micOk] 的唯一作用是**决定要不要显示一条提示**（见 `build` 里的
  ///    `if (g.id == 'r' && !_micOk) _micHint()`）。它不控制任何功能，
  ///    真去授权走的是提示里那颗按钮（[_askMic]），与这个布尔无关。
  /// 2. 收到平台异常时，**保持缺省 `true` = 不显示提示**，这是**安全默许方向**：
  ///    查不动就别拿一条「你没授权」去指控用户。
  /// 3. `_checkMic` 是 `initState` 里 fire-and-forget 调的，没人 await。
  ///    这里收紧 ⇒ 万一抛的是 `Error`，它就变成**未捕获异步异常**，
  ///    而这一页正落在「**观感别改**」那条线上 ⇒ 拿一个**用户可见的崩溃**
  ///    去换一条**本来就只是提示**的横幅不显示，是亏的。
  /// 4. 代价被明确接受：真出 `Error` 时表现是「提示一直不显示」——
  ///    用户仍有 [_askMic] 那条路可走，不是死角。
  ///
  /// ⚠️ 这条理由由 `test/custom_page_mic_hint_test.dart` 钉住：那里证明
  /// 「宽窄只在一个地方有区别（`Error`）」，并防住以后有人把它收紧。
  Future<void> _checkMic() async {
    try {
      final st = await Permission.microphone.status;
      if (mounted) setState(() => _micOk = st.isGranted);
    } catch (_) {
      // 查询失败就不提示（不打扰）—— 缺省 true 已经是不提示，什么都不用做
    }
  }

  /// 用户点「去授权」才走这条路：请求权限，没给成就引导去系统设置。
  ///
  /// 同样**刻意宽兜底**，理由同 [_checkMic]（这是用户主动点的按钮，
  /// 这里吞掉 `Error` 也只会表现为「点了没反应」，不会把整页打成红屏）。
  Future<void> _askMic() async {
    try {
      final st = await Permission.microphone.request();
      if (!mounted) return;
      setState(() => _micOk = st.isGranted);
      // 系统已拒绝过就不会再弹窗，只能引导去系统设置手动开
      if (!st.isGranted) await openAppSettings();
    } catch (_) {}
  }

  /// 本页在渲染哪个区；null = 一级目录页。
  FxGroupInfo? get _g {
    final id = widget.group;
    if (id == null) return null;
    for (final g in kFxGroups) {
      if (g.id == id) return g;
    }
    return null; // 传了不认识的区名：按一级目录页渲染，不留白屏
  }

  @override
  Widget build(BuildContext context) {
    final g = _g;
    final body = SafeArea(
      child: ListenableBuilder(
        listenable: AppConfig.instance,
        builder: (context, _) {
          final cfg = AppConfig.instance;
          return ListView(
            // 内容变长后可向下滚动，避免底部被播放栏挡住；Clamping 贴合 Android 手感
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 200),
            children: g == null
                ? _indexPage(cfg)
                : _groupPage(g, cfg),
          );
        },
      ),
    );
    if (g == null) return body; // 一级：嵌在根页面里，沿用根页面的真背景
    // 二级：**必须自带**壁纸 + 氛围层（照 effect_page.dart 的预览），
    // 否则 push 出来是一片黑底 —— 调特效时看不到背景。
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          const Positioned.fill(child: WallpaperLayer()),
          const Positioned.fill(child: AmbientLayer(isPreview: true)),
          body,
        ],
      ),
    );
  }

  /// 一级目录页：四张区入口卡。
  List<Widget> _indexPage(AppConfig cfg) {
    return [
      const Text('自定义特效',
          style: TextStyle(
              fontSize: 22, fontWeight: FontWeight.bold, color: Colors.white)),
      const SizedBox(height: 8),
      const Text('四个区各一页 —— 点一张卡进那个区',
          style: TextStyle(fontSize: 12, color: Colors.white38)),
      const SizedBox(height: 18),
      for (final g in kFxGroups) ...[
        _entryCard(g, cfg),
        const SizedBox(height: 12),
      ],
    ];
  }

  /// 二级区页面：区标题 + 该区内容（与折叠前逐项相同，只是不再和别的区挤一页）。
  List<Widget> _groupPage(FxGroupInfo g, AppConfig cfg) {
    return [
      _groupHeader(g, cfg),
      const SizedBox(height: 8),
      if (g.id == 'r' && !_micOk) _micHint(),
      if (g.id == 'v') ...[
        // 层数控件：和特效设置页里那个是**同一个控件**（`LayerStepper`），
        // 在这里也能加/删当前特效的层 —— 用户不必先进设置页。
        if (Fx.find('v', _current('v', cfg)) case final cur?)
          SurfaceCard(
            padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
            child: LayerStepper(effect: cur),
          ),
        const SizedBox(height: 12),
        _layerStrip(cfg),
        const SizedBox(height: 10),
        const Text('点一张卡 = 进它自己的设置页（还没加过的会先加上一层）· 长按 = 把当前这一层换成它',
            style: TextStyle(fontSize: 11, color: Colors.white38)),
        const SizedBox(height: 8),
      ],
      _effectGrid(g, cfg),
      const SizedBox(height: 22),
    ];
  }

  /// 区入口卡：图标 + 区名 + 一句「现在是什么状态」+ 区总开关 + 箭头。
  /// 点卡片 = 进这个区的专属页；点开关只切开关、不进页面。
  Widget _entryCard(FxGroupInfo g, AppConfig cfg) {
    final primary = Theme.of(context).colorScheme.primary;
    final on = _enabled(g.id, cfg);
    final cur = Fx.find(g.id, _current(g.id, cfg));
    final layers = g.id == 'v'
        ? ' · ${cfg.visualLayers.length} 层'
        : '';
    final state = on ? '当前：${cur?.name ?? '—'}$layers' : '已关闭 · ${g.desc}';
    return InkWell(
      onTap: () => Navigator.of(context)
          .push(smoothPageRoute(CustomPage(group: g.id))),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 6, 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: on ? primary : Colors.white12),
        ),
        child: Row(
          children: [
            Icon(g.icon, size: 22, color: on ? primary : Colors.white38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(g.title,
                      style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: on ? Colors.white : Colors.white54)),
                  const SizedBox(height: 2),
                  Text(state,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 11, color: Colors.white38)),
                ],
              ),
            ),
            Switch(
              activeThumbColor: primary,
              value: on,
              onChanged: (v) => _toggle(g.id, v, cfg),
            ),
            const Icon(Icons.chevron_right, size: 18, color: Colors.white24),
          ],
        ),
      ),
    );
  }

  /// 区标题行：图标 + 区名 + 一句说明 + 该区总开关。
  Widget _groupHeader(FxGroupInfo g, AppConfig cfg) {
    final on = _enabled(g.id, cfg);
    return Row(
      children: [
        Icon(g.icon, size: 18, color: on ? Colors.white : Colors.white38),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(g.title,
                  style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: on ? Colors.white : Colors.white54)),
              Text(g.desc, style: const TextStyle(fontSize: 11, color: Colors.white30)),
            ],
          ),
        ),
        Switch(
          activeThumbColor: Theme.of(context).colorScheme.primary,
          value: on,
          onChanged: (v) => _toggle(g.id, v, cfg),
        ),
      ],
    );
  }

  /// 律动权限提示：未授权时原生 Visualizer 拿不到数据，先讲清楚再给一键授权。
  Widget _micHint() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          const Icon(Icons.mic_off_outlined, size: 15, color: Colors.orangeAccent),
          const SizedBox(width: 6),
          const Expanded(
            child: Text('律动需要「麦克风」权限，未授权时不会跳动',
                style: TextStyle(fontSize: 11, color: Colors.orangeAccent)),
          ),
          TextButton(
            onPressed: _askMic,
            child: const Text('去授权', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  /// 视觉区图层条：同一个特效能叠好几层（每层一套自己的位置/大小/颜色参数）。
  /// 点一下 = 选中它（接着点卡片右边「设置」调的就是这一层），✕ = 删掉这一层。
  /// 至少留一层：视觉区「什么都不画」是上面那个总开关的活。
  Widget _layerStrip(AppConfig cfg) {
    final primary = Theme.of(context).colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.layers_outlined, size: 14, color: Colors.white38),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '图层 ${cfg.visualLayers.length}/$kMaxVisualLayers'
                '　点一下选中，✕ 删除（每层各调各的）',
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (var i = 0; i < cfg.visualLayers.length; i++)
              _layerChip(cfg, i, primary),
          ],
        ),
      ],
    );
  }

  /// 一个图层小胶囊：序号 + 图标 + 特效名（+ 关掉这层的眼睛记号）+ ✕。
  Widget _layerChip(AppConfig cfg, int i, Color primary) {
    final l = cfg.visualLayers[i];
    final e = Fx.find('v', l.effect);
    final sel = l.slot == cfg.visualLayerSel;
    final fg = l.enabled ? (sel ? Colors.white : Colors.white70) : Colors.white30;
    return InkWell(
      onTap: () => cfg.selectVisualLayer(l.slot),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 5, 4, 5),
        decoration: BoxDecoration(
          color: sel
              ? primary.withValues(alpha: 0.22)
              : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: sel ? primary : Colors.white12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('${i + 1}',
                style: TextStyle(fontSize: 11, color: fg.withValues(alpha: 0.7))),
            const SizedBox(width: 6),
            Icon(l.enabled ? (e?.icon ?? Icons.help_outline) : Icons.visibility_off,
                size: 13, color: fg),
            const SizedBox(width: 4),
            Text(e?.name ?? '已下架', style: TextStyle(fontSize: 12, color: fg)),
            if (cfg.visualLayers.length > 1)
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => cfg.removeVisualLayer(l.slot),
                child: const Padding(
                  padding: EdgeInsets.fromLTRB(7, 4, 5, 4),
                  child: Icon(Icons.close, size: 14, color: Colors.white54),
                ),
              )
            else
              const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }

  /// 特效卡片网格：两列，卡片上是图标 + 名称，当前选中图层的那张高亮并带对勾。
  /// 视觉区多一个「已开 N 层」的角标：同一特效能开好几层。
  Widget _effectGrid(FxGroupInfo g, AppConfig cfg) {
    final list = Fx.of(g.id);
    final cur = _current(g.id, cfg);
    final on = _enabled(g.id, cfg);
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 2.5,
      children: [
        for (final e in list)
          _effectCard(g.id, e,
              selected: e.index == cur,
              dimmed: !on,
              layers: g.id == 'v'
                  ? cfg.visualLayers.where((l) => l.effect == e.index).length
                  : 0),
      ],
    );
  }

  /// 一张特效卡片。
  ///
  /// **视觉区：整张卡一个行为** —— 点哪儿都进它自己的设置页
  /// （[`_openVisual`]：有层就进它那一层，一层都没有就**先加一层**再进）；
  /// **长按 = 把当前选中的那一层换成它**（「换个特效」的正式手势，保留）。
  ///
  /// 其余三区（律动/氛围/边框）区内互斥、没有层这回事 ⇒ 仍是两个热区：
  /// 左半 = 选中它，右半 = 进设置页。⛔ 别把这两种模型混起来。
  Widget _effectCard(String group, FxEffect e,
      {required bool selected, required bool dimmed, int layers = 0}) {
    final primary = Theme.of(context).colorScheme.primary;
    final fg = dimmed
        ? Colors.white38
        : (selected ? Colors.white : Colors.white70);
    final isVisual = group == 'v';
    // 卡片正文（图标 + 名字 + 一句状态 + 对勾）
    final left = Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      child: Row(
        children: [
          Icon(e.icon, size: 20, color: selected ? primary : fg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(e.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600, color: fg)),
                Text(
                  isVisual
                      ? (layers > 0
                          ? '已开 $layers 层 · 点一下设置'
                          : '还没有层 · 点一下加上并设置')
                      : '${e.params.length} 项设置',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 10, color: Colors.white30),
                ),
              ],
            ),
          ),
          if (selected) Icon(Icons.check_circle, size: 15, color: primary),
        ],
      ),
    );
    // 「设置」记号：视觉区里它只是**提示整卡可点**，不再是单独的热区。
    final right = SizedBox(
      width: 48,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.tune, size: 16, color: selected ? primary : Colors.white54),
          const SizedBox(height: 1),
          const Text('设置',
              style: TextStyle(fontSize: 9, color: Colors.white38)),
        ],
      ),
    );
    final divider = Container(width: 1, height: 26, color: Colors.white12);
    return Container(
      clipBehavior: Clip.antiAlias, // 水波纹不溢出圆角
      decoration: BoxDecoration(
        color: selected
            ? primary.withValues(alpha: 0.20)
            : Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: selected ? primary : Colors.white12),
      ),
      child: isVisual
          // ★ 视觉区：**整张卡**一个热区 —— 点它 = 进它自己的设置页
          ? InkWell(
              onTap: () => _openVisual(e),
              onLongPress: () => _replaceEffect(e),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [Expanded(child: left), divider, right],
              ),
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _select(group, e.index, AppConfig.instance),
                    child: left,
                  ),
                ),
                divider,
                InkWell(onTap: () => _open(group, e), child: right),
              ],
            ),
    );
  }

  /// 点一张**视觉特效卡**（整张卡）= 进它自己的设置页。
  ///
  /// * **已经有层** ⇒ 进一层：当前选中的就是它 ⇒ 进**这一层**；否则进它的**第一层**；
  /// * **一层都没有** ⇒ **先给它加一层**（`addVisualLayer`，会自动选中新那层）再进 ——
  ///   ⛔ 不再弹「长按这张卡，把它换到当前选中的那一层」那种**死胡同**;
  /// * 到上限加不上 ⇒ **先拒绝 + 说一句话**（不做「点了没反应」的死按钮）。
  Future<void> _openVisual(FxEffect e) async {
    final cfg = AppConfig.instance;
    final sel = cfg.selectedVisualLayer;
    var slot = -1;
    if (sel.effect == e.index) {
      slot = sel.slot; // 选中的就是它 ⇒ 进这一层
    } else {
      for (final l in cfg.visualLayers) {
        if (l.effect == e.index) {
          slot = l.slot; // 否则进它的第一层
          break;
        }
      }
    }
    if (slot < 0) {
      if (!await cfg.addVisualLayer(e.index)) {
        if (!mounted) return;
        _toast('已经叠了 $kMaxVisualLayers 层 —— 先删掉一层，再加「${e.name}」');
        return;
      }
      slot = cfg.visualLayerSel; // addVisualLayer 自动选中新那层
    } else {
      await cfg.selectVisualLayer(slot);
    }
    if (!mounted) return;
    Navigator.of(context).push(smoothPageRoute(
      EffectPage(group: 'v', index: e.index, slot: slot),
    ));
  }

  /// 点**非视觉区**卡片右半「设置」：先切到它（区内互斥），再进它的专属设置页。
  /// ⚠️ 视觉区**不走这里**（它整张卡都走 [_openVisual]，有自己的「没层就先加一层」规则）。
  void _open(String group, FxEffect e) {
    _select(group, e.index, AppConfig.instance);
    Navigator.of(context).push(
      smoothPageRoute(EffectPage(group: group, index: e.index)),
    );
  }

  /// 视觉区：长按一张卡 = **把当前选中的那一层换成它**（「换个特效」的唯一手势）。
  /// 走 `AppConfig.replaceVisualLayerEffect` —— 只改这一层的 `effect`，
  /// **不换槽位、不挪 z 序、不动别的层**。
  Future<void> _replaceEffect(FxEffect e) async {
    final cfg = AppConfig.instance;
    final slot = cfg.visualLayerSel;
    final no = _layerNoOf(cfg, slot);
    final wasSame = cfg.visualLayers.any((l) => l.slot == slot && l.effect == e.index);
    final ok = await cfg.replaceVisualLayerEffect(slot, e.index);
    if (!mounted) return;
    _toast(!ok
        ? '这一层已经不在了，回上一层看看'
        : (wasSame
            ? '第 $no 层本来就是「${e.name}」'
            : '第 $no 层已换成「${e.name}」'));
  }

  /// 某个槽位是第几层（给提示文案用）。
  int _layerNoOf(AppConfig cfg, int slot) {
    final i = cfg.visualLayers.indexWhere((l) => l.slot == slot);
    return i < 0 ? 1 : i + 1;
  }

  /// 一句浮层提示。⛔ 先 `clearSnackBars()` 再弹，避免两条互相盖。
  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 2000),
        behavior: SnackBarBehavior.floating,
      ));
  }

  /// ⚠️ 加层/删层**只有** `lib/widgets/layer_stepper.dart` 那个共用控件做
  /// （特效设置页 + 本页的视觉区页面），目录页没有任何加层路径。

  // ── 四个区的配置读写（索引字段分散在 AppConfig 上，这里统一收口）──────────

  /// 当前选中的特效索引。老存值可能落在**已下架**的索引上（如边框 2 节拍VU、
  /// 律动 4 音浪、氛围 9 流星）：绘制端按 `Fx.has` 回落到本区第一项在画，
  /// 目录页也得跟着回落 —— 否则整片网格没有一张高亮，界面和实际在跑的对不上。
  int _current(String id, AppConfig c) {
    final idx = switch (id) {
      // 视觉区是多图层了：高亮「当前选中的那一层」用的特效
      'v' => c.selectedVisualLayer.effect,
      'r' => c.rhythmEffect,
      'a' => c.ambientEffect,
      _ => c.edgeEffect,
    };
    return Fx.has(id, idx) ? idx : Fx.of(id).first.index;
  }

  void _select(String id, int i, AppConfig c) {
    switch (id) {
      case 'v':
        c.setVisualEffect(i);
      case 'r':
        c.setRhythmEffect(i);
      case 'a':
        c.setAmbientEffect(i);
      default:
        c.setEdgeEffect(i);
    }
  }

  bool _enabled(String id, AppConfig c) => switch (id) {
        'v' => c.heartEnabled,
        'r' => c.spectrumEnabled,
        'a' => c.rainEnabled,
        _ => c.edgeEnabled,
      };

  void _toggle(String id, bool v, AppConfig c) {
    switch (id) {
      case 'v':
        c.setHeartEnabled(v);
      case 'r':
        c.setSpectrumEnabled(v);
      case 'a':
        c.setRainEnabled(v);
      default:
        c.setEdgeEnabled(v);
    }
  }
}
