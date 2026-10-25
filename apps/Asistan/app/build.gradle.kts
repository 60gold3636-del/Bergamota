plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.bergamota.asistan"
    compileSdk = 34

    defaultConfig {
        applicationId = "com.bergamota.asistan"
        minSdk = 26
        targetSdk = 34
        versionCode = (System.getenv("GITHUB_RUN_NUMBER") ?: "1").toInt()
        versionName = "0.1." + (System.getenv("GITHUB_RUN_NUMBER") ?: "0")
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }

    // A fixed key kept in the repo so every CI build installs over the previous one.
    signingConfigs {
        create("shared") {
            storeFile = file("asistan.keystore")
            storePassword = "asistan"
            keyAlias = "asistan"
            keyPassword = "asistan"
        }
    }

    buildTypes {
        getByName("debug") { signingConfig = signingConfigs.getByName("shared") }
        getByName("release") {
            isMinifyEnabled = false
            signingConfig = signingConfigs.getByName("shared")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    kotlinOptions { jvmTarget = "17" }
}

dependencies {
    implementation("net.java.dev.jna:jna:5.13.0@aar")
    implementation("com.alphacephei:vosk-android:0.3.47@aar")
}
