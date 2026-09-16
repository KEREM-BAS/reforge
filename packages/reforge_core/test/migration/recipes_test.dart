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

String fileAfter(MigrationPlan plan, String path) =>
    plan.fileChanges.singleWhere((c) => c.path == path).after;

String skipReason(MigrationPlan plan, String id) =>
    plan.skipped.singleWhere((s) => s.recipe.id == id).reason;

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

    group('Flutter tool migrations', () {
      test('AGP 9 opt-outs are added as Flutter would, keeping line endings',
          () {
        final plan = planFor({
          ...declarativeApp(agp: '8.11.1'),
          'android/gradle.properties':
              'org.gradle.jvmargs=-Xmx8G\r\nandroid.useAndroidX=true',
        });
        final optOuts = step(plan, RecipeIds.androidAgp9OptOuts);
        expect(optOuts.status, StepStatus.auto);
        expect(optOuts.proposal.necessity, Necessity.flutterMigration);
        expect(optOuts.proposal.impact, contains('LF line endings'));
        expect(
            fileAfter(plan, 'android/gradle.properties'),
            'org.gradle.jvmargs=-Xmx8G\r\nandroid.useAndroidX=true\r\n'
            "# Added by Reforge, as Flutter's DisableBuiltInKotlinMigration does\r\n"
            'android.builtInKotlin=false\r\n'
            "# Added by Reforge, as Flutter's DisableNewDslMigration does\r\n"
            'android.newDsl=false\r\n');
      });

      test('AGP 9 opt-outs respect existing values and older releases', () {
        final partial = planFor({
          ...declarativeApp(agp: '8.11.1'),
          'android/gradle.properties': 'android.newDsl=true\n',
        });
        expect(fileAfter(partial, 'android/gradle.properties'),
            isNot(contains('android.newDsl=false')));
        expect(step(partial, RecipeIds.androidAgp9OptOuts).proposal.summary,
            'Add android.builtInKotlin=false to android/gradle.properties.');

        final older = planFor({
          ...declarativeApp(agp: '8.11.1'),
          'android/gradle.properties': '\n',
        }, target: '3.41.0');
        expect(skipReason(older, RecipeIds.androidAgp9OptOuts),
            contains('does not add'));

        final missing = planFor(declarativeApp(agp: '8.11.1'));
        final manual = step(missing, RecipeIds.androidAgp9OptOuts);
        expect(manual.status, StepStatus.manual);
        expect(missing.isComplete, isTrue,
            reason: 'Flutter creates the file itself; not a blocker.');
      });

      const eager =
          'task clean(type: Delete) {\n    delete rootProject.buildDir\n}\n';

      test('the eager clean task is registered lazily', () {
        final plan = planFor({
          ...declarativeApp(agp: '8.11.1'),
          'android/build.gradle': 'allprojects {}\n\n$eager',
        });
        final clean = step(plan, RecipeIds.androidCleanTask);
        expect(clean.status, StepStatus.auto);
        expect(clean.proposal.necessity, Necessity.flutterMigration);
        expect(
            fileAfter(plan, 'android/build.gradle'),
            'allprojects {}\n\ntasks.register("clean", Delete) {\n'
            '    delete rootProject.layout.buildDirectory\n}\n');

        final crlf = planFor({
          ...declarativeApp(agp: '8.11.1'),
          'android/build.gradle':
              eager.replaceAll('\n', '\r\n').replaceFirst(RegExp(r'\r\n$'), ''),
        });
        expect(
            fileAfter(crlf, 'android/build.gradle'),
            'tasks.register("clean", Delete) {\r\n'
            '    delete rootProject.layout.buildDirectory\r\n}');
      });

      test('only the form Flutter migrates is changed', () {
        final indented = planFor({
          ...declarativeApp(agp: '8.11.1'),
          'android/build.gradle':
              'task clean(type: Delete) {\n  delete rootProject.buildDir\n}\n',
        });
        expect(skipReason(indented, RecipeIds.androidCleanTask),
            contains('no clean task in the form'));

        final older = planFor({
          ...declarativeApp(agp: '8.11.1'),
          'android/build.gradle': eager,
        }, target: '3.7.0');
        expect(skipReason(older, RecipeIds.androidCleanTask),
            contains('does not migrate the clean task'));
      });
    });

    group('Kotlin Gradle plugin in the app module', () {
      Map<String, String> agp9App(
              {required String app,
              String properties = 'android.newDsl=false\n'
                  'android.builtInKotlin=false\n',
              bool kotlinDeclared = true,
              String appPath = 'android/app/build.gradle'}) =>
          {
            'pubspec.yaml': pubspec('^3.9.0'),
            'android/settings.gradle': 'plugins {\n'
                '    id "dev.flutter.flutter-plugin-loader" version "1.0.0"\n'
                '    id "com.android.application" version "9.0.1" apply false\n'
                '${kotlinDeclared ? '    id "org.jetbrains.kotlin.android" version "2.3.20" apply false\n' : ''}'
                '}\ninclude ":app"\n',
            'android/build.gradle': 'allprojects {}\n',
            appPath: app,
            'android/gradle.properties': properties,
            'android/gradle/wrapper/gradle-wrapper.properties':
                r'distributionUrl=https\://services.gradle.org/distributions/gradle-9.1.0-bin.zip'
                    '\n',
          };

      const include = PlanOptions(
          acceptAllReviews: true,
          includedRecipes: {RecipeIds.androidAppKotlinPlugin});

      const groovyApp = 'plugins {\n'
          '    id "com.android.application"\n'
          '    id "kotlin-android"\n'
          '    id "dev.flutter.flutter-gradle-plugin"\n'
          '}\n\n'
          'android {\n'
          '    namespace = "com.example.app"\n\n'
          '    kotlinOptions {\n'
          '        jvmTarget = JavaVersion.VERSION_1_8\n'
          '    }\n'
          '}\n\n'
          'flutter {\n    source = "../.."\n}\n';

      test('Groovy: the plugin is removed and jvmTarget moves', () {
        final plan = planFor(agp9App(app: groovyApp), options: include);
        final step = plan.steps.singleWhere(
            (s) => s.recipe.id == RecipeIds.androidAppKotlinPlugin);
        expect(step.status, StepStatus.review);
        expect(step.proposal.necessity, Necessity.recommended);
        expect(
            fileAfter(plan, 'android/app/build.gradle'),
            'plugins {\n'
            '    id "com.android.application"\n'
            '    id "dev.flutter.flutter-gradle-plugin"\n'
            '}\n\n'
            'android {\n'
            '    namespace = "com.example.app"\n'
            '}\n\n'
            'kotlin {\n'
            '    compilerOptions {\n'
            '        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_1_8\n'
            '    }\n'
            '}\n\n'
            'flutter {\n    source = "../.."\n}\n');
      });

      test('Kotlin DSL template of Flutter 3.41', () {
        const app = 'plugins {\n'
            '    id("com.android.application")\n'
            '    id("kotlin-android")\n'
            '    id("dev.flutter.flutter-gradle-plugin")\n'
            '}\n\n'
            'android {\n'
            '    namespace = "com.example.app"\n'
            '    kotlinOptions {\n'
            '        jvmTarget = JavaVersion.VERSION_17.toString()\n'
            '    }\n'
            '}\n';
        final plan = planFor(
            agp9App(app: app, appPath: 'android/app/build.gradle.kts'),
            options: include);
        final after = fileAfter(plan, 'android/app/build.gradle.kts');
        expect(after, isNot(contains('kotlin-android')));
        expect(after, isNot(contains('kotlinOptions')));
        expect(
            after,
            endsWith(
                '}\n\nkotlin {\n    compilerOptions {\n        jvmTarget = '
                'org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17\n    }\n}\n'));
      });

      test('built-in Kotlin makes it required; unknowns make it manual', () {
        final builtIn = planFor(agp9App(
            app: groovyApp, properties: 'android.builtInKotlin=true\n'));
        final required = builtIn.steps.singleWhere(
            (s) => s.recipe.id == RecipeIds.androidAppKotlinPlugin);
        expect(required.proposal.necessity, Necessity.required);
        expect(builtIn.remainingFindings.map((f) => f.code),
            isNot(contains('ANDROID_APP_APPLIES_KOTLIN_PLUGIN')),
            reason: 'the accepted step resolves it');
        final skipped = planFor(
            agp9App(app: groovyApp, properties: 'android.builtInKotlin=true\n'),
            options: const PlanOptions(
                acceptAllReviews: true,
                skippedRecipes: {RecipeIds.androidAppKotlinPlugin}));
        final finding = skipped.remainingFindings
            .singleWhere((f) => f.code == 'ANDROID_APP_APPLIES_KOTLIN_PLUGIN');
        expect(finding.severity, Severity.error);
        expect(skipped.isComplete, isFalse);

        final custom = planFor(
            options: include,
            agp9App(
                app: groovyApp.replaceFirst(
                    'jvmTarget = JavaVersion.VERSION_1_8',
                    'jvmTarget = JavaVersion.VERSION_1_8\n        freeCompilerArgs += ["-Xopt-in"]')));
        expect(
            custom.steps
                .singleWhere(
                    (s) => s.recipe.id == RecipeIds.androidAppKotlinPlugin)
                .status,
            StepStatus.manual);

        final undeclared = planFor(
            agp9App(app: groovyApp, kotlinDeclared: false),
            options: include);
        expect(
            undeclared.steps
                .singleWhere(
                    (s) => s.recipe.id == RecipeIds.androidAppKotlinPlugin)
                .proposal
                .manualSteps
                .first,
            contains('not declared in settings'));
      });

      test('older targets and AGP 8 keep the plugin', () {
        final agp8 = planFor({
          ...agp9App(app: groovyApp),
          'android/settings.gradle': 'plugins {\n'
              '    id "dev.flutter.flutter-plugin-loader" version "1.0.0"\n'
              '    id "com.android.application" version "8.11.1" apply false\n'
              '    id "org.jetbrains.kotlin.android" version "2.3.20" apply false\n'
              '}\n',
        });
        expect(skipReason(agp8, RecipeIds.androidAppKotlinPlugin),
            contains('Android Gradle Plugin 9'));
        final older = planFor(agp9App(app: groovyApp), target: '3.41.0');
        expect(skipReason(older, RecipeIds.androidAppKotlinPlugin),
            contains('does not apply the Kotlin Gradle plugin itself'));
      });
    });

    group('compileSdk', () {
      MigrationPlan planWithPlugin(String compileSdk, {int? pluginSdk}) {
        final files = {
          ...declarativeApp(
              agp: '8.11.1',
              app: 'plugins {\n    id "com.android.application"\n'
                  '    id "dev.flutter.flutter-gradle-plugin"\n}\n\n'
                  'android {\n    namespace "com.example.app"\n'
                  '    $compileSdk\n}\n'),
          if (pluginSdk != null)
            '.dart_tool/package_config.json':
                '{"configVersion": 2, "packages": [{"name": "maps", '
                    '"rootUri": "file:///cache/maps-1.0.0", "packageUri": "lib/"}]}',
        };
        return MigrationPlanner(
                knowledge: knowledge,
                recipes: builtInRecipes(),
                reforgeVersion: reforgeVersion)
            .plan(
          files: MemoryProjectFileSystem(files, rootPath: '/work'),
          target: knowledge.resolveFlutterVersion('3.47.4'),
          options: const PlanOptions(
              acceptAllReviews: true,
              includedRecipes: {RecipeIds.androidCompileSdk}),
          packageSources: MemoryPackageSources({
            '/cache/maps-1.0.0': {
              'pubspec.yaml': 'name: maps\nversion: 1.0.0\n'
                  'flutter:\n  plugin:\n    platforms:\n      android:\n'
                  '        pluginClass: Maps\n',
              'android/build.gradle':
                  'android {\n    compileSdk ${pluginSdk ?? 34}\n}\n',
            },
          }),
        );
      }

      test('a literal below the Flutter default becomes the default', () {
        final plan = planWithPlugin('compileSdkVersion 33');
        final compileSdk = step(plan, RecipeIds.androidCompileSdk);
        expect(compileSdk.status, StepStatus.review);
        expect(compileSdk.proposal.summary,
            'Raise compileSdk from 33 to flutter.compileSdkVersion (36).');
        expect(fileAfter(plan, 'android/app/build.gradle'),
            contains('    compileSdkVersion flutter.compileSdkVersion\n'));
      });

      test('plugins that need more than the default get a literal', () {
        final plan = planWithPlugin('compileSdk = 35', pluginSdk: 37);
        final compileSdk = step(plan, RecipeIds.androidCompileSdk);
        expect(compileSdk.proposal.summary, 'Raise compileSdk from 35 to 37.');
        expect(compileSdk.proposal.rationale, contains('maps (37)'));
        expect(fileAfter(plan, 'android/app/build.gradle'),
            contains('    compileSdk = 37\n'));
        expect(plan.remainingFindings.map((f) => f.code),
            isNot(contains('PLUGIN_COMPILE_SDK_ABOVE_APP')));

        final flutterDefault = planWithPlugin(
            'compileSdk = flutter.compileSdkVersion',
            pluginSdk: 37);
        expect(step(flutterDefault, RecipeIds.androidCompileSdk).status,
            StepStatus.manual);
        final warning = flutterDefault.remainingFindings
            .singleWhere((f) => f.code == 'PLUGIN_COMPILE_SDK_ABOVE_APP');
        expect(
            warning.message,
            'maps (37) compile against a higher Android '
            'SDK than the app.');
      });
    });

    group('minSdk', () {
      String groovyApp(String minSdk) =>
          'plugins {\n    id "com.android.application"\n'
          '    id "dev.flutter.flutter-gradle-plugin"\n}\n\n'
          'android {\n    namespace "com.example.app"\n'
          '    defaultConfig {\n        $minSdk\n    }\n}\n';

      test('a literal below the Flutter minimum is raised after review', () {
        final files =
            declarativeApp(agp: '8.11.1', app: groovyApp('minSdkVersion 21'));
        final pending = planFor(files, options: const PlanOptions());
        final minSdk = step(pending, RecipeIds.androidMinSdk);
        expect(minSdk.status, StepStatus.review);
        expect(minSdk.proposal.necessity, Necessity.required);
        expect(minSdk.applied, isFalse);
        expect(pending.isComplete, isFalse);
        expect(minSdk.proposal.summary,
            'Raise minSdk from 21 to flutter.minSdkVersion, API level 24 (Android 7.0).');
        expect(minSdk.proposal.notes.first,
            contains('Android 5.0 to 6.0 (API levels 21 to 23)'));
        expect(minSdk.proposal.evidence.map((e) => e.source?.url),
            contains(endsWith('min_sdk_version_migration.dart')));

        final accepted = planFor(files,
            options:
                const PlanOptions(acceptedReviews: {RecipeIds.androidMinSdk}));
        expect(fileAfter(accepted, 'android/app/build.gradle'),
            contains('        minSdkVersion flutter.minSdkVersion\n'));
      });

      test('Kotlin DSL and flavor overrides are raised together', () {
        final files = declarativeApp(agp: '8.11.1', app: '')
          ..remove('android/app/build.gradle')
          ..['android/app/build.gradle.kts'] = 'plugins {\n'
              '    id("com.android.application")\n'
              '    id("dev.flutter.flutter-gradle-plugin")\n}\n\n'
              'android {\n    namespace = "com.example.app"\n'
              '    defaultConfig {\n        minSdk = 19\n    }\n'
              '    productFlavors {\n'
              '        create("dev") {\n            minSdk = 21\n        }\n'
              '        create("prod") {\n            minSdkVersion(26)\n        }\n'
              '    }\n}\n';
        final plan = planFor(files);
        final minSdk = step(plan, RecipeIds.androidMinSdk);
        expect(minSdk.proposal.summary, startsWith('Raise 2 minSdk values'));
        expect(minSdk.proposal.evidence.first.description,
            'defaultConfig minSdk is 19');
        final after = fileAfter(plan, 'android/app/build.gradle.kts');
        expect(
            'minSdk = flutter.minSdkVersion'.allMatches(after), hasLength(2));
        expect(after, contains('minSdkVersion(26)'));
      });

      test('expressions and older releases', () {
        final expression = planFor(declarativeApp(
            agp: '8.11.1',
            app:
                groovyApp('minSdkVersion localProperties.minSdk.toInteger()')));
        expect(skipReason(expression, RecipeIds.androidMinSdk),
            contains('does not evaluate'));

        final older = planFor(
            declarativeApp(agp: '8.11.1', app: groovyApp('minSdkVersion 15')),
            target: '3.10.0');
        final minSdk = step(older, RecipeIds.androidMinSdk);
        expect(minSdk.proposal.necessity, Necessity.required);
        expect(minSdk.proposal.summary, contains('API level 16'));
        expect(minSdk.proposal.evidence.map((e) => e.source?.url),
            isNot(contains(endsWith('min_sdk_version_migration.dart'))));
      });

      test('analysis reports minSdk below the minimum', () {
        final project = ProjectInspector(
                MemoryProjectFileSystem(declarativeApp(
                    agp: '8.11.1', app: groovyApp('minSdkVersion 21'))),
                knowledge: knowledge)
            .inspectProject('');
        Finding? finding(String target) => CompatibilityAnalyzer(knowledge)
            .analyze(project, release: knowledge.resolveFlutterVersion(target))
            .where((f) => f.code == 'ANDROID_MIN_SDK_BELOW_FLUTTER_MINIMUM')
            .firstOrNull;
        expect(finding('3.47.4')!.severity, Severity.error);
        expect(finding('3.47.4')!.relatedRecipes, [RecipeIds.androidMinSdk]);
        expect(finding('3.29.0'), isNull);
      });
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
                includedRecipes: {RecipeIds.androidGradleJvmArgs},
                skippedRecipes: {RecipeIds.androidAgp9OptOuts}));
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
                includedRecipes: {RecipeIds.androidGradleJvmArgs},
                skippedRecipes: {RecipeIds.androidAgp9OptOuts}));
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
            includedRecipes: {RecipeIds.androidJetifier},
            skippedRecipes: {RecipeIds.androidAgp9OptOuts});
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
          options: const PlanOptions(
              includedRecipes: {RecipeIds.androidJetifier},
              skippedRecipes: {RecipeIds.androidAgp9OptOuts}),
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
