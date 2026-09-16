import '../recipe.dart';
import 'android/flutter_gradle_plugin_dsl_recipe.dart';
import 'android/gradle_wrapper_recipe.dart';
import 'android/namespace_recipe.dart';
import 'android/plugin_version_recipes.dart';
import 'dart/sdk_constraint_recipe.dart';
import 'ios/deployment_target_recipe.dart';

/// The recipes shipped with Reforge, in their default evaluation order.
List<MigrationRecipe> builtInRecipes() => const [
      DartSdkConstraintRecipe(),
      FlutterGradlePluginDslRecipe(),
      GradleWrapperRecipe(),
      AgpVersionRecipe(),
      KotlinVersionRecipe(),
      NamespaceRecipe(),
      IosDeploymentTargetRecipe(),
    ];
