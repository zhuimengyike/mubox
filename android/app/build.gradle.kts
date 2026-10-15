import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// 正式签名：只有 android/key.properties 存在时才启用（模板见同目录 key.properties.example）。
// 默认不启用是有意的 —— 手机上现装的那版是 debug 签名，一改签名 adb install -r 就会
// INSTALL_FAILED_UPDATE_INCOMPATIBLE，只能「导出备份 → 卸载 → 装 → 恢复」，会清 App 私有数据。
val keystorePropsFile = rootProject.file("key.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) {
        FileInputStream(keystorePropsFile).use { load(it) }
    }
}
val hasReleaseSigning = keystorePropsFile.exists()

android {
    namespace = "com.mubox.mubox"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.mubox.mubox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // 仅当 key.properties 存在时创建正式签名配置，避免配置阶段因缺文件报错
        if (hasReleaseSigning) {
            create("release") {
                storeFile = file(keystoreProps.getProperty("storeFile"))
                storePassword = keystoreProps.getProperty("storePassword")
                keyAlias = keystoreProps.getProperty("keyAlias")
                keyPassword = keystoreProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // key.properties 未启用时回退 debug 签名（保持「能覆盖安装到现有那版」）
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    // 体积优化：Flutter 引擎(libflutter/libapp)已是 arm64 单架构，其它 ABI 的插件 JNI 库
    // 在非 arm64 设备上根本没有对应引擎、跑不起来，属于纯死重，直接不打包。
    //
    // 例外——模拟器兼容性自测：
    //   `flutter build apk --release --target-platform android-x64 -PcompatTest=true`
    //   在官方模拟器（x86_64 系统镜像）上验证多版本 Android 的兼容性时，必须保留
    //   x86_64 的 libflutter.so/libapp.so，否则装上去启动即崩（找不到引擎 so）。
    //   默认（不带 -PcompatTest）时行为与以前逐字一致，发布包不受任何影响。
    val compatTest = (project.findProperty("compatTest") as? String) == "true"
    packaging {
        jniLibs {
            excludes += if (compatTest) {
                listOf(
                    "**/armeabi-v7a/**",
                    "**/armeabi/**",
                    "**/x86/**",
                )
            } else {
                listOf(
                    "**/armeabi-v7a/**",
                    "**/armeabi/**",
                    "**/x86/**",
                    "**/x86_64/**",
                )
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
