// Golden migration tests.
//
// Each directory in fixtures/migrations describes a case:
//   case.yaml   project, target and plan options (acceptReviews,
//               includeRecommended, include: [RECIPE_ID, ...])
//   plan.md     the expected plan summary
//   files/      the expected content of every file the plan changes
//
// Run with UPDATE_GOLDENS=1 to regenerate expectations, then review the diff.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge_core/reforge_core.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

import '../support/fixtures.dart';

final _update = Platform.environment['UPDATE_GOLDENS'] == '1';

String renderPlanSummary(MigrationPlan plan) {
  final buffer = StringBuffer()
    ..writeln('# Plan to Flutter ${plan.target.version}')
    ..writeln()
    ..writeln('complete: ${plan.isComplete}')
    ..writeln();
  for (final step in plan.steps) {
    buffer.writeln('## ${step.recipe.id} (${step.status.name}, '
        '${step.proposal.necessity.name}${step.applied ? ', applied' : ''})');
    buffer.writeln();
    buffer.writeln(step.proposal.summary);
    for (final note in step.proposal.notes) {
      buffer.writeln('- note: $note');
    }
    for (final manual in step.proposal.manualSteps) {
      buffer.writeln('- manual: $manual');
    }
    buffer.writeln('- files: ${step.fileChanges.keys.join(', ')}');
    buffer.writeln();
  }
  buffer.writeln('## Skipped');
  buffer.writeln();
  for (final skipped in plan.skipped) {
    buffer.writeln('- ${skipped.recipe.id}: ${skipped.reason}');
  }
  buffer.writeln();
  buffer.writeln('## Remaining findings');
  buffer.writeln();
  for (final finding in plan.remainingFindings) {
    buffer.writeln('- ${finding.severity.name} ${finding.code}');
  }
  return buffer.toString();
}

void main() {
  final root = Directory(p.join(repositoryRoot(), 'fixtures', 'migrations'));
  final cases = root
      .listSync()
      .whereType<Directory>()
      .where((d) => File(p.join(d.path, 'case.yaml')).existsSync())
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  final knowledge = KnowledgeBase.bundled;
  final planner = MigrationPlanner(
    knowledge: knowledge,
    recipes: builtInRecipes(),
    reforgeVersion: reforgeVersion,
  );

  for (final directory in cases) {
    final name = p.basename(directory.path);
    test(name, () {
      final spec =
          loadYaml(File(p.join(directory.path, 'case.yaml')).readAsStringSync())
              as YamlMap;
      final project = fixtureProject(spec['project'] as String);
      final options = PlanOptions(
        acceptAllReviews: spec['acceptReviews'] == true,
        includeRecommended: spec['includeRecommended'] == true,
        includedRecipes: {
          for (final id in (spec['include'] as YamlList? ?? const [])) '$id',
        },
      );
      final target = knowledge.resolveFlutterVersion('${spec['target']}');
      final files = LocalProjectFileSystem(project);
      final plan = planner.plan(files: files, target: target, options: options);

      final summaryFile = File(p.join(directory.path, 'plan.md'));
      final expectedDirectory = Directory(p.join(directory.path, 'files'));
      final summary = renderPlanSummary(plan);

      if (_update) {
        summaryFile.writeAsStringSync(summary);
        if (expectedDirectory.existsSync()) {
          expectedDirectory.deleteSync(recursive: true);
        }
        for (final change in plan.fileChanges) {
          final file = File(p.join(expectedDirectory.path, change.path));
          file.parent.createSync(recursive: true);
          file.writeAsStringSync(change.after);
        }
        return;
      }

      expect(summary, summaryFile.readAsStringSync());
      final expectedFiles = expectedDirectory.existsSync()
          ? expectedDirectory
              .listSync(recursive: true)
              .whereType<File>()
              .map((f) => p
                  .relative(f.path, from: expectedDirectory.path)
                  .replaceAll(r'\', '/'))
              .toSet()
          : <String>{};
      expect(plan.fileChanges.map((c) => c.path).toSet(), expectedFiles);
      for (final change in plan.fileChanges) {
        expect(
            change.after,
            File(p.join(expectedDirectory.path, change.path))
                .readAsStringSync(),
            reason: change.path);
      }

      // Idempotency: planning again on the migrated files changes nothing.
      final migrated = MemoryProjectFileSystem({
        for (final entry in _allFiles(project).entries) entry.key: entry.value,
        for (final change in plan.fileChanges) change.path: change.after,
      }, rootPath: project);
      final again =
          planner.plan(files: migrated, target: target, options: options);
      expect(again.fileChanges, isEmpty,
          reason: 'A second plan must not change files again.');
      expect(again.steps.where((s) => s.applied), isEmpty,
          reason: 'Every applied step must be idempotent.');
      expect(again.steps.map((s) => s.recipe.id).toList(),
          plan.steps.where((s) => !s.applied).map((s) => s.recipe.id).toList(),
          reason: 'Only steps that were not applied may remain.');
    });
  }
}

Map<String, String> _allFiles(String project) {
  final result = <String, String>{};
  for (final entity in Directory(project).listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative =
        p.relative(entity.path, from: project).replaceAll(r'\', '/');
    try {
      result[relative] = entity.readAsStringSync();
    } on FileSystemException {
      continue;
    }
  }
  return result;
}
