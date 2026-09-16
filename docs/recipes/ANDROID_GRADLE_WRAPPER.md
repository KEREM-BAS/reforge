# ANDROID_GRADLE_WRAPPER

Upgrade the Gradle version in `android/gradle/wrapper/gradle-wrapper.properties`.

## What it detects

The Gradle version in `distributionUrl` is lower than the minimum required by:

- the target Flutter release's Gradle floor (Flutter's dependency version
  checker fails the build below it), and
- the Android Gradle Plugin version the project will use after the plan,
  according to the official AGP/Gradle compatibility table.

With `--include-recommended`, the Flutter warning threshold is used instead of
the error threshold.

## Why

| Source | Fact |
| --- | --- |
| `DependencyVersionChecker.kt` (per Flutter release) | Gradle error and warning floors |
| [AGP release notes](https://developer.android.com/build/releases/about-agp#updating-gradle) | Minimum Gradle for each AGP line |
| [Gradle releases](https://services.gradle.org/versions/all) | Published versions and checksums |

## What it changes

- The version in `distributionUrl` is replaced by the **earliest published
  Gradle release** satisfying every requirement. The distribution type (`bin`
  or `all`) and the URL's escaping are preserved.
- When `distributionSha256Sum` pins the distribution, it is replaced by the
  published SHA-256 of the new distribution.

The wrapper JAR and `gradlew` scripts are not regenerated; they remain
compatible. `./gradlew wrapper --gradle-version <v>` can refresh them later.

## Status

| Status | When |
| --- | --- |
| auto | The distribution comes from services.gradle.org. |
| review | A custom distribution host is used, or a pinned checksum is unknown. |
| manual | `distributionUrl` has a format Reforge does not edit. |
| blocked | No known Gradle release satisfies the requirement (upgrade Reforge). |

## Verification

Static checks and `flutter build apk --debug`.

## Notes

Gradle 9 requires Java 17 or newer to run. Reforge reports JDK problems from
the environment separately (`ENV_JAVA_CANNOT_RUN_GRADLE`); it never changes
the JDK.
