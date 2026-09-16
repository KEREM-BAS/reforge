/// Broad failure categories.
///
/// The CLI maps categories to process exit codes and JSON output exposes them,
/// so automation can react to failures without parsing human-readable text.
enum ErrorCategory {
  /// The command line or configuration is invalid.
  usage,

  /// The host environment cannot perform the requested operation
  /// (for example an iOS build on Linux).
  unsupportedEnvironment,

  /// The directory is not a Flutter project Reforge can work with.
  invalidProject,

  /// A project file could not be parsed well enough to continue.
  parse,

  /// The requested migration target is unknown or unsupported.
  unsupportedTarget,

  /// A migration cannot proceed (blockers, stale plan, dirty files).
  migrationBlocked,

  /// Applying a migration failed.
  migrationFailed,

  /// An external tool (flutter, git, java, ...) is missing or misbehaved.
  externalTool,

  /// The migration journal is inconsistent, or a rollback found conflicts.
  journal,

  /// A defect in Reforge itself.
  internal,
}

/// Base class of every error Reforge reports deliberately.
///
/// Each error has a stable [code] (for example `PROJECT_NOT_FOUND`) that can be
/// referenced in documentation, issues and automation, a human-readable
/// [message], and optional [hints] describing what the user can do next.
sealed class ReforgeException implements Exception {
  const ReforgeException(
    this.code,
    this.message, {
    this.hints = const [],
  });

  final String code;
  final String message;
  final List<String> hints;

  ErrorCategory get category;

  Map<String, Object?> toJson() => {
        'code': code,
        'category': category.name,
        'message': message,
        if (hints.isNotEmpty) 'hints': hints,
      };

  @override
  String toString() => '$code: $message';
}

final class InvalidUsageException extends ReforgeException {
  const InvalidUsageException(super.code, super.message, {super.hints});

  @override
  ErrorCategory get category => ErrorCategory.usage;
}

final class UnsupportedEnvironmentException extends ReforgeException {
  const UnsupportedEnvironmentException(super.code, super.message,
      {super.hints});

  @override
  ErrorCategory get category => ErrorCategory.unsupportedEnvironment;
}

final class InvalidProjectException extends ReforgeException {
  const InvalidProjectException(super.code, super.message, {super.hints});

  @override
  ErrorCategory get category => ErrorCategory.invalidProject;
}

final class ProjectParseException extends ReforgeException {
  const ProjectParseException(
    super.code,
    super.message, {
    required this.path,
    this.line,
    super.hints,
  });

  /// Project-relative path of the file that failed to parse.
  final String path;
  final int? line;

  @override
  ErrorCategory get category => ErrorCategory.parse;

  @override
  Map<String, Object?> toJson() => {
        ...super.toJson(),
        'path': path,
        if (line != null) 'line': line,
      };
}

final class UnsupportedTargetException extends ReforgeException {
  const UnsupportedTargetException(super.code, super.message, {super.hints});

  @override
  ErrorCategory get category => ErrorCategory.unsupportedTarget;
}

final class MigrationBlockedException extends ReforgeException {
  const MigrationBlockedException(super.code, super.message, {super.hints});

  @override
  ErrorCategory get category => ErrorCategory.migrationBlocked;
}

final class MigrationFailedException extends ReforgeException {
  const MigrationFailedException(
    super.code,
    super.message, {
    super.hints,
    this.restored = false,
  });

  /// Whether every file touched before the failure was restored.
  final bool restored;

  @override
  ErrorCategory get category => ErrorCategory.migrationFailed;

  @override
  Map<String, Object?> toJson() => {...super.toJson(), 'restored': restored};
}

final class ExternalToolException extends ReforgeException {
  const ExternalToolException(
    super.code,
    super.message, {
    required this.executable,
    super.hints,
  });

  final String executable;

  @override
  ErrorCategory get category => ErrorCategory.externalTool;

  @override
  Map<String, Object?> toJson() =>
      {...super.toJson(), 'executable': executable};
}

final class JournalException extends ReforgeException {
  const JournalException(super.code, super.message, {super.hints});

  @override
  ErrorCategory get category => ErrorCategory.journal;
}

/// A violated internal invariant. Seeing this is always a Reforge bug.
final class InternalException extends ReforgeException {
  const InternalException(super.code, super.message, {super.hints});

  @override
  ErrorCategory get category => ErrorCategory.internal;
}
