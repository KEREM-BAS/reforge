# Changelog

## 0.1.0-dev

First development release. Expect breaking changes before 1.0.

- **Commands:** `inspect`, `env`, `plan`, `apply`, `verify`, `rollback`,
  `history`, `diagnose`, `recipes` and `explain`, with text, JSON and SARIF
  output and exit codes for CI (`plan --fail-on`).
- **Knowledge base (2026-09-16):** facts about every stable Flutter release
  from 3.0.0 to 3.47.4, extracted from Flutter's sources at each release tag,
  and the published Gradle, Android Gradle Plugin and Kotlin releases. Older
  releases, back to 1.17.0, are identified by their revision.
- **17 migration recipes:** Flutter Gradle plugin DSL, Gradle wrapper, Android
  Gradle Plugin and Kotlin versions, `namespace`, `minSdk` and `compileSdk`
  (including what plugins and the Android embedding need), AGP 9 opt-outs, the
  lazy `clean` task, the Kotlin Gradle plugin under AGP 9, the Kotlin JVM
  target, `jcenter()`, Gradle JVM arguments, Jetifier, iOS and macOS
  deployment targets, and the Dart SDK constraint.
- **Dependency checks** after `flutter pub get`: plugins without a namespace,
  using the removed v1 embedding, applying the Kotlin Gradle plugin, declaring
  `jcenter()`, or needing a different `compileSdk`, `minSdk`, iOS or macOS
  version than the app.
- **Environment checks:** the JDK, Xcode and CocoaPods against the target
  release.
- **Safety:** transactional `apply` with a journal and backups; `rollback` of
  migrations and of the files tools changed during `verify`; a warning when a
  Flutter release is newer than the knowledge base.
- **Validation:** real Android, iOS and macOS builds of apps from the Flutter
  2.2, 3.3 and 3.22 templates, recorded in
  [docs/validation.md](https://github.com/KEREM-BAS/reforge/blob/main/docs/validation.md).

Known limitations: Dart code that uses removed Flutter APIs is left to
`dart fix`; web, Windows and Linux hosts are not inspected; the builds were
validated with Flutter 3.44.0.
