/// 单个特效的设置页：点自定义特效列表里的任一特效进入这里。
///
/// 页面是**通用**的：控件由 `effect_catalog.dart` 里该特效的参数表自动生成，
/// 加一个参数不需要动本文件。背景铺的是真实的壁纸 + 氛围层，
/// 所以调哪个参数都当场看得见效果（律动类在播放栏顶部，另外在页面底部给了一条放大的预览带）。
library;

import 'package:flutter/material.dart';

import '../app_config.dart';
import '../effect_catalog.dart';
import '../player_service.dart';
import '../theme.dart';
import '../widgets/ambient_layer.dart';
import '../widgets/fx_step_button.dart';
import '../widgets/glass_panel.dart';
import '../widgets/layer_stepper.dart';
import '../widgets/spectrum.dart';
import '../widgets/wallpaper_layer.dart';

class EffectPage extends StatefulWidget {
  const EffectPage({super.key, required this.group, required this.index, this.slot = 0});

  /// 区前缀：v 视觉 / r 律动 / a 氛围 / e 边框
  final String group;

  /// 区内特效索引
  final int index;

  /// 视觉区专用：改的是**哪一层**（参数槽位）。0 = 老键那层；其它层键带 `#槽位` 上标。
  /// 视觉区多图层后「同一特效各调各的」就靠它区分。
  /// ⚠️ 这只是**进来时**的那一层：页面里按了「＋」之后会自己跟到新层（见 [_slot]）。
  final int slot;

  @override
  State<EffectPage> createState() => _EffectPageState();
}

class _EffectPageState extends State<EffectPage> {
  /// 本页正在改的那一层。**必须可动**：页面里的「＋」会新建一层并自动选中它，
  /// 这时还按进来时那个 slot 去读写参数，用户看到的就是「加了层但调的是旧那层」。
  late int _slot = widget.slot;

  /// 这一层的槽位特效用完了 / 被删了 ⇒ 退回「当前选中的那一层」。
  int get _curSlot {
    final list = AppConfig.instance.visualLayers;
    for (final l in list) {
      if (l.slot == _slot) return _slot;
    }
    return AppConfig.instance.selectedVisualLayer.slot;
  }

  String get group => widget.group;
  int get index => widget.index;
  int get slot => _curSlot;

  /// 本页在改的那套参数键。
  ///
  /// 🔴 **只有视觉区（`v`）才有「一层一套参数」这回事**：`visualLayers` 是视觉区专用的
  /// 图层表，键上标 `#槽位` 也只被视觉区的画家消费（`ambient_painter.dart` 的 `_vPrefix`）。
  /// 氛围 / 律动 / 边框三区的参数是**区内一套**（`_aPrefix`/`_ePrefix` 拼的都是基键，
  /// `ambient_layer.dart` 的 `_generateAll()` 也全部读基键）⇒ 那三区**必须用基键**。
  ///
  /// ⚠️ 原来这里**不分區**，一律走 `fxInstanceKey`：非视觉区的 `slot` 恒为 0
  /// （`custom_page.dart` 那几处不传 `slot:`），但 [_curSlot] 会在
  /// 「`visualLayers` 里没有 slot == 0 的层」时**回落到当前选中层的槽位**
  /// ⇒ 写进去的是 `a4#3.count`，而画布只读 `a4.count` ⇒
  /// **数字会动、画面纹丝不动**（症状：这些滑杆怎么拖都没反应）。
  /// 有单测钉住 ★3/★4/★5（收回这一行 ⇒ 当场红）。
  ///
  /// 标了 `shared` 的参数（牵手联动这类**整组公共**项）永远用老键 ——
  /// 三颗爱心共用一个「牵手联动」开关，在哪一层的设置页里改都是同一个。
  String _k(FxParam p) =>
      group == 'v' ? fxInstanceKey(p.key, slot, shared: p.shared) : p.key;

  /// 本特效**自己的**层槽位（按图层表顺序）。
  /// ⛔ 只数 `effect == widget.index` 的层 —— 别的特效的层混不进来。
  List<int> _mySlots() => [
        for (final l in AppConfig.instance.visualLayers)
          if (l.effect == widget.index) l.slot
      ];

  int _myIndexOf(List<int> mine) {
    final i = mine.indexOf(slot);
    return i < 0 ? 0 : i;
  }

  /// 视觉区：本页这个特效的**第几层**（1-based，只数它自己的层）。
  int get _layerNo => _myIndexOf(_mySlots()) + 1;

  /// 在**本特效自己的各层**之间切换（多个之后要能单独调整任意一个）。
  /// 只改本页在调哪一层 + 目录页高亮；⛔ **不动 `visualLayers` 的顺序与槽位**。
  void _switchLayer(int delta) {
    final cfg = AppConfig.instance;
    final mine = _mySlots();
    if (mine.length < 2) return;
    final next = mine[(_myIndexOf(mine) + delta + mine.length) % mine.length];
    setState(() => _slot = next);
    cfg.selectVisualLayer(next);
  }

  /// 「＋」加完层后把本页的编辑目标跟到新那层（`LayerStepper.onChanged`）。
  ///
  /// ⚠️ 守卫用 `mounted`（State 的），**不是 `context`**：加层会让「切层入口」插进
  /// `ListView`（子项无 key）⇒ `LayerStepper` 那个 element 被重建、
  /// **它的 context 当场失效**（真机实测：用 context 守卫会把这个回调一起吞掉，
  /// 标题停在「第 1 层」而切层入口已写「第 1/2 层」）。
  void _followNewLayer() {
    if (!mounted) return;
    setState(() => _slot = AppConfig.instance.visualLayerSel);
  }

  @override
  Widget build(BuildContext context) {
    final effect = Fx.find(group, index);
    if (effect == null) {
      // 索引已下架（老存值）时不留空白页，直接退回
      return const Scaffold(backgroundColor: Colors.transparent);
    }
    return Scaffold(
      backgroundColor: Colors.transparent,
      resizeToAvoidBottomInset: false,
      body: Stack(
        children: [
          // 真实预览：壁纸 + 氛围层（爱心/雨滴/边框等都在这层里跑）
          const Positioned.fill(child: WallpaperLayer()),
          // 预览层永不冻结：用户经常暂停着调特效
          const Positioned.fill(child: AmbientLayer(isPreview: true)),
          SafeArea(
            child: Column(
              children: [
                _header(context, effect),
                Expanded(
                  child: ListenableBuilder(
                    listenable: AppConfig.instance,
                    builder: (context, _) => ListView(
                      physics: const ClampingScrollPhysics(),
                      // 底部留白：律动预览带占了下半屏一块，别让参数被压在它后面
                      padding: EdgeInsets.fromLTRB(20, 4, 20, group == 'r' ? 220 : 160),
                      children: _body(context, effect),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (group == 'r') _rhythmPreview(context),
        ],
      ),
    );
  }

  /// 顶部：返回 + 特效名（视觉区带**本特效**第几层）+ 恢复默认。
  Widget _header(BuildContext context, FxEffect effect) {
    final n = AppConfig.instance.visualLayers.length; // 视觉区总共几层
    final m = _mySlots().length; // 这个特效自己几层
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: '返回',
            onPressed: () => Navigator.pop(context),
          ),
          Expanded(
            child: Text(
              group == 'v'
                  ? (m >= 2
                      ? '${effect.name} · 第 $_layerNo/$m 层'
                      : '${effect.name} · 第 $_layerNo 层')
                  : effect.name,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: Colors.white),
            ),
          ),
          // 视觉区：删掉正在调的这一层（只剩一层时不给删，那是总开关的活）
          if (group == 'v' && n > 1)
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.white70),
              tooltip: '删除这一层',
              onPressed: () => _deleteLayer(context, effect),
            ),
          TextButton.icon(
            style: TextButton.styleFrom(foregroundColor: Colors.white70),
            icon: const Icon(Icons.restart_alt, size: 18),
            label: const Text('恢复默认', style: TextStyle(fontSize: 13)),
            onPressed: () => _reset(context, effect),
          ),
        ],
      ),
    );
  }

  /// 删掉当前这一层（它那套参数会被一起清掉）并返回目录页。
  Future<void> _deleteLayer(BuildContext context, FxEffect effect) async {
    final cfg = AppConfig.instance;
    // 先取好 messenger：下面 pop 之后这个 context 就失效了
    final messenger = ScaffoldMessenger.of(context);
    final no = _layerNo;
    await cfg.removeVisualLayer(slot);
    if (!context.mounted) return;
    Navigator.pop(context);
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text('已删除「${effect.name}」第 $no 层'),
        duration: const Duration(milliseconds: 1400),
        behavior: SnackBarBehavior.floating,
      ));
  }

  /// 页面主体：总开关 → （视觉区）层数控件 + 本层开关 → 色调（氛围区）→ 全部参数。
  List<Widget> _body(BuildContext context, FxEffect effect) {
    final cfg = AppConfig.instance;
    return [
      Text(effect.desc, style: const TextStyle(fontSize: 12, color: Colors.white38)),
      const SizedBox(height: 14),
      SurfaceCard(
        padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
        child: _enableTile(context, effect),
      ),
      const SizedBox(height: 16),
      // 视觉区：这个特效的**层数**（＋/－）→ 这一层自己的显示开关。
      // ⚠️ 与上面那个「视觉特效」开关**不是一回事**：那个管整片视觉区。
      if (group == 'v') ...[
        // 这个特效有**多层**时：给它一个在**自己的各层之间切换**的入口
        // （用户：「弄了多个之后可以单独调整任意一个」）。
        if (_mySlots().length >= 2) ...[
          SurfaceCard(
            padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
            child: _layerSwitchRow(),
          ),
          const SizedBox(height: 16),
        ],
        SurfaceCard(
          padding: const EdgeInsets.fromLTRB(14, 4, 6, 4),
          child: LayerStepper(
            effect: effect,
            // 「＋」会自动选中新那层 ⇒ 本页跟着它，别继续调旧那层
            onChanged: _followNewLayer,
          ),
        ),
        const SizedBox(height: 16),
        SurfaceCard(
          padding: const EdgeInsets.fromLTRB(14, 2, 14, 2),
          child: _layerTile(context, effect),
        ),
        const SizedBox(height: 16),
      ],
      // 固定本色的特效（火焰/花瓣/雨滴/雪花/阳光/萤火虫/烟花）：说明一句为什么没有颜色选项。
      // 能自选颜色的特效，颜色就是下面「专属设置」里的第一项（catalog 的 color 参数）。
      if (group == 'a' && !effect.tintable) ...[
        Row(
          children: [
            const Icon(Icons.palette_outlined, size: 14, color: Colors.white38),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                effect.tintHint ?? '「${effect.name}」用固定本色，不跟氛围色调走',
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),
      ],
      const Text('专属设置', style: TextStyle(fontSize: 13, color: Colors.white)),
      const SizedBox(height: 6),
      SurfaceCard(
        padding: const EdgeInsets.fromLTRB(14, 8, 14, 12),
        child: Column(
          children: [
            for (final p in effect.params) _paramTile(context, p, cfg),
          ],
        ),
      ),
    ];
  }

  /// 同一个特效有**多层**时的切层入口：只在本特效自己的各层之间循环。
  /// 切换只改本页在调哪一层 + 目录页高亮，⛔ **不动 `visualLayers` 的顺序与槽位**。
  Widget _layerSwitchRow() {
    final mine = _mySlots();
    final i = _myIndexOf(mine);
    final primary = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('本特效共 ${mine.length} 层 —— 逐层各自调',
                  style: const TextStyle(fontSize: 13, color: Colors.white)),
              const Text('切换只换本页在调哪一层，别的特效的层不混进来',
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          tooltip: '这个特效的上一层',
          icon: const Icon(Icons.chevron_left, color: Colors.white70),
          onPressed: () => _switchLayer(-1),
        ),
        Text('第 ${i + 1}/${mine.length} 层',
            style: TextStyle(fontSize: 12, color: primary)),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 20,
          tooltip: '这个特效的下一层',
          icon: const Icon(Icons.chevron_right, color: Colors.white70),
          onPressed: () => _switchLayer(1),
        ),
      ],
    );
  }

  /// 该特效所在区的总开关（爱心/律动/氛围/边框）。
  /// ⚠️ 视觉区这条开关管的是**整片视觉区**（所有层一起开关），**不是这个特效、
  /// 更不是这一层** —— 所以副标题特意把「所有层」写出来，免得和下面那个
  /// 「当前特效「X」· 共 N 层」的 ＋/－ 控件混成一件事。
  Widget _enableTile(BuildContext context, FxEffect effect) {
    final cfg = AppConfig.instance;
    final (title, value, onChanged) = switch (effect.group) {
      'v' => ('视觉特效', cfg.heartEnabled, cfg.setHeartEnabled),
      'r' => ('律动特效', cfg.spectrumEnabled, cfg.setSpectrumEnabled),
      'a' => ('氛围特效', cfg.rainEnabled, cfg.setRainEnabled),
      _ => ('边框特效', cfg.edgeEnabled, cfg.setEdgeEnabled),
    };
    final sub = effect.group == 'v'
        ? (value ? '整片视觉区（所有层）正在显示' : '整片视觉区已关闭，调参数也看不到效果')
        : (value ? '正在显示' : '已关闭，调参数也看不到效果');
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      activeThumbColor: Theme.of(context).colorScheme.primary,
      title: Text(title, style: const TextStyle(fontSize: 14, color: Colors.white)),
      subtitle: Text(sub,
          style: const TextStyle(fontSize: 11, color: Colors.white38)),
      value: value,
      onChanged: onChanged,
    );
  }

  /// 视觉区：当前这一层自己的显示开关。关掉只是不画它，参数照留
  /// （想「对比开/不开」时不用删层重调）。
  Widget _layerTile(BuildContext context, FxEffect effect) {
    final cfg = AppConfig.instance;
    final on = cfg.visualLayers
        .firstWhere((l) => l.slot == slot,
            orElse: () => const VisualLayer(effect: 0, slot: 0))
        .enabled;
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      activeThumbColor: Theme.of(context).colorScheme.primary,
      title: const Text('显示这一层',
          style: TextStyle(fontSize: 14, color: Colors.white)),
      subtitle: Text(
        on ? '第 $_layerNo 层正在显示' : '这一层已隐藏（参数还留着）',
        style: const TextStyle(fontSize: 11, color: Colors.white38),
      ),
      value: on,
      onChanged: (v) => cfg.setVisualLayerEnabled(slot, v),
    );
  }

  /// 颜色参数：一条可横滑的色卡。
  /// 第一张是「跟随主题」，后面是全部主题色 —— **包括用户自己在主题色页里
  /// 建的自定义色**，被删掉的内置色不再出现（与主题色页保持一致）。
  Widget _colorPicker(BuildContext context, FxParam p, AppConfig cfg) {
    final themePrimary = context.accent;
    final themeLight = context.accentLight;
    final choices = fxTintChoices(cfg, themePrimary, themeLight);
    final cur = cfg.fx(_k(p)).round();
    // 当前选的是「已被删掉的内置主题色」时，它不在可选列表里 → 临时补一张，
    // 否则整条色卡没有任何一张是选中态，看着像「没选过颜色 / 选了跟随主题」。
    if (!choices.any((c) => c.tint == cur)) {
      final (cp, cl) = fxTintColors(cur, themePrimary, themeLight);
      choices.insert(
          1, (tint: cur, name: '已删除', primary: cp, light: cl));
    }
    final curName = choices
        .firstWhere((c) => c.tint == cur, orElse: () => choices.first)
        .name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(p.label,
                  style: const TextStyle(fontSize: 13, color: Colors.white)),
            ),
            Text(curName,
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 34,
          // PageStorageKey：页面重建（拖别的滑杆）时色卡条的横向滚动位置不跳回开头
          child: ListView.separated(
            key: PageStorageKey<String>('fxcolor_${_k(p)}'),
            scrollDirection: Axis.horizontal,
            itemCount: choices.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, i) {
              final c = choices[i];
              final on = c.tint == cur;
              return InkWell(
                onTap: () => cfg.setFx(_k(p), c.tint.toDouble()),
                borderRadius: BorderRadius.circular(20),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [c.primary, c.light],
                    ),
                    border: Border.all(
                      color: on ? Colors.white : Colors.white24,
                      width: on ? 2 : 1,
                    ),
                  ),
                  // 「跟随主题」那张放个 ⟳ 记号，一眼区分它不是某个具体颜色
                  child: c.tint < 0
                      ? const Icon(Icons.sync, size: 13, color: Colors.white)
                      : null,
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  /// 单个参数控件：开关型走 Switch，颜色型走色卡，其余走滑块。
  Widget _paramTile(BuildContext context, FxParam p, AppConfig cfg) {
    if (p.isColor) return _colorPicker(context, p, cfg);
    if (p.isToggle) {
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        dense: true,
        activeThumbColor: Theme.of(context).colorScheme.primary,
        title: Text(p.label, style: const TextStyle(fontSize: 13, color: Colors.white)),
        value: cfg.fxOn(_k(p)),
        onChanged: (v) => cfg.setFx(_k(p), v ? 1 : 0),
      );
    }
    final v = cfg.fx(_k(p)).clamp(p.min, p.max);
    final slider = Slider(
      value: v,
      min: p.min,
      max: p.max,
      divisions: _divisions(p),
      activeColor: Theme.of(context).colorScheme.primary,
      onChanged: (nv) => cfg.setFx(_k(p), nv),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(p.label,
                  style: const TextStyle(fontSize: 13, color: Colors.white)),
            ),
            Text(p.display(v),
                style: const TextStyle(fontSize: 12, color: Colors.white54)),
          ],
        ),
        // 位置参数（0.1% 一格）：滑杆两边各配一颗 −/+ 按钮，
        // 「手指拖个大概、按钮对准」。⚠️ **只有这一种格式**多这两颗按钮，
        // 别的参数那一行仍是「滑杆直接铺满」（逐像素不变）。
        if (p.format == FxFormat.position)
          Row(
            children: [
              _stepButton(p, cfg, up: false, value: v),
              Expanded(child: slider),
              _stepButton(p, cfg, up: true, value: v),
            ],
          )
        else
          slider,
      ],
    );
  }

  /// 位置参数那一对 −/+ 微调按钮。
  /// ⚠️ key 用**带图层上标的键**（`_k(p)`）：同一特效开多层时，
  /// 裸键 `v0.x` 会让两层的按钮**撞 key**（Flutter 直接抛 duplicate key）。
  Widget _stepButton(FxParam p, AppConfig cfg,
      {required bool up, required double value}) {
    final k = _k(p);
    return FxStepButton(
      key: ValueKey<String>('fx_step_$k${up ? '_up' : '_down'}'),
      icon: up ? Icons.add : Icons.remove,
      delta: up ? kFxPosStep : -kFxPosStep,
      value: value,
      min: p.min,
      max: p.max,
      onChanged: (nv) => cfg.setFx(k, nv),
    );
  }

  /// 滑块档数：按显示格式给一个「一格动一点、又不至于滑不动」的粒度。
  /// ⚠️ `position`（视觉区 v0~v7 的「水平/垂直位置」）刻意比 `percent` 细 20 倍：
  /// 2% 一格在 1080 宽的手机上约 9 个逻辑像素，用户想放的地方会落在档与档之间
  /// （步长常量与 −/+ 按钮共用 `kFxPosStep`，别在这儿再写一个 0.001）。
  int _divisions(FxParam p) {
    final step = switch (p.format) {
      FxFormat.times => 0.05,
      FxFormat.integer => 1.0,
      FxFormat.percent => 0.02,
      FxFormat.position => kFxPosStep,
      FxFormat.px => 1.0,
      FxFormat.sec => 0.5,
      FxFormat.toggle => 1.0,
      FxFormat.color => 1.0, // 颜色不走滑块，不会用到
    };
    return ((p.max - p.min) / step).round().clamp(1, 2000);
  }

  /// 恢复本特效全部参数为默认值（含颜色：颜色参数也在 params 里，一起清掉）。
  /// 视觉区按**当前这一层**的键清（只影响这一层，不牵连同特效的其它层）。
  Future<void> _reset(BuildContext context, FxEffect effect) async {
    final keys = [for (final p in effect.params) _k(p)];
    await AppConfig.instance.resetFx(keys);
    if (context.mounted) {
      ScaffoldMessenger.of(context)
        ..clearSnackBars()
        ..showSnackBar(SnackBar(
          content: Text('「${effect.name}」的参数已恢复默认'),
          duration: const Duration(milliseconds: 1400),
          behavior: SnackBarBehavior.floating,
        ));
    }
  }

  /// 律动类特效的实时预览带：律动长在播放栏顶部，页面背景里看不到，
  /// 所以在底部单独给一条放大的频谱（播放中才会跳）。
  Widget _rhythmPreview(BuildContext context) {
    final player = playerService;
    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: ListenableBuilder(
        // 包一层：开关/播放状态变化时，预览与这条预告文案都要跟着变
        listenable: player == null
            ? AppConfig.instance
            : Listenable.merge([AppConfig.instance, player.changeNotifier]),
        builder: (context, _) {
          final playing = player?.isPlaying ?? false;
          return GlassPanel(
            borderRadius: BorderRadius.circular(16),
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.graphic_eq, size: 14, color: Colors.white54),
                    const SizedBox(width: 6),
                    const Text('实时预览',
                        style: TextStyle(fontSize: 12, color: Colors.white70)),
                    const Spacer(),
                    Text(
                      !AppConfig.instance.spectrumEnabled
                          ? '已关闭'
                          : (playing ? '播放中跳动' : '播放后跳动'),
                      style: const TextStyle(fontSize: 11, color: Colors.white38),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                SizedBox(
                  height: 56,
                  // ⚠️ active 必须跟真实播放状态走（和播放栏、均衡器页同一个道理）：
                  // 没播放时还持有引擎的话，原生 sessionId<0 会退避重试 8 次后彻底放弃
                  // 且不通知 Dart，那之后就算从通知栏起播，律动也整场不动了。
                  child: SpectrumView(
                    active: playing,
                    height: 56,
                    colors: [context.accent, context.accentLight],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
