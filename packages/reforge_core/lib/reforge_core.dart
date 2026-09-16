/// The Reforge engine.
///
/// Inspect Flutter projects, reason about compatibility with a target Flutter
/// release, plan migrations, apply them transactionally and verify results.
library;

export 'package:pub_semver/pub_semver.dart' show Version, VersionConstraint;

export 'src/analysis/compatibility_analyzer.dart';
export 'src/apply/applier.dart';
export 'src/apply/journal.dart';
export 'src/common/errors.dart';
export 'src/common/source.dart';
export 'src/environment/environment.dart';
export 'src/environment/environment_probe.dart';
export 'src/environment/process_runner.dart';
export 'src/fs/project_file_system.dart';
export 'src/inspection/current_flutter_version.dart';
export 'src/inspection/dependency_inspector.dart';
export 'src/inspection/project_inspector.dart';
export 'src/knowledge/flutter_release.dart';
export 'src/knowledge/knowledge_base.dart';
export 'src/knowledge/knowledge_source.dart';
export 'src/migration/plan.dart';
export 'src/migration/planner.dart';
export 'src/migration/recipe.dart';
export 'src/migration/recipe_ids.dart';
export 'src/migration/recipes/built_in_recipes.dart';
export 'src/model/android_project.dart';
export 'src/model/declarations.dart';
export 'src/model/dependencies.dart';
export 'src/model/finding.dart';
export 'src/model/flutter_project.dart';
export 'src/model/ios_project.dart';
export 'src/vcs/git.dart';
export 'src/verification/diagnosis.dart';
export 'src/verification/failure_signatures.dart';
export 'src/verification/verifier.dart';
export 'src/version/tool_version.dart';

/// The version of Reforge.
const reforgeVersion = '0.1.0-dev';

/// Version of the JSON output schema. Incremented on breaking changes.
const jsonSchemaVersion = 1;
