import 'package:reforge_core/reforge_core.dart';

/// Builds SARIF 2.1.0 logs for code scanning tools.
///
/// Findings, plan steps and failure diagnoses become results. Locations are
/// only the repository files Reforge read (never files of dependencies or the
/// environment), relative to the directory Reforge ran in.
final class SarifBuilder {
  SarifBuilder({required this.command, this.pathPrefix = ''});

  /// The Reforge command, used to categorize the run.
  final String command;

  /// Prepended to project-relative paths so that locations are relative to
  /// the directory Reforge was run from (for example `apps/shop/` with
  /// `-C apps/shop`).
  final String pathPrefix;

  final Map<String, Map<String, Object?>> _rules = {};
  final List<Map<String, Object?>> _results = [];

  void addFinding(Finding finding) {
    final level = _levelOf(finding.severity);
    _rule(finding.code, finding.title, level);
    _results.add({
      'ruleId': finding.code,
      'level': level,
      'message': {
        'text': [
          _sentence(finding.title),
          finding.message,
          if (finding.impact != null) 'Impact: ${finding.impact}',
          if (finding.suggestedAction != null)
            'Action: ${finding.suggestedAction}',
        ].join(' '),
      },
      'locations': _locations(finding.evidence, pathPrefix),
      'properties': {
        'confidence': finding.confidence.name,
        if (finding.relatedRecipes.isNotEmpty)
          'relatedRecipes': finding.relatedRecipes,
        if (finding.subject != null) 'subject': finding.subject,
        if (finding.project != null && finding.project!.isNotEmpty)
          'project': finding.project,
      },
    });
  }

  /// Adds a migration step. Required steps that are not applied are errors
  /// (blocked or manual) or warnings (review not accepted); everything else is
  /// a note.
  void addStep(PlanStep step) {
    final required = step.proposal.necessity == Necessity.required;
    final level = switch (step.status) {
      _ when step.applied || !required => 'note',
      StepStatus.blocked || StepStatus.manual => 'error',
      _ => 'warning',
    };
    _rule(step.recipe.id, step.recipe.title, level, help: step.recipe.summary);
    final locations = _locations(step.proposal.evidence, pathPrefix);
    _results.add({
      'ruleId': step.recipe.id,
      'level': level,
      'message': {
        'text': [
          _sentence(step.proposal.summary),
          step.proposal.rationale,
          if (!step.applied) 'Status: ${step.status.name}, not applied.',
          ...step.proposal.manualSteps,
        ].join(' '),
      },
      'locations': locations.isNotEmpty
          ? locations
          : [
              for (final path in step.fileChanges.keys)
                _location(SourceRef(path), pathPrefix),
            ],
      'properties': {
        'status': step.status.name,
        'necessity': step.proposal.necessity.name,
        'applied': step.applied,
        if (step.project.isNotEmpty) 'project': step.project,
      },
    });
  }

  void addDiagnosis(Diagnosis diagnosis, {required String output}) {
    final failure = diagnosis.failure;
    _rule(failure.id, failure.explanation, 'error');
    _results.add({
      'ruleId': failure.id,
      'level': 'error',
      'message': {
        'text': [
          failure.explanation,
          for (final finding in diagnosis.confirmedBy)
            'Confirmed by ${finding.code}: ${_sentence(finding.title)}',
          'Suggested: ${failure.suggestion}',
        ].join(' '),
      },
      'locations': [
        for (final finding in diagnosis.confirmedBy)
          ..._locations(finding.evidence, pathPrefix),
      ],
      'properties': {
        'output': output,
        'evidence': failure.evidence,
        if (failure.details.isNotEmpty) 'details': failure.details,
        if (failure.relatedRecipes.isNotEmpty)
          'relatedRecipes': failure.relatedRecipes,
      },
    });
  }

  Map<String, Object?> build() => {
        r'$schema': 'https://json.schemastore.org/sarif-2.1.0.json',
        'version': '2.1.0',
        'runs': [
          {
            'tool': {
              'driver': {
                'name': 'Reforge',
                'version': reforgeVersion,
                'rules': _rules.values.toList(),
              },
            },
            'automationDetails': {'id': 'reforge/$command/'},
            'invocations': [
              {'executionSuccessful': true},
            ],
            'results': _results,
          },
        ],
      };

  void _rule(String id, String title, String level, {String? help}) {
    _rules.putIfAbsent(
        id,
        () => {
              'id': id,
              'shortDescription': {'text': _sentence(title)},
              if (help != null) 'help': {'text': help},
              'defaultConfiguration': {'level': level},
            });
  }

  static List<Map<String, Object?>> _locations(
      List<Evidence> evidence, String prefix) {
    final seen = <String>{};
    return [
      for (final item in evidence)
        if (item.location case final location?)
          if ((item.kind == EvidenceKind.projectFile ||
                  item.kind == EvidenceKind.generatedFile) &&
              seen.add(location.display))
            _location(location, prefix),
    ];
  }

  static Map<String, Object?> _location(SourceRef ref, String prefix) => {
        'physicalLocation': {
          'artifactLocation': {'uri': '$prefix${ref.path}'},
          if (ref.line != null)
            'region': {
              'startLine': ref.line,
              if (ref.column != null) 'startColumn': ref.column,
            },
        },
      };

  static String _levelOf(Severity severity) => switch (severity) {
        Severity.error => 'error',
        Severity.warning => 'warning',
        Severity.info => 'note',
      };

  static String _sentence(String text) => text.endsWith('.') ? text : '$text.';
}
