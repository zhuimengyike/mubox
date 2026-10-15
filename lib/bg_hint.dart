/// 「允许后台运行」一次性引导的判定 —— **纯逻辑，零 Flutter 依赖**（可纯 Dart 单测）。
///
/// 规则：**没提示过** 且 **还没拿到后台运行授权** ⇒ 该弹一次；其余一律不弹。
/// 只判这两个输入，是因为「一辈子只弹一次」这件事**必须靠落盘**
/// （`AppConfig.bgHintShown` ← SharedPreferences `bg_hint_shown`），
/// 不能靠内存字段：内存里置位、进程一重启就没了，用户会被反复骚扰。
///
/// 四行真值表 + 一条负向（「把落盘那一步收起来 ⇒ 同一场景重启后又弹」）
/// 都有单测钉住。
library;

/// [alreadyShown] 之前已经提示过（**从 prefs 读回来的**，不是内存里的临时值）
/// [granted]      已经拿到后台运行 / 忽略电池优化的授权
bool shouldShowBgHint({required bool alreadyShown, required bool granted}) =>
    !alreadyShown && !granted;
