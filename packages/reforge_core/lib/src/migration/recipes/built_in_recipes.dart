import '../recipe.dart';
import 'android/compile_sdk_recipe.dart';
import 'android/flutter_gradle_plugin_dsl_recipe.dart';
import 'android/flutter_tool_migration_recipes.dart';
import 'android/gradle_properties_recipes.dart';
import 'android/gradle_wrapper_recipe.dart';
import 'android/kotlin_plugin_recipe.dart';
import 'android/min_sdk_recipe.dart';
import 'android/namespace_recipe.dart';
import 'android/plugin_version_recipes.dart';
import 'dart/sdk_constraint_recipe.dart';
import 'darwin/deployment_target_recipe.dart';

/// The recipes shipped with Reforge, in their default evaluation order.
List<MigrationRecipe> builtInRecipes() => const [
      DartSdkConstraintRecipe(),
      FlutterGradlePluginDslRecipe(),
      GradleWrapperRecipe(),
      Agp9OptOutsRecipe(),
      CompileSdkRecipe(),
      AgpVersionRecipe(),
      KotlinVersionRecipe(),
      AppKotlinPluginRecipe(),
      NamespaceRecipe(),
      MinSdkRecipe(),
      LazyCleanTaskRecipe(),
      GradleJvmArgsRecipe(),
      JetifierRecipe(),
      DeploymentTargetRecipe.ios(),
      DeploymentTargetRecipe.macos(),
    ];
