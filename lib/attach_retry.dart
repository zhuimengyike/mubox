/// 音效「挂载状态」的**纯判定**（零 Flutter 依赖，可纯 Dart 单测）。
///
/// 背景：`LoudnessEnhancer` 挂到**新建的音频会话**上会**间歇性**失败 ——
/// 原生日志 `loudness attach failed: Cannot initialize effect engine for type:
/// fe3199be-aed0-413f-87bb-11260eb63cf1 Error: -3`，其中 `-3` 是
/// `AudioEffect.ERROR_NO_INIT`（AOSP `AudioEffect.java`：Operation failed due to
/// bad object initialization）。**同一台机器、同一个 effect 型号**换一个 session
/// 却挂得上（`dumpsys media.audio_flinger` 里能看到同型号在别的 session 注册成功）
/// ⇒ **不是「这台设备没有这个接口」，是「这一次没挂上」。**
///
/// 而这两件事在 UI 上原本是**同一个样子**：原生 `info()` 只回报
/// `loudSupported = (loud != null)`，`sound_effects_page.dart` 据此
/// ① 把开关显示成 off、② 把开关 `onChanged` 置 null（**点不动**）、
/// ③ 卡片文案写「这台设备没有提供响度增强接口」。
/// ⇒ 用户被误导，而且**失去了自救入口**（拨不动开关 ⇒ 触发不了重挂）。
///
/// 这个文件把那三种状态分开，并且**刻意让「没试过」落回原来的样子**
/// （`unknown` = 禁用 + 原文案），这样「正常路径观感零变化」是结构性的。
///
/// 三态真值表 / 开关可点性 / 文案分流都有单测钉住（每条都带正负一对）；
/// 方法通道真的带上了 `playerId` 也有断言守着。
library;

/// 一个 effect 的「挂载状态」：
/// * [unknown] —— 这一次**根本没试过**（没播放过 / 会话还没就绪）。**这是唯一允许
///   说「设备没有提供接口」的状态**：只有真去挂了一次且确定性地被拒，才谈得上"没有"。
/// * [failed] —— 试过了、**挂失败了**。原因未定 ⇒ 不许断言硬件没有，要可重试。
/// * [ok] —— 挂上了。
enum AttachState { unknown, failed, ok }

/// 原生 `info()` 的两个布尔回报 → [AttachState]。
///
/// ⚠️ 判定顺序是刻意的：`supported == true` 时 `failed` 必须被忽略
/// （老版本原生不回报 `*AttachFailed`，值会是 false，天然落到 [ok] / [unknown]）。
AttachState attachStateOf({
  required bool supported,
  required bool attachAttempted,
  required bool attachFailed,
}) {
  if (supported) return AttachState.ok;
  if (attachAttempted && attachFailed) return AttachState.failed;
  return AttachState.unknown;
}

/// 「拨开关」这条路能不能补救 —— 只有 [AttachState.failed] 能。
///
/// * [AttachState.ok] 不用补救（本来就挂着）；
/// * [AttachState.unknown] 要**保持改动前**的禁用行为：那时候说"没有提供接口"
///   虽然也不够准，但**没有任何证据**说它其实支持，放开开关只会让用户
///   对着一个按不动的功能乱点。宁可保守。
bool loudRetryable(AttachState s) => s == AttachState.failed;

/// 响度开关**能不能点**。`available == false` 时整块卡片根本不渲染
/// （`sound_effects_page.dart` 会走 `_notAttached`），所以那种情况返回 false 只是兜底。
///
/// 硬支持条件仍是 `available && (supported || 可重试)`，其中 `supported`
/// 就是 `s.loudSupported`（= 原生 `loud != null`）⇒
/// **正常路径（挂上了 / 从没试过）行为不变。**
bool loudSwitchEnabledFor({
  required bool available,
  required bool supported,
  required AttachState state,
}) => available && (supported || loudRetryable(state));

/// 响度开关**显示成什么**（`Switch.value`）。
///
/// ⚠️ 开关"显示为开"仍然只认 [supported] —— 拨到 on 而 native 挂不上，
/// 显示成 on 就是**骗人**（原来的老毛病）。开关可点 ≠ 开关显示为开：
/// 点一下 ⇒ 走一次真实重挂 ⇒ 成功之后 `supported` 变 true，这时才翻过去。
bool loudSwitchValueFor({
  required bool supported,
  required bool enabled,
}) => supported && enabled;

/// 卡片说明该说哪一句。
///
/// * [AttachState.ok] / [AttachState.unknown] ⇒ 返回空串，由页面走**改动前那两句原文**
///   （一字不改 ⇒ 观感零变化是结构性的）；
/// * [AttachState.failed] + `retryable` ⇒ 只说「这一次没挂上」+ 告诉用户怎么办。
///   ⛔ 绝不许把「暂时失败」说成「硬件没有」；
/// * [AttachState.failed] + `retryable` + **[retryExhausted]** ⇒ 同上，但要**说清已经用满**
///   以及**什么会重新给机会**（换歌 = 新 session，原生那边预算归零）。
///   ★ 这一段是「点不开 ⇒ 连点」那个风暴的**止血另一半**：失败之后必须给一个
///   **看得见、且稳定**的说法，否则用户只能靠反复点开关来试探 —— 而每一次点
///   在原生侧都是一次真实重挂（极端情况下 3 秒能点上 7 次，每次都在出声中途拆效果链）。
///   ⛔ 这里**只改文案**，不许顺手把开关禁掉：既定方案是「保留开关 + 再试一次」，
///   把这一项标成不可用就是换个方向的谎报。
/// * [AttachState.failed] + **不** `retryable`（= `IllegalArgumentException`，
///   `ERROR_BAD_VALUE`：这个 effect 类型压根不被支持）⇒ 返回空串，让页面说
///   「这台设备没有提供响度增强接口」—— 这一句**在这个分支上是真话**，
///   不为了"统一"去改一句本来就说对了的文案。
String loudCardDesc(
  AttachState state, {
  required bool retryable,
  bool retryExhausted = false,
}) {
  if (state != AttachState.failed || !retryable) return '';
  if (retryExhausted) {
    return '响度增强连着几次都没能挂上（音效引擎初始化失败）\n'
        '这条输出上一直起不来 —— 不是这台设备没有这个接口；\n'
        '换一首歌重新播放会自动再试几次，不用杀后台';
  }
  return '这次没能挂上响度增强（音效引擎初始化失败）\n点右边的开关再试一次就行';
}
