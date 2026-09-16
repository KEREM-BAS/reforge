# ANDROID_JETIFIER

Remove `android.enableJetifier=true` from `android/gradle.properties` once
the target Flutter release no longer enables Jetifier in new projects.

Recommended step: planned with `--include ANDROID_JETIFIER` or
`--include-recommended`.

## What it detects

- `android.enableJetifier` is `true`, and
- the target release's app template does not enable Jetifier (Flutter 3.38.0
  and later).

## Why

Jetifier rewrites dependencies built against the Android Support Library to
AndroidX, on every build.

| Source | Fact |
| --- | --- |
| Flutter app template at each release tag | `android.enableJetifier=true` until 3.35.x, absent from 3.38.0 |
| [flutter/flutter#173430](https://github.com/flutter/flutter/issues/173430) | Flutter no longer uses the Support Library; Jetifier fails to transform dependencies compiled for newer Java versions (`Unsupported class file major version 68`) |
| [Build Analyzer](https://developer.android.com/build/build-analyzer) | Android Studio can check whether the flag can be removed, for better build performance |

Jetifier transforms also need memory: see
[ANDROID_GRADLE_JVM_ARGS](ANDROID_GRADLE_JVM_ARGS.md).

## What it changes

The `android.enableJetifier=true` line is removed. Nothing else changes.

## Status

| Status | When |
| --- | --- |
| review | No build script declares an Android Support Library dependency. Reforge cannot see the Android dependencies of plugins and libraries, so a person must confirm. |
| manual | A build script depends on `com.android.support` artifacts, or the property is set more than once. Replace those dependencies with AndroidX ([mapping](https://developer.android.com/jetpack/androidx/migrate)) first. |

## Verification

Static checks and `flutter build apk --debug`. A dependency that still needs
Jetifier usually fails the build with duplicate or missing `android.support`
classes; `reforge verify` explains Jetifier failures as
`JETIFIER_TRANSFORM_FAILED`.

## Manual follow-up

If a dependency still uses the Support Library, keep Jetifier (skip the step
with `--skip ANDROID_JETIFIER`) and upgrade or replace that dependency.
