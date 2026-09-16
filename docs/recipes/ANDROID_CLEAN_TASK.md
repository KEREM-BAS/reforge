# ANDROID_CLEAN_TASK

Replace the eager `clean` task of older app templates in `android/build.gradle`
with a lazily registered task, as the Flutter tool of the target release would
during the next Android build.

Necessity: `flutterMigration` (planned by default; skipping it does not make a
plan incomplete).

## What it detects

- The target release's tool runs `TopLevelGradleBuildFileMigration` (Flutter
  3.10 and later), and
- the Groovy `android/build.gradle` contains exactly the text Flutter matches
  (line endings aside):

```groovy
task clean(type: Delete) {
    delete rootProject.buildDir
}
```

Other formatting (different indentation, extra statements) is not migrated by
Flutter and is left unchanged. Kotlin DSL build files are never migrated.

## Why

`top_level_gradle_build_file_migration.dart` replaces that text before every
Android build. Its line-based migrator also rewrites the whole file with LF
line endings.

## What it changes

```groovy
tasks.register("clean", Delete) {
    delete rootProject.layout.buildDirectory
}
```

The file's line endings and everything around the task are kept.

## Status

| Status | When |
| --- | --- |
| auto | Always, when it applies. |

## Verification

Static checks and `flutter build apk --debug`.
