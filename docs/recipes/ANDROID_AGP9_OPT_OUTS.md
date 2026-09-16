# ANDROID_AGP9_OPT_OUTS

Add `android.builtInKotlin=false` and `android.newDsl=false` to
`android/gradle.properties`, as the Flutter tool of the target release would
during the next Android build.

Necessity: `flutterMigration` (planned by default; skipping it does not make a
plan incomplete, because Flutter makes the change itself).

## What it detects

- The target release's tool runs `DisableBuiltInKotlinMigration` and
  `DisableNewDslMigration` (Flutter 3.44 and later, recorded per release in
  the knowledge base from `lib/src/android/gradle.dart`), and
- `gradle.properties` does not set `android.builtInKotlin` or
  `android.newDsl`, with any value.

## Why

| Source | Fact |
| --- | --- |
| [AGP 9.0.0 release notes](https://developer.android.com/build/releases/agp-9-0-0-release-notes) | `android.builtInKotlin` and `android.newDsl` change from `false` to `true`; setting them to `false` opts out. |
| `disable_built_in_kotlin_migration.dart`, `disable_new_dsl_migration.dart` | Before every Android build, Flutter appends each property with the value `false` when it is not set, creating `gradle.properties` if needed. |
| App template (3.44+) | New projects set both properties to `false`. |

The Flutter tool rewrites `gradle.properties` through its line-based migrator,
which also converts CRLF line endings to LF.

## What it changes

The missing properties are appended in the order Flutter appends them, each
preceded by a comment naming the Flutter migration, using the file's line
endings. Existing values, including `true`, are never changed.

## Status

| Status | When |
| --- | --- |
| auto | `gradle.properties` exists. |
| manual | `gradle.properties` does not exist; create it (Flutter would). |

## Verification

Static checks and `flutter build apk --debug`.

## Notes

Flutter 3.44+ warns that apps applying the Kotlin Gradle plugin should migrate
to built-in Kotlin
([guide](https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin/for-app-developers)).
That migration changes build scripts and is not part of this recipe; once it
is done, `android.builtInKotlin` can be removed.
