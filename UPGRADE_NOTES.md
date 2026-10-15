# Mu Box 手机版 — 依赖升级指引

> 本项目有两个「打过补丁的本地依赖」（`third_party/`），是**升级 Flutter / AGP 时最容易崩**的地方。
> 这份文档说明它们为何必须保留、升级的标准流程，以及有哪些**与主项目耦合**的地方要一起复查。
>
> **每个补丁具体改了哪些文件、每一处改了什么**，以各目录自己的 `NOTICE.md` 为准（单一真相源，
> 本文不抄第二份）：
>
> - [`third_party/audioplayers_android/NOTICE.md`](third_party/audioplayers_android/NOTICE.md)
> - [`third_party/on_audio_query_android/NOTICE.md`](third_party/on_audio_query_android/NOTICE.md)
>
> 另外请一并读 `pubspec.yaml` 里 `dependency_overrides` 那段注释。

---

## 1. 为什么有两个本地补丁

| 补丁 | 对应上游实现 | 版本 | 为什么必须补 |
|---|---|---|---|
| `third_party/on_audio_query_android` | `on_audio_query_android` | 1.1.0 | ① 未声明 `namespace`，AGP 8+ 直接报错；② 权限数组误含 `READ_MEDIA_IMAGES`，Android 13+ 会把「音频权限」误判成没授权；③ 权限请求在「不再询问」时不给任何回调，Dart 侧会永久挂起；④ 上游很久没更新，对新 AGP / Java 不完全兼容 |
| `third_party/audioplayers_android` | `audioplayers_android` | 5.3.0 | ① 未暴露 `MediaPlayer` 的 **audio session id**，真实频谱（`Visualizer` 必须挂到「自己这个播放器」的 session 上）拿不到 id；② 焦点被拒（`AUDIOFOCUS_REQUEST_FAILED`）时**一个回调都不跑** ⇒ 播放器永不 `start()`，而 Dart 侧已经把状态置成 playing ⇒ 界面显示在播、却一声不响 |

依赖关系：`pubspec.yaml` 用 `dependency_overrides` 把这两个实现指向本地副本，因此主包
（`on_audio_query`、`audioplayers`）的版本**只能精确锁定**（不能写 `^`）。否则
`flutter pub upgrade` 会把实现悄悄升到补丁没覆盖的版本，表现为**编译报错**或
**频谱 / 扫描静默失效**。

---

## 2. 升级时必须一起复查的耦合点

补丁改动本身的清单在各自的 `NOTICE.md`，这里只列**跨仓库、容易漏**的部分：

- **`audioplayers_android` 的焦点补丁 ↔ Dart 侧接线**
  Dart 侧 `lib/player_service.dart` 把原生回上来的 `AudioFocusDenied` 接到
  `PlayerService.lastError`（播放栏弹 SnackBar + UI 转暂停），对应的用例在
  `test/player_service_audio_focus_test.dart`。
  ⇒ **若某天上游自己修好了焦点拒绝、这个 fork 被丢掉，Dart 侧那段错误接线要一起复查**
  （留着无害，但别以为原生还在报那条错误）。
- **`audioplayers_android` 的 session 登记表 ↔ 三个原生引擎**
  `android/app/src/main/kotlin/**` 下的 `SpectrumEngine.kt` / `EqualizerEngine.kt` /
  `ExtraEffectsEngine.kt` 都直接 `import xyz.luan.audioplayers.AudioSessionProvider`，
  按**播放器身份**查 session。⇒ 换实现时，这三个引擎的取 session 方式要同步改。
  `test/audio_session_test.dart` 按**内容锚点**读那 5 个 `.kt` 与 `AudioSessionProvider.kt`
  —— 改这些文件时别把锚点字符串改掉。
- **`on_audio_query_android` 的权限数组 ↔ 主工程 Manifest**
  主工程的 `android/app/src/main/AndroidManifest.xml` 只声明「读音频」相关权限，
  与补丁后的权限数组一一对应。加权限别只改一边。
- **`on_audio_query_android` 不许自己 `apply plugin: 'kotlin-android'`**
  Flutter 的 Built-in Kotlin 已经替每个插件 apply 过了，插件再 apply 一次就是重复
  （现在只是 WARNING，未来 Flutter 会直接构建失败）。
  ⚠️ `buildscript` 里的 KGP classpath **必须保留**。

---

## 3. 升级 Flutter / AGP 的标准流程

升 `flutter`（或改 `compileSdk` / AGP）前**不要**先改 `pubspec.yaml`。按这个顺序：

1. **升级主包版本**（`pubspec.yaml`）：
   - 若新 `audioplayers` 已原生暴露 session id、且已修好焦点被拒 → 可**删掉**
     `third_party/audioplayers_android` 这个 override（同时按第 2 节复查 Dart 侧接线）；
   - 若新 `on_audio_query`（或 fork）已声明 `namespace` + 修好权限 → 可**删掉**
     `third_party/on_audio_query_android` 这个 override；
   - 否则仍保留 override，但把主版本放开到**目标版本**，再逐条核对补丁是否仍适用。
2. **重打补丁**：对着两个 `NOTICE.md` 的清单，把
   `namespace / compileSdk / JVM target / 权限数组 / AudioSessionProvider / 焦点重试`
   重新落到 `third_party/` 的新版本副本上
   （可先 `flutter pub get` 拉新实现，再拷进 `third_party/` 改）。
3. **构建验证**：`./build_release.sh` 或 `.\build_release.ps1`。两个脚本内置**三道装包后体检**，
   任一不过就非 0 退出、拦住 `adb install`：
   - **资源体检**：`android/app/src/main/res/raw/keep.xml` 名单里的 **8 个 drawable** 是否还在包里
     （被 `shrinkResources` 删掉的话，通知栏会没卡片 + 播放被系统静音）；
   - **版本体检**：APK 的 `versionName` / `versionCode` 与 `pubspec.yaml` 的 `version:` 是否一致；
   - **签名体检**：APK 的实际证书指纹是否等于 **`MUBOX_EXPECT_SIGNER_SHA256`** 环境变量
     里填的值（脚本不再内置任何人的指纹）。**这个变量没设时只打印实际指纹、不拦构建**；
     设了而不符就非 0 退出。要把它当门禁用，就在自己的 shell 里 export 自己的指纹：
     `.sh` 与 `.ps1` 读的是**同一个**环境变量。
4. **频谱实测**（关键）：装上后打开一首歌，看播放栏频谱是否**满格 / 起伏**。若频谱静默或全满，
   多半是 `AudioSessionProvider` 那份登记没被写进去（fork 的补丁丢了），或 `Visualizer`
   attach 到了 0 / 错误的 session。原生退避重试用尽时会通过 EventChannel 回
   `SPECTRUM_UNAVAILABLE` 错误，logcat 里也能看到 `SpectrumEngine: 重试 8 次仍失败`。
5. **回归核心**：扫描、歌单顺序、一键导出、歌词校准、交叉淡变。

> 升级成功后把 `pubspec.lock` 一并提交，并核对两个 `NOTICE.md` 里的清单是否还准确
> （不一致就地更新 `NOTICE.md`，别只改代码）。
