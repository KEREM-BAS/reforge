import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge_core/reforge_core.dart';

import '../exit_codes.dart';
import '../render/plan_renderer.dart';
import 'plan_support.dart';
import 'reforge_command.dart';

final class ApplyCommand extends ReforgeCommand with PlanningCommand {
  ApplyCommand(super.context) {
    addPlanningOptions(argParser);
    argParser
      ..addOption('plan',
          valueHelp: 'file',
          help: 'Apply only if the plan computed now is identical to this '
              'reviewed plan (written by `reforge plan --out`).')
      ..addFlag('allow-incomplete',
          negatable: false,
          help: 'Apply even though the plan leaves required steps or errors '
              'open. The project may not build until they are resolved.')
      ..addFlag('allow-dirty',
          negatable: false,
          help: 'Apply even if files to change have uncommitted Git changes.')
      ..addFlag('yes',
          abbr: 'y', negatable: false, help: 'Do not ask for confirmation.');
  }

  @override
  String get name => 'apply';

  @override
  String get description =>
      'Apply a migration plan: back up every file, record a journal, write '
      'changes atomically, then verify statically. Undo with `reforge '
      'rollback`.';

  @override
  Future<int> run() async {
    final (plan, _) = await computePlan();
    final reviewed = argResults!['plan'] as String?;
    if (reviewed != null) _ensureMatchesReviewedPlan(plan, reviewed);

    if (plan.fileChanges.isEmpty) {
      if (format == OutputFormat.json) {
        writeJson({'applied': false, 'plan': plan.toJson(includeDiffs: false)});
      } else {
        renderPlan(terminal, plan, verbose: verbose, diff: false);
        terminal.line();
        terminal.line('Nothing to apply.');
      }
      return plan.isComplete ? ExitCodes.success : ExitCodes.migrationBlocked;
    }

    if (!plan.isComplete && !(argResults!['allow-incomplete'] as bool)) {
      final open = [
        ...plan.outstandingSteps
            .map((s) => '${s.recipe.id} (${s.status.name})'),
        ...plan.remainingErrors.map((f) => f.code),
        if (plan.unanalyzedFiles.isNotEmpty)
          '${plan.unanalyzedFiles.length} unanalyzed file(s)',
      ];
      throw MigrationBlockedException(
        'PLAN_INCOMPLETE',
        'The plan does not resolve everything required for Flutter '
            '${plan.target.version}: ${open.toSet().join(', ')}.',
        hints: [
          'Review the plan: ${suggestedCommand('plan', plan)}',
          'Accept review steps with --accept, or apply the partial migration '
              'with --allow-incomplete.',
        ],
      );
    }

    final git =
        await readGitWorkingTree(projectDirectory, context.processRunner);
    final dirty = git == null
        ? const <String>[]
        : plan.fileChanges
            .map((c) => c.path)
            .where(git.changedPaths.contains)
            .toList();
    if (dirty.isNotEmpty && !(argResults!['allow-dirty'] as bool)) {
      throw MigrationBlockedException(
        'DIRTY_FILES',
        'Files to change have uncommitted changes: ${dirty.join(', ')}.',
        hints: const [
          'Commit or stash them so the migration can be reviewed on its own, '
              'or use --allow-dirty.',
        ],
      );
    }

    if (format == OutputFormat.text) {
      renderPlan(terminal, plan, verbose: verbose, diff: false);
      terminal.line();
      if (git == null) {
        terminal.line(terminal.dim('Not a Git repository: the Reforge journal '
            'is the only way back.'));
      }
    }
    if (!(argResults!['yes'] as bool)) {
      if (!interactive) {
        throw const InvalidUsageException(
          'CONFIRMATION_REQUIRED',
          'Applying changes requires confirmation.',
          hints: ['Pass --yes when running non-interactively.'],
        );
      }
      stdout.write('Apply ${plan.fileChanges.length} file change(s)? [y/N] ');
      final line = stdin.readLineSync();
      if (line == null) {
        throw const InvalidUsageException(
          'CONFIRMATION_REQUIRED',
          'No confirmation was given (end of input).',
          hints: ['Pass --yes when running non-interactively.'],
        );
      }
      final answer = line.trim().toLowerCase();
      if (answer != 'y' && answer != 'yes') {
        terminal.line('Nothing was changed.');
        return ExitCodes.success;
      }
    }

    final applier = MigrationApplier(projectRoot: projectDirectory);
    final session = applier.apply(plan);

    final verifier = Verifier(
      projectRoot: projectDirectory,
      knowledge: context.knowledge,
      planner: MigrationPlanner(
        knowledge: context.knowledge,
        recipes: builtInRecipes(),
        reforgeVersion: reforgeVersion,
      ),
      runner: context.processRunner,
      operatingSystem: Platform.operatingSystem,
    );
    final check = verifier.verifyStatically(
      target: plan.target,
      options: plan.options,
      changedFiles: [for (final change in plan.fileChanges) change.path],
    );
    session.verifications = [
      ...session.verifications,
      VerificationRecord(
        check: check.check.name,
        status: check.status.name,
        summary: check.summary,
        recordedAt: context.clock().toUtc(),
        duration: check.duration,
        details: check.details,
      ),
    ];
    applier.journal.save(session);

    final checks = plan.steps
        .where((s) => s.applied)
        .expand((s) => s.proposal.verification)
        .where((c) => c != VerificationCheck.staticAnalysis)
        .toSet();
    if (format == OutputFormat.json) {
      writeJson({
        'applied': true,
        'session': session.id,
        'files': [for (final file in session.files) file.path],
        'staticVerification': check.toJson(),
        'recommendedChecks': [for (final c in checks) c.name],
        'plan': plan.toJson(includeDiffs: false),
      });
    } else {
      final t = terminal;
      t.line('${t.green(t.ok)} Applied ${session.files.length} file change(s) '
          'in session ${t.bold(session.id)}.');
      t.line(
          '${check.status == CheckStatus.passed ? t.green(t.ok) : t.red(t.fail)} '
          'Static verification: ${check.summary}');
      for (final detail in check.details) {
        t.line('    ${t.dim(detail)}');
      }
      t.line();
      t.line('Next:');
      t.line(
          '  reforge verify    ${t.dim('run ${checks.map(_checkLabel).join(', ')}')}');
      t.line('  reforge rollback  ${t.dim('restore the previous files')}');
    }
    return check.status == CheckStatus.passed
        ? ExitCodes.success
        : ExitCodes.failed;
  }

  void _ensureMatchesReviewedPlan(MigrationPlan plan, String path) {
    final file = File(
        p.isAbsolute(path) ? path : p.join(context.workingDirectory, path));
    if (!file.existsSync()) {
      throw InvalidUsageException(
          'PLAN_FILE_MISSING', 'Plan file $path does not exist.');
    }
    final Object? json;
    try {
      json = jsonDecode(file.readAsStringSync());
    } on FormatException {
      throw InvalidUsageException(
          'PLAN_FILE_INVALID', '$path is not a Reforge plan.');
    }
    final reviewedId = json is Map ? json['planId'] : null;
    if (reviewedId != plan.id) {
      throw MigrationBlockedException(
        'PLAN_CHANGED',
        'The plan computed now (${plan.id}) differs from the reviewed plan '
            '($reviewedId). The project, the options or the Reforge version '
            'changed since it was reviewed.',
        hints: const ['Review the plan again and apply the new one.'],
      );
    }
  }
}

String _checkLabel(VerificationCheck check) => switch (check) {
      VerificationCheck.staticAnalysis => 'static checks',
      VerificationCheck.pubGet => 'flutter pub get',
      VerificationCheck.analyze => 'flutter analyze',
      VerificationCheck.androidBuild => 'an Android debug build',
      VerificationCheck.iosBuild => 'an iOS build',
    };
