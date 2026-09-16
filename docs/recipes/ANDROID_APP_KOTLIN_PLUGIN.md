# ANDROID_APP_KOTLIN_PLUGIN

Stop applying the Kotlin Gradle plugin in the app module, which Flutter 3.44 and
later apply themselves, and move `kotlinOptions` to `kotlin { compilerOptions }`.

Necessity: `recommended`, or `required` when built-in Kotlin is enabled.

## What it detects

- The target release's Gradle plugin applies the Kotlin Gradle plugin to app
  and plugin modules that do not apply it (Flutter 3.44 and later, generated
  per release from `FlutterPluginUtils.kt`);
- the project uses Android Gradle Plugin 9 or later (after the plan's
  upgrades);
- the app module applies the Kotlin Android plugin: `id "kotlin-android"`,
  `id("org.jetbrains.kotlin.android")`, `kotlin("android")`,
  `alias(libs.plugins.kotlin.android)` or `apply plugin: 'kotlin-android'`.

## Why

| Source | Fact |
| --- | --- |
| `FlutterPluginUtils.kt` (`detectApplyingKotlinGradlePlugin`), 3.44+ | While built-in Kotlin is disabled, Flutter applies `kotlin-android` to modules that do not apply it. With Android Gradle Plugin 9 it warns that apps applying the plugin "will cause build failures in future versions of Flutter". |
| App template, 3.44+ | The app module no longer applies `kotlin-android`; `kotlin { compilerOptions { jvmTarget = JvmTarget.JVM_17 } }` replaces `android { kotlinOptions { } }`; settings keep the plugin with `apply false`. |
| [Flutter migration guide](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers) | Remove the Kotlin Android plugin and `kotlinOptions` from the app module. Enabling built-in Kotlin needs Flutter 3.47 and Android Gradle Plugin 9. |
| [Kotlin compiler options](https://kotlinlang.org/docs/gradle-compiler-options.html) | `kotlinOptions {}` is deprecated since Kotlin 2.0.0 in favor of `compilerOptions {}`. |
| [AGP 9.0.0 release notes](https://developer.android.com/build/releases/agp-9-0-0-release-notes) | Built-in Kotlin is on by default; with it on, applying the Kotlin Android plugin fails the build. |

## What it changes

- The statement applying the Kotlin Android plugin is removed from the app
  module. The plugin's declaration in `settings.gradle` (or the root build
  file) stays, so Flutter can apply it.
- A `kotlinOptions` block containing only `jvmTarget` (`JavaVersion.VERSION_17`,
  `JavaVersion.VERSION_17.toString()`, `'17'`, `'1.8'`, ...) is removed and a
  top-level block is added after `android {}`:

```groovy
kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}
```

`android.builtInKotlin` is not changed.

## Status

| Status | When |
| --- | --- |
| review | The change can be made. |
| manual | The Kotlin plugin is not declared in settings or the root build file; `kotlinOptions` sets other options or cannot be converted; the Kotlin Gradle plugin is older than 2.0.0; or a `kotlin {}` block already exists. |

## Verification

Static checks and `flutter build apk --debug`.

## Related findings

- `ANDROID_APP_APPLIES_KOTLIN_PLUGIN`: a warning, or an error when built-in
  Kotlin is enabled.
- `PLUGINS_APPLY_KOTLIN_GRADLE_PLUGIN`: plugins that still apply the Kotlin
  Gradle plugin (read from the pub cache), which Flutter warns will break
  future builds. Those need plugin upgrades; Reforge never edits dependencies.
