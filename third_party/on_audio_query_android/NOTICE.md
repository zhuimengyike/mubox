# NOTICE — third_party/on_audio_query_android

**本目录是上游 `on_audio_query_android` 的修改版（vendored fork），不是上游原件。**

| 项 | 值 |
|---|---|
| 上游仓库 | https://github.com/LucJosin/on_audio_query |
| 上游路径 | `packages/on_audio_query_android` |
| 本目录声明的版本 | `1.1.0`（见 `pubspec.yaml` 的 `version:`） |
| 对照快照 | 上游 `main` 分支（该仓库**没有可用的 tag**，见下方「复核说明」） |
| 许可证 | **BSD 3-Clause**（⛔ 不是 MIT） |
| `LICENSE` 状态 | 与上游**逐字节相同**（1520 B，sha256 `DC07AB312EA89942…`，`Copyright (c) 2022, Lucas Josino`）⇒ 未改动，无需替换 |

> ⚠️ **许可证是 BSD 3-Clause，不是 MIT。** 本目录的 `LICENSE` 正文（`Redistribution and use in
> source and binary forms…` + 三条条款）与上游 `packages/on_audio_query_android/LICENSE`
> 逐字节一致 —— 谁要写「本项目依赖的第三方许可证清单」，这里按 **BSD-3-Clause** 记。

### 逐文件对照结果（sha256，逐个文件比）

| 口径 | 数量 |
|---|---|
| 与上游 `main` **逐字节相同** | **33** |
| 有改动 | **3**（`android/build.gradle`、`OnAudioQueryPlugin.kt`、`controllers/PermissionController.kt`） |
| 新增 / 删除 | **0 / 0**（本 `NOTICE.md` 不算上游对照项） |
| 合计 | 上游 36 个文件 = 33 相同 + 3 改动；本地 36 + 1 = 37 |

## 为什么这个 fork 必须留着

`on_audio_query_android` 1.1.0 是 `on_audio_query 2.9.0` 的 Android 端实现，比较老：
在新版 AGP 上**连编译都过不去**（未声明 `namespace`），权限判定在 Android 13+ 上还会误判。
上游 1.1.0 之后没有新版本，只能 fork。主项目用 `pubspec.yaml` 的 `dependency_overrides`
把 `on_audio_query_android` 指向本目录 —— 因此主包 `on_audio_query` 的版本也被**精确锁定**
（不能写 `^`）。

## 改动点（逐文件，与上游 `main` 逐字节对照）

### 1. `android/build.gradle`

| 改动 | 说明 |
|---|---|
| **新增** `namespace 'com.lucasjosino.on_audio_query'` | 上游没有这行，AGP 8+ 直接报错 |
| `compileSdkVersion` **33 → 36** | 对齐主工程工具链 |
| **新增** `compileOptions { sourceCompatibility/targetCompatibility = JavaVersion.VERSION_17 }` 与 `kotlinOptions { jvmTarget = '17' }` | 避免 AGP 9 + Java 21 下 `Inconsistent JVM Target`（Java 默认 11 vs Kotlin 默认 21） |
| **删除** `apply plugin: 'kotlin-android'` | Flutter 的 Built-in Kotlin 已替每个插件 `apply("kotlin-android")`，插件再 apply 一次就是重复：现在只是 WARNING，未来 Flutter 会**直接构建失败**。检测方式是按 build 文件**文本**匹配，所以删掉这一行即根治。⚠️ `buildscript` 里的 KGP classpath **必须保留**（Flutter apply 时要用它） |
| **删除** `rootProject.allprojects { repositories { google(); mavenCentral() } }` | 仓库地址由主工程的 `settings.gradle.kts` 统一提供，插件侧再声明会污染主工程配置 |

### 2. `android/src/main/kotlin/com/lucasjosino/on_audio_query/OnAudioQueryPlugin.kt`

在「没有权限处理器」那个分支里补了一行 `return`。
原版缺这句会继续往下执行 `find()`，触发 `Multiple results` 异常。

### 3. `android/src/main/kotlin/com/lucasjosino/on_audio_query/controllers/PermissionController.kt`

三处改动，都在权限这条线上：

1. **权限数组削到只剩「读音频」**
   - Android 13+（`TIRAMISU`）：**去掉 `READ_MEDIA_IMAGES`**，只留 `READ_MEDIA_AUDIO`
   - Android 12-：**去掉 `WRITE_EXTERNAL_STORAGE`**，只留 `READ_EXTERNAL_STORAGE`
   - 理由：这是个音乐播放器，不读图片、不写外部存储。原版把 `READ_MEDIA_IMAGES` 也算进
     「音频权限」里 ⇒ Android 13+ 上会因它未授予而把整组权限**误判成没授权**。
2. **`retryRequestPermission()` 不再按下标取权限**
   - 原版写死 `permissions[0]` 与 `permissions[1]`；上面的数组被削到只剩 **1** 个元素之后，
     一旦有人传 `retryRequest = true` 走进这里，`permissions[1]` 会抛
     `ArrayIndexOutOfBoundsException`（`||` 短路：只有 `permissions[0]` 的 rationale 为假时才求值右边）。
   - 改成 `permissions.any { ActivityCompat.shouldShowRequestPermissionRationale(activity, it) }`，
     将来加减权限都不会再越界。
3. **「不再询问」时显式回一个结果**
   - 原版在 rationale 为假（用户已选「不再询问」）时**既不 `success` 也不 `error`** ⇒
     Dart 侧 `await permissionsRequest()` **永久挂起**，曲库停在「扫描中」转圈、之后再也不请求权限。
   - 现在显式 `PluginProvider.result().success(false)`，Dart 侧据此进「权限被拒」分支，
     界面才会给出重新授权入口。

### 4. 其余文件与上游逐字节相同

`pubspec.yaml`、`CHANGELOG.md`、`LICENSE`、`README.md`、`android/gradle.properties`、
`android/settings.gradle`、`android/gradle/wrapper/gradle-wrapper.properties`、
`android/src/main/AndroidManifest.xml`，以及 `queries/` · `types/` · `utils/` ·
`consts/` · `interfaces/` · `PluginProvider.kt` 下的全部 Kotlin 文件。

## 行为不变量（改这里之前先读）

- ⛔ **别把 `apply plugin: 'kotlin-android'` 加回来**（理由见第 1 条）。
- ⛔ **别把 `READ_MEDIA_IMAGES` 加回权限数组**：加回去 = Android 13+ 上误判成没权限。
- ⛔ **别按 `permissions[0] / permissions[1]` 这种下标写法取权限**：数组长度会变。
- 上游 `README.md` 里那句「endorsed 实现，正常用 `on_audio_query` 即可、无需手动加进 pubspec」
  对本 fork **已不准** —— 主项目靠 `dependency_overrides` 强制指向本目录。

## 复核说明

这份清单是**逐字节对照**出来的。复核方式（需要能访问 GitHub）：

```bash
git -c core.autocrlf=false diff --no-index --stat \
  third_party/on_audio_query_android <上游 main 的 packages/on_audio_query_android>
```

上游文件可按路径从 `raw.githubusercontent.com` 取：
`https://raw.githubusercontent.com/LucJosin/on_audio_query/main/packages/on_audio_query_android/<路径>`

**两点说明**：
1. 该仓库**没有任何 tag**（`1.1.0` / `on_audio_query_android-v1.1.0` 等写法都取不到），
   所以对照点是 `main` 分支；`main` 上 `pubspec.yaml` 的 `version` 也是 `1.1.0`，
   与本目录声明一致。
2. 本文只写「`main` 分支」，不钉具体 commit SHA。

## 升级时怎么办

见仓库根目录的依赖升级指引 `UPGRADE_NOTES.md`（本目录的改动点以本文件为准）。
