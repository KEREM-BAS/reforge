import 'package:reforge_core/reforge_core.dart';

import '../output/terminal.dart';
import 'findings_renderer.dart';

void renderPlan(Terminal t, MigrationPlan plan,
    {required bool verbose, required bool diff}) {
  t.line(t.bold('Migration plan to Flutter ${plan.target.version}') +
      t.dim('  (Dart ${plan.target.dartVersion})'));
  for (final entry in plan.currentFlutter.entries) {
    final project = entry.key.isEmpty ? '' : '${entry.key}: ';
    final current = entry.value;
    final basis = switch (current?.basis) {
      CurrentFlutterBasis.pinned => 'pinned',
      CurrentFlutterBasis.environment => 'flutter on PATH',
      CurrentFlutterBasis.lastPubGet => 'last pub get',
      CurrentFlutterBasis.created => 'created with',
      null => 'unknown',
    };
    t.line(t.dim('${project}current Flutter: '
        '${current?.release.version ?? 'unknown'} ($basis)'));
  }

  final projects = plan.steps.map((s) => s.project).toSet().toList();
  if (plan.steps.isEmpty) {
    t.line();
    t.line('  ${t.green(t.ok)} No migration steps are needed.');
  }
  for (final project in projects) {
    t.line();
    if (projects.length > 1 || project.isNotEmpty) {
      t.line(t.bold(project.isEmpty ? '(workspace root)' : project));
    }
    for (final step in plan.steps.where((s) => s.project == project)) {
      _renderStep(t, step, verbose: verbose);
    }
  }

  if (verbose && plan.skipped.isNotEmpty) {
    t.heading('Not applicable');
    for (final skipped in plan.skipped) {
      t.line('  ${t.dim(t.info)} ${skipped.recipe.id}'
          '${skipped.project.isEmpty ? '' : t.dim(' (${skipped.project})')}');
      t.paragraph(skipped.reason);
    }
  }

  if (plan.fileChanges.isNotEmpty) {
    t.heading('Files to change (${plan.fileChanges.length})');
    for (final change in plan.fileChanges) {
      final stat = _stat(change);
      t.line('  ${change.path} ${t.dim('${t.green('+${stat.$1}')} '
          '${t.red('-${stat.$2}')}  ${change.recipes.toSet().join(', ')}')}');
    }
    if (diff) {
      for (final change in plan.fileChanges) {
        t.line();
        for (final line in change.diff.split('\n')) {
          if (line.startsWith('+') && !line.startsWith('+++')) {
            t.line(t.green(line));
          } else if (line.startsWith('-') && !line.startsWith('---')) {
            t.line(t.red(line));
          } else if (line.startsWith('@@')) {
            t.line(t.cyan(line));
          } else {
            t.line(line);
          }
        }
      }
    } else {
      t.line(t.dim('  Use --diff to see the changes.'));
    }
  }

  final remaining = plan.remainingFindings
      .where((f) => verbose || f.severity != Severity.info)
      .toList();
  if (remaining.isNotEmpty) {
    t.heading('Still open after this plan');
    // Findings that an unapplied step of this plan would resolve are listed
    // briefly; everything else is explained in full.
    final unappliedRecipes = {
      for (final step in plan.steps)
        if (!step.applied) step.recipe.id,
    };
    for (final finding in remaining) {
      final resolvers =
          finding.relatedRecipes.where(unappliedRecipes.contains).toList();
      if (!verbose && resolvers.isNotEmpty) {
        final symbol = finding.severity == Severity.error
            ? t.red(t.fail)
            : t.yellow(t.warn);
        t.line('  $symbol ${finding.code} '
            '${t.dim('resolved by ${resolvers.join(', ')} (not applied)')}');
      } else {
        renderFinding(t, finding, verbose: verbose);
      }
    }
  }

  t.heading('Summary');
  final counts = [
    for (final status in StepStatus.values)
      if (plan.stepsWith(status).isNotEmpty)
        '${plan.stepsWith(status).length} ${status.name}',
  ];
  t.line(
      '  ${plan.steps.length} steps${counts.isEmpty ? '' : ' ${t.dot} ${counts.join(' ${t.dot} ')}'}'
      ' ${t.dot} ${plan.fileChanges.length} files');
  if (plan.isComplete) {
    t.line('  ${t.green(t.ok)} ${t.bold('Complete')}: applying this plan '
        'resolves every known blocker for Flutter ${plan.target.version}.');
  } else {
    t.line('  ${t.yellow(t.warn)} ${t.bold('Incomplete')}:');
    final pendingReviews = plan.outstandingSteps
        .where((s) => s.status == StepStatus.review)
        .toList();
    if (pendingReviews.isNotEmpty) {
      t.line('    ${pendingReviews.length} review step(s) not accepted: '
          '${pendingReviews.map((s) => s.recipe.id).toSet().join(', ')}');
    }
    final manual = plan.outstandingSteps
        .where((s) =>
            s.status == StepStatus.manual || s.status == StepStatus.blocked)
        .toList();
    if (manual.isNotEmpty) {
      t.line('    ${manual.length} manual or blocked step(s): '
          '${manual.map((s) => s.recipe.id).toSet().join(', ')}');
    }
    if (plan.remainingErrors.isNotEmpty) {
      t.line('    ${plan.remainingErrors.length} error(s) remain: '
          '${plan.remainingErrors.map((f) => f.code).toSet().join(', ')}');
    }
    if (plan.unanalyzedFiles.isNotEmpty) {
      t.line(
          '    ${plan.unanalyzedFiles.length} file(s) could not be analyzed.');
    }
  }
  t.line(t.dim('  Plan id ${plan.id}'));
}

void _renderStep(Terminal t, PlanStep step, {required bool verbose}) {
  final (symbol, label) = switch (step.status) {
    StepStatus.auto => (t.green(t.ok), t.green('auto')),
    StepStatus.review => step.applied
        ? (t.green(t.ok), t.yellow('review, accepted'))
        : (t.yellow('?'), t.yellow('review')),
    StepStatus.manual => (t.yellow(t.warn), t.yellow('manual')),
    StepStatus.blocked => (t.red(t.fail), t.red('blocked')),
  };
  final necessity = step.proposal.necessity == Necessity.recommended
      ? t.dim(' recommended')
      : '';
  t.line('  $symbol ${t.bold(step.recipe.id)}  $label$necessity');
  t.paragraph(step.proposal.summary);
  if (verbose) {
    t.paragraph(t.dim('Why: ${step.proposal.rationale}'));
    if (step.proposal.impact != null) {
      t.paragraph(t.dim('Impact: ${step.proposal.impact}'));
    }
    for (final evidence in step.proposal.evidence) {
      final where = evidence.location?.display ?? evidence.source?.url;
      t.line('    ${t.dim('${t.info} ${evidence.description}'
          '${where == null ? '' : ' ($where)'}')}');
    }
  }
  final showNotes = verbose ||
      step.status == StepStatus.review ||
      step.status == StepStatus.manual ||
      step.status == StepStatus.blocked;
  if (showNotes) {
    for (final note in step.proposal.notes) {
      t.paragraph('${t.dim('-')} $note', indent: 6, hanging: 2);
    }
  }
  for (final manual in step.proposal.manualSteps) {
    t.paragraph('${t.arrow} $manual', indent: 6, hanging: 2);
  }
}

(int, int) _stat(PlannedFileChange change) {
  var added = 0;
  var removed = 0;
  for (final line in change.diff.split('\n')) {
    if (line.startsWith('+') && !line.startsWith('+++')) added++;
    if (line.startsWith('-') && !line.startsWith('---')) removed++;
  }
  return (added, removed);
}
