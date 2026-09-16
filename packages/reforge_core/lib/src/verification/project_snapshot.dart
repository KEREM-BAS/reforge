import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// The content of the files that define a Flutter project and its host
/// platforms, captured before an external tool runs so that the tool's
/// changes can be reported and undone.
///
/// Captured, for every project directory:
/// - `pubspec.yaml`, `pubspec.lock`, `.gitignore`, `.metadata` and
///   `analysis_options.yaml`;
/// - every file below `android`, `ios`, `macos`, `linux`, `windows` and
///   `web`, except build output, dependency caches and files the Flutter tool
///   generates, which Flutter's app templates list in `.gitignore` (for
///   example `local.properties`, `gradlew` or `Generated.xcconfig`).
///
/// Signing secrets (`key.properties`, `*.keystore`, `*.jks`) are never read.
/// Symbolic links are not followed and files larger than 4 MiB are skipped.
final class ProjectSnapshot {
  ProjectSnapshot._(this.root, this._files);

  /// Captures the projects at [projectPaths] (workspace-relative, `''` for
  /// the root) below [root].
  factory ProjectSnapshot.capture(String root, Iterable<String> projectPaths) {
    final files = <String, List<int>>{};
    void addFile(String path) {
      final absolute = p.join(root, p.joinAll(path.split('/')));
      if (FileSystemEntity.typeSync(absolute, followLinks: false) !=
          FileSystemEntityType.file) {
        return;
      }
      final file = File(absolute);
      if (file.lengthSync() > _maximumFileSize) return;
      files[path] = file.readAsBytesSync();
    }

    void walk(String path) {
      final directory = Directory(p.join(root, p.joinAll(path.split('/'))));
      if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      final entries = directory.listSync(followLinks: false)
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final entry in entries) {
        final name = p.basename(entry.path);
        final child = '$path/$name';
        if (entry is Directory) {
          if (!_excludedDirectories.contains(name)) walk(child);
        } else if (entry is File && !_isRegenerated(name)) {
          addFile(child);
        }
      }
    }

    for (final project in projectPaths.toSet()) {
      final prefix = project.isEmpty ? '' : '$project/';
      for (final name in _projectFiles) {
        addFile('$prefix$name');
      }
      for (final platform in _platformDirectories) {
        walk('$prefix$platform');
      }
    }
    return ProjectSnapshot._(root, files);
  }

  static const _maximumFileSize = 4 * 1024 * 1024;

  static const _projectFiles = [
    'pubspec.yaml',
    'pubspec.lock',
    '.gitignore',
    '.metadata',
    'analysis_options.yaml',
  ];

  static const _platformDirectories = [
    'android',
    'ios',
    'macos',
    'linux',
    'windows',
    'web',
  ];

  /// Build output, caches and directories the Flutter tool recreates.
  static const _excludedDirectories = {
    'build',
    '.gradle',
    '.cxx',
    '.kotlin',
    'captures',
    '.idea',
    '.dart_tool',
    'Pods',
    '.symlinks',
    'ephemeral',
    '.generated',
    'DerivedData',
    'xcuserdata',
    'dgph',
    'App.framework',
    'Flutter.framework',
    'flutter_assets',
    '.build',
    '.swiftpm',
  };

  /// Generated files (from the `.gitignore` files of Flutter's app templates)
  /// and signing secrets.
  static bool _isRegenerated(String name) =>
      const {
        'local.properties',
        'gradlew',
        'gradlew.bat',
        'gradle-wrapper.jar',
        'key.properties',
        'Generated.xcconfig',
        'flutter_export_environment.sh',
        'Flutter.podspec',
        'app.flx',
        'app.zip',
        'generated_plugins.cmake',
        '.DS_Store',
      }.contains(name) ||
      name.endsWith('.keystore') ||
      name.endsWith('.jks') ||
      name.startsWith('GeneratedPluginRegistrant.') ||
      name.startsWith('generated_plugin_registrant.');

  final String root;
  final Map<String, List<int>> _files;

  /// Captured project-relative paths.
  Iterable<String> get paths => _files.keys;

  /// The captured content of [path], or `null` when it was not captured.
  List<int>? contentOf(String path) => _files[path];

  /// Files that differ between this snapshot and [after]: created, changed or
  /// deleted, sorted by path.
  List<SnapshotChange> changesTo(ProjectSnapshot after) {
    final changes = <SnapshotChange>[];
    for (final path in {..._files.keys, ...after._files.keys}) {
      final before = _files[path];
      final now = after._files[path];
      final beforeHash = before == null ? null : bytesHash(before);
      final afterHash = now == null ? null : bytesHash(now);
      if (beforeHash != afterHash) {
        changes.add(SnapshotChange(path, before, beforeHash, afterHash));
      }
    }
    return changes..sort((a, b) => a.path.compareTo(b.path));
  }
}

/// A difference between two snapshots.
final class SnapshotChange {
  const SnapshotChange(this.path, this.before, this.beforeHash, this.afterHash);

  final String path;

  /// The previous content; `null` when the file was created.
  final List<int>? before;

  final String? beforeHash;

  /// `null` when the file was deleted.
  final String? afterHash;
}

/// SHA-256 of [bytes]; equal to `contentHash` of the same text as UTF-8.
String bytesHash(List<int> bytes) => sha256.convert(bytes).toString();
