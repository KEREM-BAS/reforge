import 'package:pub_semver/pub_semver.dart';

/// Pub (Dart 3+) treats a `<3.0.0` upper bound of a null-safe constraint
/// (lower bound 2.12 or higher) as `<4.0.0`.
///
/// Source: dart-lang/pub, `SdkConstraint.interpretDartSdkConstraint`.
VersionConstraint effectiveDartSdkConstraint(
    VersionConstraint constraint, Version sdk) {
  if (sdk.major >= 3 &&
      constraint is VersionRange &&
      constraint.min != null &&
      constraint.min! >= Version(2, 12, 0) &&
      constraint.max == Version(3, 0, 0).firstPreRelease &&
      !constraint.includeMax) {
    return VersionRange(
      min: constraint.min,
      includeMin: constraint.includeMin,
      max: Version(4, 0, 0),
    );
  }
  return constraint;
}
