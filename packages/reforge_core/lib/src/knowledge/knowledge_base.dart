import 'package:collection/collection.dart';
import 'package:pub_semver/pub_semver.dart';

import '../common/errors.dart';
import '../version/tool_version.dart';
import 'data/android_toolchain.dart' as android;
import 'data/flutter_release_record.dart';
import 'data/flutter_releases.g.dart';
import 'data/toolchain_release_record.dart';
import 'data/toolchain_releases.g.dart';
import 'flutter_release.dart';
import 'knowledge_source.dart';

/// Version of the bundled knowledge base. Reports and plans record it so that
/// results can be reproduced.
const knowledgeBaseVersion = flutterKnowledgeGeneratedOn;

/// Compatibility knowledge Reforge relies on.
///
/// Every answer is either backed by a cited source or is `null` ("unknown").
/// The knowledge base never extrapolates beyond its data.
final class KnowledgeBase {
  KnowledgeBase(List<FlutterRelease> releases)
      : releases = List<FlutterRelease>.unmodifiable(<FlutterRelease>[
          ...releases
        ]..sort((a, b) => a.version.compareTo(b.version)));

  /// The knowledge base bundled with this version of Reforge.
  static final KnowledgeBase bundled =
      KnowledgeBase(flutterReleaseRecords.map(_releaseFromRecord).toList());

  String get version => knowledgeBaseVersion;

  /// Stable Flutter releases, ascending.
  final List<FlutterRelease> releases;

  FlutterRelease get latestStable => releases.last;

  late final Map<Version, FlutterRelease> _byVersion = {
    for (final release in releases) release.version: release,
  };

  FlutterRelease? release(Version version) => _byVersion[version];

  FlutterRelease? releaseByRevision(String revision) =>
      releases.firstWhereOrNull((r) => r.revision == revision);

  /// Resolves a user-provided Flutter version: `3.47.4`, `3.47` (latest patch
  /// of that line) or `stable` (latest stable release).
  ///
  /// Throws [UnsupportedTargetException] for unknown or malformed versions.
  FlutterRelease resolveFlutterVersion(String input) {
    final text = input.trim();
    if (text == 'stable' || text == 'latest') return latestStable;
    final parts = text.split('.');
    if (parts.length == 2 && parts.every((p) => int.tryParse(p) != null)) {
      final major = int.parse(parts[0]);
      final minor = int.parse(parts[1]);
      final line = releases
          .where((r) => r.version.major == major && r.version.minor == minor)
          .toList();
      if (line.isNotEmpty) return line.last;
    } else {
      try {
        final found = release(Version.parse(text));
        if (found != null) return found;
      } on FormatException {
        throw UnsupportedTargetException(
          'TARGET_INVALID',
          '"$input" is not a Flutter version.',
          hints: const [
            'Use a stable version such as 3.47.4, a line such as 3.47, or "stable".'
          ],
        );
      }
    }
    throw UnsupportedTargetException(
      'TARGET_UNKNOWN_FLUTTER_VERSION',
      'Flutter $input is not a stable release known to this Reforge knowledge '
          'base (generated $version, latest known stable ${latestStable.version}).',
      hints: const [
        'Upgrade Reforge to get knowledge about newer Flutter releases.',
        'Beta and main channel releases are not supported as migration targets.',
      ],
    );
  }

  /// Releases whose `flutter create` template sets [key] to [value] in
  /// `android/gradle.properties`, ascending. Runs of whitespace in values are
  /// compared as a single space.
  List<FlutterRelease> releasesWithTemplateGradleProperty(
      String key, String value) {
    final normalized = normalizePropertyValue(value);
    return [
      for (final release in releases)
        if (release.template.gradleProperties[key] case final templateValue?)
          if (normalizePropertyValue(templateValue) == normalized) release,
    ];
  }

  /// The minimum Gradle version required by [agp], or `null` when the AGP
  /// line is not in the knowledge base.
  Fact<ToolVersion>? minimumGradleForAgp(ToolVersion agp) {
    final minimum = android.agpMinimumGradle['${agp.major}.${agp.minor}'];
    if (minimum == null) return null;
    return Fact(ToolVersion.parse(minimum), android.agpGradleSource);
  }

  /// The minimum Java major version needed to run [agp].
  Fact<int>? minimumJavaForAgp(ToolVersion agp) {
    for (final entry in android.agpMinimumJava.entries) {
      if (agp >= ToolVersion.parse(entry.key)) {
        return Fact(entry.value, android.agpJavaSource);
      }
    }
    return null;
  }

  /// Whether [gradle] can run on Java [javaMajor]: `true`, `false`, or `null`
  /// when the Java version is newer than the knowledge base.
  Fact<bool>? gradleRunsOnJava(ToolVersion gradle, int javaMajor) {
    final support = android.gradleJavaSupport[javaMajor];
    if (support == null) {
      if (javaMajor < 8) return const Fact(false, android.gradleJavaSource);
      return null;
    }
    if (gradle < ToolVersion.parse(support.first)) {
      return const Fact(false, android.gradleJavaSource);
    }
    final last = support.last;
    if (last != null) {
      final lastLine = ToolVersion.parse(last);
      if (gradle.major > lastLine.major ||
          (gradle.major == lastLine.major && gradle.minor > lastLine.minor)) {
        return const Fact(false, android.gradleJavaSource);
      }
    }
    return const Fact(true, android.gradleJavaSource);
  }

  /// The first Gradle version able to run on Java [javaMajor].
  Fact<ToolVersion>? minimumGradleForJava(int javaMajor) {
    final support = android.gradleJavaSupport[javaMajor];
    if (support == null) return null;
    return Fact(ToolVersion.parse(support.first), android.gradleJavaSource);
  }

  /// The minimum Android Gradle Plugin version supporting [apiLevel] as
  /// `compileSdk`.
  Fact<ToolVersion>? minimumAgpForCompileSdk(int apiLevel) {
    final minimum = android.apiLevelMinimumAgp[apiLevel];
    if (minimum == null) return null;
    return Fact(ToolVersion.parse(minimum), android.apiLevelAgpSource);
  }

  static const agp9ReleaseNotesSource = android.agp9ReleaseNotesSource;
  static const flutterTemplateJvmTargetSource =
      android.flutterTemplateJvmTargetSource;
  static const kotlinJvmTargetValidationSource =
      android.kotlinJvmTargetValidationSource;
  static final kotlinJvmTargetFailureSince =
      ToolVersion.parse(android.kotlinJvmTargetFailureSince);
  static const gradle9JcenterRemovalSource =
      android.gradle9JcenterRemovalSource;
  static const flutterTemplateJcenterRemovalSource =
      android.flutterTemplateJcenterRemovalSource;
  static const agp8NamespaceSource = android.agp8NamespaceSource;
  static const builtInKotlinGuideSource = android.builtInKotlinGuideSource;
  static const kotlinCompilerOptionsSource =
      android.kotlinCompilerOptionsSource;

  /// The first Flutter release without the Android v1 embedding API.
  static final Fact<Version> androidV1EmbeddingRemoval = Fact(
      Version.parse(android.androidV1EmbeddingRemovedIn),
      android.androidV1EmbeddingRemovalSource);

  /// The Android platform version of [apiLevel] (for example `7.0` for 24),
  /// or `null` when unknown.
  Fact<String>? androidVersionOf(int apiLevel) {
    final version = android.androidApiLevelVersions[apiLevel];
    return version == null
        ? null
        : Fact(version, android.androidApiLevelsSource);
  }

  static const jetifierTemplateRemovalSource =
      android.jetifierTemplateRemovalSource;
  static const buildAnalyzerJetifierSource =
      android.buildAnalyzerJetifierSource;
  static const androidxMigrationSource = android.androidxMigrationSource;

  static const gradleReleasesSource = KnowledgeSource(
    title: 'Gradle releases and distribution checksums',
    url: 'https://services.gradle.org/versions/all',
    retrieved: toolchainReleasesGeneratedOn,
  );

  static const agpReleasesSource = KnowledgeSource(
    title: 'Android Gradle Plugin releases (Google Maven)',
    url:
        'https://dl.google.com/dl/android/maven2/com/android/tools/build/gradle/maven-metadata.xml',
    retrieved: toolchainReleasesGeneratedOn,
  );

  static const kotlinReleasesSource = KnowledgeSource(
    title: 'Kotlin Gradle plugin releases (Maven Central)',
    url:
        'https://repo1.maven.org/maven2/org/jetbrains/kotlin/kotlin-gradle-plugin/maven-metadata.xml',
    retrieved: toolchainReleasesGeneratedOn,
  );

  late final List<(ToolVersion, GradleReleaseRecord)> _gradle = [
    for (final record in gradleReleases)
      (ToolVersion.parse(record.version), record),
  ]..sort((a, b) => a.$1.compareTo(b.$1));

  late final List<ToolVersion> _agp =
      androidGradlePluginReleases.map(ToolVersion.parse).toList()..sort();

  late final List<ToolVersion> _kotlin =
      kotlinGradlePluginReleases.map(ToolVersion.parse).toList()..sort();

  /// The earliest published stable Gradle release at or above [minimum].
  Fact<ToolVersion>? earliestGradleRelease(ToolVersion minimum) {
    for (final (version, _) in _gradle) {
      if (version >= minimum) return Fact(version, gradleReleasesSource);
    }
    return null;
  }

  /// The published Gradle release equal to [version], with checksums.
  GradleReleaseRecord? gradleRelease(ToolVersion version) {
    for (final (known, record) in _gradle) {
      if (known == version) return record;
    }
    return null;
  }

  /// The earliest published stable Android Gradle Plugin at or above
  /// [minimum].
  Fact<ToolVersion>? earliestAgpRelease(ToolVersion minimum) {
    for (final version in _agp) {
      if (version >= minimum) return Fact(version, agpReleasesSource);
    }
    return null;
  }

  /// The earliest published stable Kotlin Gradle plugin at or above
  /// [minimum].
  Fact<ToolVersion>? earliestKotlinRelease(ToolVersion minimum) {
    for (final version in _kotlin) {
      if (version >= minimum) return Fact(version, kotlinReleasesSource);
    }
    return null;
  }

  /// The documented `plugins {}` id for a buildscript classpath artifact
  /// (`group:name`), or `null` when not documented.
  Fact<String>? pluginIdForClasspath(String module) {
    final id = android.classpathPluginIds[module];
    return id == null ? null : Fact(id, android.pluginMarkerSource);
  }
}

/// [value] trimmed, with runs of whitespace replaced by a single space.
String normalizePropertyValue(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ');

FlutterRelease _releaseFromRecord(FlutterReleaseRecord record) {
  VersionFloor? floor(String? encoded) {
    if (encoded == null) return null;
    final parts = encoded.split('/');
    return VersionFloor(
      error: ToolVersion.parse(parts[0]),
      warn: ToolVersion.parse(parts[1]),
    );
  }

  return FlutterRelease(
    version: Version.parse(record.version),
    revision: record.revision,
    dartVersion: Version.parse(record.dart),
    releaseDate: DateTime.parse(record.date),
    androidRequirements: AndroidRequirements(
      gradle: floor(record.gradleFloor),
      androidGradlePlugin: floor(record.agpFloor),
      kotlin: floor(record.kotlinFloor),
      java: floor(record.javaFloor),
      minSdk: floor(record.minSdkFloor),
    ),
    androidDefaults: FlutterAndroidDefaults(
      compileSdk: record.compileSdk,
      targetSdk: record.targetSdk,
      minSdk: record.minSdk,
      ndkVersion: record.ndk,
    ),
    template: TemplateToolchain(
      gradle: ToolVersion.parse(record.templateGradle),
      androidGradlePlugin: ToolVersion.parse(record.templateAgp),
      kotlin: ToolVersion.parse(record.templateKotlin),
      dsl: GradleDsl.values.byName(record.templateDsl),
      declarativePlugins: record.templateDeclarativePlugins,
      namespaceInBuildScript: record.templateNamespace,
      gradleProperties: record.templateGradleProperties,
      appAppliesKotlinPlugin: record.templateAppKotlinPlugin,
    ),
    imperativeGradleApply:
        ImperativeGradleApply.values.byName(record.imperativeApply),
    iosMinimumDeploymentTarget: ToolVersion.parse(record.iosMinimum),
    macosMinimumDeploymentTarget: ToolVersion.parse(record.macosMinimum),
    embeddingMinCompileSdk: record.embeddingMinCompileSdk,
    embeddingMinCompileSdkLibraries: record.embeddingMinCompileSdkLibraries,
    darwinRequirements: DarwinRequirements(
      xcode: floor(record.xcodeFloor)!,
      cocoapods: floor(record.cocoapodsFloor)!,
    ),
    androidMigrations: record.androidMigrations,
    appliesKotlinPlugin: record.appliesKotlinPlugin,
  );
}
