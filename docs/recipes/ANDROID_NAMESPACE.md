# ANDROID_NAMESPACE

Declare `android.namespace` in the app module and remove `package` attributes
from `AndroidManifest.xml` files.

## What it detects

The app module has no `namespace`, or manifests still declare `package="…"`,
while the project uses Android Gradle Plugin 8 or newer (required) or 7.3 to
7.x (recommended). The AGP version is the one the project has after earlier
steps of the plan.

## Why

AGP 8 requires the namespace in the build script and rejects the `package`
attribute in source manifests ("Namespace not specified", "Incorrect package
found in source AndroidManifest.xml"). Flutter templates declare the namespace
since Flutter 3.10.

## What it changes

- Inserts `namespace "…"` (Groovy) or `namespace = "…"` (Kotlin DSL, or Groovy
  files that use assignments) as the first entry of the `android {}` block,
  with the indentation of the surrounding entries. The value comes from the
  main manifest's `package` attribute.
- Removes the `package` attribute (and its preceding whitespace) from every
  manifest under `android/app/src/*/`.

## Status

| Status | When |
| --- | --- |
| auto | All manifests agree on one valid package name. |
| manual | Manifests disagree, no package attribute exists, the namespace is computed by an expression, or the `android {}` block has an unusual layout. |

When `app/build.gradle` cannot be parsed reliably the recipe does not apply
and the plan reports the file as unanalyzed.

## Verification

Static checks and `flutter build apk --debug`.
