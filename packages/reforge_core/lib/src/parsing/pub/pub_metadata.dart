import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import '../parse_diagnostic.dart';

/// How a locked package relates to the root package.
enum LockedDependencyKind {
  directMain,
  directDev,
  directOverridden,
  transitive
}

final class LockedPackage {
  const LockedPackage({
    required this.name,
    required this.version,
    required this.source,
    required this.kind,
  });

  final String name;

  /// The locked version as written.
  final String version;

  /// `hosted`, `path`, `git` or `sdk`.
  final String source;

  final LockedDependencyKind kind;

  Version? get parsedVersion {
    try {
      return Version.parse(version);
    } on FormatException {
      return null;
    }
  }
}

/// A parsed `pubspec.lock`.
final class PubspecLock {
  const PubspecLock({
    required this.packages,
    required this.dartSdkConstraint,
    required this.flutterSdkConstraint,
  });

  factory PubspecLock.parse(String path, String source) {
    final Object? root;
    try {
      root = loadYaml(source);
    } on YamlException catch (e) {
      throw DocumentParseException(path, e.message,
          line: e.span == null ? null : e.span!.start.line + 1);
    }
    if (root is! Map) {
      throw DocumentParseException(path, 'The lockfile must be a YAML map.');
    }
    final packages = <String, LockedPackage>{};
    final packagesNode = root['packages'];
    if (packagesNode is Map) {
      for (final entry in packagesNode.entries) {
        final value = entry.value;
        if (value is! Map) continue;
        packages['${entry.key}'] = LockedPackage(
          name: '${entry.key}',
          version: '${value['version'] ?? ''}',
          source: '${value['source'] ?? ''}',
          kind: switch ('${value['dependency']}') {
            'direct main' => LockedDependencyKind.directMain,
            'direct dev' => LockedDependencyKind.directDev,
            'direct overridden' => LockedDependencyKind.directOverridden,
            _ => LockedDependencyKind.transitive,
          },
        );
      }
    }
    final sdks = root['sdks'];
    return PubspecLock(
      packages: Map.unmodifiable(packages),
      dartSdkConstraint: sdks is Map ? sdks['dart']?.toString() : null,
      flutterSdkConstraint: sdks is Map ? sdks['flutter']?.toString() : null,
    );
  }

  final Map<String, LockedPackage> packages;

  /// The intersection of all packages' Dart SDK constraints (`sdks.dart`).
  final String? dartSdkConstraint;

  /// The intersection of all packages' Flutter SDK constraints
  /// (`sdks.flutter`).
  final String? flutterSdkConstraint;
}

final class PackageConfigEntry {
  const PackageConfigEntry({
    required this.name,
    required this.rootUri,
    required this.languageVersion,
  });

  final String name;
  final String rootUri;

  /// The package's language version (derived by pub from the lower bound of
  /// its SDK constraint), e.g. `2.12` or `3.4`.
  final String? languageVersion;

  /// Language version as a comparable [Version] (`3.4` becomes `3.4.0`).
  Version? get parsedLanguageVersion {
    final text = languageVersion;
    if (text == null) return null;
    try {
      return Version.parse('$text.0');
    } on FormatException {
      return null;
    }
  }
}

/// A parsed `.dart_tool/package_config.json`, written by `pub get`.
final class PackageConfig {
  const PackageConfig({
    required this.packages,
    required this.generatorVersion,
    required this.flutterVersion,
    required this.flutterRoot,
  });

  factory PackageConfig.parse(String path, String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (e) {
      throw DocumentParseException(path, e.message);
    }
    if (json is! Map<String, Object?>) {
      throw DocumentParseException(path, 'Expected a JSON object.');
    }
    final packages = <String, PackageConfigEntry>{};
    final list = json['packages'];
    if (list is List) {
      for (final item in list) {
        if (item is! Map<String, Object?>) continue;
        final name = item['name'];
        final rootUri = item['rootUri'];
        if (name is! String || rootUri is! String) continue;
        packages[name] = PackageConfigEntry(
          name: name,
          rootUri: rootUri,
          languageVersion: item['languageVersion'] as String?,
        );
      }
    }
    return PackageConfig(
      packages: Map.unmodifiable(packages),
      generatorVersion: json['generatorVersion'] as String?,
      flutterVersion: json['flutterVersion'] as String?,
      flutterRoot: json['flutterRoot'] as String?,
    );
  }

  final Map<String, PackageConfigEntry> packages;

  /// The Dart SDK version of the `pub` that wrote the file.
  final String? generatorVersion;

  /// The Flutter version that ran `pub get` (written by recent Flutter SDKs).
  final String? flutterVersion;

  final String? flutterRoot;
}

final class RegisteredPlugin {
  const RegisteredPlugin({
    required this.name,
    required this.path,
    required this.nativeBuild,
    required this.devDependency,
  });

  final String name;

  /// Absolute path of the plugin package on the machine that ran `pub get`.
  final String path;

  final bool nativeBuild;
  final bool devDependency;
}

/// A parsed `.flutter-plugins-dependencies` file, generated by the Flutter
/// tool on `pub get`.
final class FlutterPluginsDependencies {
  const FlutterPluginsDependencies({
    required this.pluginsByPlatform,
    required this.flutterVersion,
    required this.dateCreated,
    required this.swiftPackageManagerEnabled,
  });

  factory FlutterPluginsDependencies.parse(String path, String source) {
    final Object? json;
    try {
      json = jsonDecode(source);
    } on FormatException catch (e) {
      throw DocumentParseException(path, e.message);
    }
    if (json is! Map<String, Object?>) {
      throw DocumentParseException(path, 'Expected a JSON object.');
    }
    final byPlatform = <String, List<RegisteredPlugin>>{};
    final plugins = json['plugins'];
    if (plugins is Map<String, Object?>) {
      for (final entry in plugins.entries) {
        final list = entry.value;
        if (list is! List) continue;
        byPlatform[entry.key] = [
          for (final item in list)
            if (item is Map<String, Object?> && item['name'] is String)
              RegisteredPlugin(
                name: item['name']! as String,
                path: '${item['path'] ?? ''}',
                nativeBuild: item['native_build'] != false,
                devDependency: item['dev_dependency'] == true,
              ),
        ];
      }
    }
    final spm = json['swift_package_manager_enabled'];
    return FlutterPluginsDependencies(
      pluginsByPlatform: Map.unmodifiable(byPlatform),
      flutterVersion: json['version'] as String?,
      dateCreated: json['date_created'] as String?,
      swiftPackageManagerEnabled: switch (spm) {
        bool() => {'ios': spm, 'macos': spm},
        Map<String, Object?>() => {
            for (final e in spm.entries)
              if (e.value is bool) e.key: e.value! as bool,
          },
        _ => const {},
      },
    );
  }

  final Map<String, List<RegisteredPlugin>> pluginsByPlatform;

  /// The Flutter version that generated the file.
  final String? flutterVersion;

  final String? dateCreated;

  /// Whether the Swift Package Manager integration was enabled per platform
  /// when the file was generated.
  final Map<String, bool> swiftPackageManagerEnabled;
}

/// A parsed `.metadata` file, written by `flutter create`.
final class FlutterProjectMetadata {
  const FlutterProjectMetadata({
    required this.revision,
    required this.channel,
    required this.projectType,
    required this.createRevisions,
  });

  factory FlutterProjectMetadata.parse(String path, String source) {
    final Object? root;
    try {
      root = loadYaml(source);
    } on YamlException catch (e) {
      throw DocumentParseException(path, e.message,
          line: e.span == null ? null : e.span!.start.line + 1);
    }
    if (root is! Map) {
      throw DocumentParseException(path, 'Expected a YAML map.');
    }
    final version = root['version'];
    final createRevisions = <String, String>{};
    final migration = root['migration'];
    if (migration is Map && migration['platforms'] is List) {
      for (final platform in migration['platforms'] as List) {
        if (platform is Map &&
            platform['platform'] != null &&
            platform['create_revision'] != null) {
          createRevisions['${platform['platform']}'] =
              '${platform['create_revision']}';
        }
      }
    }
    return FlutterProjectMetadata(
      revision: version is Map ? version['revision']?.toString() : null,
      channel: version is Map ? version['channel']?.toString() : null,
      projectType: root['project_type']?.toString(),
      createRevisions: Map.unmodifiable(createRevisions),
    );
  }

  /// Flutter framework revision recorded by `flutter create` (or the last
  /// `flutter migrate`).
  final String? revision;
  final String? channel;

  /// `app`, `plugin`, `package`, `module`, `plugin_ffi`, ...
  final String? projectType;

  /// Revision each platform directory was created with, by platform name.
  final Map<String, String> createRevisions;
}
