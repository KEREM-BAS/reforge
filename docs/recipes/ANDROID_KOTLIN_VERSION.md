# ANDROID_KOTLIN_VERSION

Upgrade the Kotlin Gradle plugin (KGP).

## What it detects

The declared Kotlin Gradle plugin version is below the target Flutter
release's Kotlin floor. Declarations are found in settings or root plugins
blocks (`org.jetbrains.kotlin.android`, `kotlin("android")`) or in the root
`buildscript` classpath, including `ext.kotlin_version`.

## Why

Flutter's Gradle plugin fails the build below its Kotlin error floor (source:
`DependencyVersionChecker.kt` per release). Target versions come from the
[published Kotlin Gradle plugin releases](https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-gradle-plugin/maven-metadata.xml).

## What it changes

- The declared version is replaced by the earliest published release at or
  above the floor.
- When the root build file still defines `kotlin_version` for other
  dependencies (for example `kotlin-reflect`) and it matched the plugin
  version, it is upgraded too, so Kotlin libraries stay aligned with the
  compiler.

## Status

| Status | When |
| --- | --- |
| auto | Upgrade within the same major version. |
| review | Upgrade from Kotlin 1.x to 2.x, which enables the K2 compiler. |
| manual | The version cannot be resolved or edited safely. |

## Verification

Static checks and `flutter build apk --debug`.
