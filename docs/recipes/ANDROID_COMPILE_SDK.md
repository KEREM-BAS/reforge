# ANDROID_COMPILE_SDK

Raise a literal `compileSdk` of the app module that is lower than the target
release's `flutter.compileSdkVersion`, or than the Android SDK the project's
plugins compile against.

Required when the literal is below the compileSdk the AndroidX libraries of
the target release's Android embedding require (34 for Flutter 3.29 to 3.47):
the build fails otherwise. Recommended in the other cases, planned with
`--include ANDROID_COMPILE_SDK` or `--include-recommended`.

## What it detects

- `compileSdk` / `compileSdkVersion` in `android {}` of the app module is an
  integer below `flutter.compileSdkVersion` of the target release, or below
  the highest literal `compileSdk` of the resolved plugins (read from their
  build scripts in the pub cache); or
- the app uses `flutter.compileSdkVersion`, but a plugin compiles against a
  higher Android SDK than that (then the step is manual).

## Why

| Source | Fact |
| --- | --- |
| `flutter.gradle`, `flutter.groovy` or `FlutterExtension.kt` at each release tag | `flutter.compileSdkVersion` (36 in 3.47) |
| `flutter.gradle` (3.10), `flutter.groovy`, `FlutterPluginUtils.kt`, `ValidateCompileSdkVersionTask.kt` (3.47) | Flutter's Gradle plugin warns when plugins compile against a higher Android SDK than the app, and asks to raise `compileSdk`. |
| Android Gradle Plugin AAR metadata check | Libraries can require modules that use them to compile against a minimum Android SDK; the build fails below it. |
| `engine/src/flutter/tools/androidx/files.json` at each release tag (3.29+), with each AAR's `aar-metadata.properties` | The AndroidX libraries of the Android embedding (`androidx.core:core:1.13.1`, `androidx.fragment:fragment:1.7.1`, `androidx.window:window-java:1.2.0`, `androidx.lifecycle` 2.7.0 in 3.47) declare `minCompileSdk=34`. Unknown before 3.29, whose engine sources are not part of flutter/flutter. |

An app created with Flutter 2.2 (`compileSdkVersion 30`) and migrated to 3.47
failed to build with Flutter 3.44 in AGP's AAR metadata check (21 issues,
starting with `androidx.fragment:fragment:1.7.1`); see
[validation](../validation.md).

`compileSdk` only selects the Android APIs available when compiling. It does
not change `targetSdk` or the runtime behavior of the app.

## What it changes

The literal is replaced with `flutter.compileSdkVersion` when that is high
enough, otherwise with the plugins' highest `compileSdk`. The syntax around the
value is kept.

Android Gradle Plugin requirements of the new compile SDK are handled by
[ANDROID_AGP_VERSION](ANDROID_AGP_VERSION.md), which runs after this recipe.

## Status

| Status | When |
| --- | --- |
| review | A literal is raised. |
| manual | The app uses `flutter.compileSdkVersion` and a plugin needs more. |

## Verification

Static checks and `flutter build apk --debug`.

## Related findings and failures

- `ANDROID_COMPILE_SDK_BELOW_FLUTTER_MINIMUM` (error) reports a compileSdk
  below what the Android embedding requires.
- `PLUGIN_COMPILE_SDK_ABOVE_APP` names the plugins, as Flutter's warning does.
- `COMPILE_SDK_BELOW_LIBRARY_MINIMUM` and `COMPILE_SDK_BELOW_DEPENDENCY_MINIMUM`
  explain Android Gradle Plugin's AAR metadata failures in `reforge diagnose`
  and `reforge verify`, confirmed by `ANDROID_COMPILE_SDK_BELOW_FLUTTER_MINIMUM`.
