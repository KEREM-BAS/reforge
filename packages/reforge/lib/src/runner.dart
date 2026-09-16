import 'dart:convert';

import 'package:args/args.dart';
import 'package:args/command_runner.dart' as args;
import 'package:reforge_core/reforge_core.dart';

import 'cli_context.dart';
import 'commands/env_command.dart';
import 'commands/inspect_command.dart';
import 'exit_codes.dart';

const _description = 'Reforge keeps Flutter apps upgradeable: it inspects '
    'projects, plans migrations to a target Flutter release, applies them '
    'safely and verifies the result.';

/// Runs the Reforge CLI and returns the process exit code.
Future<int> runReforge(List<String> arguments, {CliContext? context}) async {
  final ctx = context ?? CliContext.io();
  final runner = args.CommandRunner<int>('reforge', _description)
    ..argParser.addOption(
      'project',
      abbr: 'C',
      valueHelp: 'directory',
      help: 'The Flutter project or workspace directory (default: current).',
    )
    ..argParser.addOption(
      'format',
      allowed: const ['text', 'json'],
      defaultsTo: 'text',
      help: 'Output format. JSON output is stable and versioned.',
    )
    ..argParser
        .addFlag('no-color', negatable: false, help: 'Disable colored output.')
    ..argParser.addFlag('verbose',
        abbr: 'v', negatable: false, help: 'Show more detail.')
    ..argParser.addFlag('version',
        negatable: false, help: 'Print the Reforge version.');

  runner
    ..addCommand(InspectCommand(ctx))
    ..addCommand(EnvCommand(ctx));

  ArgResults? parsed;
  try {
    parsed = runner.parse(arguments);
    if (parsed['version'] as bool) {
      ctx.out.writeln('reforge $reforgeVersion '
          '(knowledge base ${ctx.knowledge.version})');
      return ExitCodes.success;
    }
    return await runner.runCommand(parsed) ?? ExitCodes.success;
  } on args.UsageException catch (e) {
    ctx.err
      ..writeln(e.message)
      ..writeln()
      ..writeln(e.usage);
    return ExitCodes.usage;
  } on ReforgeException catch (e) {
    final json = _wantsJson(arguments, parsed);
    if (json) {
      ctx.out.writeln(const JsonEncoder.withIndent('  ').convert({
        'schemaVersion': jsonSchemaVersion,
        'reforge': {
          'version': reforgeVersion,
          'knowledgeBase': ctx.knowledge.version,
        },
        'command': parsed?.command?.name,
        'error': e.toJson(),
      }));
    } else {
      ctx.err.writeln('error ${e.code}: ${e.message}');
      for (final hint in e.hints) {
        ctx.err.writeln('  hint: $hint');
      }
    }
    return ExitCodes.forCategory(e.category);
  }
}

bool _wantsJson(List<String> arguments, ArgResults? parsed) {
  if (parsed != null) return parsed['format'] == 'json';
  for (var i = 0; i < arguments.length; i++) {
    if (arguments[i] == '--format=json') return true;
    if (arguments[i] == '--format' &&
        i + 1 < arguments.length &&
        arguments[i + 1] == 'json') {
      return true;
    }
  }
  return false;
}
