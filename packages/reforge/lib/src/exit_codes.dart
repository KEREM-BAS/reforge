import 'package:reforge_core/reforge_core.dart';

/// Process exit codes. Stable: automation depends on them.
abstract final class ExitCodes {
  /// The command succeeded.
  static const success = 0;

  /// The command ran but its outcome is failing (for example `plan
  /// --fail-on=blocked` found blockers, or `verify` failed).
  static const failed = 1;

  /// Invalid command line or configuration.
  static const usage = 2;

  /// The directory is not a Flutter project Reforge can read.
  static const invalidProject = 3;

  /// A migration cannot proceed (blockers, stale plan, dirty files).
  static const migrationBlocked = 4;

  /// Applying a migration failed.
  static const migrationFailed = 5;

  /// The target or environment is unsupported.
  static const unsupported = 6;

  /// An external tool is missing or failed.
  static const externalTool = 7;

  /// The journal is inconsistent or a rollback found conflicts.
  static const journal = 8;

  /// A defect in Reforge.
  static const internal = 70;

  static int forCategory(ErrorCategory category) => switch (category) {
        ErrorCategory.usage => usage,
        ErrorCategory.invalidProject || ErrorCategory.parse => invalidProject,
        ErrorCategory.migrationBlocked => migrationBlocked,
        ErrorCategory.migrationFailed => migrationFailed,
        ErrorCategory.unsupportedTarget ||
        ErrorCategory.unsupportedEnvironment =>
          unsupported,
        ErrorCategory.externalTool => externalTool,
        ErrorCategory.journal => journal,
        ErrorCategory.internal => internal,
      };
}
