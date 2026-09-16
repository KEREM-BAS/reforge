import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import '../../common/source.dart';
import '../parse_diagnostic.dart';
import 'yaml_utils.dart';

/// How a dependency is sourced.
sealed class PubDependencySource {
  const PubDependencySource();
}

final class HostedDependency extends PubDependencySource {
  const HostedDependency(this.constraintText, {this.hostedUrl});

  /// The version constraint as written (`any` when omitted).
  final String constraintText;
  final String? hostedUrl;

  VersionConstraint? get constraint {
    try {
      return VersionConstraint.parse(constraintText);
    } on FormatException {
      return null;
    }
  }
}

final class PathDependency extends PubDependencySource {
  const PathDependency(this.path);

  final String path;
}

final class GitDependency extends PubDependencySource {
  const GitDependency(this.url, {this.ref, this.path});

  final String url;
  final String? ref;
  final String? path;
}

final class SdkDependency extends PubDependencySource {
  const SdkDependency(this.sdk);

  final String sdk;
}

/// A source shape Reforge does not understand.
final class UnknownDependency extends PubDependencySource {
  const UnknownDependency(this.description);

  final String description;
}

final class PubDependency {
  const PubDependency(this.name, this.source, this.location);

  final String name;
  final PubDependencySource source;
  final SourceRef location;
}

/// A YAML scalar with its source location.
final class LocatedScalar {
  const LocatedScalar(this.value, this.location);

  final String value;
  final SourceRef location;
}

/// Plugin platforms declared under `flutter.plugin.platforms`.
final class FlutterPluginDeclaration {
  const FlutterPluginDeclaration(this.platforms);

  final List<String> platforms;
}

/// A parsed `pubspec.yaml`.
final class Pubspec {
  const Pubspec({
    required this.path,
    required this.name,
    required this.version,
    required this.sdkConstraint,
    required this.flutterConstraint,
    required this.dependencies,
    required this.devDependencies,
    required this.dependencyOverrides,
    required this.hasFlutterSection,
    required this.plugin,
    required this.isModule,
    required this.workspace,
    required this.resolution,
  });

  factory Pubspec.parse(String path, String source) {
    final YamlNode root;
    try {
      root = loadYamlNode(source, sourceUrl: Uri.file(path));
    } on YamlException catch (e) {
      throw DocumentParseException(path, e.message,
          line: e.span == null ? null : e.span!.start.line + 1);
    }
    if (root is! YamlMap) {
      throw DocumentParseException(path, 'The pubspec must be a YAML map.');
    }

    final nameNode = root.nodes['name'];
    final name = nameNode is YamlScalar ? nameNode.value : null;
    if (name is! String || name.isEmpty) {
      throw DocumentParseException(path, 'Missing a "name" field.',
          line: nameNode == null ? null : nameNode.span.start.line + 1);
    }

    LocatedScalar? scalarAt(YamlNode? node) {
      if (node is! YamlScalar || node.value == null) return null;
      return LocatedScalar('${node.value}', refForNode(path, node));
    }

    final environment = root.nodes['environment'];
    final flutter = root.nodes['flutter'];
    final pluginNode = flutter is YamlMap ? flutter.nodes['plugin'] : null;
    FlutterPluginDeclaration? plugin;
    if (pluginNode is YamlMap) {
      final platforms = pluginNode.nodes['platforms'];
      plugin = FlutterPluginDeclaration(platforms is YamlMap
          ? platforms.keys.map((k) => '$k').toList()
          : const []);
    }
    final workspaceNode = root.nodes['workspace'];

    return Pubspec(
      path: path,
      name: name,
      version: scalarAt(root.nodes['version'])?.value,
      sdkConstraint:
          environment is YamlMap ? scalarAt(environment.nodes['sdk']) : null,
      flutterConstraint: environment is YamlMap
          ? scalarAt(environment.nodes['flutter'])
          : null,
      dependencies: _dependencies(path, root.nodes['dependencies']),
      devDependencies: _dependencies(path, root.nodes['dev_dependencies']),
      dependencyOverrides:
          _dependencies(path, root.nodes['dependency_overrides']),
      hasFlutterSection: flutter != null,
      plugin: plugin,
      isModule: flutter is YamlMap && flutter.nodes['module'] != null,
      workspace: workspaceNode is YamlList
          ? workspaceNode.nodes
              .whereType<YamlScalar>()
              .map((n) => '${n.value}')
              .toList()
          : const [],
      resolution: scalarAt(root.nodes['resolution'])?.value,
    );
  }

  final String path;
  final String name;
  final String? version;

  /// `environment.sdk`, as written.
  final LocatedScalar? sdkConstraint;

  /// `environment.flutter`, as written.
  final LocatedScalar? flutterConstraint;

  final Map<String, PubDependency> dependencies;
  final Map<String, PubDependency> devDependencies;
  final Map<String, PubDependency> dependencyOverrides;

  final bool hasFlutterSection;

  /// Present when this package is a Flutter plugin.
  final FlutterPluginDeclaration? plugin;

  /// Whether this is an add-to-app Flutter module.
  final bool isModule;

  /// Members of a pub workspace declared by this pubspec.
  final List<String> workspace;

  /// `resolution: workspace` for workspace members.
  final String? resolution;

  /// Whether the package depends on the Flutter SDK.
  bool get dependsOnFlutter => dependencies.values.any((d) =>
      d.source is SdkDependency &&
      (d.source as SdkDependency).sdk == 'flutter');

  VersionConstraint? get parsedSdkConstraint {
    final text = sdkConstraint?.value;
    if (text == null) return null;
    try {
      return VersionConstraint.parse(text);
    } on FormatException {
      return null;
    }
  }
}

Map<String, PubDependency> _dependencies(String path, YamlNode? node) {
  if (node is! YamlMap) return const {};
  final result = <String, PubDependency>{};
  for (final entry in node.nodes.entries) {
    final keyNode = entry.key as YamlNode;
    final name = '${keyNode.value}';
    result[name] =
        PubDependency(name, _source(entry.value), refForNode(path, keyNode));
  }
  return result;
}

PubDependencySource _source(YamlNode node) {
  if (node is YamlScalar) {
    return HostedDependency(node.value == null ? 'any' : '${node.value}');
  }
  if (node is YamlMap) {
    final map = node.value;
    if (map['sdk'] != null) return SdkDependency('${map['sdk']}');
    if (map['path'] != null) return PathDependency('${map['path']}');
    final git = map['git'];
    if (git is String) return GitDependency(git);
    if (git is Map) {
      return GitDependency('${git['url']}',
          ref: git['ref']?.toString(), path: git['path']?.toString());
    }
    if (map.containsKey('hosted') || map.containsKey('version')) {
      final hosted = map['hosted'];
      return HostedDependency('${map['version'] ?? 'any'}',
          hostedUrl:
              hosted is Map ? hosted['url']?.toString() : hosted?.toString());
    }
  }
  return UnknownDependency(node.span.text);
}
