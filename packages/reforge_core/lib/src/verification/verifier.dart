import 'dart:io';

import 'package:path/path.dart' as p;

import '../apply/journal.dart';
import '../common/errors.dart';
import '../environment/process_runner.dart';
import '../fs/project_file_system.dart';
import '../inspection/project_inspector.dart';
import '../knowledge/flutter_release.dart';
import '../knowledge/knowledge_base.dart';
import '../migration/edit_validation.dart';
import '../migration/plan.dart';
import '../migration/planner.dart';
import '../migration/recipe.dart';
import 'failure_signatures.dart';
import 'project_snapshot.dart';

enum CheckStatus { passed, failed, skipped }

/// The result of one verification check.
final class CheckResult {
  const CheckResult({
    required this.check,
    required this.status,
    required this.summary,
    this.command,
    this.exitCode,
    this.duration,
    this.logFile,
    this.details = const [],
    this.diagnoses = const [],
    this.failingModule,
    this.toolChanges = const [],
  });

  final VerificationCheck check;
  final CheckStatus status;
  final String summary;
  final String? command;
  final int? exitCode;
  final Duration? duration;

  /// Absolute path of the full output log.
  final String? logFile;

  final List<String> details;
  final List<FailureDiagnosis> diagnoses;

  /// The Gradle module whose task failed, when identifiable.
  final String? failingModule;

  /// Project files the tool created, modified or deleted while it ran.
  /// Backups are project-relative paths below the backup directory given to
  /// [Verifier.runToolCheck].
  final List<ToolFileChange> toolChanges;

  Map<String, Object?> toJson() => {
        'check': check.name,
        'status': status.name,
        'summary': summary,
        if (command != null) 'command': command,
        if (exitCode != null) 'exitCode': exitCode,
        if (duration != null) 'durationMs': duration!.inMilliseconds,
        if (logFile != null) 'logFile': logFile,
        if (details.isNotEmpty) 'details': details,
        if (diagnoses.isNotEmpty)
          'diagnoses': [for (final d in diagnoses) d.toJson()],
        if (failingModule != null) 'failingModule': failingModule,
        if (toolChanges.isNotEmpty)
          'toolChanges': [
            for (final change in toolChanges)
              {'path': change.path, 'change': change.kind},
          ],
      };
}

/// Verifies that a project is healthy after a migration.
final class Verifier {
  Verifier({
    required this.projectRoot,
    required this.knowledge,
    required this.planner,
    required this.runner,
    required this.operatingSystem,
  });

  final String projectRoot;
  final KnowledgeBase knowledge;
  final MigrationPlanner planner;
  final ProcessRunner runner;
  final String operatingSystem;

  /// Offline verification: files changed by the migration still parse, and
  /// planning again for [target] applies nothing, i.e. every recipe's
  /// postcondition holds on disk.
  CheckResult verifyStatically({
    required FlutterRelease target,
    required PlanOptions options,
    List<String> changedFiles = const [],
  }) {
    final stopwatch = Stopwatch()..start();
    final files = LocalProjectFileSystem(projectRoot);
    final problems = <String>[];
    for (final path in changedFiles) {
      final content = files.readString(path);
      if (content == null) {
        problems.add('$path no longer exists.');
        continue;
      }
      final invalid = validateEditedFile(path, content);
      if (invalid != null) problems.add('$path: $invalid');
    }
    final MigrationPlan replan =
        planner.plan(files: files, target: target, options: options);
    for (final step in replan.steps.where((s) => s.applied)) {
      problems.add('${step.recipe.id} still applies: ${step.proposal.summary}');
    }
    final remainingErrors =
        replan.remainingErrors.map((f) => '${f.code}: ${f.message}').toList();
    return CheckResult(
      check: VerificationCheck.staticAnalysis,
      status: problems.isEmpty ? CheckStatus.passed : CheckStatus.failed,
      summary: problems.isEmpty
          ? 'Changed files parse and no migration step applies again.'
          : '${problems.length} problem(s) found.',
      duration: stopwatch.elapsed,
      details: [
        ...problems,
        for (final error in remainingErrors) 'Remaining: $error',
      ],
    );
  }

  /// Runs a toolchain check with the `flutter` executable.
  ///
  /// [target] is the release the project was migrated to; it makes failure
  /// explanations refer to the target's values. When [backupDirectory] is
  /// given, the previous content of every project file the tool changes is
  /// kept there, so the change can be undone.
  Future<CheckResult> runToolCheck(
    VerificationCheck check, {
    required String flutterExecutable,
    required String logDirectory,
    FlutterRelease? target,
    String? backupDirectory,
    void Function(String line)? onOutput,
  }) async {
    final List<String> arguments;
    switch (check) {
      case VerificationCheck.staticAnalysis:
        throw ArgumentError('Use verifyStatically for static analysis.');
      case VerificationCheck.pubGet:
        arguments = const ['pub', 'get'];
      case VerificationCheck.analyze:
        arguments = const [
          'analyze',
          '--no-fatal-infos',
          '--no-fatal-warnings'
        ];
      case VerificationCheck.androidBuild:
        if (!Directory(p.join(projectRoot, 'android')).existsSync()) {
          return CheckResult(
              check: check,
              status: CheckStatus.skipped,
              summary: 'The project has no Android host.');
        }
        arguments = const ['build', 'apk', '--debug'];
      case VerificationCheck.iosBuild:
        if (operatingSystem != 'macos') {
          return CheckResult(
              check: check,
              status: CheckStatus.skipped,
              summary: 'iOS builds require macOS (this is $operatingSystem).');
        }
        if (!Directory(p.join(projectRoot, 'ios')).existsSync()) {
          return CheckResult(
              check: check,
              status: CheckStatus.skipped,
              summary: 'The project has no iOS host.');
        }
        arguments = const ['build', 'ios', '--debug', '--no-codesign'];
    }

    final command = ExternalCommand(
      flutterExecutable,
      arguments,
      workingDirectory: projectRoot,
      environment: const {'FLUTTER_SUPPRESS_ANALYTICS': 'true'},
      timeout: const Duration(minutes: 45),
    );
    final projects = _projectPaths();
    final before = ProjectSnapshot.capture(projectRoot, projects);
    final result = await runner.run(command, onOutput: onOutput);
    final after = ProjectSnapshot.capture(projectRoot, projects);
    final toolChanges = [
      for (final change in before.changesTo(after))
        ToolFileChange(
          path: change.path,
          beforeHash: change.beforeHash,
          afterHash: change.afterHash,
          backup: backupDirectory == null || change.before == null
              ? null
              : _backup(backupDirectory, change.path, change.before!),
        ),
    ];
    Directory(logDirectory).createSync(recursive: true);
    final log = File(p.join(logDirectory, '${check.name}.log'));
    log.writeAsStringSync('\$ ${command.display}\n'
        'exit code: ${result.exitCode}${result.timedOut ? ' (timed out)' : ''}\n\n'
        '${result.stdout}\n--- stderr ---\n${result.stderr}');

    if (result.startError != null) {
      return CheckResult(
        check: check,
        status: CheckStatus.failed,
        summary: 'Could not run ${command.display}: ${result.startError}',
        command: command.display,
        logFile: log.path,
      );
    }
    final output = '${result.stdout}\n${result.stderr}';
    final passed = result.succeeded;
    return CheckResult(
      check: check,
      status: passed ? CheckStatus.passed : CheckStatus.failed,
      summary: passed
          ? '${command.display} succeeded.'
          : result.timedOut
              ? '${command.display} timed out.'
              : '${command.display} failed with exit code ${result.exitCode}.',
      command: command.display,
      exitCode: result.exitCode,
      duration: result.elapsed,
      logFile: log.path,
      diagnoses: passed ? const [] : diagnoseFailure(output, target: target),
      failingModule: passed ? null : failingGradleModule(output),
      toolChanges: toolChanges,
      details: passed ? const [] : _tail(output, 15),
    );
  }

  /// Workspace-relative directories of the projects to watch for changes.
  List<String> _projectPaths() {
    try {
      final workspace = ProjectInspector(LocalProjectFileSystem(projectRoot),
              knowledge: knowledge)
          .inspectWorkspace();
      return [for (final project in workspace.projects) project.path];
    } on ReforgeException {
      return const [''];
    }
  }

  /// Writes [content] below [directory] and returns its project-relative
  /// path.
  String _backup(String directory, String path, List<int> content) {
    final file = File(p.joinAll([directory, ...path.split('/')]));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(content, flush: true);
    return p.relative(file.path, from: projectRoot).replaceAll(r'\', '/');
  }

  static List<String> _tail(String output, int lines) {
    final all = output
        .split('\n')
        .map((l) => l.trimRight())
        .where((l) => l.isNotEmpty)
        .toList();
    return all.length <= lines ? all : all.sublist(all.length - lines);
  }
}
