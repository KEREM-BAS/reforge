import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:meta/meta.dart';

import '../knowledge/flutter_release.dart';
import '../model/finding.dart';
import '../text/unified_diff.dart';
import 'recipe.dart';

/// A step of a migration plan.
@immutable
final class PlanStep {
  const PlanStep({
    required this.recipe,
    required this.project,
    required this.proposal,
    required this.applied,
    required this.fileChanges,
    this.blockedBy = const [],
  });

  final RecipeDescriptor recipe;

  /// Workspace-relative project path.
  final String project;

  final Proposal proposal;

  /// Whether the step's edits are part of the plan's resulting file state.
  /// Auto steps and accepted review steps are applied.
  final bool applied;

  /// The step's changes: file path to (before, after) content.
  final Map<String, ({String before, String after})> fileChanges;

  /// Recipes whose unapplied steps block this step.
  final List<String> blockedBy;

  StepStatus get status => proposal.status;

  Map<String, Object?> toJson({bool includeDiffs = true}) => {
        'recipe': recipe.id,
        'title': recipe.title,
        'project': project,
        'status': proposal.status.name,
        'necessity': proposal.necessity.name,
        'applied': applied,
        'summary': proposal.summary,
        'rationale': proposal.rationale,
        if (proposal.impact != null) 'impact': proposal.impact,
        'confidence': proposal.confidence.name,
        'evidence': [for (final e in proposal.evidence) e.toJson()],
        if (proposal.notes.isNotEmpty) 'notes': proposal.notes,
        if (proposal.manualSteps.isNotEmpty)
          'manualSteps': proposal.manualSteps,
        if (blockedBy.isNotEmpty) 'blockedBy': blockedBy,
        'verification': [for (final v in proposal.verification) v.name],
        if (proposal.details.isNotEmpty) 'details': proposal.details,
        'files': [
          for (final entry in fileChanges.entries)
            {
              'path': entry.key,
              if (includeDiffs)
                'diff': unifiedDiff(
                    path: entry.key,
                    before: entry.value.before,
                    after: entry.value.after),
            },
        ],
        'documentation': recipe.documentation,
      };
}

/// A recipe that was evaluated but did not apply.
@immutable
final class SkippedRecipe {
  const SkippedRecipe(this.recipe, this.project, this.reason);

  final RecipeDescriptor recipe;
  final String project;
  final String reason;

  Map<String, Object?> toJson() =>
      {'recipe': recipe.id, 'project': project, 'reason': reason};
}

/// A change to one file across the whole plan.
@immutable
final class PlannedFileChange {
  const PlannedFileChange(this.path, this.before, this.after, this.recipes);

  final String path;
  final String? before;
  final String after;

  /// Recipes contributing to the change.
  final List<String> recipes;

  String get diff => unifiedDiff(path: path, before: before, after: after);
}

/// A migration plan: an ordered, reviewable description of every change
/// needed to move a workspace to [target].
@immutable
final class MigrationPlan {
  const MigrationPlan({
    required this.target,
    required this.options,
    required this.steps,
    required this.skipped,
    required this.fileChanges,
    required this.remainingFindings,
    required this.inputs,
    required this.reforgeVersion,
    required this.knowledgeBaseVersion,
    required this.currentFlutter,
  });

  final FlutterRelease target;
  final PlanOptions options;
  final List<PlanStep> steps;
  final List<SkippedRecipe> skipped;

  /// The combined effect of all applied steps.
  final List<PlannedFileChange> fileChanges;

  /// Problems still present after the plan's applied steps, evaluated
  /// against the target release.
  final List<Finding> remainingFindings;

  /// Content hashes of every file read while planning (`null` = absent).
  final Map<String, String?> inputs;

  final String reforgeVersion;
  final String knowledgeBaseVersion;

  /// The Flutter version each project uses today, by project path.
  final Map<String, String?> currentFlutter;

  Iterable<PlanStep> stepsWith(StepStatus status) =>
      steps.where((s) => s.status == status);

  /// Steps that stop the migration from completing: blocked or manual
  /// required steps, and unaccepted required review steps.
  List<PlanStep> get outstandingSteps => [
        for (final step in steps)
          if (step.proposal.necessity == Necessity.required && !step.applied)
            step,
      ];

  /// Errors that remain after the plan is applied.
  List<Finding> get remainingErrors =>
      remainingFindings.where((f) => f.severity == Severity.error).toList();

  /// Files Reforge could not analyze; the plan cannot vouch for them.
  List<Finding> get unanalyzedFiles => remainingFindings
      .where((f) => f.code == 'PROJECT_FILE_UNREADABLE')
      .toList();

  /// Whether applying this plan is expected to leave the workspace without
  /// known errors for the target release. A plan is never complete while
  /// project files could not be analyzed.
  bool get isComplete =>
      outstandingSteps.isEmpty &&
      remainingErrors.isEmpty &&
      unanalyzedFiles.isEmpty;

  /// A stable identifier derived from everything that determines the plan.
  String get id {
    final canonical = jsonEncode({
      'reforge': reforgeVersion,
      'knowledgeBase': knowledgeBaseVersion,
      'target': '${target.version}',
      'options': options.toJson(),
      'inputs': Map.fromEntries(
          inputs.entries.toList()..sort((a, b) => a.key.compareTo(b.key))),
      'changes': [
        for (final change in fileChanges)
          {
            'path': change.path,
            'after': sha256.convert(utf8.encode(change.after)).toString()
          },
      ],
      'steps': [
        for (final step in steps)
          [step.recipe.id, step.project, step.status.name, step.applied],
      ],
    });
    return sha256.convert(utf8.encode(canonical)).toString().substring(0, 16);
  }

  Map<String, Object?> toJson({bool includeDiffs = true}) => {
        'planId': id,
        'target': {
          'flutter': '${target.version}',
          'dart': '${target.dartVersion}',
        },
        'currentFlutter': currentFlutter,
        'options': options.toJson(),
        'summary': {
          'steps': steps.length,
          for (final status in StepStatus.values)
            status.name: stepsWith(status).length,
          'applied': steps.where((s) => s.applied).length,
          'filesChanged': fileChanges.length,
          'remainingErrors': remainingErrors.length,
          'unanalyzedFiles': unanalyzedFiles.length,
          'complete': isComplete,
        },
        'steps': [for (final s in steps) s.toJson(includeDiffs: includeDiffs)],
        'skipped': [for (final s in skipped) s.toJson()],
        'fileChanges': [
          for (final change in fileChanges)
            {
              'path': change.path,
              'recipes': change.recipes,
              if (includeDiffs) 'diff': change.diff,
            },
        ],
        'remainingFindings': [for (final f in remainingFindings) f.toJson()],
        'inputs': inputs,
        'reforge': {
          'version': reforgeVersion,
          'knowledgeBase': knowledgeBaseVersion,
        },
      };
}
