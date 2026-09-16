# Validation with real builds

Golden tests prove what Reforge writes. They cannot prove that the result
builds. This page records end-to-end runs against real toolchains: what was
run, on what, and what happened, including failures. Each observation names
the Reforge commit it applies to.

Observations here are evidence about specific projects and toolchains, not
documented requirements. They are used to find gaps in recipes and failure
signatures; recipes cite their own sources.

## 2026-09-16: Flutter 3.3-era app to Flutter 3.47.4

**Project.** An app created with the Flutter 3.3 templates (imperative Gradle
apply, AGP 7.1.2, Gradle 7.4, Kotlin 1.6.10, manifest `package`, iOS 11.0,
`org.gradle.jvmargs=-Xmx1536M`, Jetifier enabled) with the default counter app
code. The same shapes are in `fixtures/projects/flutter_3_3_app`.

**Environment.** macOS 26.5, Flutter 3.44.0 (the newest SDK installed; the
knowledge base targets 3.47.4, so builds are evidence for the 3.44 tool, see
below), JDK 21.0.6 (Android Studio), Xcode 26.5, CocoaPods 1.16.2.

### Run 1: required steps only (Reforge 85e46c8)

`reforge apply --to 3.47.4 --accept-all`, then `reforge verify --check android`:

1. `flutter build apk --debug` failed compiling Dart:
   `The getter 'headline4' isn't defined for the type 'TextTheme'`.
   The migration was fine; the app code used an API removed from Flutter.
   Reforge had no explanation for it.
2. After `dart fix --apply`, the build failed in Gradle:
   `Execution failed for JetifyTransform: ... armeabi_v7a_debug-1.0.0-....jar`,
   `Java heap space`.
3. With `org.gradle.jvmargs` set to the Flutter 3.29+ template value, the build
   succeeded.
4. The Flutter tool had modified `android/build.gradle` (clean task) and
   `android/gradle.properties` (`android.builtInKotlin=false`,
   `android.newDsl=false`) during the builds. `reforge rollback` correctly
   refused to overwrite them.

Resulting changes:

- `DART_COMPILATION_ERROR` diagnosis suggesting `dart fix` (93b2c52);
- files modified by tools during `verify` are reported and recorded, and
  rollback conflicts name the command that modified the file (93b2c52);
- `GRADLE_OUT_OF_MEMORY` and `JETIFIER_TRANSFORM_FAILED` diagnoses,
  `ANDROID_GRADLE_JVM_ARGS` and `ANDROID_JETIFIER` recipes, `--include`
  (dffdd6c);
- `ANDROID_AGP9_OPT_OUTS` and `ANDROID_CLEAN_TASK`, which make the Flutter
  tool's build-time changes part of the plan (38c7bb7).

### Run 2: with the new recipes (Reforge 38c7bb7)

```bash
reforge apply --to 3.47.4 --accept-all --include ANDROID_GRADLE_JVM_ARGS,ANDROID_JETIFIER --yes
flutter pub get && dart fix --apply
reforge verify --check android
reforge rollback
```

- 10 steps planned (7 auto, 3 review), 10 files changed, static verification
  passed.
- `flutter build apk --debug` succeeded in 23 s, with Jetifier disabled.
- The Flutter tool modified no project file during the build (`git status`
  clean afterwards).
- `reforge rollback` restored all 10 files without conflict; `android/` and
  `ios/` were byte-identical to the original commit.

### Run 3: iOS build (Reforge 38c7bb7)

Same migration and `dart fix`, then `reforge verify --check ios`:

- `flutter build ios --debug --no-codesign` succeeded in 16 s.
- The Flutter tool changed six project files during the build. Reforge
  reported three of them (`ios/Podfile`, `project.pbxproj`, `Info.plist`); its
  file list did not include the others:
  - `.gitignore`: `.build/` and `.swiftpm/` added
    (`SwiftPackageManagerGitignoreMigration`);
  - `ios/Podfile`: the commented-out `# platform :ios, '11.0'` became `'13.0'`
    (`IOSDeploymentTargetMigration` of the 3.44 tool; the 3.47 tool writes
    `'15.0'`);
  - `project.pbxproj`: `objectVersion` 50 to 54, `LastUpgradeCheck` 1300 to
    1510, `alwaysOutOfDate` on script phases, the Thin Binary input path;
  - `Runner.xcscheme`: `LastUpgradeVersion`, `customLLDBInitFile`,
    `enableGPUValidationMode`;
  - `AppDelegate.swift`: `@UIApplicationMain` to `@main` and the UIScene
    implicit engine delegate;
  - `Info.plist`: `CADisableMinimumFrameDurationOnPhone` and a scene manifest.

The iOS tool runs 16 migrations, several of them conditional (feature flags,
Swift Package Manager settings, the device being built for). Mirroring them all
as recipes would duplicate a moving target, so Reforge makes their effects
recoverable instead:

- `verify` snapshots all project files, not a fixed list, and backs up the
  previous content of every file a tool changes; `rollback` undoes those
  changes before restoring the migrated files;
- `IOS_DEPLOYMENT_TARGET` also updates the commented-out Podfile platform line,
  as the tool does.

### Run 4: rollback after real builds (Reforge 36d7843)

Same migration, `dart fix`, then `reforge verify --check ios --check android`
and `reforge rollback`:

- Both builds succeeded. The Android build created `gradlew`, `gradlew.bat` and
  `gradle-wrapper.jar` (absent from the repository, as Flutter's template
  `.gitignore` excludes them). The iOS build changed `.gitignore`,
  `project.pbxproj`, `Runner.xcscheme`, `AppDelegate.swift` and `Info.plist`.
  The Podfile was not changed: the migration had already updated its
  commented-out platform line.
- `reforge rollback` undid the tool changes and the migration: `android/`,
  `ios/` and `.gitignore` were byte-identical to the original commit. Only
  `lib/main.dart` (`dart fix`) and `pubspec.lock` (created by `pub get` before
  verification) remained, as they were changed outside Reforge.

Follow-up: files that Flutter's app templates ignore (`gradlew`,
`gradle-wrapper.jar`, `Flutter.podspec`, ...) are no longer reported as tool
changes, and signing secrets are never read.

### Run 5: every recommended step, Android Gradle Plugin 9 (Reforge 7ee46fb + ANDROID_APP_KOTLIN_PLUGIN)

```bash
reforge apply --to 3.47.4 --accept-all --include-recommended --yes
flutter pub get && dart fix --apply
reforge verify --check android
```

- 12 steps: Gradle 7.4 to 9.1.0, Android Gradle Plugin 7.1.2 to 9.0.1, Kotlin
  1.6.10 to 2.3.20, the AGP 9 opt-outs, the Kotlin Android plugin removed from
  the app module with `kotlinOptions { jvmTarget = '1.8' }` turned into
  `kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_1_8 } }`, JVM
  arguments, Jetifier removal, namespace, clean task and the iOS deployment
  target.
- `flutter build apk --debug` succeeded in 69 s. The Flutter tool applied the
  Kotlin Gradle plugin itself, and its warning that the app "applies the Kotlin
  Gradle Plugin, which will cause build failures in future versions of
  Flutter" (present in run 1) no longer appeared.
- No project file was changed by the build.

### Caveat

The builds ran with Flutter 3.44.0 because 3.47.4 was not installed. The
Android migrations of the 3.44 and 3.47 tools are the same list
(`FlutterRelease.androidMigrations`), and `reforge verify` marks such results
as not being evidence for the target.
