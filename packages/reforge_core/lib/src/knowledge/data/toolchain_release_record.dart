/// A published Gradle release and the SHA-256 checksums of its distributions.
final class GradleReleaseRecord {
  const GradleReleaseRecord(this.version,
      {required this.bin, required this.all});

  /// The version exactly as Gradle names it (`8.14`, `8.10.2`, `9.1.0`).
  final String version;

  /// SHA-256 of `gradle-<version>-bin.zip`.
  final String bin;

  /// SHA-256 of `gradle-<version>-all.zip`.
  final String all;
}
