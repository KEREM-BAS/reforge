import 'dart:io';

import 'package:args/args.dart';
import 'package:reforge_core/reforge_core.dart';

import 'reforge_command.dart';

/// Options shared by commands that compute a migration plan.
mixin PlanningCommand on ReforgeCommand {
  void addPlanningOptions(ArgParser parser) {
    parser
      ..addOption(
        'to',
        valueHelp: 'version',
        help: 'Target Flutter release: 3.47.4, 3.47 (latest patch) or stable.',
      )
      ..addFlag(
        'include-recommended',
        negatable: false,
        help: 'Also plan recommended upgrades (Flutter warning thresholds and '
            'deprecations), not only required ones.',
      )
      ..addMultiOption(
        'accept',
        valueHelp: 'RECIPE_ID',
        help: 'Accept review steps of these recipes so they are applied and '
            'later steps can build on them.',
      )
      ..addFlag(
        'accept-all',
        negatable: false,
        help: 'Accept every review step.',
      )
      ..addMultiOption(
        'skip',
        valueHelp: 'RECIPE_ID',
        help: 'Do not evaluate these recipes.',
      )
      ..addOption(
        'workspace-project',
        valueHelp: 'path',
        help: 'In a workspace, plan only the project at this path.',
      )
      ..addFlag(
        'env',
        defaultsTo: true,
        help: 'Probe the local toolchain to report environment problems that '
            'remain after the plan. File changes never depend on it.',
      );
  }

  FlutterRelease resolveTarget() {
    final value = argResults!['to'] as String?;
    if (value == null) {
      throw const InvalidUsageException(
        'TARGET_REQUIRED',
        'Choose a target Flutter release with --to.',
        hints: ['Example: reforge plan --to 3.47'],
      );
    }
    return context.knowledge.resolveFlutterVersion(value);
  }

  PlanOptions planOptions() {
    final accepted = (argResults!['accept'] as List<String>).toSet();
    final skipped = (argResults!['skip'] as List<String>).toSet();
    final known = builtInRecipes().map((r) => r.descriptor.id).toSet();
    for (final id in [...accepted, ...skipped]) {
      if (!known.contains(id)) {
        throw InvalidUsageException(
          'UNKNOWN_RECIPE',
          'Unknown recipe "$id".',
          hints: ['Known recipes: ${(known.toList()..sort()).join(', ')}'],
        );
      }
    }
    return PlanOptions(
      includeRecommended: argResults!['include-recommended'] as bool,
      acceptAllReviews: argResults!['accept-all'] as bool,
      acceptedReviews: accepted,
      skippedRecipes: skipped,
    );
  }

  Future<(MigrationPlan, Environment?)> computePlan() async {
    final target = resolveTarget();
    final options = planOptions();
    final environmentFuture = argResults!['env'] as bool
        ? context.probeEnvironment()
        : Future<Environment?>.value();
    final planner = MigrationPlanner(
      knowledge: context.knowledge,
      recipes: builtInRecipes(),
      reforgeVersion: reforgeVersion,
    );
    final environment = await environmentFuture;
    final plan = planner.plan(
      files: LocalProjectFileSystem(projectDirectory),
      target: target,
      options: options,
      environment: environment,
      projectPath: argResults!['workspace-project'] as String?,
    );
    return (plan, environment);
  }

  /// The command line that reproduces [plan] with review acceptance.
  String suggestedCommand(String command, MigrationPlan plan,
      {Set<String> extraAccepts = const {}}) {
    final accepted = {
      ...plan.options.acceptedReviews,
      ...extraAccepts,
    }.toList()
      ..sort();
    return [
      'reforge $command --to ${plan.target.version}',
      if (plan.options.includeRecommended) '--include-recommended',
      if (plan.options.acceptAllReviews) '--accept-all',
      if (!plan.options.acceptAllReviews && accepted.isNotEmpty)
        '--accept ${accepted.join(',')}',
      for (final skipped in plan.options.skippedRecipes) '--skip $skipped',
    ].join(' ');
  }

  /// Whether a person can answer prompts. Dart reports character devices such
  /// as /dev/null as terminals, so both stdin and stdout must be terminals and
  /// end of input is still handled by callers.
  bool get interactive =>
      identical(context.out, stdout) && stdin.hasTerminal && stdout.hasTerminal;
}
