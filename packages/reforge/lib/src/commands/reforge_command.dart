import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;
import 'package:reforge_core/reforge_core.dart';

import '../cli_context.dart';
import '../output/sarif.dart';
import '../output/terminal.dart';

enum OutputFormat { text, json, sarif }

/// Base class of Reforge commands: shared option handling and output.
abstract class ReforgeCommand extends Command<int> {
  ReforgeCommand(this.context);

  final CliContext context;

  OutputFormat get format =>
      OutputFormat.values.byName(globalResults!['format'] as String);

  bool get verbose => globalResults!['verbose'] as bool;

  /// Absolute path of the project directory.
  String get projectDirectory {
    final option = globalResults!['project'] as String?;
    final directory = option == null
        ? context.workingDirectory
        : p.normalize(p.isAbsolute(option)
            ? option
            : p.join(context.workingDirectory, option));
    if (!Directory(directory).existsSync()) {
      throw InvalidUsageException(
          'PROJECT_DIRECTORY_MISSING', 'Directory $directory does not exist.');
    }
    return directory;
  }

  late final Terminal terminal = Terminal(
    context.out,
    color: context.color ??
        (!(globalResults!['no-color'] as bool) &&
            !Platform.environment.containsKey('NO_COLOR') &&
            identical(context.out, stdout) &&
            stdout.hasTerminal &&
            stdout.supportsAnsiEscapes),
    unicode: context.unicode,
  );

  /// Writes a JSON document wrapped in the standard envelope.
  void writeJson(Map<String, Object?> result) {
    context.out.writeln(const JsonEncoder.withIndent('  ').convert({
      'schemaVersion': jsonSchemaVersion,
      'reforge': {
        'version': reforgeVersion,
        'knowledgeBase': context.knowledge.version,
      },
      'command': name,
      'result': result,
    }));
  }

  /// A SARIF builder whose locations are relative to the working directory.
  SarifBuilder sarifBuilder() {
    final relative =
        p.relative(projectDirectory, from: context.workingDirectory);
    final prefix = relative == '.' || relative.startsWith('..')
        ? ''
        : '${relative.replaceAll(r'\', '/')}/';
    return SarifBuilder(command: name, pathPrefix: prefix);
  }

  /// Writes a SARIF log (without the Reforge JSON envelope).
  void writeSarif(SarifBuilder builder) {
    context.out
        .writeln(const JsonEncoder.withIndent('  ').convert(builder.build()));
  }

  /// Runs inspection of the selected project directory.
  Workspace inspectWorkspace() => ProjectInspector(
        LocalProjectFileSystem(projectDirectory),
        knowledge: context.knowledge,
      ).inspectWorkspace();
}
