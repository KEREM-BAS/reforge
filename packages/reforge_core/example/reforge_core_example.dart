import 'dart:io';

import 'package:reforge_core/reforge_core.dart';

/// Prints the migration plan of the Flutter project in the current directory
/// (or the directory given as the first argument) to the latest stable
/// Flutter release this version of Reforge knows. Planning only reads files.
void main(List<String> arguments) {
  final knowledge = KnowledgeBase.bundled;
  final plan = MigrationPlanner(
    knowledge: knowledge,
    recipes: builtInRecipes(),
    reforgeVersion: reforgeVersion,
  ).plan(
    files: LocalProjectFileSystem(arguments.firstOrNull ?? '.'),
    target: knowledge.resolveFlutterVersion('stable'),
  );
  for (final step in plan.steps) {
    stdout.writeln(
        '${step.recipe.id} (${step.status.name}): ${step.proposal.summary}');
  }
}
