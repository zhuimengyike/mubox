#!/usr/bin/env bash
# Mu Box 手机版 —— 一键构建（Git Bash / macOS 通用）。
# 用法（在**项目根目录**下执行；脚本自己会 cd 到它所在目录）：
#   ./build_release.sh            # 只构建 APK（含装包后体检：资源 + 版本 + 签名）
#   ./build_release.sh --install  # 构建 + 体检 + adb install -r（保留数据覆盖安装）
#   ./build_release.sh --install --allow-missing-tools   # 逃生门：体检工具找不到时也放行
#                                                        # （**只**放过「工具缺失」，签名不符 / 资源缺失照样拦）
set -e

cd "$(dirname "$0")"
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

INSTALL=0
ALLOW_MISSING_TOOLS=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        --allow-missing-tools) ALLOW_MISSING_TOOLS=1 ;;
        *) echo "❌ 未知参数：$arg（支持 --install / --allow-missing-tools）"; exit 2 ;;
    esac
done

# ==================== release 资源体检 ====================
# 为什么要有这道体检：Flutter release 默认 isShrinkResources=true，而 AGP 只扫 dex 引用、
# 扫不到 libapp.so（AOT 快照）里的 Dart 字符串 —— 凡是「资源名只写在 Dart 字符串里」的插件
# drawable 都会被当垃圾**静默删掉**：不报错、不崩溃，装到手机上才发现。
# audio_service 的 7 个通知按钮图标就是这么没的（iconId=0 → CustomAction.build() 每 500ms
# 抛异常 → MediaSession 恒 state=NONE → 通知栏没卡片 + 播放被系统静音）。
# 修法 = android/app/src/main/res/raw/keep.xml；这里做「装包后验收」，少一个就非 0 退出。
# ⚠️ 这份清单与 build_release.ps1 保持一致：keep.xml 里加图标时两个脚本都要改。
EXPECTED_RES=(
    drawable/audio_service_fast_forward
    drawable/audio_service_fast_rewind
    drawable/audio_service_pause
    drawable/audio_service_play_arrow
    drawable/audio_service_skip_next
    drawable/audio_service_skip_previous
    drawable/audio_service_stop
    drawable/ic_stat_music
)

# ==================== 装机前签名体检 ====================
# 为什么要有这道体检：`android/key.properties` 不存在时 android/app/build.gradle.kts 会回退
# 到 signingConfigs.debug。debug keystore 一旦被删/重建（换机器、清过 ~/.android 都会发生），
# 签名就变了，`adb install -r` 必报 INSTALL_FAILED_UPDATE_INCOMPATIBLE —— 物理上无法覆盖安装，
# 只能走「App 内导出备份 → 卸载（App 私有数据全清）→ 装新版 → 从 zip 恢复」。
# 与其等 adb 报错（那时已经要面对清数据），不如在装机前拿 APK 的**实际证书指纹**比一比。
#
# 目标是哪个签名，判定条件与 android/app/build.gradle.kts 的 hasReleaseSigning **逐字一致**：
#   android/key.properties 不存在 → 走 debug 签名  （~/.android/debug.keystore；
#                                                    Windows 上是 %USERPROFILE%\.android\debug.keystore）
#   android/key.properties 存在   → 走正式签名    （android/keystore/mubox-release.jks）
# 期望值**只从环境变量 `MUBOX_EXPECT_SIGNER_SHA256` 读**，脚本里不内置任何人的指纹：
#   · 设了这个变量 → 与现在一样：APK 实际指纹不符就非 0 退出、拦住 adb install；
#   · 没设         → **只打印**实际指纹（下面那条「== ✅ 签名体检」行就是），不拦构建。
#     这样 clone 下来的人不会被别人的机器指纹挡住。
# 值是小写十六进制、**无冒号**（apksigner 的输出格式；取自 keytool -list -v 的
# "SHA256: ..." 去掉冒号转小写）。换 keystore 就换这个环境变量，脚本本身不用改。
#   临时（当前 shell）：export MUBOX_EXPECT_SIGNER_SHA256='<你的指纹>'
# 两个脚本读的是**同一个**环境变量名（.ps1 里是 $env:MUBOX_EXPECT_SIGNER_SHA256）。

# 找 aapt2：**不写死 build-tools 版本号**（版本会变），取版本号最大的那个。
# 顺序：$ANDROID_SDK_ROOT / $ANDROID_HOME → android/local.properties 的 sdk.dir →
#       $MUBOX_ANDROID_SDK（本机兜底路径请写进这个环境变量，⛔ 别把绝对路径写进仓库）。
find_aapt2() {
    local roots=() sdk p
    [ -n "${ANDROID_SDK_ROOT:-}" ] && roots+=("$ANDROID_SDK_ROOT")
    [ -n "${ANDROID_HOME:-}" ] && roots+=("$ANDROID_HOME")
    if [ -f android/local.properties ]; then
        p=$(sed -n 's/^sdk\.dir=//p' android/local.properties | head -n1 | tr -d '\r')
        [ -n "$p" ] && roots+=("$p")
    fi
    [ -n "${MUBOX_ANDROID_SDK:-}" ] && roots+=("$MUBOX_ANDROID_SDK")
    for sdk in "${roots[@]}"; do
        sdk="${sdk//\\//}"                       # Windows 反斜杠 → 正斜杠
        for p in "$sdk"/build-tools/*/aapt2.exe "$sdk"/build-tools/*/aapt2; do
            [ -f "$p" ] && printf '%s\n' "$p"
        done
    done \
      | awk -F/ '{ v=$(NF-1); split(v,a,"."); printf "%05d%05d%05d\t%s\n", a[1],a[2],a[3],$0 }' \
      | sort | tail -n1 | cut -f2-
}

# 找 apksigner：策略与 find_aapt2 完全相同（同一批 build-tools 目录）。
# Windows 是 apksigner.bat，Linux/macOS 是无扩展名的 apksigner —— 两个都找。
find_apksigner() {
    local roots=() sdk p
    [ -n "${ANDROID_SDK_ROOT:-}" ] && roots+=("$ANDROID_SDK_ROOT")
    [ -n "${ANDROID_HOME:-}" ] && roots+=("$ANDROID_HOME")
    if [ -f android/local.properties ]; then
        p=$(sed -n 's/^sdk\.dir=//p' android/local.properties | head -n1 | tr -d '\r')
        [ -n "$p" ] && roots+=("$p")
    fi
    [ -n "${MUBOX_ANDROID_SDK:-}" ] && roots+=("$MUBOX_ANDROID_SDK")
    for sdk in "${roots[@]}"; do
        sdk="${sdk//\\//}"
        for p in "$sdk"/build-tools/*/apksigner.bat "$sdk"/build-tools/*/apksigner; do
            [ -f "$p" ] && printf '%s\n' "$p"
        done
    done \
      | awk -F/ '{ v=$(NF-1); split(v,a,"."); printf "%05d%05d%05d\t%s\n", a[1],a[2],a[3],$0 }' \
      | sort | tail -n1 | cut -f2-
}

check_release_resources() {
    local apk="$1" aapt2 dump name
    local missing=()

    aapt2="$(find_aapt2)"
    if [ -z "$aapt2" ]; then
        if [ "$ALLOW_MISSING_TOOLS" = "1" ]; then
            echo ""
            echo "⚠️  找不到 aapt2，已按 --allow-missing-tools **跳过 release 资源体检**（风险自负）"
            echo "    ⇒ 这次没有验证 keep.xml 名单里的资源是否还在包里。"
            return 0
        fi
        echo ""
        echo "❌❌❌ 资源体检无法执行：找不到 aapt2 ❌❌❌"
        echo "    （找过 \$ANDROID_SDK_ROOT / \$ANDROID_HOME / android/local.properties / \$MUBOX_ANDROID_SDK 下的 build-tools/*/）"
        echo "    ⇒ 无法验证 keep.xml 名单里的资源是否还在包里；少一个就是「通知栏没卡片 + 播放被静音」。"
        echo "    已拦住装机（不执行 adb install）。确实要跳过：显式加 --allow-missing-tools。"
        return 1
    fi

    dump="$(MSYS_NO_PATHCONV=1 "$aapt2" dump resources "$apk" 2>/dev/null | tr -d '\r')"
    if [ -z "$dump" ]; then
        if [ "$ALLOW_MISSING_TOOLS" = "1" ]; then
            echo ""
            echo "⚠️  aapt2 dump resources 没有输出（aapt2=$aapt2），已按 --allow-missing-tools **跳过资源体检**"
            return 0
        fi
        echo ""
        echo "❌❌❌ 资源体检无法执行：aapt2 dump resources 没有输出（aapt2=$aapt2）❌❌❌"
        echo "    ⇒ 无法验证 keep.xml 名单里的资源是否还在包里。"
        echo "    已拦住装机（不执行 adb install）。确实要跳过：显式加 --allow-missing-tools。"
        return 1
    fi

    for name in "${EXPECTED_RES[@]}"; do
        printf '%s\n' "$dump" | grep -qE " $name([[:space:]]|\$)" || missing+=("$name")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        echo ""
        echo "❌❌❌ release 资源体检失败：${#missing[@]}/${#EXPECTED_RES[@]} 个资源不在包里 ❌❌❌"
        echo "⚠️  资源又被 shrinkResources 删了，检查 android/app/src/main/res/raw/keep.xml"
        for name in "${missing[@]}"; do echo "        缺失：$name"; done
        echo "    后果：通知栏按钮 iconId=0 → 每 500ms 抛异常 → 通知栏没卡片 + 播放被系统静音。"
        echo "    已拦住装机（不执行 adb install）。"
        return 1
    fi

    echo "== ✅ release 资源体检通过：${#EXPECTED_RES[@]} 个资源齐全（7 个 audio_service 图标 + ic_stat_music）=="
    for name in "${EXPECTED_RES[@]}"; do echo "     ✓ $name"; done
    return 0
}

# 版本体检：pubspec.yaml 的 version: 与 APK 里真实的 versionName/versionCode 对账。
# 防的是「装了个旧包」—— APK 文件在、资源和签名也都过，但它根本不是这次要发的那个版本
# （构建静默失败留下上一次的产物时就会这样）。装完再看手机上的版本号就晚了。
check_release_version() {
    local apk="$1" aapt2 badging want want_name want_code got_name got_code

    if [ ! -f pubspec.yaml ]; then
        echo "⚠️  找不到 pubspec.yaml，**已跳过版本体检**"
        return 0
    fi
    want="$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -n1 | tr -d '\r' | tr -d ' ')"
    want_name="${want%%+*}"
    want_code=""
    case "$want" in *+*) want_code="${want##*+}" ;; esac

    aapt2="$(find_aapt2)"
    if [ -z "$aapt2" ]; then
        # aapt2 缺失这一种情况，资源体检那关已经拦过（或已被 --allow-missing-tools 显式放行）
        echo "⚠️  找不到 aapt2，**已跳过版本体检**"
        return 0
    fi

    badging="$(MSYS_NO_PATHCONV=1 "$aapt2" dump badging "$apk" 2>/dev/null | tr -d '\r' | head -n1)"
    got_name="$(printf '%s\n' "$badging" | sed -n "s/.*versionName='\([^']*\)'.*/\1/p")"
    got_code="$(printf '%s\n' "$badging" | sed -n "s/.*versionCode='\([^']*\)'.*/\1/p")"

    if [ -z "$got_name" ] || [ -z "$got_code" ]; then
        echo ""
        echo "❌❌❌ 版本体检失败：读不出 APK 的 versionName/versionCode ❌❌❌"
        printf '%s\n' "$badging" | sed 's/^/        /'
        echo "    已拦住装机（不执行 adb install）。"
        return 1
    fi

    if [ "$got_name" != "$want_name" ] ||
       { [ -n "$want_code" ] && [ "$got_code" != "$want_code" ]; }; then
        echo ""
        echo "❌❌❌ 版本体检失败：APK 版本与 pubspec.yaml 对不上 ❌❌❌"
        echo "    pubspec.yaml：$want_name+${want_code:-?}"
        echo "    APK 实际：    $got_name+$got_code"
        echo "    常见原因：这次构建没覆盖旧产物（构建静默失败 / 输出目录里躺着上一次的 APK）。"
        echo "    已拦住装机（不执行 adb install）。"
        return 1
    fi

    echo "== ✅ 版本体检通过：$got_name+$got_code（与 pubspec.yaml 一致）=="
    return 0
}

check_release_signature() {
    local apk="$1" apksigner out digests n expected route

    # 先定「该是什么签名」—— 判定条件与 app/build.gradle.kts 的 hasReleaseSigning 一致
    if [ -f android/key.properties ]; then
        route="正式签名（android/key.properties 存在 → mubox-release.jks）"
    else
        route="debug 签名（android/key.properties 不存在 → ~/.android/debug.keystore）"
    fi
    echo "== 签名体检：期望走【$route】=="

    # 期望指纹只认环境变量（脚本不内置任何指纹）。大小写与冒号都容忍。
    expected="$(printf '%s' "${MUBOX_EXPECT_SIGNER_SHA256:-}" | tr -d ':' | tr 'A-F' 'a-f')"
    if [ -z "$expected" ]; then
        echo "== ℹ️ 未设置 MUBOX_EXPECT_SIGNER_SHA256 ⇒ 本次只打印 APK 的实际证书指纹，不做比对 =="
        echo "   （要比对就先设置它：export MUBOX_EXPECT_SIGNER_SHA256='<你自己的证书指纹>'）"
    fi

    apksigner="$(find_apksigner)"
    if [ -z "$apksigner" ]; then
        if [ "$ALLOW_MISSING_TOOLS" = "1" ]; then
            echo ""
            echo "⚠️  找不到 apksigner，已按 --allow-missing-tools **跳过签名体检**（风险自负）"
            echo "    ⇒ 这次没有验证 APK 签名与手机里那版是否一致。"
            return 0
        fi
        echo ""
        echo "❌❌❌ 签名体检无法执行：找不到 apksigner ❌❌❌"
        echo "    （找过 \$ANDROID_SDK_ROOT / \$ANDROID_HOME / android/local.properties / \$MUBOX_ANDROID_SDK 下的 build-tools/*/apksigner.bat）"
        echo "    ⇒ 无法确认 APK 签名与手机里那版一致；不一致时 adb install -r 会失败，且只能卸载重装（清数据）。"
        echo "    已拦住装机（不执行 adb install）。确实要跳过：显式加 --allow-missing-tools。"
        return 1
    fi

    out="$(MSYS_NO_PATHCONV=1 "$apksigner" verify --print-certs "$apk" 2>&1 | tr -d '\r')"
    # apksigner 的 SHA-256 是**小写十六进制、不带冒号**；这里同时兼容带冒号/大写，
    # 并 sort -u 去重（同一张证书在 v1/v2/v3 各打一行是正常的）。
    digests="$(printf '%s\n' "$out" \
        | sed -n 's/.*SHA-256 digest:[[:space:]]*\([0-9a-fA-F:]*\).*/\1/p' \
        | tr 'A-F' 'a-f' | tr -d ':' | sed '/^$/d' | sort -u)"

    if [ -z "$digests" ]; then
        echo ""
        echo "❌❌❌ 签名体检失败：读不出 APK 的证书指纹（apksigner 输出如下）❌❌❌"
        printf '%s\n' "$out" | sed 's/^/        /'
        echo "    已拦住装机（不执行 adb install）。"
        return 1
    fi

    # 没设环境变量 ⇒ 只打印实际指纹，不做判定、不拦构建（别拿别人的机器指纹挡住 clone 的人）。
    if [ -z "$expected" ]; then
        echo "== ✅ 签名体检（仅打印）：$digests =="
        return 0
    fi

    n="$(printf '%s\n' "$digests" | wc -l | tr -d ' ')"
    if [ "$n" != "1" ] || [ "$digests" != "$expected" ]; then
        echo ""
        echo "❌❌❌ 签名体检失败：APK 签名指纹与预期不符 ❌❌❌"
        echo "    预期：$expected"
        while IFS= read -r d; do echo "    实际：$d"; done <<< "$digests"
        if [ "$n" != "1" ]; then echo "    ⚠️ 这个 APK 有 $n 个不同的签名者，本身就不正常。"; fi
        echo "    后果：adb install -r 会报 INSTALL_FAILED_UPDATE_INCOMPATIBLE，"
        echo "          只能「App 内导出备份 → 卸载（App 私有数据全清）→ 装新版 → 从 zip 恢复」。"
        echo "    常见原因：~/.android/debug.keystore 被删/重建；"
        echo "              或 android/key.properties 的存在状态被改（切换了签名路线）。"
        echo "    已拦住装机（不执行 adb install）。"
        return 1
    fi

    echo "== ✅ 签名体检通过：$digests =="
    return 0
}

echo "== 开始构建 Mu Box release APK (arm64) =="
flutter --no-version-check build apk --release --target-platform android-arm64 --tree-shake-icons

APK="build/app/outputs/flutter-apk/app-release.apk"
if [ ! -f "$APK" ]; then
    echo "❌ 构建结束但找不到 APK：$APK（体检无从做起，直接拦住）"
    exit 1
fi
echo "== 构建成功：$APK =="

check_release_resources "$APK" || exit 1
check_release_version   "$APK" || exit 1
check_release_signature "$APK" || exit 1

if [ "$INSTALL" = "1" ]; then
    echo "== 覆盖安装到设备（保留数据）=="
    MSYS_NO_PATHCONV=1 adb install -r "$APK"
    echo "== 安装完成 =="
fi
