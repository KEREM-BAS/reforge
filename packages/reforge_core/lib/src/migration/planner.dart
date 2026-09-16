import '../analysis/compatibility_analyzer.dart';
import '../common/errors.dart';
import '../environment/environment.dart';
import '../fs/project_file_system.dart';
import '../inspection/current_flutter_version.dart';
import '../inspection/project_inspector.dart';
import '../knowledge/flutter_release.dart';
import '../knowledge/knowledge_base.dart';
import '../model/finding.dart';
import '../model/flutter_project.dart';
import '../text/text_edit.dart';
import 'edit_validation.dart';
import 'plan.dart';
import 'recipe.dart';

/// Builds migration plans by evaluating recipes sequentially over an overlay
/// file system.
///
/// Each recipe sees the project as left by the steps before it, so recipes
/// compose without edit conflicts. Every applied step is validated twice: the
/// edited files must still parse, and evaluating the same recipe again on the
/// result must report that nothing is left to do.
final class MigrationPlanner {
  MigrationPlanner({
    required this.knowledge,
    required List<MigrationRecipe> recipes,
    required this.reforgeVersion,
  }) : recipes = orderRecipes(recipes);

  final KnowledgeBase knowledge;
  final List<MigrationRecipe> recipes;
  final String reforgeVersion;

  MigrationPlan plan({
    required ProjectFileSystem files,
    required FlutterRelease target,
    PlanOptions options = const PlanOptions(),
    Environment? environment,
    String? projectPath,
  }) {
    final overlay = OverlayFileSystem(files);
    final workspace =
        ProjectInspector(overlay, knowledge: knowledge).inspectWorkspace();
    final projects = workspace.projects
        .where((p) => p.kind != FlutterProjectKind.dartPackage)
        .where((p) => projectPath == null || p.path == projectPath)
        .toList();
    if (projectPath != null && projects.isEmpty) {
      throw InvalidUsageException(
        'PROJECT_NOT_IN_WORKSPACE',
        'No Flutter project at "$projectPath" in this workspace.',
        hints: [
          'Projects: ${workspace.projects.map((p) => p.path.isEmpty ? '.' : p.path).join(', ')}',
        ],
      );
    }

    final steps = <PlanStep>[];
    final skipped = <SkippedRecipe>[];
    final remaining = <Finding>[];
    final currentFlutter = <String, CurrentFlutterVersion?>{};
    final recipesByPath = <String, List<String>>{};

    for (final original in projects) {
      final current = resolveCurrentFlutterVersion(original,
          environment: environment, knowledge: knowledge);
      currentFlutter[original.path] = current;
      final unapplied = <String>{};

      for (final recipe in recipes) {
        final descriptor = recipe.descriptor;
        if (options.skippedRecipes.contains(descriptor.id)) {
          skipped.add(SkippedRecipe(
              descriptor, original.path, 'Excluded by the plan options.',
              kind: SkipKind.excluded));
          continue;
        }
        final project = ProjectInspector(overlay, knowledge: knowledge)
            .inspectProject(original.path);
        final context = RecipeContext(
          project: project,
          target: target,
          knowledge: knowledge,
          files: overlay,
          options: options,
          currentFlutter: current,
          environment: environment,
        );
        final result = recipe.evaluate(context);
        switch (result) {
          case NotApplicable(:final reason):
            skipped.add(SkippedRecipe(descriptor, original.path, reason));
            continue;
          case Proposal():
            break;
        }
        var proposal = result;
        if (proposal.necessity == Necessity.recommended &&
            !options.includesRecommended(descriptor.id)) {
          skipped.add(SkippedRecipe(
            descriptor,
            original.path,
            'Recommended but not required for Flutter ${target.version}: '
            '${proposal.summary}',
            kind: SkipKind.recommendationNotIncluded,
            summary: proposal.summary,
          ));
          continue;
        }

        final blockers = descriptor.requires.where(unapplied.contains).toList();
        if (blockers.isNotEmpty &&
            (proposal.status == StepStatus.auto ||
                proposal.status == StepStatus.review)) {
          proposal = proposal.withStatus(StepStatus.blocked, extraNotes: [
            'Blocked until ${blockers.join(', ')} is applied: this step '
                'depends on it.',
          ]);
        }

        final changes = <String, ({String before, String after})>{};
        if (proposal.status == StepStatus.auto ||
            proposal.status == StepStatus.review) {
          final fork = overlay.fork();
          final problem = _applyEdits(fork, proposal, changes);
          final idempotencyProblem =
              problem ?? _checkIdempotent(recipe, context, fork, original.path);
          overlay.absorbObservations(fork);
          if (problem != null || idempotencyProblem != null) {
            changes.clear();
            proposal = proposal.withStatus(StepStatus.manual, extraNotes: [
              'Reforge could not produce a safe automatic change '
                  '(${problem ?? idempotencyProblem}). This is a defect in '
                  'Reforge; please report it.',
            ]);
          }
        }

        final applied = proposal.status == StepStatus.auto ||
            (proposal.status == StepStatus.review &&
                options.accepts(descriptor.id));
        if (applied) {
          for (final entry in changes.entries) {
            overlay.writeString(entry.key, entry.value.after);
            recipesByPath.putIfAbsent(entry.key, () => []).add(descriptor.id);
          }
        } else {
          unapplied.add(descriptor.id);
        }
        steps.add(PlanStep(
          recipe: descriptor,
          project: original.path,
          proposal: proposal,
          applied: applied,
          fileChanges: changes,
          blockedBy: blockers,
        ));
      }

      final migrated = ProjectInspector(overlay, knowledge: knowledge)
          .inspectProject(original.path);
      remaining.addAll(CompatibilityAnalyzer(knowledge)
          .analyze(migrated, release: target, environment: environment));
    }

    final fileChanges = [
      for (final entry in overlay.changedFiles.entries)
        PlannedFileChange(entry.key, files.readString(entry.key), entry.value,
            recipesByPath[entry.key] ?? const []),
    ]..sort((a, b) => a.path.compareTo(b.path));

    return MigrationPlan(
      target: target,
      options: options,
      steps: steps,
      skipped: skipped,
      fileChanges: fileChanges,
      remainingFindings: remaining,
      inputs: overlay.observedInputs,
      reforgeVersion: reforgeVersion,
      knowledgeBaseVersion: knowledge.version,
      currentFlutter: currentFlutter,
    );
  }

  /// Applies a proposal's edits to [fork]. All edits of one file refer to the
  /// file's content before the step, so they are applied together.
  String? _applyEdits(OverlayFileSystem fork, Proposal proposal,
      Map<String, ({String before, String after})> changes) {
    final byPath = <String, List<TextEdit>>{};
    for (final fileEdit in proposal.edits) {
      byPath.putIfAbsent(fileEdit.path, () => []).addAll(fileEdit.edits);
    }
    for (final entry in byPath.entries) {
      final before = fork.readString(entry.key);
      if (before == null) {
        return 'cannot edit missing file ${entry.key}';
      }
      final String after;
      try {
        after = applyTextEdits(before, entry.value);
      } on InternalException catch (e) {
        return e.message;
      }
      if (after == before) continue;
      final invalid = validateEditedFile(entry.key, after);
      if (invalid != null) return '${entry.key}: $invalid';
      changes[entry.key] = (before: before, after: after);
      fork.writeString(entry.key, after);
    }
    return null;
  }

  String? _checkIdempotent(MigrationRecipe recipe, RecipeContext context,
      OverlayFileSystem fork, String projectPath) {
    final FlutterProject migrated;
    try {
      migrated = ProjectInspector(fork, knowledge: knowledge)
          .inspectProject(projectPath);
    } on ReforgeException catch (e) {
      return 'the edited project could not be inspected: ${e.message}';
    }
    final again = recipe.evaluate(RecipeContext(
      project: migrated,
      target: context.target,
      knowledge: context.knowledge,
      files: fork,
      options: context.options,
      currentFlutter: context.currentFlutter,
      environment: context.environment,
    ));
    return again is NotApplicable
        ? null
        : '${recipe.descriptor.id} still applies after its own changes';
  }
}

/// Orders recipes so that every recipe comes after the recipes it lists in
/// `runsAfter`, keeping the given order otherwise.
List<MigrationRecipe> orderRecipes(List<MigrationRecipe> recipes) {
  final byId = {for (final r in recipes) r.descriptor.id: r};
  final ordered = <MigrationRecipe>[];
  final visiting = <String>{};
  final done = <String>{};

  void visit(MigrationRecipe recipe) {
    final id = recipe.descriptor.id;
    if (done.contains(id)) return;
    if (!visiting.add(id)) {
      throw InternalException(
          'RECIPE_CYCLE', 'Recipe ordering has a cycle involving $id.');
    }
    for (final dependency in recipe.descriptor.runsAfter) {
      final other = byId[dependency];
      if (other != null) visit(other);
    }
    visiting.remove(id);
    done.add(id);
    ordered.add(recipe);
  }

  recipes.forEach(visit);
  return ordered;
}
