# ANDROID_AGP_VERSION

Upgrade the Android Gradle Plugin (AGP).

## What it detects

The declared AGP version is below the target Flutter release's AGP floor.
Reforge finds the declaration wherever it lives:

- `plugins { id "com.android.application" version "…" }` in `settings.gradle(.kts)`;
- the root `build.gradle(.kts)` plugins block;
- `buildscript { dependencies { classpath "com.android.tools.build:gradle:…" } }`,
  including versions defined through `ext` variables or `gradle.properties`.

Version catalogs are reported as unknown instead of being guessed.

With `--include-recommended`, the Flutter warning threshold and the minimum
AGP for the compile SDK are used.

## Why

Flutter's Gradle plugin fails the build below its AGP error floor. Sources:
`DependencyVersionChecker.kt` for each Flutter release, the
[AGP API level table](https://developer.android.com/build/releases/about-agp#api-level-support),
and the [published AGP releases](https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/maven-metadata.xml).

## What it changes

The version literal at its definition is replaced by the **earliest published
AGP release** that satisfies the requirement. Upgrades to AGP 9 run after
[ANDROID_AGP9_OPT_OUTS](ANDROID_AGP9_OPT_OUTS.md), which sets
`android.builtInKotlin=false` and `android.newDsl=false` as Flutter 3.44+
does; when those properties are missing, the step's notes say so.

## Status

| Status | When |
| --- | --- |
| auto | Upgrade within the same major version. |
| review | Major upgrade (7 to 8, 8 to 9). The notes list behaviour changes: JDK 17, namespace, BuildConfig generation and non-transitive R classes for AGP 8 (with the app sources that reference `BuildConfig`); built-in Kotlin and the new DSL for AGP 9. |
| manual | The version cannot be resolved or edited safely. |
| blocked | The Gradle wrapper upgrade it depends on was not applied. |

## Verification

Static checks and `flutter build apk --debug`.
