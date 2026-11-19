import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties (never committed; see
// mobile/README.md "Signing an Android release"). Without it the release
// build is left unsigned rather than silently signed with the debug key.
fun readSigningProperties(contents: String): Properties {
    fun parse(text: String) = Properties().apply { load(text.reader()) }

    val standard = runCatching { parse(contents) }
    val windowsAbsolutePath = Regex("""^[A-Za-z]:[/\\]""")
    val standardStoreFile = standard.getOrNull()?.getProperty("storeFile")
    if (standardStoreFile != null && windowsAbsolutePath.containsMatchIn(standardStoreFile)) {
        return standard.getOrThrow()
    }

    // A pasted drive-letter path uses single backslashes. Java Properties
    // treats these as escapes (including \t and \u). Leave every other
    // property, escaped paths, and continuation lines to its normal parser.
    val rawWindowsStoreFile = Regex("""([ \t\f]*storeFile(?:[ \t\f]*[=:][ \t\f]*|[ \t\f]+))([A-Za-z]:\\(?!\\).*)""")
    var continued = false
    var corrected = false
    val normalized = contents.lineSequence().joinToString("\n") { line ->
        val entry = if (continued) null else rawWindowsStoreFile.matchEntire(line)
        val value = if (entry != null) {
            corrected = true
            entry.groupValues[1] + entry.groupValues[2].replace('\\', '/')
        } else {
            line
        }
        val first = line.trimStart(' ', '\t', '\u000c').firstOrNull()
        val comment = !continued && (first == '#' || first == '!')
        continued = !comment && value.takeLastWhile { it == '\\' }.length % 2 == 1
        value
    }
    return if (corrected) parse(normalized) else standard.getOrThrow()
}

val keystorePropertiesFile = rootProject.file("key.properties")
val hasKeystoreProperties = keystorePropertiesFile.exists()
val releaseSigning = if (hasKeystoreProperties) runCatching {
    val properties = readSigningProperties(keystorePropertiesFile.readText(Charsets.ISO_8859_1))
    val store = properties.getProperty("storeFile")?.takeUnless { it.isBlank() }?.let { file(it) }
    properties to store
}.getOrNull() else null

if (hasKeystoreProperties) {
    val checkReleaseKeystore = tasks.register("checkReleaseKeystore") {
        val readable = releaseSigning != null
        val store = releaseSigning?.second
        doLast {
            if (!readable) {
                throw GradleException("Could not read android/key.properties. Check its Java properties syntax.")
            }
            if (store?.isFile != true) {
                throw GradleException(
                    "Set storeFile in android/key.properties to an existing keystore file. " +
                        "Use C:/Users/.../orecchino-upload.jks on Windows. Relative paths start in android/app."
                )
            }
        }
    }
    tasks.matching { it.name == "preReleaseBuild" || it.name == "validateSigningRelease" }.configureEach {
        dependsOn(checkReleaseKeystore)
    }
}

android {
    namespace = "dev.bentley.orecchino_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = rootProject.extra["orecchinoNdkVersion"] as String

    compileOptions {
        // flutter_local_notifications needs core library desugaring.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Same reverse-DNS root as the iOS bundle ID (dev.bentley.orecchino.mobile)
        // and the Mac app (dev.bentley.orecchino).
        applicationId = "dev.bentley.orecchino.mobile"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // versionCode / versionName come from pubspec.yaml's `version`.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasKeystoreProperties) {
            create("release") {
                val keystoreProperties = releaseSigning?.first
                keyAlias = keystoreProperties?.getProperty("keyAlias")
                keyPassword = keystoreProperties?.getProperty("keyPassword")
                storeFile = releaseSigning?.second
                storePassword = keystoreProperties?.getProperty("storePassword")
            }
        }
    }

    buildTypes {
        release {
            // null (unsigned) when android/key.properties is absent.
            signingConfig = signingConfigs.findByName("release")
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

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
