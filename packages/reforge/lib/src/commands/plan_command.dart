import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge_core/reforge_core.dart';

import '../exit_codes.dart';
import '../render/plan_renderer.dart';
import 'plan_support.dart';
import 'reforge_command.dart';

final class PlanCommand extends ReforgeCommand with PlanningCommand {
  PlanCommand(super.context) {
    addPlanningOptions(argParser);
    argParser
      ..addFlag('diff',
          negatable: false, help: 'Show unified diffs of every file change.')
      ..addOption('out',
          valueHelp: 'file',
          help: 'Also write the plan as JSON to this file for review or '
              '`reforge apply --plan`.')
      ..addOption(
        'fail-on',
        allowed: const ['never', 'blocked', 'incomplete', 'changes'],
        defaultsTo: 'never',
        help: 'Exit with code 1 when the plan has manual or blocked steps '
            '(blocked), is not complete (incomplete), or would change files '
            '(changes). Useful in CI.',
      );
  }

  @override
  String get name => 'plan';

  @override
  String get description =>
      'Compute the migration to a target Flutter release without changing '
      'anything: every step, why it is needed, the exact file changes and '
      'what remains open.';

  @override
  Future<int> run() async {
    final (plan, _) = await computePlan();
    final out = argResults!['out'] as String?;
    if (out != null) {
      final file =
          File(p.isAbsolute(out) ? out : p.join(context.workingDirectory, out));
      file.writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(plan.toJson()));
    }
    if (format == OutputFormat.sarif) {
      final sarif = sarifBuilder();
      plan.steps.forEach(sarif.addStep);
      plan.remainingFindings.forEach(sarif.addFinding);
      writeSarif(sarif);
    } else if (format == OutputFormat.json) {
      writeJson(plan.toJson());
    } else {
      renderPlan(terminal, plan,
          verbose: verbose, diff: argResults!['diff'] as bool);
      if (!plan.isComplete) {
        final reviews = plan.outstandingSteps
            .where((s) => s.status == StepStatus.review)
            .map((s) => s.recipe.id)
            .toSet();
        if (reviews.isNotEmpty) {
          terminal.line();
          terminal.line('Review the steps above, then accept them to plan '
              'what depends on them:');
          terminal.line(
              '  ${suggestedCommand('plan', plan, extraAccepts: reviews)}');
        }
      } else if (plan.fileChanges.isNotEmpty) {
        terminal.line();
        terminal.line('Apply it with:');
        terminal.line('  ${suggestedCommand('apply', plan)}');
      }
      if (out != null) terminal.line(terminal.dim('Plan written to $out'));
    }

    final failed = switch (argResults!['fail-on'] as String) {
      'blocked' => plan.steps.any((s) =>
          s.status == StepStatus.manual || s.status == StepStatus.blocked),
      'incomplete' => !plan.isComplete,
      'changes' => plan.fileChanges.isNotEmpty || !plan.isComplete,
      _ => false,
    };
    return failed ? ExitCodes.failed : ExitCodes.success;
  }
}
