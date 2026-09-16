# Plan to Flutter 3.47.4

complete: true

## ANDROID_GRADLE_WRAPPER (auto, required, applied)

Upgrade the Gradle wrapper from 7.6.3 to 8.14.
- note: Only the distribution is changed. The wrapper JAR and gradlew scripts keep working; `./gradlew wrapper` can refresh them later.
- files: apps/customer_app/android/gradle/wrapper/gradle-wrapper.properties

## ANDROID_AGP9_OPT_OUTS (auto, flutterMigration, applied)

Add android.builtInKotlin=false and android.newDsl=false to apps/customer_app/android/gradle.properties.
- files: apps/customer_app/android/gradle.properties

## ANDROID_AGP_VERSION (review, required, applied)

Upgrade the Android Gradle Plugin from 7.3.0 to 8.11.1.
- note: This is a major version upgrade (7.3.0 to 8.11.1).
- note: Android Gradle Plugin 8 requires JDK 17 to run Gradle.
- note: Android Gradle Plugin 8 no longer generates BuildConfig by default and makes R classes non-transitive by default.
- files: apps/customer_app/android/settings.gradle

## ANDROID_KOTLIN_VERSION (review, required, applied)

Upgrade the Kotlin Gradle plugin from 1.7.10 to 2.2.20.
- note: This is a major version upgrade (1.7.10 to 2.2.20).
- note: Kotlin 2 compiles with the K2 compiler by default. Kotlin sources in the app module and Kotlin-based plugins should be rebuilt and tested.
- files: apps/customer_app/android/settings.gradle

## ANDROID_KOTLIN_JVM_TARGET (review, required, applied)

Set the Kotlin jvmTarget of apps/customer_app/android/app/build.gradle to 1.8, its Java target.
- note: Kotlin code that inlines functions compiled for a newer JVM target fails to compile with an older target; raise both targets together if that happens.
- files: apps/customer_app/android/app/build.gradle

## IOS_DEPLOYMENT_TARGET (auto, required, applied)

Raise the iOS deployment target to 15.0.
- note: The commented-out platform line in the Podfile is updated too, as Flutter's build does.
- note: MinimumOSVersion is removed from AppFrameworkInfo.plist, as Flutter 3.47.4 sets it when building App.framework.
- files: apps/customer_app/ios/Runner.xcodeproj/project.pbxproj, apps/customer_app/ios/Podfile, apps/customer_app/ios/Flutter/AppFrameworkInfo.plist

## ANDROID_FLUTTER_GRADLE_PLUGIN_DSL (auto, required, applied)

Apply Flutter's Gradle plugins with plugins {} blocks.
- note: Plugin sources were not available (run flutter pub get), so Reforge could not check whether plugins read rootProject.ext.kotlin_version.
- files: apps/driver_app/android/settings.gradle, apps/driver_app/android/build.gradle

## ANDROID_GRADLE_WRAPPER (auto, required, applied)

Upgrade the Gradle wrapper from 7.5 to 8.14.
- note: Only the distribution is changed. The wrapper JAR and gradlew scripts keep working; `./gradlew wrapper` can refresh them later.
- files: apps/driver_app/android/gradle/wrapper/gradle-wrapper.properties

## ANDROID_AGP9_OPT_OUTS (auto, flutterMigration, applied)

Add android.builtInKotlin=false and android.newDsl=false to apps/driver_app/android/gradle.properties.
- files: apps/driver_app/android/gradle.properties

## ANDROID_AGP_VERSION (review, required, applied)

Upgrade the Android Gradle Plugin from 7.3.0 to 8.11.1.
- note: This is a major version upgrade (7.3.0 to 8.11.1).
- note: Android Gradle Plugin 8 requires JDK 17 to run Gradle.
- note: Android Gradle Plugin 8 no longer generates BuildConfig by default and makes R classes non-transitive by default.
- files: apps/driver_app/android/settings.gradle

## ANDROID_KOTLIN_VERSION (review, required, applied)

Upgrade the Kotlin Gradle plugin from 1.7.10 to 2.2.20.
- note: This is a major version upgrade (1.7.10 to 2.2.20).
- note: Kotlin 2 compiles with the K2 compiler by default. Kotlin sources in the app module and Kotlin-based plugins should be rebuilt and tested.
- files: apps/driver_app/android/settings.gradle

## IOS_DEPLOYMENT_TARGET (auto, required, applied)

Raise the iOS deployment target to 15.0.
- note: The commented-out platform line in the Podfile is updated too, as Flutter's build does.
- note: MinimumOSVersion is removed from AppFrameworkInfo.plist, as Flutter 3.47.4 sets it when building App.framework.
- files: apps/driver_app/ios/Runner.xcodeproj/project.pbxproj, apps/driver_app/ios/Podfile, apps/driver_app/ios/Flutter/AppFrameworkInfo.plist

## Skipped

- DART_SDK_CONSTRAINT: environment.sdk "^3.6.0" allows Dart 3.13.3.
- ANDROID_FLUTTER_GRADLE_PLUGIN_DSL: Flutter's Gradle plugins are already applied declaratively.
- ANDROID_COMPILE_SDK: compileSdk uses flutter.compileSdkVersion (36 in Flutter 3.47.4).
- ANDROID_APP_KOTLIN_PLUGIN: Flutter 3.47.4 only warns about apps applying the Kotlin Gradle plugin with Android Gradle Plugin 9 or later; this project uses 8.11.1.
- ANDROID_NAMESPACE: android.namespace is declared and no manifest declares a package attribute.
- ANDROID_MIN_SDK: minSdk uses flutter.minSdkVersion.
- ANDROID_CLEAN_TASK: apps/customer_app/android/build.gradle has no clean task in the form the Flutter tool migrates.
- ANDROID_JCENTER: The Android build scripts do not declare jcenter().
- ANDROID_GRADLE_JVM_ARGS: Recommended but not required for Flutter 3.47.4: Update org.gradle.jvmargs to the value generated by Flutter 3.47.4.
- ANDROID_JETIFIER: Recommended but not required for Flutter 3.47.4: Remove android.enableJetifier=true from apps/customer_app/android/gradle.properties.
- MACOS_DEPLOYMENT_TARGET: The project has no macOS host.
- DART_SDK_CONSTRAINT: environment.sdk "^3.6.0" allows Dart 3.13.3.
- ANDROID_COMPILE_SDK: compileSdk uses flutter.compileSdkVersion (36 in Flutter 3.47.4).
- ANDROID_KOTLIN_JVM_TARGET: apps/driver_app/android/app/build.gradle configures the Kotlin JVM target or a JVM toolchain.
- ANDROID_APP_KOTLIN_PLUGIN: Flutter 3.47.4 only warns about apps applying the Kotlin Gradle plugin with Android Gradle Plugin 9 or later; this project uses 8.11.1.
- ANDROID_NAMESPACE: android.namespace is declared and no manifest declares a package attribute.
- ANDROID_MIN_SDK: minSdk uses flutter.minSdkVersion.
- ANDROID_CLEAN_TASK: apps/driver_app/android/build.gradle has no clean task in the form the Flutter tool migrates.
- ANDROID_JCENTER: The Android build scripts do not declare jcenter().
- ANDROID_GRADLE_JVM_ARGS: Recommended but not required for Flutter 3.47.4: Update org.gradle.jvmargs to the value generated by Flutter 3.47.4.
- ANDROID_JETIFIER: Recommended but not required for Flutter 3.47.4: Remove android.enableJetifier=true from apps/driver_app/android/gradle.properties.
- MACOS_DEPLOYMENT_TARGET: The project has no macOS host.
- DART_SDK_CONSTRAINT: environment.sdk "^3.6.0" allows Dart 3.13.3.
- ANDROID_FLUTTER_GRADLE_PLUGIN_DSL: The project has no Android host.
- ANDROID_GRADLE_WRAPPER: The project has no Android host.
- ANDROID_AGP9_OPT_OUTS: The project has no Android host.
- ANDROID_COMPILE_SDK: The project has no Android app module.
- ANDROID_AGP_VERSION: The project has no Android host.
- ANDROID_KOTLIN_VERSION: The project has no Android host.
- ANDROID_KOTLIN_JVM_TARGET: The project has no Android app module.
- ANDROID_APP_KOTLIN_PLUGIN: The project has no Android app module.
- ANDROID_NAMESPACE: The project has no Android app module.
- ANDROID_MIN_SDK: The project has no Android app module.
- ANDROID_CLEAN_TASK: The project has no Android host.
- ANDROID_JCENTER: The project has no Android host.
- ANDROID_GRADLE_JVM_ARGS: The project has no Android host.
- ANDROID_JETIFIER: The project has no Android host.
- IOS_DEPLOYMENT_TARGET: The project has no iOS host.
- MACOS_DEPLOYMENT_TARGET: The project has no macOS host.

## Remaining findings

- info DEPENDENCIES_NOT_RESOLVED
- warning ANDROID_AGP_BELOW_FLUTTER_RECOMMENDED
- warning ANDROID_GRADLE_BELOW_FLUTTER_RECOMMENDED
- warning ANDROID_KOTLIN_BELOW_FLUTTER_RECOMMENDED
- info DEPENDENCIES_NOT_RESOLVED
- warning ANDROID_AGP_BELOW_FLUTTER_RECOMMENDED
- warning ANDROID_GRADLE_BELOW_FLUTTER_RECOMMENDED
- warning ANDROID_KOTLIN_BELOW_FLUTTER_RECOMMENDED
- info DEPENDENCIES_NOT_RESOLVED
