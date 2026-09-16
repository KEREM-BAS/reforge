import 'package:reforge_core/reforge_core.dart';

import '../output/terminal.dart';

void renderFindings(Terminal t, List<Finding> findings,
    {required bool verbose}) {
  final sorted = [...findings]
    ..sort((a, b) => a.severity.index.compareTo(b.severity.index));
  final visible = verbose
      ? sorted
      : sorted.where((f) => f.severity != Severity.info).toList();
  final hidden = sorted.length - visible.length;

  final errors = findings.where((f) => f.severity == Severity.error).length;
  final warnings = findings.where((f) => f.severity == Severity.warning).length;
  t.heading('Findings ${t.dim('$errors errors ${t.dot} $warnings warnings'
      '${hidden > 0 ? ' ${t.dot} $hidden info (use --verbose)' : ''}')}');
  if (visible.isEmpty) {
    t.line('  ${t.green(t.ok)} No problems found.');
    return;
  }
  for (final finding in visible) {
    renderFinding(t, finding, verbose: verbose);
  }
}

void renderFinding(Terminal t, Finding finding, {required bool verbose}) {
  final symbol = switch (finding.severity) {
    Severity.error => t.red(t.fail),
    Severity.warning => t.yellow(t.warn),
    Severity.info => t.cyan(t.info),
  };
  t.line();
  t.line('  $symbol ${t.bold(finding.code)}'
      '${finding.project == null || finding.project!.isEmpty ? '' : t.dim('  ${finding.project}')}');
  t.paragraph(finding.title);
  t.paragraph(finding.message);
  if (finding.why != null && verbose) {
    t.paragraph('Why: ${finding.why}');
  }
  if (finding.impact != null) t.paragraph('Impact: ${finding.impact}');
  if (finding.suggestedAction != null) {
    t.paragraph('Action: ${finding.suggestedAction}');
  }
  if (finding.relatedRecipes.isNotEmpty) {
    t.line('    ${t.dim('Recipe: ${finding.relatedRecipes.join(', ')}')}');
  }
  if (finding.confidence != Confidence.certain) {
    t.line('    ${t.dim('Confidence: ${finding.confidence.name}')}');
  }
  if (verbose) {
    for (final evidence in finding.evidence) {
      final where = evidence.location?.display ?? evidence.source?.url;
      t.line('    ${t.dim('${t.info} ${evidence.description}'
          '${where == null ? '' : ' ($where)'}')}');
    }
  }
}
