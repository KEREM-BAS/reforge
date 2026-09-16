# reforge_core

The engine of [Reforge](https://github.com/KEREM-BAS/reforge), Flutter upgrade
infrastructure:

- parsers for Gradle scripts (Groovy and Kotlin DSL), properties files,
  Podfiles, podspecs, Xcode projects and Android manifests, with source
  positions for surgical edits;
- a typed model of Flutter projects, their Android, iOS and macOS hosts and
  their resolved plugins;
- a knowledge base of stable Flutter releases and Android toolchain releases,
  with sources;
- migration recipes, the planner, transactional apply and rollback;
- verification and failure diagnosis.

Most users want the [`reforge`](https://pub.dev/packages/reforge)
command-line tool. The Dart API of this package is not stable before 1.0.

## Example

```dart
import 'dart:io';

import 'package:reforge_core/reforge_core.dart';

void main() {
  final knowledge = KnowledgeBase.bundled;
  final plan = MigrationPlanner(
    knowledge: knowledge,
    recipes: builtInRecipes(),
    reforgeVersion: reforgeVersion,
  ).plan(
    files: LocalProjectFileSystem('path/to/flutter_app'),
    target: knowledge.resolveFlutterVersion('stable'),
  );
  for (final step in plan.steps) {
    stdout.writeln(
        '${step.recipe.id} (${step.status.name}): ${step.proposal.summary}');
  }
}
```

Planning only reads files. See the
[architecture](https://github.com/KEREM-BAS/reforge/blob/main/docs/architecture.md)
and the [knowledge base](https://github.com/KEREM-BAS/reforge/blob/main/docs/knowledge-base.md)
documentation.
