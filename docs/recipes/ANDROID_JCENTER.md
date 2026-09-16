# ANDROID_JCENTER

Replace the JCenter repository in the Android build scripts with Maven Central.

Required when the project's Gradle wrapper is Gradle 9 or later (including a
Gradle upgrade planned in the same migration); recommended otherwise, planned
with `--include ANDROID_JCENTER` or `--include-recommended`.

## What it detects

`jcenter()` or `jcenter { ... }` in a `repositories {}` block, at any depth
(`buildscript`, `allprojects`, `pluginManagement`, ...), in
`android/settings.gradle`, `android/build.gradle` and `android/app/build.gradle`
(Groovy or Kotlin DSL). Comments, strings and variables named `jcenter` do not
count.

## Why

| Source | Fact |
| --- | --- |
| [Gradle 9.0 upgrade guide](https://docs.gradle.org/current/userguide/upgrading_major_version_9.html), "Removal of deprecated jcenter()" | Gradle 9.0.0 removed `jcenter()`, deprecated since Gradle 7.0. JCenter has redirected to Maven Central since August 2024; `mavenCentral()` is the closest direct replacement. |
| [flutter/flutter#80908](https://github.com/flutter/flutter/pull/80908) | Flutter's app templates declared `jcenter()` until Flutter 2.5, so apps created with Flutter 2.2 or earlier still do. |

With Gradle 9, the build fails while configuring the project
(`Could not find method jcenter()`, or `Unresolved reference 'jcenter'` in
Kotlin DSL). Flutter 3.47 recommends Gradle 9.1.

## What it changes

- `jcenter` becomes `mavenCentral`, exactly where it is written (a content
  filter in `jcenter { ... }` is kept).
- Where the same `repositories` block already declares `mavenCentral()` and
  `jcenter()` stands alone on its line, the line is removed instead.

Because JCenter already serves Maven Central's content, resolution does not
change.

## Status

| Status | When |
| --- | --- |
| auto | Always. |

## Plugins

Plugins that declare `jcenter()` in their own Android build scripts fail with
Gradle 9 too. Reforge cannot edit them; after `flutter pub get` it reports them
as `PLUGIN_GRADLE_JCENTER` (an error with Gradle 9, a warning when the target
release recommends Gradle 9). Upgrade or replace those plugins.

## Verification

Static checks and `flutter build apk --debug`. `reforge verify` and
`reforge diagnose` explain the Gradle error as `GRADLE_JCENTER_REMOVED`.
