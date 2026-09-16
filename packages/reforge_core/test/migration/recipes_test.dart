import 'package:reforge_core/reforge_core.dart';
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

    group('gradle.properties', () {
      const legacyProperties = 'org.gradle.jvmargs=-Xmx1536M\n'
          'android.useAndroidX=true\n'
          'android.enableJetifier=true\n';
      const target347 = '-Xmx8G -XX:MaxMetaspaceSize=4G '
          '-XX:ReservedCodeCacheSize=512m -XX:+HeapDumpOnOutOfMemoryError';

      Map<String, String> appWith(String properties, {String? app}) => {
            ...declarativeApp(agp: '8.11.1'),
            'android/gradle.properties': properties,
            if (app != null) 'android/app/build.gradle': app,
          };

      String propertiesAfter(MigrationPlan plan) => plan.fileChanges
          .singleWhere((c) => c.path == 'android/gradle.properties')
          .after;

      test('recommended steps are listed, not planned, by default', () {
        final plan = planFor(appWith(legacyProperties));
        expect(plan.steps.map((s) => s.recipe.id),
            isNot(contains(RecipeIds.androidGradleJvmArgs)));
        expect(plan.recommendationsNotIncluded.map((s) => s.recipe.id),
            [RecipeIds.androidGradleJvmArgs, RecipeIds.androidJetifier]);
        expect(plan.recommendationsNotIncluded.first.summary,
            'Update org.gradle.jvmargs to the value generated by Flutter 3.47.4.');
      });

      test('an unmodified template heap moves to the target template', () {
        final plan = planFor(appWith(legacyProperties),
            options: const PlanOptions(
                acceptAllReviews: true,
                includedRecipes: {RecipeIds.androidGradleJvmArgs}));
        final jvm = step(plan, RecipeIds.androidGradleJvmArgs);
        expect(jvm.status, StepStatus.auto);
        expect(jvm.proposal.necessity, Necessity.recommended);
        expect(jvm.applied, isTrue);
        expect(jvm.proposal.notes.single, contains('from 1536M to 8G'));
        expect(jvm.proposal.evidence[1].description,
            contains('Flutter 3.0.0 to 3.13.9'));
        expect(
            propertiesAfter(plan),
            'org.gradle.jvmargs=$target347\n'
            'android.useAndroidX=true\n'
            'android.enableJetifier=true\n');
        // Including one recommendation does not include the others.
        expect(plan.steps.map((s) => s.recipe.id),
            isNot(contains(RecipeIds.androidAgpVersion)));
        expect(plan.recommendationsNotIncluded.map((s) => s.recipe.id),
            [RecipeIds.androidJetifier]);
      });

      test('template values match regardless of whitespace', () {
        final plan = planFor(
            appWith('org.gradle.jvmargs = -Xmx4G   '
                '-XX:+HeapDumpOnOutOfMemoryError\n'),
            options: const PlanOptions(
                includedRecipes: {RecipeIds.androidGradleJvmArgs}));
        expect(
            step(plan, RecipeIds.androidGradleJvmArgs)
                .proposal
                .evidence[1]
                .description,
            contains('Flutter 3.22.0 to 3.22.3'));
        expect(propertiesAfter(plan), 'org.gradle.jvmargs = $target347\n');
      });

      test('customized and newer values are left unchanged', () {
        String reason(MigrationPlan plan) => plan.skipped
            .singleWhere((s) => s.recipe.id == RecipeIds.androidGradleJvmArgs)
            .reason;
        const options = PlanOptions(includeRecommended: true);
        expect(
            reason(planFor(appWith('org.gradle.jvmargs=-Xmx6g\n'),
                options: options)),
            contains('customized'));
        expect(
            reason(planFor(appWith('org.gradle.jvmargs=$target347\n'),
                target: '3.22.0', options: options)),
            contains('newer than the target'));
        expect(reason(planFor(appWith('android.useAndroidX=true\n'))),
            contains('does not set org.gradle.jvmargs'));
      });

      test('Jetifier removal is reviewed and needs a target without it', () {
        const options = PlanOptions(
            acceptAllReviews: true,
            includedRecipes: {RecipeIds.androidJetifier});
        final plan = planFor(appWith(legacyProperties), options: options);
        final jetifier = step(plan, RecipeIds.androidJetifier);
        expect(jetifier.status, StepStatus.review);
        expect(jetifier.proposal.evidence.map((e) => e.source?.url),
            contains('https://github.com/flutter/flutter/issues/173430'));
        expect(jetifier.proposal.evidence[1].description,
            contains('from Flutter 3.38.0'));
        expect(propertiesAfter(plan),
            'org.gradle.jvmargs=-Xmx1536M\nandroid.useAndroidX=true\n');

        final older = planFor(appWith(legacyProperties),
            target: '3.35.0', options: options);
        expect(
            older.skipped
                .singleWhere((s) => s.recipe.id == RecipeIds.androidJetifier)
                .reason,
            contains('still enables Jetifier'));
      });

      test('Support Library dependencies make Jetifier removal manual', () {
        final plan = planFor(
          appWith(legacyProperties,
              app: 'plugins {\n    id "com.android.application"\n'
                  '    id "dev.flutter.flutter-gradle-plugin"\n}\n\n'
                  'android {\n    namespace "com.example.app"\n}\n\n'
                  'dependencies {\n'
                  "    implementation 'com.android.support:appcompat-v7:28.0.0'\n"
                  '}\n'),
          options:
              const PlanOptions(includedRecipes: {RecipeIds.androidJetifier}),
        );
        final jetifier = step(plan, RecipeIds.androidJetifier);
        expect(jetifier.status, StepStatus.manual);
        expect(jetifier.proposal.manualSteps.first,
            contains('com.android.support:appcompat-v7'));
        expect(plan.fileChanges.map((c) => c.path),
            isNot(contains('android/gradle.properties')));
      });

      test('including the AGP recommendation keeps Gradle consistent', () {
        final plan = planFor(appWith(legacyProperties),
            options: const PlanOptions(
                acceptAllReviews: true,
                includedRecipes: {RecipeIds.androidAgpVersion}));
        final agp = step(plan, RecipeIds.androidAgpVersion);
        expect(agp.proposal.details['to'], '9.0.1');
        final wrapper = step(plan, RecipeIds.androidGradleWrapper);
        expect(wrapper.proposal.necessity, Necessity.required);
        expect(wrapper.proposal.details['to'], '9.1.0');
      });
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
