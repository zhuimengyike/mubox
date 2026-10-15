# Mu Box 手机版 —— 一键构建（Android release，走国内镜像 + 跳过版本检查）。
#
# 用法（在**项目根目录**下执行）：
#   .\build_release.ps1            # 只构建 APK（含装包后体检：资源 + 版本 + 签名）
#   .\build_release.ps1 -Install   # 构建 + 体检 + adb install -r（保留数据覆盖安装）
#   .\build_release.ps1 -Install -AllowMissingTools   # 逃生门：体检工具找不到时也放行
#                                                     # （**只**放过「工具缺失」，签名不符 / 资源缺失照样拦）
#
# 为什么要固化这些参数：
#   - --no-version-check：网络到 GitHub 不可达时，flutter 启动会卡在版本检查（看起来像假死）。
#   - 镜像 PUB_HOSTED_URL / FLUTTER_STORAGE_BASE_URL：依赖走 flutter-io.cn。
#   - --target-platform android-arm64：单架构体积最小（fat APK 53M -> ~18.7M）。
#   - 首次构建 Gradle 要下载依赖较慢（10 分钟级）；之后守护进程常驻，二次构建会很快。
#
# 注意：
#   - 绝不使用 `flutter install`（会先卸载再装，清空 App 私有数据）。
#   - 正常构建别去 gradlew --stop，保留 Gradle 守护进程可加速后续构建。
#
# Android SDK 位置按这个顺序找：$env:ANDROID_SDK_ROOT / $env:ANDROID_HOME →
# android\local.properties 的 sdk.dir → $env:MUBOX_ANDROID_SDK。
# ⛔ 别把本机绝对路径写进这个脚本，要兜底就设 MUBOX_ANDROID_SDK 环境变量。
param(
    [switch]$Install,
    [switch]$AllowMissingTools
)

$ErrorActionPreference = 'Stop'
$env:PUB_HOSTED_URL = 'https://pub.flutter-io.cn'
$env:FLUTTER_STORAGE_BASE_URL = 'https://storage.flutter-io.cn'

# ==================== release 资源体检 ====================
# 为什么要有这道体检：Flutter release 默认 isShrinkResources=true，而 AGP 只扫 dex 引用、
# 扫不到 libapp.so（AOT 快照）里的 Dart 字符串 —— 凡是「资源名只写在 Dart 字符串里」的插件
# drawable 都会被当垃圾**静默删掉**：不报错、不崩溃，装到手机上才发现。
# audio_service 的 7 个通知按钮图标就是这么没的（iconId=0 → CustomAction.build() 每 500ms
# 抛异常 → MediaSession 恒 state=NONE → 通知栏没卡片 + 播放被系统静音）。
# 修法 = android/app/src/main/res/raw/keep.xml；这里做「装包后验收」，少一个就非 0 退出。
# ⚠️ 这份清单与 build_release.sh 保持一致：keep.xml 里加图标时两个脚本都要改。
$ExpectedRes = @(
    'drawable/audio_service_fast_forward',
    'drawable/audio_service_fast_rewind',
    'drawable/audio_service_pause',
    'drawable/audio_service_play_arrow',
    'drawable/audio_service_skip_next',
    'drawable/audio_service_skip_previous',
    'drawable/audio_service_stop',
    'drawable/ic_stat_music'
)

# ==================== 装机前签名体检 ====================
# 为什么要有这道体检：`android/key.properties` 不存在时 android/app/build.gradle.kts 会回退
# 到 signingConfigs.debug。debug keystore 一旦被删/重建（换机器、清过 ~\.android 都会发生），
# 签名就变了，`adb install -r` 必报 INSTALL_FAILED_UPDATE_INCOMPATIBLE —— 物理上无法覆盖安装，
# 只能走「App 内导出备份 → 卸载（App 私有数据全清）→ 装新版 → 从 zip 恢复」。
# 与其等 adb 报错（那时已经要面对清数据），不如在装机前拿 APK 的**实际证书指纹**比一比。
#
# 目标是哪个签名，判定条件与 android/app/build.gradle.kts 的 hasReleaseSigning **逐字一致**：
#   android/key.properties 不存在 → 走 debug 签名  （%USERPROFILE%\.android\debug.keystore）
#   android/key.properties 存在   → 走正式签名    （android/keystore/mubox-release.jks）
# 期望值**只从环境变量 `MUBOX_EXPECT_SIGNER_SHA256` 读**，脚本里不内置任何人的指纹：
#   · 设了这个变量 → 与现在一样：APK 实际指纹不符就非 0 退出、拦住 adb install；
#   · 没设         → **只打印**实际指纹（下面那条「== ✅ 签名体检」行就是），不拦构建。
#     这样 clone 下来的人不会被别人的机器指纹挡住。
# 值是小写十六进制、**无冒号**（apksigner 的输出格式；取自 keytool -list -v 的
# "SHA256: ..." 去掉冒号转小写）。换 keystore 就换这个环境变量，脚本本身不用改。
#   临时（当前 shell）：$env:MUBOX_EXPECT_SIGNER_SHA256='<你的指纹>'
#   持久（当前用户）：  [Environment]::SetEnvironmentVariable('MUBOX_EXPECT_SIGNER_SHA256','<你的指纹>','User')

# 找 aapt2：**不写死 build-tools 版本号**（版本会变），取版本号最大的那个。
# 顺序：$env:ANDROID_SDK_ROOT / $env:ANDROID_HOME → android\local.properties 的 sdk.dir →
#       $env:MUBOX_ANDROID_SDK（本机兜底路径请写进这个环境变量）。
function Find-Aapt2 {
    $roots = @()
    if ($env:ANDROID_SDK_ROOT) { $roots += $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { $roots += $env:ANDROID_HOME }
    if (Test-Path 'android\local.properties') {
        $m = Select-String -Path 'android\local.properties' -Pattern '^sdk\.dir=' | Select-Object -First 1
        if ($m) { $roots += ($m.Line -replace '^sdk\.dir=', '' -replace '\\\\', '\') }
    }
    if ($env:MUBOX_ANDROID_SDK) { $roots += $env:MUBOX_ANDROID_SDK }
    $cands = @()
    foreach ($r in ($roots | Where-Object { $_ })) {
        # 候选根目录可能整个不存在（环境变量指向已拔掉的移动盘 / 写错的盘符）——
        # 必须先 Test-Path 跳过。否则 Join-Path 会抛 DriveNotFoundException，
        # 在 $ErrorActionPreference='Stop' 下变成终止性错误，反而报不出「工具找不到」。
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $bt = Join-Path $r 'build-tools'
        if (-not (Test-Path -LiteralPath $bt)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $bt -Directory -ErrorAction SilentlyContinue)) {
            foreach ($n in @('aapt2.exe', 'aapt2')) {
                $p = Join-Path $d.FullName $n
                if (Test-Path $p) {
                    $ver = [version]'0.0.0'
                    try { $ver = [version]$d.Name } catch { }
                    $cands += [pscustomobject]@{ Version = $ver; Dir = $d.Name; Path = $p }
                }
            }
        }
    }
    if ($cands.Count -eq 0) { return $null }
    return ($cands | Sort-Object Version | Select-Object -Last 1)
}

# 找 apksigner：策略与 Find-Aapt2 完全相同（同一批 build-tools 目录）。
# Windows 是 apksigner.bat，Linux/macOS 是无扩展名的 apksigner —— 两个都找。
function Find-ApkSigner {
    $roots = @()
    if ($env:ANDROID_SDK_ROOT) { $roots += $env:ANDROID_SDK_ROOT }
    if ($env:ANDROID_HOME) { $roots += $env:ANDROID_HOME }
    if (Test-Path 'android\local.properties') {
        $m = Select-String -Path 'android\local.properties' -Pattern '^sdk\.dir=' | Select-Object -First 1
        if ($m) { $roots += ($m.Line -replace '^sdk\.dir=', '' -replace '\\\\', '\') }
    }
    if ($env:MUBOX_ANDROID_SDK) { $roots += $env:MUBOX_ANDROID_SDK }
    $cands = @()
    foreach ($r in ($roots | Where-Object { $_ })) {
        # 同上：候选根目录不存在时先跳过，别让 Join-Path 抛 DriveNotFoundException
        if (-not (Test-Path -LiteralPath $r)) { continue }
        $bt = Join-Path $r 'build-tools'
        if (-not (Test-Path -LiteralPath $bt)) { continue }
        foreach ($d in (Get-ChildItem -LiteralPath $bt -Directory -ErrorAction SilentlyContinue)) {
            foreach ($n in @('apksigner.bat', 'apksigner')) {
                $p = Join-Path $d.FullName $n
                if (Test-Path $p) {
                    $ver = [version]'0.0.0'
                    try { $ver = [version]$d.Name } catch { }
                    $cands += [pscustomobject]@{ Version = $ver; Dir = $d.Name; Path = $p }
                }
            }
        }
    }
    if ($cands.Count -eq 0) { return $null }
    return ($cands | Sort-Object Version | Select-Object -Last 1)
}

function Test-ReleaseResources {
    param([string]$Apk)
    $aapt2 = Find-Aapt2
    if (-not $aapt2) {
        if ($AllowMissingTools) {
            Write-Host ''
            Write-Host '⚠️  找不到 aapt2，已按 -AllowMissingTools **跳过 release 资源体检**（风险自负）'
            Write-Host '    ⇒ 这次没有验证 keep.xml 名单里的资源是否还在包里。'
            return $true
        }
        Write-Host ''
        Write-Host '❌❌❌ 资源体检无法执行：找不到 aapt2 ❌❌❌'
        Write-Host '    （找过 $env:ANDROID_SDK_ROOT / $env:ANDROID_HOME / android\local.properties / $env:MUBOX_ANDROID_SDK 下的 build-tools\*）'
        Write-Host '    ⇒ 无法验证 keep.xml 名单里的资源是否还在包里；少一个就是「通知栏没卡片 + 播放被静音」。'
        Write-Host '    已拦住装机（不执行 adb install）。确实要跳过：显式加 -AllowMissingTools。'
        return $false
    }
    $dump = & $aapt2.Path dump resources $Apk 2>$null
    if (-not $dump) {
        if ($AllowMissingTools) {
            Write-Host ''
            Write-Host "⚠️  aapt2 dump resources 没有输出（aapt2=$($aapt2.Path)），已按 -AllowMissingTools **跳过资源体检**"
            return $true
        }
        Write-Host ''
        Write-Host "❌❌❌ 资源体检无法执行：aapt2 dump resources 没有输出（aapt2=$($aapt2.Path)）❌❌❌"
        Write-Host '    ⇒ 无法验证 keep.xml 名单里的资源是否还在包里。'
        Write-Host '    已拦住装机（不执行 adb install）。确实要跳过：显式加 -AllowMissingTools。'
        return $false
    }
    $missing = @()
    foreach ($name in $ExpectedRes) {
        $hit = $dump | Where-Object { $_ -match ('\s' + [regex]::Escape($name) + '(\s|$)') } | Select-Object -First 1
        if (-not $hit) { $missing += $name }
    }
    if ($missing.Count -gt 0) {
        Write-Host ''
        Write-Host "❌❌❌ release 资源体检失败：$($missing.Count)/$($ExpectedRes.Count) 个资源不在包里 ❌❌❌"
        Write-Host '⚠️  资源又被 shrinkResources 删了，检查 android/app/src/main/res/raw/keep.xml'
        foreach ($name in $missing) { Write-Host "        缺失：$name" }
        Write-Host '    后果：通知栏按钮 iconId=0 → 每 500ms 抛异常 → 通知栏没卡片 + 播放被系统静音。'
        Write-Host '    已拦住装机（不执行 adb install）。'
        return $false
    }
    Write-Host "== ✅ release 资源体检通过：$($ExpectedRes.Count) 个资源齐全（7 个 audio_service 图标 + ic_stat_music）=="
    foreach ($name in $ExpectedRes) { Write-Host "     ✓ $name" }
    return $true
}

function Test-ReleaseVersion {
    param([string]$Apk)

    if (-not (Test-Path 'pubspec.yaml')) {
        Write-Host '⚠️  找不到 pubspec.yaml，**已跳过版本体检**'
        return $true
    }
    $wantLine = (Select-String -Path 'pubspec.yaml' -Pattern '^version:' | Select-Object -First 1).Line
    $want = ($wantLine -replace '^version:\s*', '').Trim()
    if ($want -match '\+') {
        $wantName = $want.Split('+')[0]
        $wantCode = $want.Split('+')[1]
    } else {
        $wantName = $want
        $wantCode = ''
    }

    $aapt2 = Find-Aapt2
    if (-not $aapt2) {
        # aapt2 缺失这一种情况，资源体检那关已经拦过（或已被 -AllowMissingTools 显式放行）
        Write-Host '⚠️  找不到 aapt2，**已跳过版本体检**'
        return $true
    }

    $badging = (& $aapt2.Path dump badging $Apk 2>$null | Select-Object -First 1)
    if (-not $badging) {
        Write-Host ''
        Write-Host '❌❌❌ 版本体检失败：aapt2 dump badging 没有输出 ❌❌❌'
        Write-Host '    已拦住装机（不执行 adb install）。'
        return $false
    }
    $mName = [regex]::Match([string]$badging, "versionName='([^']*)'")
    $mCode = [regex]::Match([string]$badging, "versionCode='([^']*)'")
    if (-not $mName.Success -or -not $mCode.Success) {
        Write-Host ''
        Write-Host '❌❌❌ 版本体检失败：读不出 APK 的 versionName/versionCode ❌❌❌'
        Write-Host "        $badging"
        Write-Host '    已拦住装机（不执行 adb install）。'
        return $false
    }
    $gotName = $mName.Groups[1].Value
    $gotCode = $mCode.Groups[1].Value

    $codeMismatch = ($wantCode -ne '') -and ($gotCode -ne $wantCode)
    if (($gotName -ne $wantName) -or $codeMismatch) {
        Write-Host ''
        Write-Host '❌❌❌ 版本体检失败：APK 版本与 pubspec.yaml 对不上 ❌❌❌'
        Write-Host "    pubspec.yaml：$wantName+$(if ($wantCode) { $wantCode } else { '?' })"
        Write-Host "    APK 实际：    $gotName+$gotCode"
        Write-Host '    常见原因：这次构建没覆盖旧产物（构建静默失败 / 输出目录里躺着上一次的 APK）。'
        Write-Host '    已拦住装机（不执行 adb install）。'
        return $false
    }

    Write-Host "== ✅ 版本体检通过：$gotName+$gotCode（与 pubspec.yaml 一致）=="
    return $true
}

# 读期望指纹：只认环境变量 `MUBOX_EXPECT_SIGNER_SHA256`（本脚本不内置任何指纹）。
# 返回 $null = 没设 ⇒ 体检只打印实际指纹、不做判定。
function Get-ExpectedSignerSha256 {
    $v = $env:MUBOX_EXPECT_SIGNER_SHA256
    if ([string]::IsNullOrWhiteSpace($v)) { return $null }
    return ($v.Trim() -replace ':', '').ToLowerInvariant()
}

function Test-ReleaseSignature {
    param([string]$Apk)

    # 先定「该是什么签名」—— 判定条件与 android/app/build.gradle.kts 的 hasReleaseSigning 一致
    if (Test-Path 'android\key.properties') {
        $route = '正式签名（android\key.properties 存在 → mubox-release.jks）'
    } else {
        $route = 'debug 签名（android\key.properties 不存在 → ~\.android\debug.keystore）'
    }
    Write-Host "== 签名体检：期望走【$route】=="

    $expected = Get-ExpectedSignerSha256
    if (-not $expected) {
        Write-Host '== ℹ️ 未设置 MUBOX_EXPECT_SIGNER_SHA256 ⇒ 本次只打印 APK 的实际证书指纹，不做比对 =='
        Write-Host '   （要比对就先设置它：$env:MUBOX_EXPECT_SIGNER_SHA256=''<你自己的证书指纹>''）'
    }

    $apkSigner = Find-ApkSigner
    if (-not $apkSigner) {
        if ($AllowMissingTools) {
            Write-Host ''
            Write-Host '⚠️  找不到 apksigner，已按 -AllowMissingTools **跳过签名体检**（风险自负）'
            Write-Host '    ⇒ 这次没有验证 APK 签名与手机里那版是否一致。'
            return $true
        }
        Write-Host ''
        Write-Host '❌❌❌ 签名体检无法执行：找不到 apksigner ❌❌❌'
        Write-Host '    （找过 $env:ANDROID_SDK_ROOT / $env:ANDROID_HOME / android\local.properties / $env:MUBOX_ANDROID_SDK 下的 build-tools\*\apksigner.bat）'
        Write-Host '    ⇒ 无法确认 APK 签名与手机里那版一致；不一致时 adb install -r 会失败，且只能卸载重装（清数据）。'
        Write-Host '    已拦住装机（不执行 adb install）。确实要跳过：显式加 -AllowMissingTools。'
        return $false
    }

    # ⚠️ PS 5.1 陷阱：$ErrorActionPreference='Stop' 时，原生命令往 stderr 写东西会被当成
    # 终止性错误抛出（NativeCommandError）。apksigner 失败时正是往 stderr 打 Java 栈，
    # 所以这里临时把它放宽，跑完再还原。
    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $out = & $apkSigner.Path verify --print-certs $Apk 2>&1
    $ErrorActionPreference = $prevEap

    # apksigner 的 SHA-256 是**小写十六进制、不带冒号**；这里同时兼容带冒号/大写，
    # 并去重（同一张证书在 v1/v2/v3 各打一行是正常的）。
    $digests = @()
    foreach ($line in @($out)) {
        $m = [regex]::Match([string]$line, 'SHA-256 digest:\s*([0-9a-fA-F:]+)')
        if ($m.Success) {
            $d = ($m.Groups[1].Value -replace ':', '').ToLower()
            if ($d -and ($digests -notcontains $d)) { $digests += $d }
        }
    }

    if ($digests.Count -eq 0) {
        Write-Host ''
        Write-Host '❌❌❌ 签名体检失败：读不出 APK 的证书指纹（apksigner 输出如下）❌❌❌'
        foreach ($line in @($out)) { Write-Host "        $line" }
        Write-Host '    已拦住装机（不执行 adb install）。'
        return $false
    }

    # 没设环境变量 ⇒ 只打印实际指纹，不做判定、不拦构建（别拿别人的机器指纹挡住 clone 的人）。
    if (-not $expected) {
        Write-Host "== ✅ 签名体检（仅打印）：$($digests -join ', ') =="
        return $true
    }

    if (($digests.Count -ne 1) -or ($digests[0] -ne $expected)) {
        Write-Host ''
        Write-Host '❌❌❌ 签名体检失败：APK 签名指纹与预期不符 ❌❌❌'
        Write-Host "    预期：$expected"
        foreach ($d in $digests) { Write-Host "    实际：$d" }
        if ($digests.Count -ne 1) { Write-Host "    ⚠️ 这个 APK 有 $($digests.Count) 个不同的签名者，本身就不正常。" }
        Write-Host '    后果：adb install -r 会报 INSTALL_FAILED_UPDATE_INCOMPATIBLE，'
        Write-Host '          只能「App 内导出备份 → 卸载（App 私有数据全清）→ 装新版 → 从 zip 恢复」。'
        Write-Host '    常见原因：%USERPROFILE%\.android\debug.keystore 被删/重建；'
        Write-Host '              或 android\key.properties 的存在状态被改（切换了签名路线）。'
        Write-Host '    已拦住装机（不执行 adb install）。'
        return $false
    }

    Write-Host "== ✅ 签名体检通过：$($digests[0]) =="
    return $true
}

Write-Host '== 开始构建 Mu Box release APK (arm64) =='
flutter --no-version-check build apk --release --target-platform android-arm64 --tree-shake-icons
if ($LASTEXITCODE -ne 0) {
    throw "flutter build 失败（详见上方输出）"
}

$apk = 'build\app\outputs\flutter-apk\app-release.apk'
if (-not (Test-Path $apk)) { throw "构建完成但找不到 APK：$apk（体检无从做起，直接拦住）" }
Write-Host "== 构建成功：$apk =="

if (-not (Test-ReleaseResources $apk)) { exit 1 }
if (-not (Test-ReleaseVersion   $apk)) { exit 1 }
if (-not (Test-ReleaseSignature $apk)) { exit 1 }

if ($Install) {
    Write-Host '== 覆盖安装到设备（保留数据）=='
    adb install -r $apk
    if ($LASTEXITCODE -ne 0) { throw "adb install 失败" }
    Write-Host '== 安装完成 =='
}
