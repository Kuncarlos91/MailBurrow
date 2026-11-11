import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Keep signing secrets in the existing ignored repository-root configuration.
val signingPropertiesFile = rootProject.file("../keystore.properties")
val signingProperties = Properties().apply {
    if (signingPropertiesFile.isFile) {
        signingPropertiesFile.inputStream().use(::load)
    }
}
fun signingProperty(name: String): String = signingProperties.getProperty(name)
    ?.takeIf { it.isNotBlank() }
    ?: error("Repository-root keystore.properties is missing '$name'. See docs/releasing/android.md.")

android {
    namespace = "com.kuncarlos91.mailburrow"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Permanent store identity. Release installs as com.kuncarlos91.mailburrow;
        // debug adds .debug so both can be installed side by side.
        applicationId = "com.kuncarlos91.mailburrow"
        manifestPlaceholders["appLabel"] = "MailBurrow Preview"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        create("release") {
            if (signingPropertiesFile.isFile) {
                // Relative key paths are resolved from the repository root.
                storeFile = signingPropertiesFile.parentFile.resolve(signingProperty("storeFile"))
                storePassword = signingProperty("storePassword")
                keyAlias = signingProperty("keyAlias")
                keyPassword = signingProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            applicationIdSuffix = ".debug"
        }
        release {
            manifestPlaceholders["appLabel"] = "MailBurrow"
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

// Public release APKs ship 64-bit ARM only; see docs/releasing/android-rc9.md.
// `flutter build apk --target-platform android-arm64` limits only Flutter's own
// libraries (libapp.so, libflutter.so). Flutter's Gradle plugin still sets the
// default ABI list, so plugin native libraries (for example jni's
// libdartjni.so) would be packaged for armeabi-v7a and x86_64 too. Android would
// then offer the APK to devices that have no Flutter engine for their ABI, and
// the app would crash on launch. Exclude every non-arm64 native library from
// release packaging. Debug builds keep all ABIs for emulators.
androidComponents {
    onVariants(selector().withBuildType("release")) { variant ->
        variant.packaging.jniLibs.excludes.addAll(
            listOf("**/armeabi-v7a/**", "**/armeabi/**", "**/x86/**", "**/x86_64/**")
        )
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

dependencies {
    // JVM-only regression coverage for saved-document viewer selection.
    testImplementation("junit:junit:4.13.2")
}
