# IOS_DEPLOYMENT_TARGET

Raise the iOS deployment target to the minimum supported by the target
Flutter release.

## What it detects

- `IPHONEOS_DEPLOYMENT_TARGET` of the Xcode project and of application targets
  below the minimum;
- a Podfile `platform :ios, '…'` below the minimum, or the template's
  commented-out platform line when no platform is set;
- `MinimumOSVersion` in `ios/Flutter/AppFrameworkInfo.plist`.

## Why

| Flutter | Minimum iOS |
| --- | --- |
| 3.0 | 9.0 |
| 3.3 to 3.16.5 | 11.0 |
| 3.16.6 to 3.32 | 12.0 |
| 3.35 to 3.44 | 13.0 |
| 3.47 | 15.0 |

Source: `ios_deployment_target_migration.dart` (and `darwin.dart` where
present) at each release tag. Since Flutter 3.41 the tool removes
`MinimumOSVersion` from `AppFrameworkInfo.plist` (flutter/flutter#178253).

## What it changes

- Each low `IPHONEOS_DEPLOYMENT_TARGET` value in `project.pbxproj` (edited in
  place through an OpenStep property list parser).
- The Podfile platform version; the commented-out platform line is updated
  when no platform is set, as Flutter's migration does.
- `AppFrameworkInfo.plist`: removes `MinimumOSVersion` for targets 3.41 and
  later, otherwise sets it to the minimum.

Extension and test targets are not changed; the notes list them when they are
below the minimum. Podfile `post_install` overrides of
`IPHONEOS_DEPLOYMENT_TARGET` for pods are reported, not changed.

## Status

| Status | When |
| --- | --- |
| auto | Always, unless the Podfile cannot be parsed reliably. |
| review | The Podfile could not be parsed reliably. |

## Verification

Static checks and `flutter build ios --debug --no-codesign` (macOS only).
