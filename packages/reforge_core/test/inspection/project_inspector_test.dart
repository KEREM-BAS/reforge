import 'package:pub_semver/pub_semver.dart';
import 'package:reforge_core/src/common/errors.dart';
import 'package:reforge_core/src/fs/project_file_system.dart';
import 'package:reforge_core/src/inspection/current_flutter_version.dart';
import 'package:reforge_core/src/inspection/project_inspector.dart';
import 'package:reforge_core/src/knowledge/knowledge_base.dart';
import 'package:reforge_core/src/model/android_project.dart';
import 'package:reforge_core/src/model/darwin_project.dart';
import 'package:reforge_core/src/model/declarations.dart';
import 'package:reforge_core/src/model/flutter_project.dart';
import 'package:reforge_core/src/version/tool_version.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

FlutterProject inspectFixture(String name) {
  final workspace =
      ProjectInspector(LocalProjectFileSystem(fixtureProject(name)))
          .inspectWorkspace();
  expect(workspace.projects, hasLength(1));
  return workspace.projects.single;
}

String editableText(String fixture, EditableValue editable) =>
    editable.range.textOf(readFixture(fixture, editable.path));

void main() {
  group('Flutter 3.3 template app', () {
    late FlutterProject project;
    setUpAll(() => project = inspectFixture('flutter_3_3_app'));

    test('identifies the project and its creating Flutter version', () {
      expect(project.name, 'legacy_app');
      expect(project.kind, FlutterProjectKind.app);
      final metadata = project.flutterVersionObservations.single;
      expect(metadata.signal, FlutterVersionSignal.metadataRevision);
      expect(metadata.version, Version(3, 3, 0));
      expect(project.problems, isEmpty);
    });

    test('Android toolchain with provenance', () {
      final android = project.android!;
      expect(android.pluginApplication.style, GradlePluginStyle.imperative);

      final agp = android.toolchain.androidGradlePlugin!;
      expect(agp.version, ToolVersion.parse('7.1.2'));
      expect(agp.site, DeclarationSite.buildscriptClasspath);
      expect(agp.resolution, ValueResolution.literal);
      expect(agp.usage.path, 'android/build.gradle');
      expect(editableText('flutter_3_3_app', agp.editable!), '7.1.2');

      final kotlin = android.toolchain.kotlin!;
      expect(kotlin.version, ToolVersion.parse('1.6.10'));
      expect(kotlin.resolution, ValueResolution.variable);
      expect(kotlin.rawText, r'$kotlin_version');
      expect(kotlin.definition!.line, 2);
      expect(editableText('flutter_3_3_app', kotlin.editable!), '1.6.10');

      final wrapper = android.toolchain.gradleWrapper!;
      expect(wrapper.version, ToolVersion.parse('7.4'));
      expect(wrapper.distributionType, 'all');
      expect(wrapper.hasChecksum, isFalse);
    });

    test('app module and manifests', () {
      final app = project.android!.app!;
      expect(app.namespace, isNull);
      expect(app.compileSdk, isA<FlutterDefaultReference>());
      expect(
          (app.minSdk! as FlutterDefaultReference).property, 'minSdkVersion');
      expect((app.applicationId! as LiteralString).value,
          'com.example.legacy_app');
      expect(project.android!.manifests.map((m) => m.sourceSet),
          unorderedEquals(['main', 'debug', 'profile']));
      expect(project.android!.mainManifest!.manifest.packageAttribute,
          'com.example.legacy_app');
    });

    test('iOS project', () {
      final ios = project.ios!;
      expect(ios.dependencyManager, DarwinDependencyManager.cocoapods);
      expect(ios.effectiveDeploymentTarget, ToolVersion.parse('11.0'));
      expect(ios.deploymentTargets.map((d) => d.owner).toSet(), {'project'});
      expect(ios.podfile!.commentedPlatform!.version, '11.0');
      expect(ios.appFrameworkMinimumOsVersion, '11.0');
      expect(ios.appDelegateLanguage, 'swift');
      for (final setting in ios.deploymentTargets) {
        expect(editableText('flutter_3_3_app', setting.editable), '11.0');
      }
    });

    test('macOS project', () {
      final macos = project.macos!;
      expect(macos.platform, DarwinPlatform.macos);
      expect(macos.directory, 'macos');
      expect(macos.dependencyManager, DarwinDependencyManager.cocoapods);
      expect(macos.effectiveDeploymentTarget, ToolVersion.parse('10.11'));
      expect(macos.deploymentTargets.map((d) => d.configuration),
          unorderedEquals(['Debug', 'Release', 'Profile']));
      expect(macos.podfile!.platform!.name, 'osx');
      expect(macos.podfile!.platform!.version, '10.11');
      expect(macos.appFrameworkMinimumOsVersion, isNull);
      expect(macos.appDelegateLanguage, 'swift');
      for (final setting in macos.deploymentTargets) {
        expect(editableText('flutter_3_3_app', setting.editable), '10.11');
      }
      expect(project.otherPlatforms, isEmpty);
    });
  });

  test('a Flutter 2.2 app is identified without release facts', () {
    final project = inspectFixture('flutter_2_2_app');
    expect(project.flutterVersionObservations.single.version, Version(2, 2, 0));
    final current =
        resolveCurrentFlutterVersion(project, knowledge: KnowledgeBase.bundled);
    expect(current!.version, Version(2, 2, 0));
    expect(current.release, isNull);
    expect(current.basis, CurrentFlutterBasis.created);
    expect(current.toJson()['described'], isFalse);
  });

  test('Flutter 3.13 transitional template mixes both styles', () {
    final project = inspectFixture('flutter_3_13_app');
    final application = project.android!.pluginApplication;
    expect(application.style, GradlePluginStyle.mixed);
    expect(application.settingsLoader, GradlePluginStyle.imperative);
    expect(application.appPlugin, GradlePluginStyle.declarative);
    expect(project.android!.toolchain.androidGradlePlugin!.site,
        DeclarationSite.buildscriptClasspath);
  });

  test('Flutter 3.22 declarative Groovy app', () {
    final project = inspectFixture('flutter_3_22_app');
    final android = project.android!;
    expect(android.pluginApplication.style, GradlePluginStyle.declarative);
    final agp = android.toolchain.androidGradlePlugin!;
    expect(agp.site, DeclarationSite.settingsPlugins);
    expect(agp.version, ToolVersion.parse('7.3.0'));
    expect(editableText('flutter_3_22_app', agp.editable!), '7.3.0');
    expect(android.toolchain.kotlin!.version, ToolVersion.parse('1.7.10'));
    expect((android.app!.namespace! as LiteralString).value,
        'com.example.notes_app');
    expect(project.ios!.effectiveDeploymentTarget, ToolVersion.parse('12.0'));
  });

  test('real Flutter 3.44 Kotlin DSL app with generated files', () {
    final project = inspectFixture('flutter_3_44_app');
    final android = project.android!;
    expect(android.settings!.path, 'android/settings.gradle.kts');
    expect(android.pluginApplication.style, GradlePluginStyle.declarative);
    expect(android.toolchain.androidGradlePlugin!.version,
        ToolVersion.parse('9.0.1'));
    expect(android.toolchain.kotlin!.version, ToolVersion.parse('2.3.20'));
    expect(
        android.toolchain.gradleWrapper!.version, ToolVersion.parse('9.1.0'));
    expect(android.toolchain.builtInKotlin, isFalse);
    expect(android.toolchain.newDsl, isFalse);
    expect(
        project.flutterVersionObservations
            .map((o) => (o.signal, '${o.version}')),
        containsAll([
          (FlutterVersionSignal.packageConfig, '3.44.0'),
          (FlutterVersionSignal.pluginRegistry, '3.44.0'),
          (FlutterVersionSignal.metadataRevision, '3.44.0'),
        ]));
    expect(project.pluginsFor('ios').map((p) => p.name),
        ['shared_preferences_foundation', 'url_launcher_ios']);
    expect(project.ios!.effectiveDeploymentTarget, ToolVersion.parse('13.0'));
    expect(project.problems, isEmpty);
  });

  test('customized Firebase app with flavors', () {
    final project = inspectFixture('firebase_flavors_app');
    final android = project.android!;
    expect(android.app!.productFlavors, ['dev', 'prod']);
    expect(android.app!.hasReleaseSigningConfig, isTrue);
    expect((android.app!.compileSdk! as LiteralInt).value, 33);
    expect(android.toolchain.androidGradlePlugin!.version,
        ToolVersion.parse('7.4.2'));
    expect(android.toolchain.gradleWrapper!.hasChecksum, isTrue);
    final podfile = project.ios!.podfile!;
    expect(podfile.platform!.version, '12.0');
    expect(podfile.buildSettingAssignments.first.setting,
        'IPHONEOS_DEPLOYMENT_TARGET');
  });

  test('custom Gradle app resolves ext block variables', () {
    final project = inspectFixture('custom_gradle_app');
    final agp = project.android!.toolchain.androidGradlePlugin!;
    expect(agp.resolution, ValueResolution.variable);
    expect(agp.version, ToolVersion.parse('7.2.2'));
    expect(editableText('custom_gradle_app', agp.editable!), '7.2.2');
    expect(
        project.android!.pluginApplication.style, GradlePluginStyle.imperative);
  });

  test('broken Gradle script degrades gracefully', () {
    final project = inspectFixture('broken_gradle_app');
    expect(project.android!.app!.script.isReliable, isFalse);
    expect(project.problems.map((p) => p.path),
        contains('android/app/build.gradle'));
    // Other files are still understood.
    expect(project.android!.toolchain.androidGradlePlugin!.version,
        ToolVersion.parse('7.3.0'));
  });

  test('pub workspace with apps from different eras', () {
    final workspace = ProjectInspector(
            LocalProjectFileSystem(fixtureProject('melos_workspace')))
        .inspectWorkspace();
    expect(workspace.layout, 'pubWorkspace');
    final byPath = {for (final p in workspace.projects) p.path: p};
    expect(
        byPath.keys,
        unorderedEquals(
            ['apps/customer_app', 'apps/driver_app', 'packages/ui_kit']));
    expect(byPath['apps/customer_app']!.android!.pluginApplication.style,
        GradlePluginStyle.declarative);
    // driver_app comes from the transitional Flutter 3.13 template.
    expect(byPath['apps/driver_app']!.android!.pluginApplication.style,
        GradlePluginStyle.mixed);
    expect(byPath['apps/driver_app']!.android!.settings!.path,
        'apps/driver_app/android/settings.gradle');
    expect(byPath['packages/ui_kit']!.kind, FlutterProjectKind.package);
  });

  group('errors and pins', () {
    test('missing pubspec', () {
      expect(
        () => ProjectInspector(MemoryProjectFileSystem({})).inspectWorkspace(),
        throwsA(isA<InvalidProjectException>()
            .having((e) => e.code, 'code', 'PROJECT_NOT_FOUND')),
      );
    });

    test('invalid pubspec', () {
      expect(
        () => ProjectInspector(
                MemoryProjectFileSystem({'pubspec.yaml': 'name: [oops\n'}))
            .inspectWorkspace(),
        throwsA(isA<InvalidProjectException>()
            .having((e) => e.code, 'code', 'PUBSPEC_INVALID')),
      );
    });

    test('Dart-only package', () {
      expect(
        () => ProjectInspector(
                MemoryProjectFileSystem({'pubspec.yaml': 'name: cli\n'}))
            .inspectWorkspace(),
        throwsA(isA<InvalidProjectException>()
            .having((e) => e.code, 'code', 'PROJECT_NOT_FLUTTER')),
      );
    });

    test('FVM and asdf pins', () {
      final workspace = ProjectInspector(MemoryProjectFileSystem({
        'pubspec.yaml':
            'name: app\ndependencies:\n  flutter:\n    sdk: flutter\n',
        '.fvmrc': '{"flutter": "3.29.3"}',
        '.tool-versions': 'java 17\nflutter 3.27.4-stable\n',
      })).inspectWorkspace();
      final project = workspace.projects.single;
      expect(project.pinnedFlutterVersion!.version, Version(3, 29, 3));
      expect(
          project.flutterVersionObservations
              .firstWhere((o) => o.signal == FlutterVersionSignal.toolVersions)
              .version,
          Version(3, 27, 4));
    });
  });
}
