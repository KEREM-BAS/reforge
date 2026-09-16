# ANDROID_MIN_SDK

Raise literal `minSdk` values below the minimum Android API level of the target
Flutter release to `flutter.minSdkVersion`.

## What it detects

`minSdk` / `minSdkVersion` set to an integer below the target's
`flutter.minSdkVersion` in `android { defaultConfig { } }` or in a product
flavor, in Groovy (`minSdkVersion 21`, `minSdk = 21`) or Kotlin DSL
(`minSdk = 21`, `minSdkVersion(21)`).

Values set by other expressions are not evaluated; the step does not apply and
the reason says so.

## Why

| Flutter | `flutter.minSdkVersion` |
| --- | --- |
| 3.0 to 3.10 | 16 |
| 3.13 to 3.19 | 19 |
| 3.22 to 3.32 | 21 |
| 3.35 and later | 24 |

| Source | Fact |
| --- | --- |
| `flutter.gradle`, `flutter.groovy` or `FlutterExtension.kt` at each release tag | `flutter.minSdkVersion` |
| `DependencyVersionChecker.kt` (3.22+) | Builds fail below the error floor and warn below the warning floor (3.47: 23 and 24), per flavor. |
| `min_sdk_version_migration.dart` (3.16+) | Before every Android build, the tool replaces too-low literal values with `flutter.minSdkVersion`. |
| [API levels](https://developer.android.com/guide/topics/manifest/uses-sdk-element#api-level-table) | Android versions of each API level, used in explanations. |

## What it changes

Each low literal is replaced with `flutter.minSdkVersion`, exactly where it is
written; the syntax around it is kept (`minSdkVersion flutter.minSdkVersion`,
`minSdk = flutter.minSdkVersion`, `minSdkVersion(flutter.minSdkVersion)`).

## Status

| Status | When |
| --- | --- |
| review | Always: raising minSdk drops support for devices. The notes name the Android versions that can no longer install the app. |

Necessity is `required`: the target release does not support lower API levels,
fails the build below its error floor, and rewrites the value itself.

## Verification

Static checks and `flutter build apk --debug`. `reforge verify` links Flutter's
"minimum Android SDK version" error to this recipe.

## Manual follow-up

`flutter.minSdkVersion` follows future Flutter upgrades. If the app must keep a
fixed minimum, use a literal value at or above the target's minimum instead.
