# Reforge fixtures

Fixture repositories are part of Reforge's test suite. They must look like real
Flutter projects from specific eras, including their quirks.

## `projects/`

| Fixture | Origin | What it exercises |
| --- | --- | --- |
| `flutter_3_3_app` | `flutter create` templates of Flutter **3.3.0**, rendered with `tool/render_flutter_app_template.dart` | Imperative Gradle plugin apply, `package=` in manifests (no `namespace`), AGP 7.1.2 / Gradle 7.4 / Kotlin 1.6.10, `sdk: '>=2.18.0 <3.0.0'`, iOS 11.0 |
| `flutter_3_13_app` | Flutter **3.13.0** templates | The transitional template: imperative `app_plugin_loader.gradle` in `settings.gradle` but a declarative `plugins {}` block in the app module, AGP/Kotlin still in the root `buildscript`; `namespace` present; AGP 7.3.0 / Gradle 7.5 / Kotlin 1.7.10, iOS 11.0 |
| `flutter_3_22_app` | Flutter **3.22.0** templates | Declarative `plugins {}` (Groovy), AGP 7.3.0 / Gradle 7.6.3 / Kotlin 1.7.10, iOS 12.0 |
| `flutter_3_44_app` | A real `flutter create` with Flutter **3.44.0** plus `shared_preferences` and `url_launcher` | Kotlin DSL, AGP 9.0.1 / Gradle 9.1.0 / Kotlin 2.3.20, generated `pubspec.lock`, `.flutter-plugins-dependencies`, `package_config.json` |
| `firebase_flavors_app` | 3.13 base, customized | Firebase Gradle plugins in `buildscript`, plugins applied at the end of the file, flavors, release signing, hard-coded SDK levels, wrapper checksum, customized Podfile with a deployment target override |
| `custom_gradle_app` | 3.3 base, customized | `ext {}` version variables, an unmapped classpath plugin (Huawei AGConnect), conditional plugin apply, extra `settings.gradle` modules, other uses of `$kotlin_version` |
| `broken_gradle_app` | 3.22 base, damaged | An `android/app/build.gradle` with an unbalanced brace |
| `melos_workspace` | Hand-written | A pub workspace with two apps from different template eras and a shared package |
| `plugins_app` | Flutter **3.22.0** templates plus hand-written resolution files | `pubspec.lock` and `.dart_tool/package_config.json` pointing at `fixtures/pub_cache` (relative `rootUri`s, so it works from any checkout): a 2021-style plugin without `namespace` that still registers with the v1 embedding, a current plugin with a conditional namespace, and a pure Dart package with a pinned SDK upper bound. The lockfile omits the hosted packages Flutter itself depends on. |

Generated files that contained machine-specific absolute paths were sanitized
(`/home/developer/...`, `/opt/flutter`).

Fixture projects carry their own `.gitignore` files. Some intentionally
committed files are ignored by those rules (for example
`.flutter-plugins-dependencies`); add such files with `git add -f`.

## `pub_cache/`

Package directories in the layout of `~/.pub-cache/hosted/pub.dev`, used by
`plugins_app`. The packages are fictional and small: only the files Reforge
reads (pubspec, Android build script, manifest, plugin sources).

## Regenerating template fixtures

```bash
cd packages/reforge_core
dart run tool/render_flutter_app_template.dart \
  --flutter <flutter git checkout> --tag 3.3.0 \
  --sdk-bounds "'>=2.18.0 <3.0.0'" \
  --out ../../fixtures/projects/flutter_3_3_app --name legacy_app --podfile
```
