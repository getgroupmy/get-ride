import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// The release signing key, when there is one. CI's android-release.yml
// writes android/key.properties from Actions secrets for the length of a
// release; it is gitignored and never committed. Without it a release
// build falls back to the debug key, which is fine for `flutter run
// --release` and the PR build check (flutter.yml), and is refused by Play.
// The store builds set GETRIDE_RELEASE_SIGNING=required (android-release.yml):
// for them a missing key fails the build instead of signing with debug.
val keystoreProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}
val releaseSigningRequired = System.getenv("GETRIDE_RELEASE_SIGNING") == "required"

android {
    namespace = "my.getgroup.get_ride"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // The Play Store identity, shared with the Expo app so this build
        // can replace it in the same listing. The Kotlin namespace above
        // is only the code's package and stays as it is.
        applicationId = "com.taxxee.teksi"
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
        // Google's own map (Admin → Settings → Maps, "Google Maps (native)"):
        // the Maps SDK for Android key, from the release workflow's
        // GOOGLE_MAPS_ANDROID_API_KEY secret. Empty, the app keeps its tiles.
        manifestPlaceholders["googleMapsKey"] = System.getenv("GOOGLE_MAPS_ANDROID_API_KEY") ?: ""
    }

    signingConfigs {
        if (keystoreProperties.getProperty("storeFile") != null) {
            create("release") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            val upload = signingConfigs.findByName("release")
            if (upload == null && releaseSigningRequired) {
                throw GradleException(
                    "GETRIDE_RELEASE_SIGNING=required, but android/key.properties is missing or has no " +
                        "storeFile: refusing to sign a store build with the debug key."
                )
            }
            signingConfig = upload ?: signingConfigs.getByName("debug")
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
