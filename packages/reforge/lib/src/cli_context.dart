import 'dart:io';

import 'package:reforge_core/reforge_core.dart';

/// Everything a command needs from the outside world, injectable for tests.
final class CliContext {
  CliContext({
    required this.out,
    required this.err,
    required this.workingDirectory,
    this.color,
    this.unicode = true,
    Future<Environment> Function()? probeEnvironment,
    ProcessRunner? processRunner,
    KnowledgeBase? knowledge,
    DateTime Function()? clock,
  })  : probeEnvironment =
            probeEnvironment ?? (() => EnvironmentProbe().probe()),
        processRunner = processRunner ?? const LocalProcessRunner(),
        knowledge = knowledge ?? KnowledgeBase.bundled,
        clock = clock ?? DateTime.now;

  factory CliContext.io() => CliContext(
        out: stdout,
        err: stderr,
        workingDirectory: Directory.current.path,
        unicode: !Platform.isWindows || stdout.supportsAnsiEscapes,
      );

  final StringSink out;
  final StringSink err;
  final String workingDirectory;

  /// Forces color on or off; `null` detects from the terminal.
  final bool? color;
  final bool unicode;

  /// Observes the local toolchain.
  final Future<Environment> Function() probeEnvironment;
  final ProcessRunner processRunner;
  final KnowledgeBase knowledge;
  final DateTime Function() clock;
}
