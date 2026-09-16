# Plan to Flutter 3.47.4

complete: true

## IOS_DEPLOYMENT_TARGET (auto, required, applied)

Raise the iOS deployment target to 15.0.
- files: ios/Runner.xcodeproj/project.pbxproj

## Skipped

- DART_SDK_CONSTRAINT: environment.sdk "^3.12.0" allows Dart 3.13.3.
- ANDROID_FLUTTER_GRADLE_PLUGIN_DSL: Flutter's Gradle plugins are already applied declaratively.
- ANDROID_GRADLE_WRAPPER: Gradle 9.1.0 already satisfies Flutter 3.47.4 and Android Gradle Plugin 9.0.1.
- ANDROID_AGP_VERSION: Android Gradle Plugin 9.0.1 already satisfies Flutter 3.47.4.
- ANDROID_KOTLIN_VERSION: Kotlin Gradle plugin 2.3.20 already satisfies Flutter 3.47.4.
- ANDROID_NAMESPACE: android.namespace is declared and no manifest declares a package attribute.

## Remaining findings

