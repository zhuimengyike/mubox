/// 氛围层「动画到底跑不跑」的判定 —— **纯函数，零 Flutter 依赖**（可纯 Dart 单测）。
///
/// 为什么要抽出来：`AmbientLayer()` 被 8 个页面共用（1 处真背景 + 7 处**非真背景**），
/// 而「暂停时冻结」这条只对真背景成立 —— 设置页里的氛围层是**特效预览**，用户经常
/// 「暂停着调特效」，预览一冻结就会被当成「特效坏了」。判定混在 `_syncAnimation`
/// 的布尔表达式里没法单测，所以整条规则抽成这里的纯函数。
///
/// ⚠️ **两个身份参数都取缺省值时，结果必须逐项等于**
/// `screenOn && (heartEnabled || rainEnabled || edgeEnabled)` ——
/// 没传这两个参数的调用点靠它保证观感不变（真值表单测钉住）。
library;

/// [screenOn]      App 在前台（锁屏/退后台为 false —— 旧行为：停）
/// [hasAnyEffect]  爱心/雨滴/边框任一开着（全关时没什么可画 —— 旧行为：停）
/// [playing]       播放器正在播
/// [hasSong]       当前有歌。用来把「暂停」和「冷启动还没开始听」分开：
///                 没有歌的时候保持旧观感照跑，只有**真的把某首歌暂停了**才冻结
/// [isPreview]     这一处**不是全局真背景**（特效预览页 / 次要页面）⇒ **永不冻结**
/// [freezeOnPause] 这一处要不要在暂停时冻结（只有 root_page 的真背景传 true）
///
/// ⚠️ 两个身份参数的缺省值（`isPreview: false, freezeOnPause: false`）让结果
/// **逐项等于** 那句 `screenOn && (heartEnabled || rainEnabled || edgeEnabled)`，
/// 所以「没传参的调用点」观感与旧的整数开关行为逐帧一致。
bool shouldAnimate({
  required bool screenOn,
  required bool hasAnyEffect,
  required bool playing,
  required bool hasSong,
  required bool isPreview,
  required bool freezeOnPause,
}) {
  if (!screenOn || !hasAnyEffect) return false;
  if (isPreview) return true; // 预览永不冻结：暂停着调特效是常规操作
  if (!freezeOnPause) return true; // 没开启冻结 ⇒ 改动前行为
  if (!hasSong) return true; // 还没放过歌：不算「暂停」，保持旧观感
  return playing;
}
