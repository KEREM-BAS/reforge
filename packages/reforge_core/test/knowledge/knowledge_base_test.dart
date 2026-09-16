import 'package:pub_semver/pub_semver.dart';
import 'package:reforge_core/src/common/errors.dart';
import 'package:reforge_core/src/knowledge/flutter_release.dart';
import 'package:reforge_core/src/knowledge/knowledge_base.dart';
import 'package:reforge_core/src/version/tool_version.dart';
import 'package:test/test.dart';

void main() {
  final kb = KnowledgeBase.bundled;
  ToolVersion v(String text) => ToolVersion.parse(text);
  FlutterRelease release(String version) => kb.release(Version.parse(version))!;

  group('Flutter releases', () {
    test('resolves versions, minor lines and the stable alias', () {
      expect(kb.resolveFlutterVersion('3.47.4').version, Version(3, 47, 4));
      expect(kb.resolveFlutterVersion('3.44').version.toString(),
          startsWith('3.44.'));
      expect(kb.resolveFlutterVersion('3.44').version,
          kb.releases.lastWhere((r) => r.version.minor == 44).version);
      expect(kb.resolveFlutterVersion('stable'), kb.latestStable);
    });

    test('never guesses unknown targets', () {
      expect(
        () => kb.resolveFlutterVersion('3.99.0'),
        throwsA(isA<UnsupportedTargetException>()
            .having((e) => e.code, 'code', 'TARGET_UNKNOWN_FLUTTER_VERSION')),
      );
      expect(
        () => kb.resolveFlutterVersion('three'),
        throwsA(isA<UnsupportedTargetException>()
            .having((e) => e.code, 'code', 'TARGET_INVALID')),
      );
    });

    test('maps revisions to releases', () {
      expect(
          kb
              .releaseByRevision('559ffa3f75e7402d65a8def9c28389a9b2e6fe42')!
              .version,
          Version(3, 44, 0));
    });

    // The expectations below were verified manually against flutter/flutter
    // sources at each tag (DependencyVersionChecker, gradle_utils.dart,
    // flutter.gradle, darwin.dart / ios_deployment_target_migration.dart).
    test('Flutter 3.47.0 Android floors and iOS minimum', () {
      final r = release('3.47.0');
      expect(r.dartVersion, Version(3, 13, 0));
      final android = r.androidRequirements;
      expect(android.androidGradlePlugin!.error, v('8.11.1'));
      expect(android.androidGradlePlugin!.warn, v('9.0.1'));
      expect(android.gradle!.error, v('8.14.0'));
      expect(android.gradle!.warn, v('9.1.0'));
      expect(android.kotlin!.error, v('2.2.20'));
      expect(android.kotlin!.warn, v('2.3.20'));
      expect(android.java!.error, v('17'));
      expect(android.minSdk!.warn, v('24'));
      expect(r.template.androidGradlePlugin, v('9.1.0'));
      expect(r.template.dsl, GradleDsl.kotlin);
      expect(r.iosMinimumDeploymentTarget, v('15.0'));
      expect(r.androidDefaults.compileSdk, 36);
    });

    test('imperative Gradle apply eras', () {
      expect(release('3.13.0').imperativeGradleApply,
          ImperativeGradleApply.supported);
      expect(release('3.16.0').imperativeGradleApply,
          ImperativeGradleApply.supportedAlongsideDeclarative);
      expect(release('3.19.0').imperativeGradleApply,
          ImperativeGradleApply.deprecated);
      expect(release('3.27.4').imperativeGradleApply,
          ImperativeGradleApply.deprecated);
      expect(release('3.29.0').imperativeGradleApply,
          ImperativeGradleApply.removed);
    });

    test('releases before 3.22 do not enforce Android dependency floors', () {
      expect(release('3.19.0').androidRequirements.androidGradlePlugin, isNull);
      expect(
          release('3.22.0').androidRequirements.androidGradlePlugin, isNotNull);
    });

    test('template eras', () {
      expect(release('3.3.0').template.namespaceInBuildScript, isFalse);
      expect(release('3.10.0').template.namespaceInBuildScript, isTrue);
      expect(release('3.16.0').template.declarativePlugins, isTrue);
      expect(release('3.27.0').template.dsl, GradleDsl.groovy);
      expect(release('3.29.0').template.dsl, GradleDsl.kotlin);
      expect(release('3.35.0').iosMinimumDeploymentTarget, v('13.0'));
      expect(release('3.3.0').iosMinimumDeploymentTarget, v('11.0'));
    });

    test('Xcode and CocoaPods requirements', () {
      String floor(VersionFloor floor) => '${floor.error}/${floor.warn}';
      DarwinRequirements apple(String version) =>
          release(version).darwinRequirements;
      expect(floor(apple('3.0.0').cocoapods), '1.9.0/1.11.0');
      expect(floor(apple('3.3.0').xcode), '13/13');
      expect(floor(apple('3.13.0').xcode), '14/14');
      expect(floor(apple('3.22.0').xcode), '14/15');
      expect(floor(apple('3.29.0').cocoapods), '1.10.0/1.16.2');
      expect(floor(apple('3.44.0').xcode), '15/16');
      expect(release('3.47.4').xcodeRequirementsSource.url,
          endsWith('packages/flutter_tools/lib/src/macos/xcode.dart'));
    });

    test('macOS minimum deployment targets', () {
      expect(release('3.3.10').macosMinimumDeploymentTarget, v('10.11'));
      expect(release('3.7.0').macosMinimumDeploymentTarget, v('10.14'));
      expect(release('3.32.8').macosMinimumDeploymentTarget, v('10.14'));
      expect(release('3.35.0').macosMinimumDeploymentTarget, v('10.15'));
      expect(release('3.44.0').macosMinimumDeploymentTarget, v('10.15'));
      expect(release('3.47.4').macosMinimumDeploymentTarget, v('12.0'));
      // Before Flutter had a macOS deployment target migration, the app
      // template is the source.
      expect(release('3.3.0').macosMinimumSource.url,
          endsWith('macos.tmpl/Runner.xcodeproj/project.pbxproj.tmpl'));
      expect(release('3.47.4').macosMinimumSource.url,
          endsWith('macos/migrations/macos_deployment_target_migration.dart'));
    });

    test('template gradle.properties history', () {
      String? property(String version, String key) =>
          release(version).template.gradleProperties[key];
      const jvmArgs = 'org.gradle.jvmargs';
      expect(property('3.0.0', jvmArgs), '-Xmx1536M');
      expect(property('3.13.9', jvmArgs), '-Xmx1536M');
      expect(property('3.16.0', jvmArgs), '-Xmx4G');
      expect(property('3.22.0', jvmArgs),
          '-Xmx4G -XX:+HeapDumpOnOutOfMemoryError');
      expect(property('3.24.0', jvmArgs),
          '-Xmx4G -XX:MaxMetaspaceSize=2G -XX:+HeapDumpOnOutOfMemoryError');
      expect(
          property('3.29.0', jvmArgs),
          '-Xmx8G -XX:MaxMetaspaceSize=4G -XX:ReservedCodeCacheSize=512m '
          '-XX:+HeapDumpOnOutOfMemoryError');
      expect(property('3.35.0', 'android.enableJetifier'), 'true');
      expect(property('3.38.0', 'android.enableJetifier'), isNull);
      expect(property('3.41.0', 'android.newDsl'), isNull);
      expect(property('3.44.0', 'android.newDsl'), 'false');
      expect(property('3.44.0', 'android.builtInKotlin'), 'false');

      final generated = KnowledgeBase.bundled
          .releasesWithTemplateGradleProperty(jvmArgs, ' -Xmx1536M ');
      expect(generated.first.version, Version(3, 0, 0));
      expect(generated.last.version, Version(3, 13, 9));
      expect(release('3.27.0').templateGradlePropertiesSource.url,
          contains('/templates/app_shared/android.tmpl/'));
      expect(release('3.29.0').templateGradlePropertiesSource.url,
          contains('/templates/app/android.tmpl/'));
    });

    test('Android project migrations of the Flutter tool', () {
      expect(release('3.7.0').androidMigrations, isEmpty);
      expect(release('3.10.0').androidMigrations,
          ['TopLevelGradleBuildFileMigration']);
      expect(release('3.16.0').runsAndroidMigration('MinSdkVersionMigration'),
          isTrue);
      expect(release('3.41.0').runsAndroidMigration('DisableNewDslMigration'),
          isFalse);
      expect(
          release('3.44.0').androidMigrations,
          containsAll(
              ['DisableBuiltInKotlinMigration', 'DisableNewDslMigration']));
      expect(
          release('3.47.4')
              .androidMigrationSource('CmakeAndroid16kPagesMigration')
              .url,
          endsWith(
              '/android/migrations/cmake_android_16k_pages_migration.dart'));
      expect(release('3.41.0').appliesKotlinPlugin, isFalse);
      expect(release('3.41.0').template.appAppliesKotlinPlugin, isTrue);
      expect(release('3.44.0').appliesKotlinPlugin, isTrue);
      expect(release('3.44.0').template.appAppliesKotlinPlugin, isFalse);
      expect(release('3.0.0').template.appAppliesKotlinPlugin, isTrue);
      expect(release('3.13.0').androidDefaults.minSdk, 19);
      expect(release('3.35.0').androidDefaults.minSdk, 24);
      expect(release('3.10.0').androidDefaultsSource.url,
          endsWith('/gradle/flutter.gradle'));
      expect(release('3.13.0').androidDefaultsSource.url,
          endsWith('/groovy/flutter.groovy'));
      expect(KnowledgeBase.bundled.androidVersionOf(24)!.value, '7.0');
      expect(KnowledgeBase.bundled.androidVersionOf(99), isNull);
    });

    test('floor status', () {
      final floor = release('3.47.0').androidRequirements.androidGradlePlugin!;
      expect(floor.statusOf(v('8.7.0')), FloorStatus.belowError);
      expect(floor.statusOf(v('8.11.1')), FloorStatus.belowWarn);
      expect(floor.statusOf(v('9.1.0')), FloorStatus.satisfied);
    });
  });

  group('Android toolchain tables', () {
    test('AGP to minimum Gradle', () {
      expect(kb.minimumGradleForAgp(v('7.3.0'))!.value, v('7.4'));
      expect(kb.minimumGradleForAgp(v('8.11.1'))!.value, v('8.13'));
      expect(kb.minimumGradleForAgp(v('9.1.0'))!.value, v('9.3.1'));
      expect(kb.minimumGradleForAgp(v('9.9.0')), isNull);
      expect(kb.minimumGradleForAgp(v('8.1.0'))!.source.url,
          contains('developer.android.com'));
    });

    test('AGP to minimum Java', () {
      expect(kb.minimumJavaForAgp(v('8.1.0'))!.value, 17);
      expect(kb.minimumJavaForAgp(v('7.4.2'))!.value, 11);
      expect(kb.minimumJavaForAgp(v('9.0.1'))!.value, 17);
    });

    test('Gradle and Java', () {
      expect(kb.gradleRunsOnJava(v('7.5'), 21)!.value, isFalse);
      expect(kb.gradleRunsOnJava(v('8.5'), 21)!.value, isTrue);
      expect(kb.gradleRunsOnJava(v('8.14.3'), 8)!.value, isTrue);
      expect(kb.gradleRunsOnJava(v('9.1.0'), 11)!.value, isFalse);
      expect(kb.gradleRunsOnJava(v('7.3'), 17)!.value, isTrue);
      expect(kb.gradleRunsOnJava(v('9.0.0'), 40), isNull);
      expect(kb.minimumGradleForJava(21)!.value, v('8.5'));
    });

    test('compile SDK to minimum AGP', () {
      expect(kb.minimumAgpForCompileSdk(36)!.value, v('8.9.1'));
      expect(kb.minimumAgpForCompileSdk(30), isNull);
    });

    test('documented plugin ids only', () {
      expect(kb.pluginIdForClasspath('com.google.gms:google-services')!.value,
          'com.google.gms.google-services');
      expect(kb.pluginIdForClasspath('com.huawei.agconnect:agcp'), isNull);
    });
  });
}
