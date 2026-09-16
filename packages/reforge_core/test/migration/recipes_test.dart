import 'package:reforge_core/reforge_core.dart';
import 'package:reforge_core/src/migration/plan.dart';
import 'package:reforge_core/src/migration/planner.dart';
import 'package:reforge_core/src/migration/recipe.dart';
import 'package:reforge_core/src/migration/recipes/built_in_recipes.dart';
import 'package:reforge_core/src/migration/recipes/dart/sdk_constraint_recipe.dart';
import 'package:test/test.dart';

final knowledge = KnowledgeBase.bundled;

MigrationPlan planFor(Map<String, String> files,
    {String target = '3.47.4',
    PlanOptions options = const PlanOptions(acceptAllReviews: true)}) {
  final planner = MigrationPlanner(
      knowledge: knowledge,
      recipes: builtInRecipes(),
      reforgeVersion: reforgeVersion);
  return planner.plan(
    files: MemoryProjectFileSystem(files),
    target: knowledge.resolveFlutterVersion(target),
    options: options,
  );
}

PlanStep step(MigrationPlan plan, String id) =>
    plan.steps.singleWhere((s) => s.recipe.id == id);

String pubspec(String sdk) => '''
name: app
environment:
  sdk: $sdk
dependencies:
  flutter:
    sdk: flutter
''';

void main() {
  group('Dart SDK constraint', () {
    test('pub reinterprets <3.0.0 for null-safe lower bounds', () {
      final dart3 = Version(3, 13, 0);
      expect(
          effectiveDartSdkConstraint(
                  VersionConstraint.parse('>=2.12.0 <3.0.0'), dart3)
              .allows(dart3),
          isTrue);
      expect(
          effectiveDartSdkConstraint(
                  VersionConstraint.parse('>=2.7.0 <3.0.0'), dart3)
              .allows(dart3),
          isFalse);
      expect(
          effectiveDartSdkConstraint(
                  VersionConstraint.parse('>=2.12.0 <3.0.0'), Version(2, 19, 0))
              .allows(Version(3, 0, 0)),
          isFalse);
    });

    test('raises an upper bound that excludes the target, keeping quotes', () {
      final plan = planFor({'pubspec.yaml': pubspec('">=3.1.0 <3.5.0"')});
      final sdk = step(plan, RecipeIds.dartSdkConstraint);
      expect(sdk.status, StepStatus.auto);
      expect(plan.fileChanges.single.after, contains('sdk: ">=3.1.0 <4.0.0"'));
    });

    test('code that predates null safety needs manual migration', () {
      final plan = planFor({'pubspec.yaml': pubspec("'>=2.7.0 <3.0.0'")});
      final sdk = step(plan, RecipeIds.dartSdkConstraint);
      expect(sdk.status, StepStatus.manual);
      expect(sdk.proposal.summary, contains('null safety'));
      expect(plan.isComplete, isFalse);
      expect(plan.fileChanges, isEmpty);
    });

    test('caret constraints already allow newer minor versions', () {
      final plan = planFor({'pubspec.yaml': pubspec('^3.1.0')});
      expect(plan.steps, isEmpty);
      expect(
          plan.skipped
              .singleWhere((s) => s.recipe.id == RecipeIds.dartSdkConstraint)
              .reason,
          contains('allows Dart'));
    });
  });

  group('Android recipes', () {
    Map<String, String> declarativeApp({
      required String agp,
      String gradleUrl =
          r'https\://services.gradle.org/distributions/gradle-8.7-bin.zip',
      String extraWrapper = '',
      String app = 'plugins {\n    id "com.android.application"\n    '
          'id "dev.flutter.flutter-gradle-plugin"\n}\n\nandroid {\n'
          '    namespace "com.example.app"\n}\n',
    }) =>
        {
          'pubspec.yaml': pubspec('^3.9.0'),
          'android/settings.gradle': 'plugins {\n'
              '    id "dev.flutter.flutter-plugin-loader" version "1.0.0"\n'
              '    id "com.android.application" version "$agp" apply false\n'
              '}\ninclude ":app"\n',
          'android/build.gradle': 'allprojects {}\n',
          'android/app/build.gradle': app,
          'android/gradle/wrapper/gradle-wrapper.properties':
              'distributionUrl=$gradleUrl\n$extraWrapper',
        };

    test('wrapper checksum is updated for bin distributions', () {
      final plan = planFor(declarativeApp(
          agp: '8.11.1', extraWrapper: 'distributionSha256Sum=0000\n'));
      final wrapper = step(plan, RecipeIds.androidGradleWrapper);
      expect(wrapper.status, StepStatus.auto);
      final after = plan.fileChanges
          .singleWhere((c) => c.path.endsWith('gradle-wrapper.properties'))
          .after;
      final record = knowledge.gradleRelease(ToolVersion.parse('8.14'))!;
      expect(after, contains('gradle-8.14-bin.zip'));
      expect(after, contains('distributionSha256Sum=${record.bin}'));
    });

    test('a custom distribution host requires review', () {
      final plan = planFor(declarativeApp(
          agp: '8.11.1',
          gradleUrl: r'https\://mirror.example.com/gradle/gradle-8.7-bin.zip'));
      expect(
          step(plan, RecipeIds.androidGradleWrapper).status, StepStatus.review);
    });

    test('an unapplied wrapper step blocks the AGP upgrade', () {
      final plan = planFor(
        declarativeApp(
            agp: '8.6.0',
            gradleUrl:
                r'https\://mirror.example.com/gradle/gradle-8.7-bin.zip'),
        options: const PlanOptions(),
      );
      expect(step(plan, RecipeIds.androidGradleWrapper).applied, isFalse);
      final agp = step(plan, RecipeIds.androidAgpVersion);
      expect(agp.status, StepStatus.blocked);
      expect(agp.blockedBy, [RecipeIds.androidGradleWrapper]);
      expect(plan.isComplete, isFalse);
    });

    test('namespace uses assignment style in Kotlin DSL', () {
      final files = declarativeApp(agp: '8.11.1', app: '')
        ..remove('android/app/build.gradle')
        ..['android/app/build.gradle.kts'] = 'plugins {\n'
            '    id("com.android.application")\n'
            '    id("dev.flutter.flutter-gradle-plugin")\n}\n\n'
            'android {\n    compileSdk = flutter.compileSdkVersion\n}\n'
        ..['android/app/src/main/AndroidManifest.xml'] =
            '<manifest xmlns:android="http://schemas.android.com/apk/res/android"\n'
                '    package="com.example.kts">\n</manifest>\n';
      final plan = planFor(files);
      final namespace = step(plan, RecipeIds.androidNamespace);
      expect(namespace.status, StepStatus.auto);
      final script = plan.fileChanges
          .singleWhere((c) => c.path == 'android/app/build.gradle.kts')
          .after;
      expect(
          script,
          contains('android {\n    namespace = "com.example.kts"\n'
              '    compileSdk = flutter.compileSdkVersion'));
    });

    test('conflicting manifest packages need manual reconciliation', () {
      final files = declarativeApp(agp: '8.11.1', app: 'android {\n}\n')
        ..['android/app/src/main/AndroidManifest.xml'] =
            '<manifest package="com.example.one"/>\n'
        ..['android/app/src/debug/AndroidManifest.xml'] =
            '<manifest package="com.example.two"/>\n';
      final plan = planFor(files);
      expect(step(plan, RecipeIds.androidNamespace).status, StepStatus.manual);
    });

    test('imperative apply in Kotlin DSL is left to a human', () {
      final plan = planFor({
        'pubspec.yaml': pubspec('^3.9.0'),
        'android/settings.gradle.kts':
            'include(":app")\napply(from = "\$flutterSdkPath/packages/flutter_tools/gradle/app_plugin_loader.gradle")\n',
        'android/build.gradle.kts': '',
        'android/app/build.gradle.kts':
            'apply(plugin = "com.android.application")\n'
                'apply(from = "\$flutterRoot/packages/flutter_tools/gradle/flutter.gradle")\n',
      });
      final dsl = step(plan, RecipeIds.androidFlutterGradlePluginDsl);
      expect(dsl.status, StepStatus.manual);
      expect(dsl.proposal.rationale, contains('Kotlin DSL'));
    });
  });

  test('recipe ordering honours runsAfter', () {
    final ids = orderRecipes(builtInRecipes().reversed.toList())
        .map((r) => r.descriptor.id)
        .toList();
    expect(ids.indexOf(RecipeIds.androidFlutterGradlePluginDsl),
        lessThan(ids.indexOf(RecipeIds.androidGradleWrapper)));
    expect(ids.indexOf(RecipeIds.androidGradleWrapper),
        lessThan(ids.indexOf(RecipeIds.androidAgpVersion)));
    expect(ids.indexOf(RecipeIds.androidAgpVersion),
        lessThan(ids.indexOf(RecipeIds.androidNamespace)));
  });
}
