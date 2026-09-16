import 'package:meta/meta.dart';

import '../common/source.dart';
import '../parsing/gradle/gradle_semantics.dart';
import '../parsing/pub/pub_metadata.dart';
import '../parsing/pub/pubspec.dart';
import 'darwin_project.dart';

export '../parsing/gradle/gradle_semantics.dart' show KotlinPluginApplication;

/// The packages a project resolved with `pub get`, read from their package
/// directories (usually the pub cache).
///
/// Facts describe the *locked* versions: after switching Flutter, `pub get`
/// may select other versions.
@immutable
final class DependencyReport {
  const DependencyReport({
    required this.configPath,
    required this.packages,
    this.unavailable = const [],
  });

  /// The `package_config.json` the packages were read from, or `null` when
  /// the project has not been resolved.
  final String? configPath;

  /// Packages whose directory could be read, in package_config order.
  final List<ResolvedPackage> packages;

  /// Names of packages whose directory could not be read.
  final List<String> unavailable;

  bool get resolved => configPath != null;

  ResolvedPackage? package(String name) =>
      packages.where((p) => p.name == name).firstOrNull;

  /// Packages whose pubspec depends on [name].
  List<ResolvedPackage> dependentsOf(String name) => [
        for (final package in packages)
          if (package.pubspec?.dependencies.containsKey(name) ?? false) package,
      ];

  Map<String, Object?> toJson() => {
        'resolved': resolved,
        if (configPath != null) 'packageConfig': configPath,
        'packages': packages.length,
        if (unavailable.isNotEmpty) 'unavailable': unavailable,
        'iosPlugins': [
          for (final package in packages)
            if (package.ios case final ios?)
              {
                'name': package.name,
                if (package.version != null) 'version': package.version,
                'minimumIos': ios.minimumVersion,
              },
        ],
        'macosPlugins': [
          for (final package in packages)
            if (package.macos case final macos?)
              {
                'name': package.name,
                if (package.version != null) 'version': package.version,
                'minimumMacos': macos.minimumVersion,
              },
        ],
        'androidPlugins': [
          for (final package in packages)
            if (package.android case final android?)
              {
                'name': package.name,
                if (package.version != null) 'version': package.version,
                'namespaceDeclared': android.declaresNamespace,
                'kotlinPlugin': android.kotlinPlugin?.name,
                if (android.compileSdk != null)
                  'compileSdk': android.compileSdk,
                if (android.minSdk != null) 'minSdk': android.minSdk,
                if (android.v1EmbeddingReferences.isNotEmpty)
                  'v1EmbeddingReferences': [
                    for (final ref in android.v1EmbeddingReferences)
                      ref.toJson(),
                  ],
              },
        ],
      };
}

/// One resolved package.
@immutable
final class ResolvedPackage {
  const ResolvedPackage({
    required this.name,
    required this.rootPath,
    this.locked,
    this.pubspec,
    this.android,
    this.ios,
    this.macos,
  });

  final String name;

  /// Absolute path of the package directory on this machine.
  final String rootPath;

  /// The lockfile entry, when the package is locked.
  final LockedPackage? locked;

  /// The package's own pubspec. Paths in it are package-relative
  /// ([displayPath]).
  final Pubspec? pubspec;

  /// Facts about the package's Android implementation, when it has one.
  final AndroidPluginFacts? android;

  /// Facts about the package's iOS (CocoaPods) implementation, when it has
  /// one.
  final DarwinPluginFacts? ios;

  /// Facts about the package's macOS (CocoaPods) implementation, when it has
  /// one.
  final DarwinPluginFacts? macos;

  /// [ios] or [macos].
  DarwinPluginFacts? darwin(DarwinPlatform platform) => switch (platform) {
        DarwinPlatform.ios => ios,
        DarwinPlatform.macos => macos,
      };

  String? get version => locked?.version ?? pubspec?.version;

  /// How files of this package are named in evidence, e.g.
  /// `camera_android 0.10.8/android/build.gradle`.
  String displayPath(String relative) =>
      '$name${version == null ? '' : ' $version'}/$relative';
}

/// What Reforge read from a plugin's `android/` directory.
@immutable
final class AndroidPluginFacts {
  const AndroidPluginFacts({
    required this.buildFile,
    required this.declaresNamespace,
    required this.kotlinPlugin,
    this.compileSdk,
    this.minSdk,
    this.v1EmbeddingReferences = const [],
  });

  /// Where the Android build script is, as a display path.
  final SourceRef buildFile;

  /// Whether the `android {}` block sets `namespace` (possibly inside a
  /// condition). `null` when the script could not be read reliably.
  final bool? declaresNamespace;

  /// How the build script applies the Kotlin Android Gradle plugin; `null`
  /// when the script could not be read reliably.
  final KotlinPluginApplication? kotlinPlugin;

  /// The Android SDK the plugin compiles against, when its build script sets
  /// `compileSdk` to a literal.
  final int? compileSdk;

  /// The minimum Android API level the plugin declares, when its build
  /// script sets `minSdk` in `defaultConfig` to a literal. Android's manifest
  /// merger rejects apps with a lower minSdk.
  final int? minSdk;

  /// Uses of `PluginRegistry.Registrar`, the Android v1 embedding API, in
  /// Java and Kotlin sources.
  final List<SourceRef> v1EmbeddingReferences;
}

/// What Reforge read from a plugin's podspec for one Apple platform (`ios/`,
/// `macos/` or the shared `darwin/`).
@immutable
final class DarwinPluginFacts {
  const DarwinPluginFacts(
      {required this.podspec, required this.minimumVersion});

  /// Where the podspec is, as a display path, with the line of the platform
  /// declaration when there is one.
  final SourceRef podspec;

  /// The minimum version of the platform the pod declares, as written, or
  /// `null` when it declares none or it could not be read.
  final String? minimumVersion;
}
