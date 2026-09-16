import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge/reforge.dart';
import 'package:reforge/src/docs/recipe_docs.g.dart';
import 'package:reforge_core/reforge_core.dart';
import 'package:test/test.dart';

import 'support/cli_harness.dart';

void main() {
  test('every recipe is documented and the bundled docs are current', () {
    final docs = Directory(p.join(repositoryRoot(), 'docs', 'recipes'));
    for (final recipe in builtInRecipes()) {
      expect(File(p.join(docs.path, '${recipe.descriptor.id}.md')).existsSync(),
          isTrue,
          reason: '${recipe.descriptor.id} needs docs/recipes/'
              '${recipe.descriptor.id}.md');
    }
    final files = {
      for (final file in docs.listSync().whereType<File>())
        if (file.path.endsWith('.md'))
          p.basenameWithoutExtension(file.path):
              file.readAsStringSync().replaceAll('\r\n', '\n'),
    };
    expect(recipeDocs, files,
        reason: 'Run `dart run tool/generate_recipe_docs.dart` in '
            'packages/reforge.');
  });

  test('recipes and explain', () async {
    final list = await runCli(['recipes']);
    expect(list.exitCode, ExitCodes.success);
    expect(list.stdout, contains('ANDROID_JETIFIER'));

    final explain = await runCli(['explain', 'android_jetifier']);
    expect(explain.exitCode, ExitCodes.success);
    expect(explain.stdout, startsWith('# ANDROID_JETIFIER'));

    final unknown = await runCli(['explain', 'NOPE']);
    expect(unknown.exitCode, ExitCodes.usage);
    expect(unknown.stderr, contains('UNKNOWN_RECIPE'));
  });
}
