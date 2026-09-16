# ANDROID_KOTLIN_JVM_TARGET

Declare the Kotlin JVM target of the app module, matching its Java target, when
the build script does not set it.

Required when the project (after the planned upgrades) uses Gradle 8 or later
and the Kotlin Gradle plugin 1.9 or later; recommended otherwise.

## What it detects

The app module applies the Kotlin Android plugin, and its build script sets no
`jvmTarget`, `jvmToolchain` or `toolchain` anywhere, and `gradle.properties`
does not relax `kotlin.jvm.target.validation.mode`.

## Why

Without a declared `jvmTarget`, the Kotlin Gradle plugin compiles to the JVM
Gradle runs on (17 or later with Android Gradle Plugin 8), while Java compiles
to `compileOptions.targetCompatibility` (Java 8 when `compileOptions` is
absent). On Gradle 8 the Kotlin Gradle plugin fails the build when the two
differ:

```text
Inconsistent JVM-target compatibility detected for tasks
'compileDebugJavaWithJavac' (1.8) and 'compileDebugKotlin' (21).
```

| Source | Fact |
| --- | --- |
| [Kotlin Gradle plugin docs](https://kotlinlang.org/docs/gradle-configure-project.html), "Check for JVM target compatibility of related compile tasks" | `kotlin.jvm.target.validation.mode` is `error` by default on Gradle 8.0+. |
| [flutter/flutter#142146](https://github.com/flutter/flutter/pull/142146) | Flutter 3.22 app templates dropped `kotlinOptions { jvmTarget }`. |
| [flutter/flutter#147326](https://github.com/flutter/flutter/pull/147326) | Flutter 3.24 templates set it again, fixing [#147185](https://github.com/flutter/flutter/issues/147185): new projects failed with Kotlin 1.9.23 on Gradle 8.6. |
| Flutter app templates before 2.5 | No `compileOptions` and no `kotlinOptions`. |

Reforge observed the failure with apps from both template eras, migrated to
Flutter 3.47.4 and built with Flutter 3.44, Gradle 8.14 and Kotlin 2.2.20
([validation](../validation.md)).

## What it changes

The Kotlin target is set to the module's Java target, so bytecode targets do
not change for Java code:

- Kotlin Gradle plugin 2.0 or later: a top-level block, as in Flutter 3.44+
  templates:

  ```groovy
  kotlin {
      compilerOptions {
          jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8
      }
  }
  ```

- older plugins: `kotlinOptions { jvmTarget = JavaVersion.VERSION_1_8.toString() }`
  inside `android {}`, after `compileOptions`.

Without `compileOptions`, the Java 8 target the module already compiles to is
declared too, before `defaultConfig`.

## Status

| Status | When |
| --- | --- |
| review | The targets are aligned. Kotlin code that inlines functions compiled for a newer JVM target fails to compile with an older target. |
| manual | `targetCompatibility` is an expression Reforge does not evaluate, or the script already has a `kotlin {}` block. |

## Verification

Static checks and `flutter build apk --debug`. `reforge verify` explains the
Gradle error as `JVM_TARGET_MISMATCH`, confirmed by
`ANDROID_KOTLIN_JVM_TARGET_UNSET` when the failing module is the app.
