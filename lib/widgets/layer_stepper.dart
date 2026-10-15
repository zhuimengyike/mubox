/// 视觉区「层数」共用控件：`当前特效「爱心」· 共 2 层   −   ＋`
///
/// **一份实现、两处共用**：
/// * `pages/effect_page.dart` —— 挂在**「视觉特效」那个区级开关下面**；
/// * `pages/custom_page.dart` 的**视觉区页面** —— 挂在区开关下面。
///
/// ⚠️ **它和上面那个开关不是一回事**：那个开关管的是**整片视觉区**（所有层一起），
/// 这个控件管的是**当前这个特效有几层**。所以文案里必须把两件事分开说，
/// ⛔ 别让用户以为那个开关只管当前这个特效。
///
/// 行为（⛔ 别在这里新写加/删层逻辑，一律走 `AppConfig` 已有的入口）：
/// * **＋** = 弹 [showFxEffectPicker]：**从全部 8 个视觉特效里挑一个**加上
///   （挑当前这个 = 再叠一层同款），走 [AppConfig.addVisualLayer] 并自动选中新那层。
///   ⚠️ 原先是「直接给当前特效再加一层同款」—— 那让用户**找不到「挑另一个特效」的入口**
///   （用户原话：「选了一个特效之后不让选第二种特效」）；
/// * **－** = [AppConfig.removeVisualLayer]（删掉**当前选中的那一层**）。
///
/// ★ 两个方向都**先判断再拒绝 + 给提示**：满 [kMaxVisualLayers] 层、
/// 或整区只剩 1 层时，点了必须**说一句话**，⛔ 绝不做成「点了没反应的死按钮」
/// （这是这个仓最忌的形状）。
library;

import 'package:flutter/material.dart';

import '../app_config.dart';
import '../effect_catalog.dart';
import 'fx_effect_picker.dart';

class LayerStepper extends StatelessWidget {
  const LayerStepper({super.key, required this.effect, this.onChanged});

  /// 当前这个特效：用来写文案（本特效有几层），也是选择器里那个「挑当前这个」的落点。
  final FxEffect effect;

  /// 层数真的变了之后的回调（特效设置页用它把编辑目标跟到新层上）。
  final VoidCallback? onChanged;

  /// 「＋」= **从 8 个视觉特效里挑一个**加上（⛔ 不再是「给当前特效加一层同款」）。
  /// 到上限**先拒绝 + 说话**，不弹选择器（不做点了没反应的死按钮）。
  ///
  /// 🔴 **`messenger` 必须在第一个 `await` 之前抓好**（同 `effect_page._deleteLayer` 的样板）：
  /// 加层会让**层数变多**、特效设置页里那个「切层入口」随插进来，而 `ListView` 的子项
  /// **没有 key** ⇒ 本控件那个 element 会被**重建**、`context` 当场失效。
  /// ⚠️ 所以 ⛔ 不能写「先 `if (!context.mounted) return;` 再 `onChanged?.call()`」——
  /// 那一句会把 `onChanged` 一起吞掉：设置页标题会停在「万花筒 · 第 1 层」
  /// 而下面的切层入口已经写着「第 1/2 层」（有单测钉住这条）。
  /// `onChanged` 回调只碰 State（不是 context），所以**先调它**，提示走抓好的 messenger。
  Future<void> _add(BuildContext context) async {
    final cfg = AppConfig.instance;
    final messenger = ScaffoldMessenger.of(context);
    if (cfg.visualLayers.length >= kMaxVisualLayers) {
      // 到上限：addVisualLayer 会返回 false（它自己不弹东西）⇒ 这里先说一句话
      _toast(messenger, '最多叠 $kMaxVisualLayers 层，先删掉一层再加吧');
      return;
    }
    final picked = await showFxEffectPicker(context);
    if (picked == null) return;
    final ok = await cfg.addVisualLayer(picked.index);
    if (!ok) {
      _toast(messenger, '最多叠 $kMaxVisualLayers 层，先删掉一层再加吧');
      return;
    }
    // ★ 先通知页面跟到新层（它只 setState，不碰这个 context）
    onChanged?.call();
    // 挑的是同一款时尤其要说一句 —— 否则画面只多一层同样的，像「没反应」
    _toast(messenger, '已加上「${picked.name}」（视觉区 ${cfg.visualLayers.length} 层）');
  }

  Future<void> _remove(BuildContext context) async {
    final cfg = AppConfig.instance;
    final messenger = ScaffoldMessenger.of(context); // 同上：await 之前抓好
    if (cfg.visualLayers.length <= 1) {
      // 只剩一层：removeVisualLayer 会直接 return（**点了没反应**）⇒ 先拦下来说话
      _toast(messenger, '视觉区至少要留一层 —— 想整片关掉请用上面的「视觉特效」开关');
      return;
    }
    await cfg.removeVisualLayer(cfg.visualLayerSel);
    onChanged?.call();
  }

  void _toast(ScaffoldMessengerState messenger, String msg) {
    messenger
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        duration: const Duration(milliseconds: 1800),
        behavior: SnackBarBehavior.floating,
      ));
  }

  @override
  Widget build(BuildContext context) {
    final cfg = AppConfig.instance;
    final n = cfg.visualLayers.length; // 视觉区**总共**几层（决定 +/− 的边界）
    final mine = cfg.visualLayers.where((l) => l.effect == effect.index).length;
    final primary = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('当前特效「${effect.name}」· 共 $mine 层',
                  style: const TextStyle(fontSize: 13, color: Colors.white)),
              const Text('「＋」从 8 个特效里挑一个加上，「−」删掉当前选中的那一层',
                  style: TextStyle(fontSize: 11, color: Colors.white38)),
            ],
          ),
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 22,
          tooltip: '删掉当前选中的那一层',
          icon: Icon(Icons.remove_circle_outline,
              color: n > 1 ? Colors.white70 : Colors.white30),
          onPressed: () => _remove(context),
        ),
        Text('$n/$kMaxVisualLayers',
            style: TextStyle(fontSize: 12, color: primary)),
        IconButton(
          visualDensity: VisualDensity.compact,
          iconSize: 22,
          tooltip: '从 8 个视觉特效里挑一个加上',
          icon: Icon(Icons.add_circle_outline,
              color: n < kMaxVisualLayers ? Colors.white70 : Colors.white30),
          onPressed: () => _add(context),
        ),
      ],
    );
  }
}
