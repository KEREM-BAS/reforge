import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

/// A command to execute. Arguments are passed directly to the executable;
/// Reforge never builds shell command lines.
@immutable
final class ExternalCommand {
  const ExternalCommand(
    this.executable,
    this.arguments, {
    this.workingDirectory,
    this.environment,
    this.timeout = const Duration(minutes: 2),
  });

  final String executable;
  final List<String> arguments;
  final String? workingDirectory;

  /// Extra environment variables layered over the current environment.
  final Map<String, String>? environment;
  final Duration timeout;

  /// A human-readable rendering for logs and reports.
  String get display => [executable, ...arguments]
      .map((part) => part.contains(' ') ? '"$part"' : part)
      .join(' ');
}

@immutable
final class CommandResult {
  const CommandResult({
    required this.command,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required this.elapsed,
    this.timedOut = false,
    this.startError,
  });

  final ExternalCommand command;

  /// Process exit code; `-1` when the process could not be started or timed
  /// out.
  final int exitCode;
  final String stdout;
  final String stderr;
  final Duration elapsed;
  final bool timedOut;

  /// Why the process could not be started (for example, not found).
  final String? startError;

  bool get succeeded => exitCode == 0 && !timedOut && startError == null;
}

abstract interface class ProcessRunner {
  /// Runs [command] to completion. Output lines are forwarded to [onOutput]
  /// as they arrive, when provided.
  Future<CommandResult> run(ExternalCommand command,
      {void Function(String line)? onOutput});
}

/// Runs processes on the local machine.
final class LocalProcessRunner implements ProcessRunner {
  const LocalProcessRunner();

  @override
  Future<CommandResult> run(ExternalCommand command,
      {void Function(String line)? onOutput}) async {
    final stopwatch = Stopwatch()..start();
    final resolved = resolveExecutable(command.executable);
    if (resolved == null) {
      return CommandResult(
        command: command,
        exitCode: -1,
        stdout: '',
        stderr: '',
        elapsed: stopwatch.elapsed,
        startError: '"${command.executable}" was not found on PATH.',
      );
    }
    final Process process;
    try {
      process = await Process.start(
        resolved,
        command.arguments,
        workingDirectory: command.workingDirectory,
        environment: command.environment,
        // Windows batch files (flutter.bat) can only be started through the
        // command interpreter; arguments are internal constants, never user
        // controlled strings.
        runInShell: Platform.isWindows &&
            (resolved.toLowerCase().endsWith('.bat') ||
                resolved.toLowerCase().endsWith('.cmd')),
      );
    } on ProcessException catch (e) {
      return CommandResult(
        command: command,
        exitCode: -1,
        stdout: '',
        stderr: '',
        elapsed: stopwatch.elapsed,
        startError: e.message,
      );
    }

    final stdout = StringBuffer();
    final stderr = StringBuffer();
    StreamSubscription<String> listen(
            Stream<List<int>> stream, StringBuffer sink) =>
        stream
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .listen((line) {
          sink.writeln(line);
          onOutput?.call(line);
        });

    final outSubscription = listen(process.stdout, stdout);
    final errSubscription = listen(process.stderr, stderr);
    var timedOut = false;
    final exitCode =
        await process.exitCode.timeout(command.timeout, onTimeout: () {
      timedOut = true;
      process.kill(ProcessSignal.sigkill);
      return -1;
    });
    await Future.wait([
      outSubscription.asFuture<void>(),
      errSubscription.asFuture<void>()
    ]).timeout(const Duration(seconds: 5), onTimeout: () => const []);
    await outSubscription.cancel();
    await errSubscription.cancel();
    return CommandResult(
      command: command,
      exitCode: exitCode,
      stdout: stdout.toString(),
      stderr: stderr.toString(),
      elapsed: stopwatch.elapsed,
      timedOut: timedOut,
    );
  }

  /// Resolves [executable] against `PATH` (and `PATHEXT` on Windows).
  /// Absolute or relative paths are returned when they exist.
  static String? resolveExecutable(
    String executable, {
    Map<String, String>? environment,
    bool? windows,
    bool Function(String path)? fileExists,
  }) {
    final exists = fileExists ?? ((String path) => File(path).existsSync());
    final isWindows = windows ?? Platform.isWindows;
    final env = environment ?? Platform.environment;
    if (executable.contains('/') || executable.contains(r'\')) {
      return exists(executable) ? executable : null;
    }
    final path = env['PATH'] ?? '';
    final separator = isWindows ? ';' : ':';
    final extensions = isWindows
        ? (env['PATHEXT'] ?? '.EXE;.BAT;.CMD')
            .split(';')
            .where((e) => e.isNotEmpty)
            .toList()
        : const [''];
    for (final directory in path.split(separator)) {
      if (directory.isEmpty) continue;
      for (final extension in extensions) {
        final candidate = p.join(directory, '$executable$extension');
        if (exists(candidate)) return candidate;
      }
    }
    return null;
  }
}
