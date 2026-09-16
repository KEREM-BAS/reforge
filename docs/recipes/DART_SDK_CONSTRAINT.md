# DART_SDK_CONSTRAINT

Make `environment.sdk` in `pubspec.yaml` accept the Dart version bundled with
the target Flutter release.

## What it detects

The SDK constraint does not allow the target Dart version, taking pub's own
interpretation into account: for null-safe constraints (lower bound 2.12 or
higher), Dart 3 reads an upper bound of `<3.0.0` as `<4.0.0`
(`SdkConstraint.interpretDartSdkConstraint` in dart-lang/pub). A constraint
such as `">=2.18.0 <3.0.0"` therefore needs no change.

## What it changes

Only the upper bound: `">=3.1.0 <3.5.0"` becomes `">=3.1.0 <4.0.0"`. The lower
bound determines the package's language version and is never changed. The
original quoting style is kept.

## Status

| Status | When |
| --- | --- |
| auto | The upper bound excludes the target and the lower bound is null safe. |
| manual | No constraint, an unparsable constraint, a union of ranges, or a lower bound below 2.12 (the code must be migrated to null safety first). |
| blocked | The lower bound is newer than the target's Dart version. |

## Verification

Static checks and `flutter pub get`.
