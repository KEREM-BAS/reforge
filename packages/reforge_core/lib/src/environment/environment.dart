import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

import '../model/finding.dart';

/// How a JDK candidate was found. Mirrors the order in which the Flutter tool
/// selects a JDK (`packages/flutter_tools/lib/src/android/java.dart`).
enum JavaSource { flutterConfig, androidStudio, javaHome, path }

@immutable
final class JavaInstallation {
  const JavaInstallation({
    required this.source,
    required this.home,
    required this.executable,
    this.version,
    this.majorVersion,
    this.error,
  });

  final JavaSource source;
  final String? home;
  final String executable;

  /// The full version string reported by `java -version`.
  final String? version;
  final int? majorVersion;
  final String? error;

  Map<String, Object?> toJson() => {
        'source': source.name,
        if (home != null) 'home': home,
        'executable': executable,
        if (version != null) 'version': version,
        if (majorVersion != null) 'majorVersion': majorVersion,
        if (error != null) 'error': error,
      };
}

@immutable
final class FlutterSdkInfo {
  const FlutterSdkInfo({
    required this.version,
    required this.channel,
    required this.frameworkRevision,
    required this.dartVersion,
    required this.root,
  });

  final Version? version;
  final String? channel;
  final String? frameworkRevision;
  final Version? dartVersion;
  final String? root;

  Map<String, Object?> toJson() => {
        'version': version?.toString(),
        'channel': channel,
        'frameworkRevision': frameworkRevision,
        'dartVersion': dartVersion?.toString(),
        'root': root,
      };
}

@immutable
final class ToolInfo {
  const ToolInfo(this.name, {this.version, this.path, this.error});

  final String name;
  final String? version;
  final String? path;
  final String? error;

  bool get isAvailable => version != null;

  Map<String, Object?> toJson() => {
        'name': name,
        if (version != null) 'version': version,
        if (path != null) 'path': path,
        if (error != null) 'error': error,
      };
}

/// The local toolchain Reforge observed. Every value is an observation of
/// this machine at probe time.
@immutable
final class Environment {
  const Environment({
    required this.operatingSystem,
    required this.operatingSystemVersion,
    required this.flutter,
    required this.flutterError,
    required this.javaCandidates,
    required this.xcode,
    required this.cocoapods,
    required this.git,
  });

  final String operatingSystem;
  final String operatingSystemVersion;
  final FlutterSdkInfo? flutter;
  final String? flutterError;

  /// JDK candidates in Flutter's selection order.
  final List<JavaInstallation> javaCandidates;

  final ToolInfo? xcode;
  final ToolInfo? cocoapods;
  final ToolInfo? git;

  /// The JDK the Flutter tool will most likely use for Android builds: the
  /// first candidate in Flutter's selection order that exists.
  JavaInstallation? get javaForFlutter => javaCandidates
      .where((c) => c.error == null && c.majorVersion != null)
      .firstOrNull;

  /// Confidence in [javaForFlutter]: explicit Flutter configuration is
  /// certain; discovery of Android Studio and environment variables mirrors
  /// Flutter's logic but may differ in edge cases.
  Confidence get javaForFlutterConfidence =>
      javaForFlutter?.source == JavaSource.flutterConfig
          ? Confidence.high
          : Confidence.medium;

  bool get isMacOS => operatingSystem == 'macos';

  Map<String, Object?> toJson() => {
        'os': {'name': operatingSystem, 'version': operatingSystemVersion},
        'flutter': flutter?.toJson(),
        if (flutterError != null) 'flutterError': flutterError,
        'java': {
          'selectedForFlutter': javaForFlutter?.toJson(),
          'selectionConfidence': javaForFlutterConfidence.name,
          'candidates': [for (final c in javaCandidates) c.toJson()],
        },
        'xcode': xcode?.toJson(),
        'cocoapods': cocoapods?.toJson(),
        'git': git?.toJson(),
      };
}
