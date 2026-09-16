import 'package:meta/meta.dart';

import '../environment/environment.dart';
import '../fs/project_file_system.dart';
import '../inspection/current_flutter_version.dart';
import '../knowledge/flutter_release.dart';
import '../knowledge/knowledge_base.dart';
import '../model/finding.dart';
import '../model/flutter_project.dart';
import '../text/text_edit.dart';

/// What a migration step can do.
enum StepStatus {
  /// Reforge applies the change and knows how to verify it.
  auto,

  /// Reforge can produce the change, but a human must accept it.
  review,

  /// Reforge explains what to do but cannot safely do it.
  manual,

  /// The step cannot proceed until something else changes.
  blocked,
}

/// Whether the target release needs the step.
enum Necessity {
  /// The target release fails to build or run without it.
  required,

  /// Deprecations and warning thresholds; applied only when requested.
  recommended,
}

enum RecipeCategory { flutter, dart, android, ios }

/// Checks that prove a step worked. Static checks run offline; the others run
/// external tools during `reforge verify`.
enum VerificationCheck {
  /// Edited files parse and the recipe no longer applies.
  staticAnalysis,

  /// `flutter pub get` succeeds.
  pubGet,

  /// `flutter analyze` reports no errors.
  analyze,

  /// `flutter build apk --debug` succeeds.
  androidBuild,

  /// `flutter build ios --debug --no-codesign` succeeds (macOS only).
  iosBuild,
}

/// Static description of a recipe.
@immutable
final class RecipeDescriptor {
  const RecipeDescriptor({
    required this.id,
    required this.title,
    required this.summary,
    required this.category,
    this.runsAfter = const [],
    this.requires = const [],
  });

  /// Stable identifier, see [RecipeIds].
  final String id;
  final String title;
  final String summary;
  final RecipeCategory category;

  /// Recipes that must be evaluated (and applied) before this one when both
  /// are part of a plan.
  final List<String> runsAfter;

  /// Recipes whose unapplied steps block this recipe's step.
  final List<String> requires;

  String get documentation => 'docs/recipes/$id.md';

  Map<String, Object?> toJson() => {
        'id': id,
        'title': title,
        'summary': summary,
        'category': category.name,
        if (runsAfter.isNotEmpty) 'runsAfter': runsAfter,
        if (requires.isNotEmpty) 'requires': requires,
        'documentation': documentation,
      };
}

/// Options that change what a plan contains.
@immutable
final class PlanOptions {
  const PlanOptions({
    this.includeRecommended = false,
    this.includedRecipes = const {},
    this.acceptAllReviews = false,
    this.acceptedReviews = const {},
    this.skippedRecipes = const {},
  });

  /// Also plan recommended (non-required) steps of every recipe.
  final bool includeRecommended;

  /// Recipes whose recommended steps are planned.
  final Set<String> includedRecipes;

  /// Treat every review step as accepted, so later steps build on it.
  final bool acceptAllReviews;

  /// Review steps accepted individually.
  final Set<String> acceptedReviews;

  /// Recipes excluded by configuration or command line.
  final Set<String> skippedRecipes;

  bool accepts(String recipeId) =>
      acceptAllReviews || acceptedReviews.contains(recipeId);

  /// Whether recommended steps of [recipeId] are planned.
  bool includesRecommended(String recipeId) =>
      includeRecommended || includedRecipes.contains(recipeId);

  /// Reads options written by [toJson]; missing fields take their defaults.
  factory PlanOptions.fromJson(Map<String, Object?> json) {
    Set<String> ids(String key) =>
        {for (final id in (json[key] as List? ?? const [])) '$id'};
    return PlanOptions(
      includeRecommended: json['includeRecommended'] == true,
      includedRecipes: ids('includedRecipes'),
      acceptAllReviews: json['acceptAllReviews'] == true,
      acceptedReviews: ids('acceptedReviews'),
      skippedRecipes: ids('skippedRecipes'),
    );
  }

  Map<String, Object?> toJson() => {
        'includeRecommended': includeRecommended,
        'includedRecipes': (includedRecipes.toList()..sort()),
        'acceptAllReviews': acceptAllReviews,
        'acceptedReviews': (acceptedReviews.toList()..sort()),
        'skippedRecipes': (skippedRecipes.toList()..sort()),
      };
}

/// What a recipe sees when it is evaluated.
@immutable
final class RecipeContext {
  const RecipeContext({
    required this.project,
    required this.target,
    required this.knowledge,
    required this.files,
    required this.options,
    this.currentFlutter,
    this.environment,
  });

  /// The project as it looks after earlier steps of the plan.
  final FlutterProject project;

  /// The Flutter release being migrated to.
  final FlutterRelease target;

  final KnowledgeBase knowledge;

  /// Files as they look after earlier steps of the plan.
  final ProjectFileSystem files;

  final PlanOptions options;
  final CurrentFlutterVersion? currentFlutter;

  /// The observed environment, when available. Recipes must produce the same
  /// file edits with or without it.
  final Environment? environment;
}

/// Edits to one file.
@immutable
final class FileEdit {
  const FileEdit(this.path, this.edits);

  /// Workspace-relative path.
  final String path;
  final List<TextEdit> edits;
}

sealed class RecipeResult {
  const RecipeResult();
}

/// The recipe does not apply. [reason] is shown in verbose plans and must
/// explain why, e.g. "namespace is already declared in android/app/build.gradle".
final class NotApplicable extends RecipeResult {
  const NotApplicable(this.reason);

  final String reason;
}

/// A proposed migration step.
final class Proposal extends RecipeResult {
  const Proposal({
    required this.status,
    required this.necessity,
    required this.summary,
    required this.rationale,
    this.impact,
    this.confidence = Confidence.certain,
    this.evidence = const [],
    this.edits = const [],
    this.notes = const [],
    this.manualSteps = const [],
    this.verification = const [VerificationCheck.staticAnalysis],
    this.details = const {},
  }) : assert(
          (status == StepStatus.manual || status == StepStatus.blocked)
              ? edits.length == 0
              : true,
          'Manual and blocked steps carry no edits.',
        );

  final StepStatus status;
  final Necessity necessity;

  /// What the step changes, in one sentence.
  final String summary;

  /// Why the step is needed.
  final String rationale;

  /// What happens if the step is not done.
  final String? impact;

  final Confidence confidence;
  final List<Evidence> evidence;
  final List<FileEdit> edits;

  /// Things a reviewer should know (why review is needed, what was kept).
  final List<String> notes;

  /// Instructions for manual or blocked steps.
  final List<String> manualSteps;

  final List<VerificationCheck> verification;

  /// Structured data for automation (e.g. `{"from": "7.3.0", "to": "8.11.1"}`).
  final Map<String, Object?> details;

  /// A copy with additional edits and notes.
  Proposal withEdits(List<FileEdit> extraEdits,
          {List<String> extraNotes = const []}) =>
      Proposal(
        status: status,
        necessity: necessity,
        summary: summary,
        rationale: rationale,
        impact: impact,
        confidence: confidence,
        evidence: evidence,
        edits: [...edits, ...extraEdits],
        notes: [...notes, ...extraNotes],
        manualSteps: manualSteps,
        verification: verification,
        details: details,
      );

  Proposal withStatus(StepStatus newStatus,
          {List<String> extraNotes = const [],
          List<String> extraManualSteps = const []}) =>
      Proposal(
        status: newStatus,
        necessity: necessity,
        summary: summary,
        rationale: rationale,
        impact: impact,
        confidence: confidence,
        evidence: evidence,
        edits: newStatus == StepStatus.manual || newStatus == StepStatus.blocked
            ? const []
            : edits,
        notes: [...notes, ...extraNotes],
        manualSteps: [...manualSteps, ...extraManualSteps],
        verification: verification,
        details: details,
      );
}

/// A unit of migration knowledge.
///
/// Implementations must be deterministic: the same context always yields the
/// same result. After a recipe's edits are applied, evaluating it again must
/// return [NotApplicable].
abstract base class MigrationRecipe {
  const MigrationRecipe();

  RecipeDescriptor get descriptor;

  RecipeResult evaluate(RecipeContext context);
}
