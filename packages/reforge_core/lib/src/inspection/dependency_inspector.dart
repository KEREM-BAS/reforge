import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/source.dart';
import '../fs/project_file_system.dart';
import '../model/darwin_project.dart';
import '../model/declarations.dart';
import '../model/dependencies.dart';
import '../model/flutter_project.dart';
import '../parsing/gradle/gradle_lexer.dart';
import '../parsing/gradle/gradle_script.dart';
import '../parsing/gradle/gradle_semantics.dart';
import '../parsing/parse_diagnostic.dart';
import '../parsing/pub/pub_metadata.dart';
import '../parsing/pub/pubspec.dart';
import '../parsing/ruby/podspec.dart';
import 'script_values.dart';

/// Opens the directories of resolved packages for reading.
abstract interface class PackageSources {
  /// A read-only view of the package directory at [absolutePath], or `null`
  /// when it is not available.
  ProjectFileSystem? open(String absolutePath);
}

/// Package directories on the local disk (the pub cache, path dependencies).
final class LocalPackageSources implements PackageSources {
  const LocalPackageSources();

  @override
  ProjectFileSystem? open(String absolutePath) =>
      Directory(absolutePath).existsSync()
          ? LocalProjectFileSystem(absolutePath)
          : null;
}

/// Package directories held in memory, for tests.
final class MemoryPackageSources implements PackageSources {
  MemoryPackageSources(this.packages);

  /// Files of each package, by absolute package directory.
  final Map<String, Map<String, String>> packages;

  @override
  ProjectFileSystem? open(String absolutePath) {
    final files = packages[p.normalize(absolutePath)];
    return files == null
        ? null
        : MemoryProjectFileSystem(files, rootPath: absolutePath);
  }
}

/// Reads the packages a project resolved with `pub get`.
///
/// Package directories come from `.dart_tool/package_config.json` (the
/// project's own, or the workspace root's for pub workspace members). Only
/// files inside each package directory are read, and nothing is executed.
final class DependencyInspector {
  DependencyInspector(this.sources);

  final PackageSources sources;

  static const _maxSourceFiles = 400;
  static const _maxDepth = 12;

  DependencyReport inspect(FlutterProject project, ProjectFileSystem files) {
    var configProject = project.path;
    var config = project.packageConfig;
    if (config == null && project.pubspec.resolution == 'workspace') {
      configProject = '';
      config = _readConfig(files, '.dart_tool/package_config.json');
    }
    if (config == null) {
      return const DependencyReport(configPath: null, packages: []);
    }
    final configPath =
        '${configProject.isEmpty ? '' : '$configProject/'}.dart_tool/package_config.json';
    final configDirectory = p.join(
        files.rootPath, p.joinAll(p.posix.dirname(configPath).split('/')));
    final base = Uri.directory(configDirectory);

    final packages = <ResolvedPackage>[];
    final unavailable = <String>[];
    for (final entry in config.packages.values) {
      final locked = project.lockfile?.packages[entry.name];
      if (entry.name == project.name || locked?.source == 'sdk') continue;
      final Uri root;
      try {
        root = base.resolve(entry.rootUri);
      } on FormatException {
        unavailable.add(entry.name);
        continue;
      }
      if (root.scheme != 'file') {
        unavailable.add(entry.name);
        continue;
      }
      final rootPath = p.normalize(root.toFilePath());
      final packageFiles = sources.open(rootPath);
      if (packageFiles == null) {
        unavailable.add(entry.name);
        continue;
      }
      packages.add(_inspectPackage(entry.name, rootPath, locked, packageFiles));
    }
    return DependencyReport(
      configPath: configPath,
      packages: packages,
      unavailable: unavailable,
    );
  }

  PackageConfig? _readConfig(ProjectFileSystem files, String path) {
    try {
      final content = files.readString(path);
      return content == null ? null : PackageConfig.parse(path, content);
    } on DocumentParseException {
      return null;
    } on FileReadException {
      return null;
    }
  }

  ResolvedPackage _inspectPackage(String name, String rootPath,
      LockedPackage? locked, ProjectFileSystem files) {
    Pubspec? pubspec;
    String? read(String path) {
      try {
        return files.readString(path);
      } on FileReadException {
        return null;
      }
    }

    final pubspecSource = read('pubspec.yaml');
    if (pubspecSource != null) {
      try {
        pubspec = Pubspec.parse('pubspec.yaml', pubspecSource);
      } on DocumentParseException {
        pubspec = null;
      }
    }
    final package = ResolvedPackage(
        name: name, rootPath: rootPath, locked: locked, pubspec: pubspec);

    AndroidPluginFacts? android;
    if (pubspec?.plugin != null) {
      final buildPath = files.fileExists('android/build.gradle.kts')
          ? 'android/build.gradle.kts'
          : files.fileExists('android/build.gradle')
              ? 'android/build.gradle'
              : null;
      final buildSource = buildPath == null ? null : read(buildPath);
      if (buildPath != null && buildSource != null) {
        final script =
            GradleScript.parse(package.displayPath(buildPath), buildSource);
        android = AndroidPluginFacts(
          buildFile: SourceRef(package.displayPath(buildPath)),
          declaresNamespace:
              script.isReliable ? _declaresNamespace(script) : null,
          kotlinPlugin:
              script.isReliable ? kotlinPluginApplication(script) : null,
          compileSdk: _literalCompileSdk(script),
          minSdk: _literalMinSdk(script),
          v1EmbeddingReferences: _v1EmbeddingReferences(package, files),
        );
      }
    }
    final podspecs = <String, Podspec>{};
    DarwinPluginFacts? darwin(DarwinPlatform platform) {
      final platforms = pubspec?.plugin?.platforms;
      // Plugins in the format before `platforms` supported Android and iOS.
      final supported = platforms != null &&
          (platforms.contains(platform.name) ||
              (platforms.isEmpty && platform == DarwinPlatform.ios));
      final path = supported ? _podspecPath(files, name, platform) : null;
      if (path == null) return null;
      final Podspec podspec;
      if (podspecs[path] case final parsed?) {
        podspec = parsed;
      } else {
        final source = read(path);
        if (source == null) return null;
        podspec =
            podspecs[path] = Podspec.parse(package.displayPath(path), source);
      }
      // CocoaPods accepts `macos` as another name for `osx`.
      final declaration = switch (platform) {
        DarwinPlatform.ios => podspec.platforms['ios'],
        DarwinPlatform.macos =>
          podspec.platforms['osx'] ?? podspec.platforms['macos'],
      };
      return DarwinPluginFacts(
        podspec: declaration?.location ?? SourceRef(package.displayPath(path)),
        minimumVersion: declaration?.version,
      );
    }

    return ResolvedPackage(
      name: name,
      rootPath: rootPath,
      locked: locked,
      pubspec: pubspec,
      android: android,
      ios: darwin(DarwinPlatform.ios),
      macos: darwin(DarwinPlatform.macos),
    );
  }

  /// The podspec of a plugin for [platform]: `ios/<name>.podspec` or
  /// `macos/<name>.podspec`, `darwin/<name>.podspec` (shared iOS and macOS
  /// sources), or the only podspec in those directories.
  static String? _podspecPath(
      ProjectFileSystem files, String name, DarwinPlatform platform) {
    for (final directory in [platform.directory, 'darwin']) {
      final named = '$directory/$name.podspec';
      if (files.fileExists(named)) return named;
      final podspecs = files
          .listDirectory(directory)
          .where((entry) => entry.endsWith('.podspec'))
          .toList();
      if (podspecs.length == 1) return podspecs.single;
    }
    return null;
  }

  /// `compileSdk` / `compileSdkVersion` of the `android {}` block when it is
  /// an integer literal.
  static int? _literalCompileSdk(GradleScript script) {
    if (!script.isReliable) return null;
    final found = findProperty(script.findBlock(const ['android']),
        const ['compileSdk', 'compileSdkVersion']);
    if (found == null) return null;
    return switch (interpretScriptValue(script, found.$1, found.$2)) {
      LiteralInt(:final value) => value,
      _ => null,
    };
  }

  /// `minSdk` / `minSdkVersion` of `android { defaultConfig {} }` when it is
  /// an integer literal. Values from the app project (`project.ext`,
  /// `flutter.minSdkVersion`) are not the plugin's own requirement.
  static int? _literalMinSdk(GradleScript script) {
    if (!script.isReliable) return null;
    // Gradle merges repeated `android` and `defaultConfig` blocks; the last
    // assignment wins.
    (GradleStatement, List<GradleToken>)? found;
    for (final android in script.blocksNamed('android')) {
      for (final defaultConfig
          in android.blocks.first.blocksNamed('defaultConfig')) {
        found = findProperty(defaultConfig.blocks.first,
                const ['minSdk', 'minSdkVersion']) ??
            found;
      }
    }
    if (found == null) return null;
    return switch (interpretScriptValue(script, found.$1, found.$2)) {
      LiteralInt(:final value) => value,
      _ => null,
    };
  }

  /// Whether the script sets `namespace` inside an `android {}` block (at
  /// any depth, e.g. inside `if (...)`), or `android.namespace` at the top
  /// level.
  static bool _declaresNamespace(GradleScript script) {
    bool walk(List<GradleStatement> statements) {
      for (final statement in statements) {
        if (statement.propertyValue('namespace') != null) return true;
        for (final block in [...statement.blocks, ...statement.innerBlocks]) {
          if (walk(block.statements)) return true;
        }
      }
      return false;
    }

    for (final statement in script.statements) {
      if (statement.propertyValue('android.namespace') != null) return true;
      if (statement.isBlockNamed('android') &&
          statement.blocks.any((block) => walk(block.statements))) {
        return true;
      }
    }
    return false;
  }

  /// The first use of `PluginRegistry.Registrar` in each Java or Kotlin
  /// source file below `android/src`. Comments and strings are ignored.
  static List<SourceRef> _v1EmbeddingReferences(
      ResolvedPackage package, ProjectFileSystem files) {
    final references = <SourceRef>[];
    var visited = 0;
    void walk(String directory, int depth) {
      if (depth > _maxDepth) return;
      for (final entry in files.listDirectory(directory)) {
        if (visited >= _maxSourceFiles) return;
        if (entry.endsWith('.java') || entry.endsWith('.kt')) {
          visited++;
          final String? source;
          try {
            source = files.readString(entry);
          } on FileReadException {
            continue;
          }
          if (source == null || !source.contains('Registrar')) continue;
          final tokens =
              GradleLexer(source, GradleDialect.kotlin).tokenize().tokens;
          for (var i = 0; i + 2 < tokens.length; i++) {
            if (tokens[i].isIdentifier('PluginRegistry') &&
                tokens[i + 1].isPunctuation('.') &&
                tokens[i + 2].isIdentifier('Registrar')) {
              references.add(SourceRef(package.displayPath(entry),
                  line: LineIndex(source).lineOf(tokens[i].offset)));
              break;
            }
          }
        } else if (files.directoryExists(entry)) {
          walk(entry, depth + 1);
        }
      }
    }

    walk('android/src', 0);
    return references;
  }
}
