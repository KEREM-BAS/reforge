import 'package:reforge_core/reforge_core.dart';

import '../exit_codes.dart';
import 'reforge_command.dart';

final class RollbackCommand extends ReforgeCommand {
  RollbackCommand(super.context) {
    argParser.addFlag('force',
        negatable: false,
        help: 'Restore backups even if files changed after the migration. '
            'Those later changes are lost.');
  }

  @override
  String get name => 'rollback';

  @override
  String get invocation => 'reforge rollback [session]';

  @override
  String get description =>
      'Restore the files changed by the most recent applied migration (or by '
      'the given session). Refuses when files changed afterwards.';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    final session = MigrationApplier(projectRoot: projectDirectory).rollback(
      sessionId: rest.isEmpty ? null : rest.first,
      force: argResults!['force'] as bool,
    );
    if (format == OutputFormat.json) {
      writeJson({
        'session': session.id,
        'status': session.status.name,
        'restoredFiles': [
          for (final file in session.files.where((f) => f.written)) file.path,
        ],
      });
    } else {
      final t = terminal;
      t.line('${t.green(t.ok)} Rolled back session ${t.bold(session.id)} '
          '(migration to Flutter ${session.targetFlutter}).');
      for (final file in session.files.where((f) => f.written)) {
        t.line('  ${t.dim('restored')} ${file.path}');
      }
    }
    return ExitCodes.success;
  }
}

final class HistoryCommand extends ReforgeCommand {
  HistoryCommand(super.context);

  @override
  String get name => 'history';

  @override
  String get description =>
      'List migration sessions recorded in this project, newest first.';

  @override
  Future<int> run() async {
    final sessions = Journal(projectDirectory).sessions();
    if (format == OutputFormat.json) {
      writeJson({
        'sessions': [
          for (final session in sessions)
            {
              'id': session.id,
              'createdAt': session.createdAt.toUtc().toIso8601String(),
              'status': session.status.name,
              'targetFlutter': session.targetFlutter,
              'planId': session.planId,
              'files': session.files.length,
              'verifications': [
                for (final record in session.verifications) record.toJson(),
              ],
            },
        ],
      });
      return ExitCodes.success;
    }
    final t = terminal;
    if (sessions.isEmpty) {
      t.line('No migration sessions recorded in $projectDirectory.');
      return ExitCodes.success;
    }
    for (final session in sessions) {
      final status = switch (session.status) {
        SessionStatus.applied => t.green('applied'),
        SessionStatus.rolledBack => t.dim('rolled back'),
        SessionStatus.failed => t.red('failed'),
        SessionStatus.applying => t.yellow('interrupted'),
      };
      final verification = session.verifications.isEmpty
          ? t.dim('not verified')
          : session.verifications
              .map((v) => '${v.check} ${v.status}')
              .join(', ');
      t.line(
          '${t.bold(session.id)}  $status  Flutter ${session.targetFlutter}  '
          '${session.files.length} files  $verification');
    }
    return ExitCodes.success;
  }
}
