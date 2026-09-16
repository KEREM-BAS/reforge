# Plan to Flutter 3.47.4

complete: true

## ANDROID_GRADLE_WRAPPER (auto, required, applied)

Upgrade the Gradle wrapper from 7.6.3 to 9.1.0.
- note: Only the distribution is changed. The wrapper JAR and gradlew scripts keep working; `./gradlew wrapper` can refresh them later.
- files: android/gradle/wrapper/gradle-wrapper.properties

## ANDROID_AGP_VERSION (review, required, applied)

Upgrade the Android Gradle Plugin from 7.3.0 to 9.0.1.
- note: This is a major version upgrade (7.3.0 to 9.0.1).
- note: Android Gradle Plugin 8 requires JDK 17 to run Gradle.
- note: Android Gradle Plugin 8 no longer generates BuildConfig by default and makes R classes non-transitive by default.
- note: Android Gradle Plugin 9 enables built-in Kotlin and the new DSL by default. Flutter's Gradle plugin requires both to be disabled (android.builtInKotlin=false, android.newDsl=false), and plugins that use removed Android Gradle Plugin APIs fail to build.
- note: android.newDsl=false and android.builtInKotlin=false are added to android/gradle.properties.
- files: android/settings.gradle, android/gradle.properties

## ANDROID_KOTLIN_VERSION (review, required, applied)

Upgrade the Kotlin Gradle plugin from 1.7.10 to 2.3.20.
- note: This is a major version upgrade (1.7.10 to 2.3.20).
- note: Kotlin 2 compiles with the K2 compiler by default. Kotlin sources in the app module and Kotlin-based plugins should be rebuilt and tested.
- files: android/settings.gradle

## IOS_DEPLOYMENT_TARGET (auto, required, applied)

Raise the iOS deployment target to 15.0.
- note: MinimumOSVersion is removed from AppFrameworkInfo.plist, as Flutter 3.47.4 sets it when building App.framework.
- files: ios/Runner.xcodeproj/project.pbxproj, ios/Flutter/AppFrameworkInfo.plist

## Skipped

- DART_SDK_CONSTRAINT: environment.sdk ">=3.4.0 <4.0.0" allows Dart 3.13.3.
- ANDROID_FLUTTER_GRADLE_PLUGIN_DSL: Flutter's Gradle plugins are already applied declaratively.
- ANDROID_NAMESPACE: android.namespace is declared and no manifest declares a package attribute.

## Remaining findings

