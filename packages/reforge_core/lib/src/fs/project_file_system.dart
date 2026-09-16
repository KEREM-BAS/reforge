import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../common/errors.dart';

/// A read-only view of a project directory.
///
/// All paths are project-relative and use `/` separators. Implementations
/// must never expose content outside the project root.
abstract interface class ProjectFileSystem {
  /// Absolute path of the project root. Used for display and for running
  /// external tools, never for resolving project files.
  String get rootPath;

  bool fileExists(String path);

  bool directoryExists(String path);

  /// Returns the UTF-8 decoded content of [path], or `null` when the file
  /// does not exist.
  ///
  /// Throws [FileReadException] when the file exists but cannot be read
  /// safely (not UTF-8, escapes the project root, I/O error).
  String? readString(String path);

  /// Lists entries directly inside [directory] (project-relative paths),
  /// sorted for determinism. Returns an empty list when the directory does not
  /// exist.
  List<String> listDirectory(String directory);
}

/// A file exists but cannot be read safely.
final class FileReadException implements Exception {
  const FileReadException(this.path, this.reason);

  final String path;
  final String reason;

  @override
  String toString() => 'Cannot read $path: $reason';
}

/// Normalizes a project-relative path and rejects paths escaping the root.
String normalizeProjectPath(String path) {
  final normalized = p.posix.normalize(path.replaceAll(r'\', '/'));
  if (normalized == '.' || normalized.isEmpty) return '';
  if (p.posix.isAbsolute(normalized) ||
      normalized == '..' ||
      normalized.startsWith('../')) {
    throw InternalException(
      'PATH_OUTSIDE_PROJECT',
      'Path "$path" is outside the project root.',
    );
  }
  return normalized;
}

/// The SHA-256 of [content] encoded as UTF-8, as a lowercase hex string.
String contentHash(String content) =>
    sha256.convert(utf8.encode(content)).toString();

/// Reads a project from the local disk.
///
/// Symbolic links are followed only when their target stays inside the
/// project root; a link pointing elsewhere (for example at `~/.ssh`) is
/// treated as unreadable so a hostile repository cannot make Reforge read or
/// report files outside the project.
final class LocalProjectFileSystem implements ProjectFileSystem {
  LocalProjectFileSystem(String rootPath)
      : rootPath = p.normalize(p.absolute(rootPath)),
        _resolvedRoot = _resolveRoot(rootPath);

  @override
  final String rootPath;
  final String _resolvedRoot;

  static String _resolveRoot(String rootPath) {
    final directory = Directory(rootPath);
    if (!directory.existsSync()) {
      return p.normalize(p.absolute(rootPath));
    }
    return p.normalize(directory.resolveSymbolicLinksSync());
  }

  String _absolute(String path) {
    final relative = normalizeProjectPath(path);
    return relative.isEmpty
        ? rootPath
        : p.join(rootPath, p.joinAll(relative.split('/')));
  }

  bool _isInsideRoot(String resolved) {
    final normalized = p.normalize(resolved);
    return normalized == _resolvedRoot ||
        p.isWithin(_resolvedRoot, normalized);
  }

  @override
  bool fileExists(String path) =>
      FileSystemEntity.typeSync(_absolute(path)) == FileSystemEntityType.file;

  @override
  bool directoryExists(String path) => Directory(_absolute(path)).existsSync();

  @override
  String? readString(String path) {
    final file = File(_absolute(path));
    if (!file.existsSync()) return null;
    final String resolved;
    try {
      resolved = file.resolveSymbolicLinksSync();
    } on FileSystemException catch (e) {
      throw FileReadException(path, e.message);
    }
    if (!_isInsideRoot(resolved)) {
      throw FileReadException(
        path,
        'it is a symbolic link pointing outside the project root',
      );
    }
    try {
      final bytes = file.readAsBytesSync();
      return utf8.decode(bytes);
    } on FormatException {
      throw FileReadException(path, 'it is not valid UTF-8');
    } on FileSystemException catch (e) {
      throw FileReadException(path, e.message);
    }
  }

  @override
  List<String> listDirectory(String directory) {
    final dir = Directory(_absolute(directory));
    if (!dir.existsSync()) return const [];
    final relativeBase = normalizeProjectPath(directory);
    final entries = <String>[];
    try {
      for (final entity in dir.listSync(followLinks: false)) {
        final name = p.basename(entity.path);
        entries.add(relativeBase.isEmpty ? name : '$relativeBase/$name');
      }
    } on FileSystemException {
      return const [];
    }
    entries.sort();
    return entries;
  }
}

/// A file system that layers in-memory writes over a base file system.
///
/// The planner applies proposed edits to an overlay so that later recipes
/// observe the migrated state without touching the disk. The overlay also
/// records every base file it consulted, which becomes the plan's input
/// fingerprint.
final class OverlayFileSystem implements ProjectFileSystem {
  OverlayFileSystem(this.base);

  final ProjectFileSystem base;
  final Map<String, String> _writes = {};
  final Map<String, String?> _observed = {};

  @override
  String get rootPath => base.rootPath;

  /// Files that were read from the base, mapped to their content hash
  /// (`null` when the file did not exist).
  Map<String, String?> get observedInputs => Map.unmodifiable(_observed);

  /// Files written to the overlay whose content differs from the base.
  Map<String, String> get changedFiles {
    final changed = <String, String>{};
    for (final entry in _writes.entries) {
      if (_baseContent(entry.key) != entry.value) {
        changed[entry.key] = entry.value;
      }
    }
    return changed;
  }

  String? _baseContent(String path) {
    final content = base.readString(path);
    _observed.putIfAbsent(
        path, () => content == null ? null : contentHash(content));
    return content;
  }

  void writeString(String path, String content) {
    _writes[normalizeProjectPath(path)] = content;
  }

  /// Creates an independent copy with the same pending writes.
  OverlayFileSystem fork() {
    final copy = OverlayFileSystem(base);
    copy._writes.addAll(_writes);
    copy._observed.addAll(_observed);
    return copy;
  }

  /// Records observations made by another overlay over the same base.
  void absorbObservations(OverlayFileSystem other) {
    for (final entry in other._observed.entries) {
      _observed.putIfAbsent(entry.key, () => entry.value);
    }
  }

  @override
  bool fileExists(String path) {
    final normalized = normalizeProjectPath(path);
    if (_writes.containsKey(normalized)) return true;
    return _baseContent(normalized) != null;
  }

  @override
  bool directoryExists(String path) {
    final normalized = normalizeProjectPath(path);
    final prefix = normalized.isEmpty ? '' : '$normalized/';
    if (_writes.keys.any((key) => key.startsWith(prefix))) return true;
    return base.directoryExists(normalized);
  }

  @override
  String? readString(String path) {
    final normalized = normalizeProjectPath(path);
    final written = _writes[normalized];
    if (written != null) return written;
    return _baseContent(normalized);
  }

  @override
  List<String> listDirectory(String directory) {
    final normalized = normalizeProjectPath(directory);
    final entries = base.listDirectory(normalized).toSet();
    final prefix = normalized.isEmpty ? '' : '$normalized/';
    for (final key in _writes.keys) {
      if (!key.startsWith(prefix)) continue;
      final rest = key.substring(prefix.length);
      final slash = rest.indexOf('/');
      entries.add(prefix + (slash == -1 ? rest : rest.substring(0, slash)));
    }
    return entries.toList()..sort();
  }
}

/// An in-memory project, used by tests and by tooling that analyzes content
/// not stored on disk.
final class MemoryProjectFileSystem implements ProjectFileSystem {
  MemoryProjectFileSystem(Map<String, String> files, {this.rootPath = '/memory'})
      : _files = {
          for (final entry in files.entries)
            normalizeProjectPath(entry.key): entry.value,
        };

  final Map<String, String> _files;

  @override
  final String rootPath;

  @override
  bool fileExists(String path) =>
      _files.containsKey(normalizeProjectPath(path));

  @override
  bool directoryExists(String path) {
    final normalized = normalizeProjectPath(path);
    if (normalized.isEmpty) return true;
    return _files.keys.any((key) => key.startsWith('$normalized/'));
  }

  @override
  String? readString(String path) => _files[normalizeProjectPath(path)];

  @override
  List<String> listDirectory(String directory) {
    final normalized = normalizeProjectPath(directory);
    final prefix = normalized.isEmpty ? '' : '$normalized/';
    final entries = <String>{};
    for (final key in _files.keys) {
      if (!key.startsWith(prefix)) continue;
      final rest = key.substring(prefix.length);
      final slash = rest.indexOf('/');
      entries.add(prefix + (slash == -1 ? rest : rest.substring(0, slash)));
    }
    return entries.toList()..sort();
  }
}
