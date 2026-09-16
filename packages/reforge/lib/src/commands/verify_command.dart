import 'package:path/path.dart' as p;
import 'package:reforge_core/reforge_core.dart';

import '../exit_codes.dart';
import 'reforge_command.dart';

const _checkNames = {
  'static': VerificationCheck.staticAnalysis,
  'pub-get': VerificationCheck.pubGet,
  'analyze': VerificationCheck.analyze,
  'android': VerificationCheck.androidBuild,
  'ios': VerificationCheck.iosBuild,
};

final class VerifyCommand extends ReforgeCommand {
  VerifyCommand(super.context) {
    argParser
      ..addOption('session',
          valueHelp: 'id',
          help: 'The migration session to verify (default: the latest applied '
              'session).')
      ..addMultiOption('check',
          allowed: _checkNames.keys,
          help: 'Checks to run. Default: the checks required by the applied '
              "migration steps. Android and iOS builds run the project's Gradle "
              'and CocoaPods build logic.')
      ..addOption('flutter',
          valueHelp: 'executable',
          defaultsTo: 'flutter',
          help: 'The flutter executable to verify with.');
  }

  @override
  String get name => 'verify';

  @override
  String get description =>
      'Verify a migrated project: static checks, then flutter pub get, '
      'analyze and builds, with failure diagnosis. Results are recorded in the '
      'migration journal.';

  @override
  Future<int> run() async {
    final journal = Journal(projectDirectory);
    final sessionId = argResults!['session'] as String?;
    final MigrationSession? session = sessionId != null
        ? journal.find(sessionId)
        : journal
            .sessions()
            .where((s) => s.status == SessionStatus.applied)
            .firstOrNull;

    final plan = session?.plan;
    final requested = (argResults!['check'] as List<String>)
        .map((name) => _checkNames[name]!)
        .toList();
    final checks = <VerificationCheck>{
      VerificationCheck.staticAnalysis,
      if (requested.isNotEmpty)
        ...requested
      else if (plan != null)
        ..._planChecks(plan)
      else ...[
        VerificationCheck.pubGet,
        VerificationCheck.analyze,
      ],
    }.toList()
      ..sort((a, b) => a.index.compareTo(b.index));
    if (checks.length > 1 && !checks.contains(VerificationCheck.pubGet)) {
      checks.insert(1, VerificationCheck.pubGet);
    }

    final environment = await context.probeEnvironment();
    final flutterVersion = environment.flutter?.version;
    final targetText = session?.targetFlutter;
    final target = targetText == null
        ? null
        : context.knowledge.resolveFlutterVersion(targetText);

    final t = terminal;
    final text = format == OutputFormat.text;
    if (text) {
      t.line(t.bold(session == null
          ? 'Verifying ${p.basename(projectDirectory)}'
          : 'Verifying session ${session.id} (Flutter ${session.targetFlutter})'));
      if (flutterVersion != null &&
          target != null &&
          flutterVersion != target.version) {
        t.line(
            t.yellow('${t.warn} Checks run with Flutter $flutterVersion, not '
                'the migration target ${target.version}. Build results are not '
                'evidence for the target.'));
      }
    }

    final verifier = Verifier(
      projectRoot: projectDirectory,
      knowledge: context.knowledge,
      planner: MigrationPlanner(
        knowledge: context.knowledge,
        recipes: builtInRecipes(),
        reforgeVersion: reforgeVersion,
      ),
      runner: context.processRunner,
      operatingSystem: environment.operatingSystem,
    );
    final logDirectory = session == null
        ? p.join(journal.directory, 'logs')
        : journal.logsDirectory(session.id);

    final results = <CheckResult>[];
    for (final check in checks) {
      if (text) t.write('  ${_label(check).padRight(14)} ');
      final CheckResult result;
      if (check == VerificationCheck.staticAnalysis) {
        result = target == null
            ? const CheckResult(
                check: VerificationCheck.staticAnalysis,
                status: CheckStatus.skipped,
                summary: 'No migration session to verify statically.')
            : verifier.verifyStatically(
                target: target,
                options: _optionsOf(plan!),
                changedFiles: [for (final file in session!.files) file.path],
              );
      } else if (results.any((r) =>
          r.check == VerificationCheck.pubGet &&
          r.status == CheckStatus.failed)) {
        result = CheckResult(
            check: check,
            status: CheckStatus.skipped,
            summary: 'Skipped because flutter pub get failed.');
      } else {
        result = await verifier.runToolCheck(
          check,
          flutterExecutable: argResults!['flutter'] as String,
          logDirectory: logDirectory,
          target: target,
          onOutput:
              verbose && text ? (line) => t.line('      ${t.dim(line)}') : null,
        );
      }
      results.add(result);
      if (text) _render(result);
    }

    if (session != null) {
      session.verifications = [
        ...session.verifications,
        for (final result in results)
          VerificationRecord(
            check: result.check.name,
            status: result.status.name,
            summary: result.summary,
            recordedAt: context.clock().toUtc(),
            command: result.command,
            exitCode: result.exitCode,
            duration: result.duration,
            logFile: result.logFile == null
                ? null
                : p.relative(result.logFile!, from: projectDirectory),
            flutterVersion: flutterVersion?.toString(),
            modifiedFiles: result.modifiedFiles,
            details: [
              ...result.details.take(20),
              for (final diagnosis in result.diagnoses) diagnosis.explanation,
            ],
          ),
      ];
      journal.save(session);
    }

    final failed =
        results.where((r) => r.status == CheckStatus.failed).toList();
    if (format == OutputFormat.json) {
      writeJson({
        'session': session?.id,
        'flutterVersion': flutterVersion?.toString(),
        'targetFlutter': targetText,
        'evidenceForTarget':
            target == null ? null : flutterVersion == target.version,
        'passed': failed.isEmpty,
        'checks': [for (final r in results) r.toJson()],
      });
    } else {
      t.line();
      t.line(failed.isEmpty
          ? '${t.green(t.ok)} ${t.bold('Verification passed.')}'
          : '${t.red(t.fail)} ${t.bold('Verification failed')}: '
              '${failed.length} of ${results.length} checks failed.');
      if (failed.isNotEmpty && session != null) {
        t.line(
            t.dim('Undo the migration with: reforge rollback ${session.id}'));
      }
    }
    return failed.isEmpty ? ExitCodes.success : ExitCodes.failed;
  }

  void _render(CheckResult result) {
    final t = terminal;
    final symbol = switch (result.status) {
      CheckStatus.passed => t.green(t.ok),
      CheckStatus.failed => t.red(t.fail),
      CheckStatus.skipped => t.dim('-'),
    };
    final duration = result.duration == null
        ? ''
        : t.dim(' (${_formatDuration(result.duration!)})');
    t.line('$symbol ${result.summary}$duration');
    if (result.modifiedFiles.isNotEmpty) {
      t.paragraph(
          t.yellow('${t.warn} The tool modified project files while running: '
              '${result.modifiedFiles.join(', ')}. These changes are not part '
              'of the Reforge migration; review them with your version '
              'control.'),
          indent: 6,
          hanging: 2);
    }
    if (result.status != CheckStatus.failed) return;
    if (result.failingModule != null) {
      t.line('      Failing Gradle module: ${t.bold(result.failingModule!)}');
    }
    for (final diagnosis in result.diagnoses) {
      t.paragraph('Likely cause: ${diagnosis.explanation}',
          indent: 6, hanging: 2);
      t.paragraph('Suggested: ${diagnosis.suggestion}', indent: 6, hanging: 2);
      if (diagnosis.relatedRecipes.isNotEmpty) {
        t.line(
            '        ${t.dim('Related recipe: ${diagnosis.relatedRecipes.join(', ')}')}');
      }
    }
    if (result.diagnoses.isEmpty) {
      for (final line in result.details) {
        t.line('      ${t.dim(line)}');
      }
    }
    if (result.logFile != null) {
      t.line(
          '      ${t.dim('Log: ${p.relative(result.logFile!, from: projectDirectory)}')}');
    }
  }
}

Iterable<VerificationCheck> _planChecks(Map<String, Object?> plan) sync* {
  for (final step in (plan['steps'] as List? ?? const [])) {
    if (step is! Map || step['applied'] != true) continue;
    for (final name in (step['verification'] as List? ?? const [])) {
      final check =
          VerificationCheck.values.where((c) => c.name == name).firstOrNull;
      if (check != null) yield check;
    }
  }
}

PlanOptions _optionsOf(Map<String, Object?> plan) =>
    PlanOptions.fromJson(plan['options'] as Map<String, Object?>? ?? const {});

String _label(VerificationCheck check) => switch (check) {
      VerificationCheck.staticAnalysis => 'static',
      VerificationCheck.pubGet => 'pub get',
      VerificationCheck.analyze => 'analyze',
      VerificationCheck.androidBuild => 'android build',
      VerificationCheck.iosBuild => 'ios build',
    };

String _formatDuration(Duration duration) {
  if (duration.inMinutes > 0) {
    return '${duration.inMinutes}m ${duration.inSeconds % 60}s';
  }
  if (duration.inSeconds > 0) return '${duration.inSeconds}s';
  return '${duration.inMilliseconds}ms';
}
