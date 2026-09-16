import 'package:meta/meta.dart';
import 'package:pub_semver/pub_semver.dart';

import '../common/source.dart';
import '../parsing/pub/pub_metadata.dart';
import '../parsing/pub/pubspec.dart';
import 'android_project.dart';
import 'declarations.dart';
import 'ios_project.dart';

enum FlutterProjectKind { app, plugin, module, package, dartPackage }

/// Where evidence about a project's Flutter version comes from.
enum FlutterVersionSignal {
  /// `.fvmrc` or `.fvm/fvm_config.json`: the version the team pinned.
  fvm,

  /// `.tool-versions` (asdf/mise).
  toolVersions,

  /// `.dart_tool/package_config.json`: the SDK that last ran `pub get`.
  packageConfig,

  /// `.flutter-plugins-dependencies`: the SDK that last ran `pub get`.
  pluginRegistry,

  /// `.metadata`: the SDK that created (or last migrated) the project.
  metadataRevision,
}

/// One observation of a Flutter version.
@immutable
final class FlutterVersionObservation {
  const FlutterVersionObservation(this.signal, this.value, this.location,
      {this.version});

  final FlutterVersionSignal signal;

  /// As written: a version, a channel name, or a revision.
  final String value;

  /// The version, when [value] is or maps to a known release.
  final Version? version;

  final SourceRef location;

  Map<String, Object?> toJson() => {
        'signal': signal.name,
        'value': value,
        if (version != null) 'version': '$version',
        'location': location.toJson(),
      };
}

/// A Flutter project (app, plugin, module or package) inside a workspace.
@immutable
final class FlutterProject {
  const FlutterProject({
    required this.path,
    required this.pubspec,
    required this.kind,
    this.lockfile,
    this.packageConfig,
    this.pluginRegistry,
    this.metadata,
    this.flutterVersionObservations = const [],
    this.android,
    this.ios,
    this.otherPlatforms = const [],
    this.problems = const [],
  });

  /// Workspace-relative directory (`''` for the workspace root).
  final String path;

  final Pubspec pubspec;
  final FlutterProjectKind kind;
  final PubspecLock? lockfile;
  final PackageConfig? packageConfig;
  final FlutterPluginsDependencies? pluginRegistry;
  final FlutterProjectMetadata? metadata;
  final List<FlutterVersionObservation> flutterVersionObservations;
  final AndroidProject? android;
  final IosProject? ios;

  /// Other platform directories present (`macos`, `web`, `linux`, `windows`).
  final List<String> otherPlatforms;

  final List<ParseProblem> problems;

  String get name => pubspec.name;

  /// Resolves a project-relative path to a workspace-relative path.
  String file(String relative) => path.isEmpty ? relative : '$path/$relative';

  /// The Flutter version the project is pinned to (FVM or `.tool-versions`),
  /// if any.
  FlutterVersionObservation? get pinnedFlutterVersion =>
      flutterVersionObservations
          .where((o) =>
              (o.signal == FlutterVersionSignal.fvm ||
                  o.signal == FlutterVersionSignal.toolVersions) &&
              o.version != null)
          .firstOrNull;

  /// Native plugins registered for [platform] in the generated plugin
  /// registry, if available.
  List<RegisteredPlugin> pluginsFor(String platform) =>
      pluginRegistry?.pluginsByPlatform[platform] ?? const [];

  Map<String, Object?> toJson() => {
        'path': path,
        'name': name,
        'kind': kind.name,
        'dart': {
          'sdkConstraint': pubspec.sdkConstraint?.value,
          if (pubspec.flutterConstraint != null)
            'flutterConstraint': pubspec.flutterConstraint!.value,
          if (lockfile?.dartSdkConstraint != null)
            'lockfileDartConstraint': lockfile!.dartSdkConstraint,
          if (lockfile?.flutterSdkConstraint != null)
            'lockfileFlutterConstraint': lockfile!.flutterSdkConstraint,
        },
        'flutterVersion': [
          for (final o in flutterVersionObservations) o.toJson(),
        ],
        'dependencies': {
          'direct': pubspec.dependencies.length,
          'dev': pubspec.devDependencies.length,
          'overrides': pubspec.dependencyOverrides.length,
          'locked': lockfile?.packages.length,
          'nativePlugins': {
            for (final platform in const ['android', 'ios'])
              platform: pluginRegistry == null
                  ? null
                  : [for (final p in pluginsFor(platform)) p.name],
          },
        },
        'android': android?.toJson(),
        'ios': ios?.toJson(),
        'otherPlatforms': otherPlatforms,
        'problems': [for (final p in problems) p.toJson()],
      };
}

/// A repository containing one or more Flutter projects.
@immutable
final class Workspace {
  const Workspace({
    required this.rootPath,
    required this.projects,
    required this.layout,
    this.problems = const [],
  });

  /// Absolute path of the workspace root, for display only.
  final String rootPath;

  final List<FlutterProject> projects;

  /// How projects were discovered: `single`, `pubWorkspace` or `melos`.
  final String layout;

  final List<ParseProblem> problems;

  Map<String, Object?> toJson() => {
        'layout': layout,
        'projects': [for (final p in projects) p.toJson()],
        'problems': [for (final p in problems) p.toJson()],
      };
}
