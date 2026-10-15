# NOTICE — third_party/audioplayers_android

**本目录是上游 `audioplayers_android` 的修改版（vendored fork），不是上游原件。**

| 项 | 值 |
|---|---|
| 上游仓库 | https://github.com/bluefireteam/audioplayers |
| 上游路径 | `packages/audioplayers_android` |
| 本目录声明的版本 | `5.3.0`（见 `pubspec.yaml` 的 `version:`） |
| 对照快照 | 上游 tag **`audioplayers_android-v5.3.0`** |
| 许可证 | **MIT** |
| `LICENSE` 状态 | 与上游**逐字节相同**（1066 B，sha256 `D6C0BDBC83E6BB5F…`）⇒ 未改动，无需替换 |

### 逐文件对照结果（sha256，逐个文件比）

| 口径 | 数量 |
|---|---|
| 与上游 tag **逐字节相同** | **13** |
| 有改动 | **9**（见下面「改动点」里的 9 个既有文件） |
| 新增 | **1**（`AudioSessionProvider.kt`；本 `NOTICE.md` 不算上游对照项） |
| 删除 | **0** |
| 合计 | 上游 22 个文件 = 13 相同 + 9 改动；本地 22 + 2 = 24 |

## 为什么这个 fork 必须留着

上游 5.3.0 **不暴露 `MediaPlayer` 的 audio session id**。真实频谱要 `Visualizer` 挂在
**自己这个播放器**的 session 上（Android 12+ 不允许 `Visualizer(0)` 这种全局挂法），
拿不到 id 就只能 fork。主项目用 `pubspec.yaml` 的 `dependency_overrides` 把
`audioplayers_android` 指向本目录 —— 因此主包 `audioplayers` 的版本也被**精确锁定**
（不能写 `^`），否则 `pub upgrade` 会拉到补丁没覆盖的实现。

## 改动点（逐文件，与上游 tag `audioplayers_android-v5.3.0` 逐字节对照）

### 1. 新增文件 `android/src/main/kotlin/xyz/luan/audioplayers/AudioSessionProvider.kt`

上游**没有**这个文件。它是本 fork 真正生效的机制：一张**按播放器身份**登记的
audio session 表。

- `put(playerId: String, session: Int)` —— 写入入口，同时更新兼容格子
- `sessionOf(playerId: String?): Int` —— 查询入口，查不到返回 `-1`
- `forget(playerId: String)` —— `MediaPlayer` release 时撤销登记
- `var sessionId: Int = -1`（`private set`）—— 兼容格子：只有 `put` 能写，
  语义仍是**旧事实**「谁最后写谁占」，留给不带身份的旧调用点

### 2. `player/MediaPlayerWrapper.kt`

- 新增 `import xyz.luan.audioplayers.AudioSessionProvider`
- `setSource()` 里 `setDataSource` 之后登记一次：`AudioSessionProvider.put(wrappedPlayer.playerId, mediaPlayer.audioSessionId)`
- `setOnPreparedListener` 里再兜底登记一次（同样的 `put`）—— 共 **2 处写入**
- `release()` 里 `AudioSessionProvider.forget(wrappedPlayer.playerId)`
- 新增 `override fun getAudioSessionId(): Int = mediaPlayer.audioSessionId`

> 为什么要写两次：`MediaPlayer` 刚构造、还没 `setDataSource` 时 `getAudioSessionId()` 返回 **0**，
> 拿 0 去 `Visualizer(0)` 会在 Android 12+ 抛 `ERROR_INVALID_OPERATION(-3)`。所以第一次登记
> 压在 `setDataSource` 之后，`onPrepared` 再覆盖一次确保稳定有效。

### 3. `player/PlayerWrapper.kt`

接口新增一行 `fun getAudioSessionId(): Int`。

### 4. `player/SoundPoolPlayer.kt`

新增 `override fun getAudioSessionId(): Int = -1`（SoundPool 没有独立 session）。

### 5. `player/WrappedPlayer.kt`

- 构造函数新增**第一个**参数 `val playerId: String`（Dart 侧 `AudioPlayer.playerId`，
  全进程唯一）—— 它是上面那张登记表的键
- 新增焦点被拒的收尾回调 `onDenied`（见第 7 条）
- `pause()` 里新增 `focusManager.cancelPendingRetry()`

### 6. `AudioplayersPlugin.kt`

`create` 分支把身份一路传下去：
`players[playerId] = WrappedPlayer(playerId, this, eventHandler, …)`（上游没有第一个参数）。

### 7. `player/FocusManager.kt` —— 焦点被拒 ⇒ 有界重试，用尽才认输

上游 `handleFocusResult()` **只有** `AUDIOFOCUS_REQUEST_GRANTED / LOSS_TRANSIENT / LOSS`
三个分支，`when` 没有 `else` ⇒ 系统回 `AUDIOFOCUS_REQUEST_FAILED` 时**一个回调都不跑**。
而 `WrappedPlayer` 里 `onGranted` 是全类唯一会 `player.start()` 的地方 ⇒
`MediaPlayer` 永不 start，但 `playing` 早已是 true、Dart 侧也无条件把状态置成 playing
⇒ **界面显示在播、喇叭一声不响**。

- 新增抽象属性 `onDenied: () -> Unit`；工厂方法 `create(...)` 多收一个参数
- 新增 `private val RETRY_DELAYS_MS = longArrayOf(250L, 750L, 2000L)`
  （**表长 = 重试次数**；共 3 次重试、总窗口 ≈3s）
- 新增 `retryOrDeny()` / `cancelPendingRetry()` / `retryRunnable`
- `handleFocusResult()` 新增分支 `AudioManager.AUDIOFOCUS_REQUEST_FAILED -> retryOrDeny()`；
  `GRANTED` 分支里补 `cancelPendingRetry()`
- `LegacyFocusManager.handleStop()` / `ModernFocusManager.handleStop()` 各补一次 `cancelPendingRetry()`
- ⚠️ **`AUDIOFOCUS_REQUEST_DELAYED`（=2）刻意不处理**：本插件从不调
  `setAcceptsDelayedFocusGain(true)`，系统只在请求显式接受延迟授予时才可能回它 ⇒ 不可达

### 8. `WrappedPlayer.kt` 的 `onDenied` 实现（与第 5 条同一文件）

```kotlin
onDenied = {
    playing = false
    handleError("AudioFocusDenied", "系统拒绝了音频焦点（可能被其他应用占用或被系统策略限制），已停止播放", null)
}
```

刻意**不**在没有焦点时照样 `start()`：那既违反 Android 焦点约定（会盖着别的 App 抢声），
也救不了「后台被 ROM mute」的场景 —— 只是把「没声音」变得更理直气壮。

### 9. `pubspec.yaml`

删掉上游 monorepo 专用的一行 `resolution: workspace`（脱离 monorepo 单独成包时不能留）。

### 10. `analysis_options.yaml`

上游的 `include: package:flame_lint/analysis_options.yaml` 换成两行注释：
主项目不依赖 `flame_lint`，留着会让 `flutter analyze` 报 `include_file_not_found`。

### 11. `android/build.gradle`

删掉上游的 `rootProject.allprojects { repositories { google(); mavenCentral() } }` 块
与文件末尾的 `repositories { mavenCentral() }`（仓库地址由主工程的
`settings.gradle.kts` 统一提供，插件侧再声明一次会污染主工程的仓库配置）。

## 行为不变量（改这里之前先读）

- **`AudioSessionProvider` 是按播放器身份查的表**，不是「全进程一个格子」。
  双播放器 / 队列预取时谁也抢不走谁的 session。
  ⚠️ 兼容格子 `sessionId` 仍在，语义仍是「谁最后写谁占」——
  **引擎永远不许读兼容格子**，必须走 `sessionOf(playerId)`。
- ⛔ **别删 `AUDIOFOCUS_REQUEST_FAILED` 分支**：没有它 `onGranted` 不跑 ⇒
  `MediaPlayer` 永不 `start()`，而 Dart 已把状态置成 playing ⇒ 用户看到「在播但没声」。
- ⛔ **`pause()` 里那句 `cancelPendingRetry()` 不能删**：否则一次「用户自己按的暂停」
  会因为重试用尽而弹出一条「焦点被拒」的错误提示。
- **丢掉这个 fork 时，主项目 Dart 侧要一起复查**：`lib/player_service.dart` 把
  `AudioFocusDenied` 接到 `lastError`（播放栏 SnackBar + UI 转暂停），
  对应的用例在 `test/player_service_audio_focus_test.dart`。
- ⚠️ `getAudioSessionId()`（第 2~4 条）在主项目里**零调用点**，属于对外暴露的能力，
  不是生效路径；**真正生效的是 `AudioSessionProvider`**。别去 Dart 侧找它的调用方。

## 怎么复核这份清单

这份清单是**逐字节对照**出来的，不是从注释里抄的。复核方式（需要能访问 GitHub）：

```bash
git -c core.autocrlf=false diff --no-index --stat \
  third_party/audioplayers_android <上游 tag audioplayers_android-v5.3.0 的 packages/audioplayers_android>
```

上游文件可按路径从 `raw.githubusercontent.com` 取：
`https://raw.githubusercontent.com/bluefireteam/audioplayers/audioplayers_android-v5.3.0/packages/audioplayers_android/<路径>`

## 升级时怎么办

见仓库根目录的依赖升级指引 `UPGRADE_NOTES.md`（本目录的改动点以本文件为准）。
