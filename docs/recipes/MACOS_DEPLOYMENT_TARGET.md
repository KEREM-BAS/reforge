# MACOS_DEPLOYMENT_TARGET

Raise the macOS deployment target to the minimum supported by the target
Flutter release.

## What it detects

- `MACOSX_DEPLOYMENT_TARGET` of the Xcode project and of application targets
  below the minimum;
- a Podfile `platform :osx, '…'` below the minimum, or the template's
  commented-out platform line when no platform is set.

## Why

| Flutter | Minimum macOS |
| --- | --- |
| 3.0 to 3.3 | 10.11 |
| 3.7 to 3.32 | 10.14 |
| 3.35 to 3.44 | 10.15 |
| 3.47 | 12.0 |

Source: `macos_deployment_target_migration.dart` (and `darwin.dart` where
present) at each release tag; before Flutter 3.7, which has no macOS
migration, the app template's `project.pbxproj`.

`flutter build macos` runs `MacOSDeploymentTargetMigration`, which rewrites
only the values earlier templates used (in 3.47: 10.11, 10.13, 10.14, 10.15
and 11.0). Other values below the minimum, such as 10.12, stay although the
release does not support them, and plugins that require the minimum fail to
resolve with CocoaPods. Reforge raises every value below the minimum as a
journaled, reversible change instead of leaving it to the build.

## What it changes

- Each low `MACOSX_DEPLOYMENT_TARGET` value in `project.pbxproj` (edited in
  place through an OpenStep property list parser).
- The Podfile platform version; the commented-out platform line is updated
  when no platform is set, as Flutter's migration does.

Values above the minimum are never lowered. Test targets and other non-app
targets are not changed; the notes list them when they are below the minimum.
Podfile `post_install` overrides of `MACOSX_DEPLOYMENT_TARGET` for pods are
reported, not changed. `Info.plist` reads `LSMinimumSystemVersion` from the
build setting in Flutter templates, so it follows without an edit.

## Status

| Status | When |
| --- | --- |
| auto | Always, unless the Podfile cannot be parsed reliably. |
| review | The Podfile could not be parsed reliably. |

## Verification

Static checks and `flutter build macos --debug` (macOS only).
