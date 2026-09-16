import 'dart:io';

import 'package:path/path.dart' as p;

import '../common/errors.dart';
import '../fs/project_file_system.dart';
import '../migration/plan.dart';
import 'journal.dart';

/// Writes a file. Replaceable in tests to inject failures.
typedef FileWriter = void Function(String absolutePath, String content);

/// Applies migration plans transactionally and rolls them back.
///
/// Guarantees:
/// - a plan is applied only if every file it read still has the content it
///   was planned against;
/// - every file is backed up before it is changed, and the journal is
///   written before the first change;
/// - files are replaced atomically; if any write fails, files already
///   written are restored from their backups;
/// - rollback restores backups only for files that still contain exactly
///   what Reforge wrote, and reports conflicts otherwise.
final class MigrationApplier {
  MigrationApplier({
    required this.projectRoot,
    DateTime Function()? clock,
    FileWriter? writer,
  })  : journal = Journal(projectRoot),
        _clock = clock ?? DateTime.now,
        _write = writer ?? writeFileAtomically;

  final String projectRoot;
  final Journal journal;
  final DateTime Function() _clock;
  final FileWriter _write;

  String _absolute(String projectPath) => p.join(
      projectRoot, p.joinAll(normalizeProjectPath(projectPath).split('/')));

  /// Checks that the project still matches what [plan] was computed from.
  void ensureCurrent(MigrationPlan plan) {
    final changed = <String>[];
    for (final entry in plan.inputs.entries) {
      final absolute = _absolute(entry.key);
      final String? hash;
      try {
        hash = FileSystemEntity.typeSync(absolute) == FileSystemEntityType.file
            ? hashOfFile(absolute)
            : null;
      } on FileSystemException {
        changed.add(entry.key);
        continue;
      }
      if (hash != entry.value) changed.add(entry.key);
    }
    if (changed.isNotEmpty) {
      throw MigrationBlockedException(
        'STALE_PLAN',
        'The project changed after the plan was computed: '
            '${changed.take(5).join(', ')}${changed.length > 5 ? ', ...' : ''}.',
        hints: const ['Compute the plan again.'],
      );
    }
  }

  MigrationSession apply(MigrationPlan plan) {
    if (plan.fileChanges.isEmpty) {
      throw const MigrationBlockedException(
          'NOTHING_TO_APPLY', 'The plan does not change any file.');
    }
    return journal.withLock(() {
      ensureCurrent(plan);
      for (final change in plan.fileChanges) {
        final absolute = _absolute(change.path);
        if (FileSystemEntity.isLinkSync(absolute)) {
          throw MigrationBlockedException(
            'SYMLINK_TARGET',
            '${change.path} is a symbolic link; Reforge does not replace links.',
            hints: const ['Apply this change manually to the link target.'],
          );
        }
        if (change.before == null) {
          throw InternalException('CREATE_NOT_SUPPORTED',
              'Plans that create ${change.path} are not supported yet.');
        }
      }

      final now = _clock().toUtc();
      final session = MigrationSession(
        id: '${_timestamp(now)}-${plan.id.substring(0, 8)}',
        createdAt: now,
        status: SessionStatus.applying,
        reforgeVersion: plan.reforgeVersion,
        knowledgeBase: plan.knowledgeBaseVersion,
        targetFlutter: '${plan.target.version}',
        planId: plan.id,
        plan: plan.toJson(includeDiffs: false),
        files: [
          for (final change in plan.fileChanges)
            JournalFile(
              path: change.path,
              beforeHash: contentHash(change.before!),
              afterHash: contentHash(change.after),
              written: false,
            ),
        ],
      );

      // Backups first, then the journal, then the changes.
      for (final change in plan.fileChanges) {
        final backup = File(journal.backupFile(session.id, change.path));
        backup.parent.createSync(recursive: true);
        backup.writeAsStringSync(change.before!, flush: true);
      }
      journal.save(session);

      for (var i = 0; i < plan.fileChanges.length; i++) {
        final change = plan.fileChanges[i];
        try {
          _write(_absolute(change.path), change.after);
        } on Object catch (error) {
          final restored = _restoreWritten(session);
          session
            ..status = SessionStatus.failed
            ..failure = 'Writing ${change.path} failed: $error'
            ..finishedAt = _clock().toUtc();
          journal.save(session);
          throw MigrationFailedException(
            'APPLY_WRITE_FAILED',
            'Writing ${change.path} failed: $error',
            restored: restored,
            hints: [
              restored
                  ? 'Files written before the failure were restored.'
                  : 'Some files could not be restored; backups are in '
                      '${journal.sessionDirectory(session.id)}.',
            ],
          );
        }
        session.files[i] = session.files[i].markWritten();
        journal.save(session);
      }
      session
        ..status = SessionStatus.applied
        ..finishedAt = _clock().toUtc();
      journal.save(session);
      return session;
    });
  }

  bool _restoreWritten(MigrationSession session) {
    var restored = true;
    for (final file in session.files.where((f) => f.written)) {
      try {
        final backup = File(journal.backupFile(session.id, file.path));
        writeFileAtomically(_absolute(file.path), backup.readAsStringSync());
      } on FileSystemException {
        restored = false;
      }
    }
    return restored;
  }

  /// Restores the files of the most recent applied session, or of [sessionId].
  ///
  /// Throws [JournalException] with code `ROLLBACK_CONFLICT` when a file was
  /// modified after Reforge wrote it, unless [force] is set.
  MigrationSession rollback({String? sessionId, bool force = false}) {
    return journal.withLock(() {
      final session = sessionId == null
          ? journal
              .sessions()
              .where((s) => s.status == SessionStatus.applied)
              .firstOrNull
          : journal.find(sessionId);
      if (session == null) {
        throw const JournalException('NOTHING_TO_ROLL_BACK',
            'There is no applied migration session to roll back.');
      }
      if (session.status != SessionStatus.applied) {
        throw JournalException('SESSION_NOT_APPLIED',
            'Session ${session.id} is ${session.status.name}; only applied sessions can be rolled back.');
      }
      final conflicts = <String>[];
      for (final file in session.files.where((f) => f.written)) {
        final current = hashOfFile(_absolute(file.path));
        if (current != file.afterHash && current != file.beforeHash) {
          conflicts.add(file.path);
        }
      }
      if (conflicts.isNotEmpty && !force) {
        throw JournalException(
          'ROLLBACK_CONFLICT',
          'These files changed after the migration: ${conflicts.join(', ')}.',
          hints: const [
            'Rolling back would discard those changes. Review them, then use '
                '--force to restore the backups anyway.',
          ],
        );
      }
      for (final file in session.files.where((f) => f.written)) {
        final backup = File(journal.backupFile(session.id, file.path));
        writeFileAtomically(_absolute(file.path), backup.readAsStringSync());
      }
      session
        ..status = SessionStatus.rolledBack
        ..rolledBackAt = _clock().toUtc();
      journal.save(session);
      return session;
    });
  }

  static String _timestamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year}${two(time.month)}${two(time.day)}T'
        '${two(time.hour)}${two(time.minute)}${two(time.second)}Z';
  }
}
