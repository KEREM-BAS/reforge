# ANDROID_FLUTTER_GRADLE_PLUGIN_DSL

Apply Flutter's Gradle plugins with `plugins {}` blocks instead of the legacy
imperative `apply from:` scripts.

## What it detects

- `android/settings.gradle` loading `.../packages/flutter_tools/gradle/app_plugin_loader.gradle`
  with `apply from:` (Flutter 1.20 to 3.13 templates), or the Flutter 1.12 to
  1.17 `.flutter-plugins` loop.
- `android/app/build.gradle` applying `.../packages/flutter_tools/gradle/flutter.gradle`
  with `apply from:` (templates before Flutter 3.13).

The Flutter 3.13 template is transitional: its app module is already
declarative but settings still uses the imperative loader. The recipe handles
each file independently.

## Why

| Flutter | Imperative apply |
| --- | --- |
| < 3.16 | The only mechanism |
| 3.16 | Declarative `plugins {}` available |
| 3.19 to 3.27 | Deprecated (build prints an error message) |
| 3.29 and later | Removed: the build fails |

Sources: `packages/flutter_tools/gradle/flutter.gradle` at each release tag,
flutter/flutter#160947, and the
[official migration guide](https://docs.flutter.dev/release/breaking-changes/flutter-gradle-plugin-apply).

The step is **required** when the target is Flutter 3.29 or later and
**recommended** for 3.16 to 3.27.

## What it changes

Following the official guide:

- **settings.gradle** is rewritten: the `pluginManagement {}` header from the
  guide, then a `plugins {}` block declaring
  `dev.flutter.flutter-plugin-loader`, the Android Gradle Plugin and, when
  used, Kotlin and documented Firebase plugins (`com.google.gms.google-services`,
  `com.google.firebase.crashlytics`) with the versions previously declared in
  the root `buildscript` classpath. Template statements are recognized
  structurally (ignoring formatting and quote style); `include` statements and
  any other statements are kept verbatim after the plugins block.
- **build.gradle (root)**: the `buildscript {}` block is removed when it only
  contains template content and migrated classpath entries. Extra properties
  still used elsewhere (for example `kotlin_version` used by `kotlin-reflect`)
  are kept. When `buildscript` contains other classpath entries, only the
  migrated entries (and variables used only by them) are removed.
- **app/build.gradle**: a `plugins {}` block is inserted at the top with the
  Android application plugin, Firebase plugins (after the Android plugin, as
  FlutterFire configures them), Kotlin plugins, and
  `dev.flutter.flutter-gradle-plugin` last. The matching `apply plugin:` and
  `apply from:` statements are removed, as are the `flutterRoot` lookup (when
  nothing else uses it) and `kotlin-stdlib` dependencies on `$kotlin_version`.

Formatting, comments and unrelated code outside the replaced statements are
preserved.

## Status

| Status | When |
| --- | --- |
| auto | Only template-shaped code is replaced. |
| review | Custom settings statements are kept after the plugins block, classpath entries without a documented plugin id stay in `buildscript`, conditional `apply plugin:` statements are left unchanged, or comments next to template code were removed. |
| manual | A script uses the Kotlin DSL, cannot be parsed reliably, contains an unrecognized `pluginManagement`/`plugins` block, or the Android Gradle Plugin or Kotlin version cannot be resolved. |

## Verification

- Static: the edited scripts parse and the recipe no longer applies.
- Toolchain: `flutter build apk --debug`.

## Manual follow-up

Plugins that read `rootProject.ext.kotlin_version` without a fallback fail
when that property is removed. When plugin sources are not available (no
`flutter pub get`), the plan says so. Such plugins should be upgraded.
