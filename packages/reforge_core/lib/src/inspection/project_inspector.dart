import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import '../common/errors.dart';
import '../common/source.dart';
import '../fs/project_file_system.dart';
import '../knowledge/knowledge_base.dart';
import '../model/darwin_project.dart';
import '../model/declarations.dart';
import '../model/flutter_project.dart';
import '../parsing/parse_diagnostic.dart';
import '../parsing/pub/pub_metadata.dart';
import '../parsing/pub/pubspec.dart';
import 'android_inspector.dart';
import 'darwin_inspector.dart';

/// Builds the typed model of a workspace and its Flutter projects.
///
/// Inspection only reads files. It never executes project code or external
/// tools, so it is safe to run on untrusted repositories.
final class ProjectInspector {
  ProjectInspector(this.files, {KnowledgeBase? knowledge})
      : knowledge = knowledge ?? KnowledgeBase.bundled,
        _android = AndroidInspector(files),
        _ios = DarwinInspector(files, DarwinPlatform.ios),
        _macos = DarwinInspector(files, DarwinPlatform.macos);

  final ProjectFileSystem files;
  final KnowledgeBase knowledge;
  final AndroidInspector _android;
  final DarwinInspector _ios;
  final DarwinInspector _macos;

  /// Inspects the workspace rooted at the file system root.
  ///
  /// Throws [InvalidProjectException] when no Flutter project can be found.
  Workspace inspectWorkspace() {
    final problems = <ParseProblem>[];
    final rootPubspec = _readPubspec('', problems);
    if (rootPubspec == null) {
      if (problems.isNotEmpty) {
        final problem = problems.first;
        throw InvalidProjectException(
          'PUBSPEC_INVALID',
          'pubspec.yaml could not be parsed: ${problem.message}',
          hints: [
            'Fix ${problem.path}${problem.line == null ? '' : ':${problem.line}'} and run Reforge again.',
          ],
        );
      }
      throw InvalidProjectException(
        'PROJECT_NOT_FOUND',
        'No pubspec.yaml found in ${files.rootPath}.',
        hints: const [
          'Run Reforge from the root of a Flutter project or workspace, or pass --project.',
        ],
      );
    }

    final memberPaths = <String>[];
    var layout = 'single';
    if (rootPubspec.workspace.isNotEmpty) {
      layout = 'pubWorkspace';
      memberPaths.addAll(rootPubspec.workspace.map(normalizeProjectPath));
    } else {
      final melosPatterns = _melosPackagePatterns(problems);
      if (melosPatterns.isNotEmpty) {
        layout = 'melos';
        memberPaths.addAll(_expandPatterns(melosPatterns));
      }
    }

    final projects = <FlutterProject>[];
    final rootProject = _projectFrom('', rootPubspec);
    if (rootProject.kind != FlutterProjectKind.dartPackage ||
        memberPaths.isEmpty) {
      projects.add(rootProject);
    }
    for (final memberPath in memberPaths.toSet()) {
      if (memberPath.isEmpty) continue;
      final pubspec = _readPubspec(memberPath, problems);
      if (pubspec == null) continue;
      projects.add(_projectFrom(memberPath, pubspec));
    }

    final flutterProjects = projects
        .where((p) => p.kind != FlutterProjectKind.dartPackage)
        .toList();
    if (flutterProjects.isEmpty) {
      throw InvalidProjectException(
        'PROJECT_NOT_FLUTTER',
        '${rootPubspec.name} does not depend on the Flutter SDK.',
        hints: const [
          'Reforge works with Flutter apps, plugins, modules and packages.'
        ],
      );
    }
    return Workspace(
      rootPath: files.rootPath,
      projects: projects,
      layout: layout,
      problems: problems,
    );
  }

  /// Inspects the single project at the workspace-relative [projectPath].
  ///
  /// Throws [InvalidProjectException] when its pubspec cannot be read.
  FlutterProject inspectProject(String projectPath) {
    final problems = <ParseProblem>[];
    final pubspec = _readPubspec(projectPath, problems);
    if (pubspec == null) {
      throw InvalidProjectException(
        'PUBSPEC_INVALID',
        problems.isEmpty
            ? 'No pubspec.yaml found in "$projectPath".'
            : 'pubspec.yaml could not be parsed: ${problems.first.message}',
      );
    }
    return _projectFrom(projectPath, pubspec);
  }

  Pubspec? _readPubspec(String projectPath, List<ParseProblem> problems) {
    final path = _join(projectPath, 'pubspec.yaml');
    try {
      final content = files.readString(path);
      if (content == null) return null;
      return Pubspec.parse(path, content);
    } on DocumentParseException catch (e) {
      problems.add(ParseProblem(path, e.message, line: e.line));
    } on FileReadException catch (e) {
      problems.add(ParseProblem(path, e.reason));
    }
    return null;
  }

  FlutterProject _projectFrom(String projectPath, Pubspec pubspec) {
    final problems = <ParseProblem>[];

    T? optional<T>(
        String relative, T Function(String path, String content) parse) {
      final path = _join(projectPath, relative);
      try {
        final content = files.readString(path);
        return content == null ? null : parse(path, content);
      } on DocumentParseException catch (e) {
        problems.add(ParseProblem(path, e.message, line: e.line));
      } on FileReadException catch (e) {
        problems.add(ParseProblem(path, e.reason));
      }
      return null;
    }

    final lockfile = optional('pubspec.lock', PubspecLock.parse);
    final packageConfig =
        optional('.dart_tool/package_config.json', PackageConfig.parse);
    final pluginRegistry = optional(
        '.flutter-plugins-dependencies', FlutterPluginsDependencies.parse);
    final metadata = optional('.metadata', FlutterProjectMetadata.parse);

    final android = _android.inspect(projectPath);
    final ios = _ios.inspect(projectPath);
    final macos = _macos.inspect(projectPath);
    if (android != null) problems.addAll(android.problems);
    if (ios != null) problems.addAll(ios.problems);
    if (macos != null) problems.addAll(macos.problems);

    return FlutterProject(
      path: projectPath,
      pubspec: pubspec,
      kind: _kindOf(projectPath, pubspec, metadata),
      lockfile: lockfile,
      packageConfig: packageConfig,
      pluginRegistry: pluginRegistry,
      metadata: metadata,
      flutterVersionObservations: _flutterVersionObservations(
          projectPath, packageConfig, pluginRegistry, metadata, problems),
      android: android,
      ios: ios,
      macos: macos,
      otherPlatforms: [
        for (final platform in const ['web', 'linux', 'windows'])
          if (files.directoryExists(_join(projectPath, platform))) platform,
      ],
      problems: problems,
    );
  }

  FlutterProjectKind _kindOf(
      String projectPath, Pubspec pubspec, FlutterProjectMetadata? metadata) {
    switch (metadata?.projectType) {
      case 'app':
        return FlutterProjectKind.app;
      case 'plugin' || 'plugin_ffi':
        return FlutterProjectKind.plugin;
      case 'module':
        return FlutterProjectKind.module;
      case 'package' || 'package_ffi':
        return FlutterProjectKind.package;
    }
    if (pubspec.plugin != null) return FlutterProjectKind.plugin;
    if (pubspec.isModule) return FlutterProjectKind.module;
    if (!pubspec.dependsOnFlutter && !pubspec.hasFlutterSection) {
      return FlutterProjectKind.dartPackage;
    }
    final hasHost = const ['android', 'ios', 'macos']
        .any((host) => files.directoryExists(_join(projectPath, host)));
    return hasHost ? FlutterProjectKind.app : FlutterProjectKind.package;
  }

  List<FlutterVersionObservation> _flutterVersionObservations(
    String projectPath,
    PackageConfig? packageConfig,
    FlutterPluginsDependencies? pluginRegistry,
    FlutterProjectMetadata? metadata,
    List<ParseProblem> problems,
  ) {
    final observations = <FlutterVersionObservation>[];
    Version? parse(String text) {
      try {
        return Version.parse(text);
      } on FormatException {
        return null;
      }
    }

    // Version managers may be configured at the project or at any parent
    // directory up to the workspace root.
    final searchPaths = <String>[projectPath];
    var cursor = projectPath;
    while (cursor.isNotEmpty) {
      final slash = cursor.lastIndexOf('/');
      cursor = slash == -1 ? '' : cursor.substring(0, slash);
      searchPaths.add(cursor);
    }

    for (final directory in searchPaths) {
      final fvmrc = _join(directory, '.fvmrc');
      final legacyFvm = _join(directory, '.fvm/fvm_config.json');
      for (final (path, key) in [
        (fvmrc, 'flutter'),
        (legacyFvm, 'flutterSdkVersion')
      ]) {
        try {
          final content = files.readString(path);
          if (content == null) continue;
          final json = jsonDecode(content);
          final value = json is Map ? json[key] : null;
          if (value is String) {
            observations.add(FlutterVersionObservation(
              FlutterVersionSignal.fvm,
              value,
              SourceRef(path),
              version: parse(value),
            ));
          }
        } on FormatException catch (e) {
          problems.add(ParseProblem(path, 'Invalid JSON: ${e.message}'));
        } on FileReadException catch (e) {
          problems.add(ParseProblem(path, e.reason));
        }
      }
      final toolVersions = _join(directory, '.tool-versions');
      try {
        final content = files.readString(toolVersions);
        if (content != null) {
          final lines = content.split('\n');
          for (var i = 0; i < lines.length; i++) {
            final parts = lines[i].trim().split(RegExp(r'\s+'));
            if (parts.length >= 2 && parts.first == 'flutter') {
              final value = parts[1];
              // asdf-flutter versions look like "3.19.0-stable".
              final versionText = value.split('-').first;
              observations.add(FlutterVersionObservation(
                FlutterVersionSignal.toolVersions,
                value,
                SourceRef(toolVersions, line: i + 1),
                version: parse(versionText),
              ));
            }
          }
        }
      } on FileReadException catch (e) {
        problems.add(ParseProblem(toolVersions, e.reason));
      }
    }

    if (packageConfig?.flutterVersion case final version?) {
      observations.add(FlutterVersionObservation(
        FlutterVersionSignal.packageConfig,
        version,
        SourceRef(_join(projectPath, '.dart_tool/package_config.json')),
        version: parse(version),
      ));
    }
    if (pluginRegistry?.flutterVersion case final version?) {
      observations.add(FlutterVersionObservation(
        FlutterVersionSignal.pluginRegistry,
        version,
        SourceRef(_join(projectPath, '.flutter-plugins-dependencies')),
        version: parse(version),
      ));
    }
    if (metadata?.revision case final revision?) {
      observations.add(FlutterVersionObservation(
        FlutterVersionSignal.metadataRevision,
        revision,
        SourceRef(_join(projectPath, '.metadata')),
        version: knowledge.flutterVersionOfRevision(revision),
      ));
    }
    return observations;
  }

  List<String> _melosPackagePatterns(List<ParseProblem> problems) {
    const path = 'melos.yaml';
    try {
      final content = files.readString(path);
      if (content == null) return const [];
      final yaml = loadYaml(content);
      final packages = yaml is Map ? yaml['packages'] : null;
      if (packages is! List) return const [];
      return packages.map((p) => '$p').toList();
    } on YamlException catch (e) {
      problems.add(ParseProblem(path, e.message,
          line: e.span == null ? null : e.span!.start.line + 1));
    } on FileReadException catch (e) {
      problems.add(ParseProblem(path, e.reason));
    }
    return const [];
  }

  /// Expands Melos package globs of the forms `dir/*` and `dir/**`.
  List<String> _expandPatterns(List<String> patterns) {
    final results = <String>{};
    const ignored = {
      'build',
      '.dart_tool',
      'ios',
      'android',
      'macos',
      'linux',
      'windows',
      'web',
      'node_modules',
      '.git'
    };
    void walk(String directory, int depth, int maxDepth) {
      if (files.fileExists(_join(directory, 'pubspec.yaml')) &&
          directory.isNotEmpty) {
        results.add(directory);
      }
      if (depth >= maxDepth) return;
      for (final entry in files.listDirectory(directory)) {
        final name = entry.split('/').last;
        if (ignored.contains(name) || name.startsWith('.')) continue;
        if (files.directoryExists(entry)) walk(entry, depth + 1, maxDepth);
      }
    }

    for (final pattern in patterns) {
      final normalized = pattern.endsWith('/')
          ? pattern.substring(0, pattern.length - 1)
          : pattern;
      if (normalized.endsWith('/**')) {
        walk(normalized.substring(0, normalized.length - 3), 0, 6);
      } else if (normalized.endsWith('/*')) {
        final base = normalized.substring(0, normalized.length - 2);
        for (final entry in files.listDirectory(base)) {
          if (files.fileExists('$entry/pubspec.yaml')) results.add(entry);
        }
      } else if (!normalized.contains('*') &&
          files.fileExists(_join(normalized, 'pubspec.yaml'))) {
        results.add(normalized);
      }
    }
    return results.toList()..sort();
  }

  static String _join(String base, String child) =>
      base.isEmpty ? child : '$base/$child';
}
