import 'package:reforge_core/reforge_core.dart';

import '../docs/recipe_docs.g.dart';
import '../exit_codes.dart';
import 'reforge_command.dart';

final class RecipesCommand extends ReforgeCommand {
  RecipesCommand(super.context);

  @override
  String get name => 'recipes';

  @override
  String get description =>
      'List the migration recipes Reforge knows, in evaluation order.';

  @override
  Future<int> run() async {
    final recipes = orderRecipes(builtInRecipes());
    if (format == OutputFormat.json) {
      writeJson({
        'recipes': [for (final recipe in recipes) recipe.descriptor.toJson()],
      });
      return ExitCodes.success;
    }
    final t = terminal;
    t.heading('Recipes ${t.dim('(${recipes.length})')}');
    for (final recipe in recipes) {
      final descriptor = recipe.descriptor;
      t.line();
      t.line('  ${t.bold(descriptor.id)}  '
          '${t.dim('${descriptor.category.name} ${t.dot} ${descriptor.title}')}');
      t.paragraph(descriptor.summary);
    }
    t.line();
    t.line(t.dim('  Details: reforge explain <RECIPE_ID>'));
    return ExitCodes.success;
  }
}

final class ExplainCommand extends ReforgeCommand {
  ExplainCommand(super.context);

  @override
  String get name => 'explain';

  @override
  String get invocation => 'reforge explain <RECIPE_ID>';

  @override
  String get description =>
      'Show the documentation of a recipe: what it detects, why, the sources '
      'of its facts, what it changes and how it is verified.';

  @override
  Future<int> run() async {
    final rest = argResults!.rest;
    final recipes = {
      for (final recipe in builtInRecipes()) recipe.descriptor.id: recipe,
    };
    if (rest.length != 1) {
      throw const InvalidUsageException('EXPLAIN_ID_REQUIRED',
          'Name one recipe, e.g. reforge explain ANDROID_JETIFIER.');
    }
    final id = rest.single.toUpperCase();
    final recipe = recipes[id];
    if (recipe == null) {
      throw InvalidUsageException('UNKNOWN_RECIPE', 'Unknown recipe "$id".',
          hints: [
            'Known recipes: ${(recipes.keys.toList()..sort()).join(', ')}'
          ]);
    }
    final document = recipeDocs[id];
    if (format == OutputFormat.json) {
      writeJson({
        ...recipe.descriptor.toJson(),
        'markdown': document,
      });
      return ExitCodes.success;
    }
    context.out.writeln(document ??
        '${recipe.descriptor.title}\n\n${recipe.descriptor.summary}');
    return ExitCodes.success;
  }
}
