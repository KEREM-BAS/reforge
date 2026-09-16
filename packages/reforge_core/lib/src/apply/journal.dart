import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/errors.dart';
import '../fs/project_file_system.dart';

enum SessionStatus {
  /// Files are being written.
  applying,

  /// Every file was written.
  applied,

  /// Writing failed; written files were restored from backups.
  failed,

  /// The session was rolled back.
  rolledBack,
}

/// A file changed by a session.
final class JournalFile {
  const JournalFile({
    required this.path,
    required this.beforeHash,
    required this.afterHash,
    required this.written,
  });

  factory JournalFile.fromJson(Map<String, Object?> json) => JournalFile(
        path: json['path']! as String,
        beforeHash: json['beforeHash']! as String,
        afterHash: json['afterHash']! as String,
        written: json['written']! as bool,
      );

  /// Project-relative path.
  final String path;

  /// SHA-256 of the content before the migration (the backup's content).
  final String beforeHash;

  /// SHA-256 of the content Reforge wrote.
  final String afterHash;

  /// Whether the new content was written.
  final bool written;

  JournalFile markWritten() => JournalFile(
      path: path, beforeHash: beforeHash, afterHash: afterHash, written: true);

  Map<String, Object?> toJson() => {
        'path': path,
        'beforeHash': beforeHash,
        'afterHash': afterHash,
        'written': written,
      };
}

/// The outcome of one verification check, recorded in the journal.
final class VerificationRecord {
  const VerificationRecord({
    required this.check,
    required this.status,
    required this.summary,
    required this.recordedAt,
    this.command,
    this.exitCode,
    this.duration,
    this.logFile,
    this.flutterVersion,
    this.details = const [],
    this.modifiedFiles = const [],
  });

  factory VerificationRecord.fromJson(Map<String, Object?> json) =>
      VerificationRecord(
        check: json['check']! as String,
        status: json['status']! as String,
        summary: json['summary']! as String,
        recordedAt: DateTime.parse(json['recordedAt']! as String),
        command: json['command'] as String?,
        exitCode: json['exitCode'] as int?,
        duration: json['durationMs'] == null
            ? null
            : Duration(milliseconds: json['durationMs']! as int),
        logFile: json['logFile'] as String?,
        flutterVersion: json['flutterVersion'] as String?,
        details: [
          for (final detail in (json['details'] as List?) ?? const [])
            detail as String,
        ],
        modifiedFiles: [
          for (final path in (json['modifiedFiles'] as List?) ?? const [])
            path as String,
        ],
      );

  /// `static`, `pubGet`, `analyze`, `androidBuild`, `iosBuild`.
  final String check;

  /// `passed`, `failed` or `skipped`.
  final String status;
  final String summary;
  final DateTime recordedAt;
  final String? command;
  final int? exitCode;
  final Duration? duration;

  /// Log path relative to the project root.
  final String? logFile;

  /// The Flutter version that ran the check.
  final String? flutterVersion;

  final List<String> details;

  /// Project configuration files the checked tool modified while running
  /// (for example Flutter's own migrations during `flutter build`).
  final List<String> modifiedFiles;

  Map<String, Object?> toJson() => {
        'check': check,
        'status': status,
        'summary': summary,
        'recordedAt': recordedAt.toUtc().toIso8601String(),
        if (command != null) 'command': command,
        if (exitCode != null) 'exitCode': exitCode,
        if (duration != null) 'durationMs': duration!.inMilliseconds,
        if (logFile != null) 'logFile': logFile,
        if (flutterVersion != null) 'flutterVersion': flutterVersion,
        if (details.isNotEmpty) 'details': details,
        if (modifiedFiles.isNotEmpty) 'modifiedFiles': modifiedFiles,
      };
}

/// A recorded migration: what was planned, what was written, how it was
/// verified.
final class MigrationSession {
  MigrationSession({
    required this.id,
    required this.createdAt,
    required this.status,
    required this.reforgeVersion,
    required this.knowledgeBase,
    required this.targetFlutter,
    required this.planId,
    required this.plan,
    required this.files,
    this.verifications = const [],
    this.finishedAt,
    this.rolledBackAt,
    this.failure,
  });

  factory MigrationSession.fromJson(Map<String, Object?> json) =>
      MigrationSession(
        id: json['id']! as String,
        createdAt: DateTime.parse(json['createdAt']! as String),
        status: SessionStatus.values.byName(json['status']! as String),
        reforgeVersion: json['reforgeVersion']! as String,
        knowledgeBase: json['knowledgeBase']! as String,
        targetFlutter: json['targetFlutter']! as String,
        planId: json['planId']! as String,
        plan: json['plan']! as Map<String, Object?>,
        files: [
          for (final file in json['files']! as List)
            JournalFile.fromJson(file as Map<String, Object?>),
        ],
        verifications: [
          for (final record in (json['verifications'] as List?) ?? const [])
            VerificationRecord.fromJson(record as Map<String, Object?>),
        ],
        finishedAt: json['finishedAt'] == null
            ? null
            : DateTime.parse(json['finishedAt']! as String),
        rolledBackAt: json['rolledBackAt'] == null
            ? null
            : DateTime.parse(json['rolledBackAt']! as String),
        failure: json['failure'] as String?,
      );

  final String id;
  final DateTime createdAt;
  SessionStatus status;
  final String reforgeVersion;
  final String knowledgeBase;
  final String targetFlutter;
  final String planId;

  /// The plan as JSON (without diffs), for reports and verification.
  final Map<String, Object?> plan;

  List<JournalFile> files;
  List<VerificationRecord> verifications;
  DateTime? finishedAt;
  DateTime? rolledBackAt;
  String? failure;

  Map<String, Object?> toJson() => {
        'id': id,
        'createdAt': createdAt.toUtc().toIso8601String(),
        'status': status.name,
        'reforgeVersion': reforgeVersion,
        'knowledgeBase': knowledgeBase,
        'targetFlutter': targetFlutter,
        'planId': planId,
        'files': [for (final file in files) file.toJson()],
        'verifications': [for (final record in verifications) record.toJson()],
        if (finishedAt != null)
          'finishedAt': finishedAt!.toUtc().toIso8601String(),
        if (rolledBackAt != null)
          'rolledBackAt': rolledBackAt!.toUtc().toIso8601String(),
        if (failure != null) 'failure': failure,
        'plan': plan,
      };
}

/// Stores migration sessions in `.reforge/` inside the project.
///
/// The directory contains its own `.gitignore`, so sessions and backups are
/// never committed by accident.
final class Journal {
  Journal(this.projectRoot);

  final String projectRoot;

  String get directory => p.join(projectRoot, '.reforge');
  String get _sessionsDirectory => p.join(directory, 'sessions');

  String sessionDirectory(String id) => p.join(_sessionsDirectory, id);

  String backupFile(String sessionId, String projectPath) => p.joinAll(
      [sessionDirectory(sessionId), 'backups', ...projectPath.split('/')]);

  String logsDirectory(String sessionId) =>
      p.join(sessionDirectory(sessionId), 'logs');

  void _ensureDirectory() {
    Directory(_sessionsDirectory).createSync(recursive: true);
    final ignore = File(p.join(directory, '.gitignore'));
    if (!ignore.existsSync()) {
      ignore.writeAsStringSync(
          '# Created by Reforge: migration journals and backups stay local.\n*\n');
    }
  }

  /// Takes an exclusive lock on the project for the duration of [action].
  T withLock<T>(T Function() action) {
    _ensureDirectory();
    final lock = File(p.join(directory, 'lock'));
    try {
      lock.createSync(exclusive: true);
    } on FileSystemException {
      throw MigrationBlockedException(
        'PROJECT_LOCKED',
        'Another Reforge process is changing this project (${lock.path}).',
        hints: const [
          'If no other Reforge process is running, delete the lock file.',
        ],
      );
    }
    try {
      lock.writeAsStringSync('pid $pid\n');
      return action();
    } finally {
      if (lock.existsSync()) lock.deleteSync();
    }
  }

  void save(MigrationSession session) {
    _ensureDirectory();
    final directory = Directory(sessionDirectory(session.id))
      ..createSync(recursive: true);
    writeFileAtomically(p.join(directory.path, 'session.json'),
        const JsonEncoder.withIndent('  ').convert(session.toJson()));
  }

  /// Sessions, newest first.
  List<MigrationSession> sessions() {
    final directory = Directory(_sessionsDirectory);
    if (!directory.existsSync()) return const [];
    final result = <MigrationSession>[];
    for (final entry in directory.listSync().whereType<Directory>()) {
      final file = File(p.join(entry.path, 'session.json'));
      if (!file.existsSync()) continue;
      try {
        result.add(MigrationSession.fromJson(
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>));
      } on FormatException {
        throw JournalException('JOURNAL_CORRUPT',
            'The migration journal ${file.path} is not valid JSON.');
      }
    }
    result.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return result;
  }

  /// Finds a session by id or unique id prefix.
  MigrationSession find(String id) {
    final matches = sessions().where((s) => s.id.startsWith(id)).toList();
    if (matches.length == 1) return matches.single;
    throw JournalException(
      matches.isEmpty ? 'SESSION_NOT_FOUND' : 'SESSION_AMBIGUOUS',
      matches.isEmpty
          ? 'No migration session matches "$id".'
          : '"$id" matches ${matches.length} sessions.',
      hints: const ['List sessions with `reforge history`.'],
    );
  }
}

/// Writes [content] to [path] through a temporary file in the same directory
/// followed by a rename, so readers never observe a partially written file.
void writeFileAtomically(String path, String content) {
  final target = File(path);
  final temporary = File(p.join(target.parent.path,
      '.${p.basename(path)}.reforge-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp'));
  try {
    temporary.writeAsStringSync(content, flush: true);
    temporary.renameSync(path);
  } finally {
    if (temporary.existsSync()) temporary.deleteSync();
  }
}

/// SHA-256 of a file's UTF-8 content, or `null` when it does not exist.
String? hashOfFile(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  return contentHash(file.readAsStringSync());
}
