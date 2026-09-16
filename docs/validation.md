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

### Run 5: every recommended step, Android Gradle Plugin 9 (Reforge 3f6c06c)

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

### Run 6: macOS host (Reforge ae8dbd1)

The fixture now has the macOS host of the Flutter 3.3 templates
(`MACOSX_DEPLOYMENT_TARGET = 10.11` in three configurations, Podfile
`platform :osx, '10.11'`).

```bash
reforge apply --to 3.47.4 --accept-all --yes
flutter pub get && dart fix --apply
reforge verify --check macos
reforge rollback
```

- `MACOS_DEPLOYMENT_TARGET` raised the three build settings and the Podfile
  platform to 12.0. `flutter build macos --debug` succeeded in 16 s.
- The Flutter tool changed four project files during the build, all reported
  and backed up: `.gitignore` (`.build/`, `.swiftpm/`), `project.pbxproj`
  (`objectVersion` 51 to 54, `LastUpgradeCheck`, `alwaysOutOfDate` on a script
  phase), `Runner.xcscheme` (`LastUpgradeVersion`, `enableGPUValidationMode`)
  and `AppDelegate.swift` (`@NSApplicationMain` to `@main`,
  `applicationSupportsSecureRestorableState`). It did not touch the deployment
  target.
- `reforge rollback` restored the migration and the tool changes; only
  `lib/main.dart` (`dart fix`), `pubspec.lock` and
  `macos/Flutter/GeneratedPluginRegistrant.swift` (`pub get`) remained.

The same run with `--to 3.44.0`, the installed SDK, set 10.15, the value the
3.44 tool's `MacOSDeploymentTargetMigration` writes; the build succeeded in
10 s and again left the deployment target unchanged.

### Run 7: Flutter 3.22-era app (Reforge c0fef96, then c3c1391)

`fixtures/projects/flutter_3_22_app` (declarative plugins, AGP 7.3.0, Gradle
7.6.3, Kotlin 1.7.10, `compileOptions` Java 8 and no Kotlin `jvmTarget`, as
Flutter 3.22 templates generated), with launcher icons added:

```bash
reforge apply --to 3.47.4 --accept-all --yes
reforge verify --check android
```

- With c0fef96 the plan had 5 steps and reported itself complete, but
  `flutter build apk --debug` failed: `Inconsistent JVM-target compatibility
  detected for tasks 'compileDebugJavaWithJavac' (1.8) and 'compileDebugKotlin'
  (21)`. The Kotlin Gradle plugin, now 2.2.20, compiled to the JVM Gradle ran
  on. Reforge explained the failure (`JVM_TARGET_MISMATCH`) but had not
  predicted it. Flutter's 3.22 templates had dropped the Kotlin target
  (flutter/flutter#142146) and 3.24 restored it after the same failure was
  reported (#147185).
- With c3c1391, `ANDROID_KOTLIN_JVM_TARGET` added
  `kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_1_8 } }` (Groovy DSL,
  Gradle 8.14) and the build succeeded in 15 s.

### Run 8: Flutter 2.2-era app (Reforge ffeb848 to c3c1391)

An app rendered from the Flutter 2.2.0 templates (now
`fixtures/projects/flutter_2_2_app`): `jcenter()`, AGP 4.1.0, Gradle 6.7,
Kotlin 1.3.50, `compileSdkVersion 30`, `minSdkVersion 16`, no
`compileOptions`. The migration to 3.47.4 was built with Flutter 3.44.0 after
`flutter pub get` and `dart fix --apply`:

1. ffeb848 planned 9 steps, "complete". The build failed in AGP's AAR metadata
   check: 21 issues, starting with `androidx.fragment:fragment:1.7.1 requires
   libraries and applications that depend on it to compile against version 34
   or later`. Reforge's diagnosis pointed to `ANDROID_COMPILE_SDK`, which the
   plan had only recommended. The AndroidX libraries of Flutter's Android
   embedding (`engine/src/flutter/tools/androidx/files.json`) declare
   `minCompileSdk=34` for every release from 3.29 to 3.47.4; c0fef96 records
   that in the knowledge base and makes the step required below it.
2. With c0fef96 the build failed on the JVM targets (1.8 and 21), as in run 7.
3. With c3c1391 (11 steps: Gradle plugin DSL, wrapper 6.7 to 8.14, AGP 4.1.0
   to 8.11.1, Kotlin 1.3.50 to 2.2.20, compileSdk, minSdk, namespace, Java and
   Kotlin targets, clean task, AGP 9 opt-outs, iOS 15.0),
   `flutter build apk --debug` succeeded in 15 s, and
   `flutter build ios --debug --no-codesign` in 15 s. The iOS build changed
   `project.pbxproj`, `Runner.xcscheme`, `AppDelegate.swift` and `Info.plist`;
   `reforge rollback` restored them and the 11 migrated files, leaving only
   `lib/main.dart` (`dart fix`) and `pubspec.lock`.

4. With every recommended step (Reforge 7634a67, `--include-recommended`): 15
   steps, adding Gradle 9.1.0, AGP 9.0.1, Kotlin 2.3.20, `jcenter()` to
   `mavenCentral()` (now required, as the plan uses Gradle 9), the Kotlin
   plugin removed from the app module, JVM arguments and Jetifier removal.
   `flutter build apk --debug` succeeded in 16 s; the only warnings were
   javac's "source value 8 is obsolete" for the app's Java 8 target.

With the required steps only, `jcenter()` stayed in `android/build.gradle` (a
recommended step with Gradle 8.14). Its Gradle 9 errors were checked separately with Gradle 9.1.0 on
minimal Groovy and Kotlin DSL scripts: `Could not find method jcenter() for
arguments []` and `Unresolved reference 'jcenter'`; with `mavenCentral()`
both configured (ffeb848).

### Caveat

The builds ran with Flutter 3.44.0 because 3.47.4 was not installed. The
Android migrations of the 3.44 and 3.47 tools are the same list
(`FlutterRelease.androidMigrations`), and `reforge verify` marks such results
as not being evidence for the target.

## 2026-09-16: parsers and dependency facts against real files

`tool/check_parsers.dart` over the local pub cache and a Flutter checkout
(apps, templates, integration tests): 1,527 Groovy and 190 Kotlin DSL Gradle
scripts, 410 Podfiles and 318 podspecs, all read reliably (Reforge bd5c2e7).
`reforge plan --to 3.47.4` over the 39 Flutter projects in the Flutter
checkout produced no internal error.

The dependency inspector over the 259 plugins in the pub cache, compared with
a text search:

- namespace: the text search missed `namespace("...")` calls inside
  `if (project.android.hasProperty("namespace"))`; Reforge was right;
- Kotlin plugin: `firebase_core` 4.14.0, `file_picker` 11.0.2 and others apply
  it only inside `if (agpMajor < 9 || !builtInKotlin)`. Reforge had reported
  them as not applying it; they are now reported as applying it conditionally
  (they support built-in Kotlin), and only the 67 plugins that always apply
  it are flagged (f02cd57);
- podspecs: a newline after a hash literal (`s.license = { ... }`) did not
  end the Ruby statement, hiding the `s.ios.deployment_target` of
  `flutter_local_notifications` and `flutter_image_compress_common`. Fixed
  (f02cd57); 185 of 186 podspecs now yield their iOS minimum, and the
  remaining one declares none;
- macOS: of the 188 plugin versions that declare macOS, 141 have a macOS or
  shared `darwin/` podspec; Reforge read the macOS minimum of all 141
  (`s.osx.deployment_target`, `s.platform = :osx`, ...), matching a text
  search. The others are app-facing packages, Dart-only implementations or
  Swift Package Manager-only releases without a podspec (2cf4735);
- minSdk: 171 of the 197 plugin build scripts set a literal `minSdk` in
  `defaultConfig`, and Reforge read all of them like a text search. `jni`
  declares `defaultConfig` twice, the second time with `minSdk 21`; the first
  implementation only read the first block (e5d2703 merges them, as Gradle does).
  The other scripts use `project.ext` values, `safeExtGet(...)` or
  `flutter.minSdkVersion`, which are not the plugin's own requirement;
- v1 embedding: the five flagged plugin versions (`awesome_notifications`
  0.9.3+1, `device_info` 2.0.3, `flutter_inappwebview` 5.8.0,
  `flutter_native_image` 0.0.6+1, `uni_links` 0.5.1) all really use
  `PluginRegistry.Registrar`.
