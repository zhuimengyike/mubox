/// 视觉特效选择器：点「＋」时**从全部 8 个视觉特效里挑一个**加上去。
///
/// ## 它替掉的是什么
/// 原来的「＋」是「给**当前这个**特效再加一层同款」（`addVisualLayer(当前特效)`）——
/// 功能没坏，但**没有「挑另一个特效」的入口**，表现就是「选了 A 就加不了 B」，
/// 开了第二个之后也没法再调整第一个。
/// 这里**列出全部 8 个**（⛔ 不是只列还没开的）：
/// * 挑**别的**特效 ⇒ 视觉区多出它的第一层（已有那些层一个都不动）；
/// * 挑**当前这个** ⇒ 等价于「给它再加一层」（老需求一并留着）；
/// * 每行右侧写清它**现在有几层**，挑之前一眼看得见。
///
/// ⚠️ 到上限（[kMaxVisualLayers]）由调用方**先拒绝 + 说话**，本弹层不负责拦。
library;

import 'package:flutter/material.dart';

import '../app_config.dart';
import '../effect_catalog.dart';
import 'glass_panel.dart';

/// 打开选择器；返回用户挑的那个特效。点空白/下滑关掉返回 null。
///
/// ⚠️ `isScrollControlled: true` + 高度上限：**8 行要能一次看全**（默认弹层高度只有
/// 屏高的 9/16，8 行会被截掉两行 ⇒ 量不到、用户也得先滑一下才知道有哪 8 个）。
Future<FxEffect?> showFxEffectPicker(BuildContext context) {
  return showModalBottomSheet<FxEffect>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(ctx).size.height * 0.8,
      ),
      child: const FxEffectPickerSheet(),
    ),
  );
}

/// 弹层本体（单独成 widget：测试要靠 `byType` 把它和页面上的同名文字分开）。
class FxEffectPickerSheet extends StatelessWidget {
  const FxEffectPickerSheet({super.key});

  @override
  Widget build(BuildContext context) {
    final cfg = AppConfig.instance;
    final primary = Theme.of(context).colorScheme.primary;
    final cur = cfg.selectedVisualLayer.effect;
    final total = cfg.visualLayers.length;
    return GlassPanel(
      borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 14, 20, 0),
              child: Text('挑一个视觉特效加上',
                  style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Colors.white)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
              child: Text(
                '挑当前这个 = 再叠一层同款；视觉区现有 $total/$kMaxVisualLayers 层',
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 14),
                children: [
                  for (final e in Fx.of('v'))
                    _row(context, e, cfg, primary, selected: e.index == cur),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一行特效：图标 + 名字 + **它现在有几层**；当前选中的那个高亮。
  Widget _row(BuildContext context, FxEffect e, AppConfig cfg, Color primary,
      {required bool selected}) {
    final n = cfg.visualLayers.where((l) => l.effect == e.index).length;
    return InkWell(
      key: ValueKey('fxpick_${e.index}'),
      onTap: () => Navigator.pop(context, e),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: selected ? primary.withValues(alpha: 0.18) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? primary : Colors.white12),
        ),
        child: Row(
          children: [
            Icon(e.icon, size: 20, color: selected ? primary : Colors.white70),
            const SizedBox(width: 10),
            Expanded(
              child: Text(e.name,
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : Colors.white70)),
            ),
            // ★ 层数写在行里：用户挑之前就能看出「这个已经开了几层」
            Text(n > 0 ? '已开 $n 层' : '还没有层',
                style: TextStyle(
                    fontSize: 11, color: n > 0 ? primary : Colors.white30)),
          ],
        ),
      ),
    );
  }
}
