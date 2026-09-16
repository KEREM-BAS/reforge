import 'package:reforge_core/reforge_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

final knowledge = KnowledgeBase.bundled;

const _config = '''
{
  "configVersion": 2,
  "packages": [
    {"name": "flutter", "rootUri": "file:///sdk/packages/flutter", "packageUri": "lib/"},
    {"name": "kts_plugin", "rootUri": "file:///cache/kts_plugin-1.0.0", "packageUri": "lib/"},
    {"name": "broken_plugin", "rootUri": "file:///cache/broken_plugin-1.0.0", "packageUri": "lib/"},
    {"name": "old_dart", "rootUri": "file:///cache/old_dart-0.1.0", "packageUri": "lib/"},
    {"name": "missing", "rootUri": "file:///cache/missing-1.0.0", "packageUri": "lib/"},
    {"name": "app", "rootUri": "../", "packageUri": "lib/"}
  ]
}
''';

const _lock = '''
packages:
  flutter:
    dependency: "direct main"
    description: flutter
    source: sdk
    version: "0.0.0"
  kts_plugin:
    dependency: "direct main"
    source: hosted
    version: "1.0.0"
  broken_plugin:
    dependency: transitive
    source: hosted
    version: "1.0.0"
  old_dart:
    dependency: transitive
    source: hosted
    version: "0.1.0"
''';

String _pluginPubspec(String name, {String sdk = '^3.0.0'}) => '''
name: $name
version: 1.0.0
environment:
  sdk: "$sdk"
dependencies:
  flutter:
    sdk: flutter
  old_dart: ^0.1.0
flutter:
  plugin:
    platforms:
      android:
        package: com.example.$name
        pluginClass: Plugin
''';

MemoryPackageSources _sources() => MemoryPackageSources({
      '/cache/kts_plugin-1.0.0': {
        'pubspec.yaml': _pluginPubspec('kts_plugin'),
        'android/build.gradle.kts':
            'plugins {\n    id("com.android.library")\n}\n\n'
                'android {\n    namespace = "com.example.kts"\n}\n',
        'android/src/main/kotlin/Plugin.kt':
            '// PluginRegistry.Registrar was removed.\n'
                'val text = "PluginRegistry.Registrar"\n',
      },
      '/cache/broken_plugin-1.0.0': {
        'pubspec.yaml': _pluginPubspec('broken_plugin'),
        'android/build.gradle': 'android {\n    compileSdk 34\n',
      },
      '/cache/old_dart-0.1.0': {
        'pubspec.yaml':
            'name: old_dart\nversion: 0.1.0\nenvironment:\n  sdk: ">=2.7.0 <3.0.0"\n',
      },
    });

FlutterProject _inspect(ProjectFileSystem files) =>
    ProjectInspector(files, knowledge: knowledge).inspectProject('');

void main() {
  group('reading packages', () {
    test('the fixture pub cache', () {
      final files = LocalProjectFileSystem(fixtureProject('plugins_app'));
      final project = _inspect(files);
      final report = DependencyInspector(const LocalPackageSources())
          .inspect(project, files);
      expect(report.resolved, isTrue);
      expect(report.unavailable, isEmpty);
      expect(report.packages.map((p) => p.name),
          ['legacy_camera_plugin', 'modern_share_plugin', 'string_tools']);

      final legacy = report.package('legacy_camera_plugin')!;
      expect(legacy.version, '0.5.8');
      expect(legacy.android!.declaresNamespace, isFalse);
      expect(legacy.android!.buildFile.path,
          'legacy_camera_plugin 0.5.8/android/build.gradle');
      expect(
          legacy.android!.v1EmbeddingReferences.single.display,
          'legacy_camera_plugin 0.5.8/android/src/main/java/com/example/'
          'legacycamera/LegacyCameraPlugin.java:9');

      final modern = report.package('modern_share_plugin')!;
      expect(modern.android!.declaresNamespace, isTrue,
          reason: 'namespace inside if (hasProperty) counts');
      expect(modern.android!.v1EmbeddingReferences, isEmpty,
          reason: 'mentions in comments do not count');
      expect(modern.android!.kotlinPlugin, KotlinPluginApplication.always);
      expect(legacy.android!.kotlinPlugin, KotlinPluginApplication.none);

      expect(legacy.ios!.minimumVersion, '9.0');
      expect(modern.ios!.minimumVersion, '17.0');
      expect(modern.ios!.podspec.display,
          'modern_share_plugin 2.1.0/ios/modern_share_plugin.podspec:11');
      expect(modern.macos!.minimumVersion, '10.15');
      expect(modern.macos!.podspec.display,
          'modern_share_plugin 2.1.0/macos/modern_share_plugin.podspec:12');
      expect(legacy.macos, isNull, reason: 'no macOS implementation');
      expect(report.package('string_tools')!.ios, isNull);
      expect(report.package('string_tools')!.android, isNull);
      expect(report.dependentsOf('string_tools').map((p) => p.name),
          ['legacy_camera_plugin']);
    });

    test('Kotlin DSL, unreadable scripts and missing packages', () {
      final files = MemoryProjectFileSystem({
        'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ^3.4.0\n'
            'dependencies:\n  flutter:\n    sdk: flutter\n',
        'pubspec.lock': _lock,
        '.dart_tool/package_config.json': _config,
      }, rootPath: '/work/app');
      final report =
          DependencyInspector(_sources()).inspect(_inspect(files), files);
      expect(report.unavailable, ['missing']);
      final kts = report.package('kts_plugin')!;
      expect(kts.android!.declaresNamespace, isTrue);
      expect(kts.android!.v1EmbeddingReferences, isEmpty,
          reason: 'comments and strings do not count');
      expect(
          report.package('broken_plugin')!.android!.declaresNamespace, isNull);
    });

    test('pub workspace members use the workspace package config', () {
      final files = MemoryProjectFileSystem({
        'pubspec.yaml':
            'name: root\nenvironment:\n  sdk: ^3.6.0\nworkspace:\n  - app\n',
        '.dart_tool/package_config.json': _config,
        'app/pubspec.yaml': 'name: app\nenvironment:\n  sdk: ^3.6.0\n'
            'resolution: workspace\n'
            'dependencies:\n  flutter:\n    sdk: flutter\n',
        'app/android/app/build.gradle': 'android {}\n',
      }, rootPath: '/work');
      final project =
          ProjectInspector(files, knowledge: knowledge).inspectProject('app');
      final report = DependencyInspector(_sources()).inspect(project, files);
      expect(report.configPath, '.dart_tool/package_config.json');
      expect(report.package('kts_plugin'), isNotNull);
    });
  });

  group('findings', () {
    List<Finding> analyze(String target, {String agp = '8.11.1'}) {
      final files = MemoryProjectFileSystem({
        'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ^3.4.0\n'
            'dependencies:\n  flutter:\n    sdk: flutter\n',
        'pubspec.lock': _lock,
        '.dart_tool/package_config.json': _config.replaceFirst(
            'file:///cache/kts_plugin-1.0.0', 'file:///cache/legacy-1.0.0'),
        'android/settings.gradle': 'plugins {\n'
            '    id "dev.flutter.flutter-plugin-loader" version "1.0.0"\n'
            '    id "com.android.application" version "$agp" apply false\n'
            '}\n',
        'android/app/build.gradle': 'android {\n    namespace "a.b"\n}\n',
      }, rootPath: '/work/app');
      final sources = MemoryPackageSources({
        ..._sources().packages,
        '/cache/legacy-1.0.0': {
          'pubspec.yaml': _pluginPubspec('kts_plugin'),
          'android/build.gradle': 'android {\n    compileSdkVersion 30\n}\n',
          'android/src/main/java/Plugin.java':
              'import io.flutter.plugin.common.PluginRegistry.Registrar;\n',
        },
      });
      final project = _inspect(files);
      return CompatibilityAnalyzer(knowledge).analyze(
        project,
        release: knowledge.resolveFlutterVersion(target),
        dependencies: DependencyInspector(sources).inspect(project, files),
      );
    }

    Finding? find(List<Finding> findings, String code) =>
        findings.where((f) => f.code == code).firstOrNull;

    test('plugins without a namespace fail with AGP 8', () {
      final finding =
          find(analyze('3.47.4'), 'PLUGIN_ANDROID_NAMESPACE_MISSING')!;
      expect(finding.severity, Severity.error);
      expect(finding.message, contains('this project uses 8.11.1'));
      expect(finding.suggestedAction, contains('a direct dependency'));
      expect(finding.evidence.first.kind, EvidenceKind.dependencyFile);
      expect(finding.evidence.last.source?.url,
          contains('agp-8-0-0-release-notes'));

      expect(
          find(analyze('3.22.0', agp: '7.3.0'),
              'PLUGIN_ANDROID_NAMESPACE_MISSING'),
          isNull);
    });

    test('the v1 embedding is a warning before 3.29 and an error after', () {
      expect(
          find(analyze('3.27.0', agp: '7.3.0'), 'PLUGIN_ANDROID_V1_EMBEDDING')!
              .severity,
          Severity.warning);
      final removed = find(analyze('3.29.0'), 'PLUGIN_ANDROID_V1_EMBEDDING')!;
      expect(removed.severity, Severity.error);
      expect(removed.evidence.first.location?.display,
          'kts_plugin 1.0.0/android/src/main/java/Plugin.java:1');
    });

    test('Dart SDK constraints follow pub', () {
      final findings = analyze('3.47.4')
          .where((f) => f.code == 'DEPENDENCY_DART_SDK_INCOMPATIBLE')
          .toList();
      expect(findings.single.title, contains('old_dart 0.1.0'));
      expect(findings.single.suggestedAction,
          contains('packages that depend on old_dart'));
      expect(find(analyze('3.47.4'), 'DEPENDENCY_FILES_UNAVAILABLE')!.message,
          contains('missing'));
    });

    test('plugins applying the Kotlin Gradle plugin, with AGP 9 only', () {
      final files = MemoryProjectFileSystem({
        'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ^3.4.0\n',
        'android/settings.gradle': 'plugins {\n'
            '    id "com.android.application" version "9.0.1" apply false\n'
            '}\n',
      });
      final project = _inspect(files);
      DependencyReport report(bool applies) => DependencyReport(
            configPath: '.dart_tool/package_config.json',
            packages: [
              ResolvedPackage(
                name: 'share_kgp',
                rootPath: '/cache/share_kgp-1.0.0',
                android: AndroidPluginFacts(
                  buildFile:
                      const SourceRef('share_kgp 1.0.0/android/build.gradle'),
                  declaresNamespace: true,
                  kotlinPlugin: applies
                      ? KotlinPluginApplication.always
                      : KotlinPluginApplication.conditional,
                ),
              ),
            ],
          );
      List<Finding> analyze(String target, {bool applies = true}) =>
          CompatibilityAnalyzer(knowledge).analyze(project,
              release: knowledge.resolveFlutterVersion(target),
              dependencies: report(applies));

      final finding = analyze('3.47.4')
          .singleWhere((f) => f.code == 'PLUGINS_APPLY_KOTLIN_GRADLE_PLUGIN');
      expect(finding.severity, Severity.warning);
      expect(finding.message, startsWith('share_kgp apply'));
      expect(
          analyze('3.41.0')
              .where((f) => f.code == 'PLUGINS_APPLY_KOTLIN_GRADLE_PLUGIN'),
          isEmpty);
      expect(
          analyze('3.47.4', applies: false)
              .where((f) => f.code == 'PLUGINS_APPLY_KOTLIN_GRADLE_PLUGIN'),
          isEmpty);
    });

    test('pods that need a newer iOS than CocoaPods resolves for', () {
      DependencyReport report(String minimumIos) => DependencyReport(
            configPath: '.dart_tool/package_config.json',
            packages: [
              ResolvedPackage(
                name: 'share_ios',
                rootPath: '/cache/share_ios-1.0.0',
                ios: DarwinPluginFacts(
                  podspec: const SourceRef(
                      'share_ios 1.0.0/ios/share_ios.podspec',
                      line: 3),
                  minimumVersion: minimumIos,
                ),
              ),
            ],
          );
      final pbxproj =
          readFixture('plugins_app', 'ios/Runner.xcodeproj/project.pbxproj');
      List<Finding> analyze(String minimumIos, {String? podfile}) {
        final files = MemoryProjectFileSystem({
          'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ^3.4.0\n',
          'ios/Runner.xcodeproj/project.pbxproj': pbxproj,
          if (podfile != null) 'ios/Podfile': podfile,
        });
        final project = _inspect(files);
        return CompatibilityAnalyzer(knowledge)
            .analyze(project,
                release: knowledge.resolveFlutterVersion('3.22.0'),
                dependencies: report(minimumIos))
            .where((f) => f.code == 'PLUGIN_IOS_DEPLOYMENT_TARGET_ABOVE_APP')
            .toList();
      }

      final fromTarget = analyze('13.0').single;
      expect(fromTarget.severity, Severity.error);
      expect(
          fromTarget.message, contains('iOS 12.0 (the app deployment target)'));
      expect(fromTarget.subject, 'share_ios');
      expect(analyze('12.0'), isEmpty);

      final fromPodfile = analyze('13.0', podfile: "platform :ios, '14.0'\n");
      expect(fromPodfile, isEmpty, reason: 'the Podfile platform wins');
      expect(analyze('16.0', podfile: "platform :ios, '14.0'\n").single.message,
          contains('the Podfile platform'));
    });

    test('pods that need a newer macOS than CocoaPods resolves for', () {
      DependencyReport report(String minimumMacos) => DependencyReport(
            configPath: '.dart_tool/package_config.json',
            packages: [
              ResolvedPackage(
                name: 'share_macos',
                rootPath: '/cache/share_macos-1.0.0',
                macos: DarwinPluginFacts(
                  podspec: const SourceRef(
                      'share_macos 1.0.0/darwin/share_macos.podspec',
                      line: 4),
                  minimumVersion: minimumMacos,
                ),
              ),
            ],
          );
      List<Finding> analyze(String minimumMacos, {String? podfile}) {
        final files = MemoryProjectFileSystem({
          'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ^3.4.0\n',
          // MACOSX_DEPLOYMENT_TARGET = 10.11 (Flutter 3.3 template).
          'macos/Runner.xcodeproj/project.pbxproj': readFixture(
              'flutter_3_3_app', 'macos/Runner.xcodeproj/project.pbxproj'),
          if (podfile != null) 'macos/Podfile': podfile,
        });
        return CompatibilityAnalyzer(knowledge)
            .analyze(_inspect(files),
                release: knowledge.resolveFlutterVersion('3.3.0'),
                dependencies: report(minimumMacos))
            .where((f) =>
                f.code.startsWith('PLUGIN_') &&
                f.code.endsWith('_DEPLOYMENT_TARGET_ABOVE_APP'))
            .toList();
      }

      final fromTarget = analyze('10.14').single;
      expect(fromTarget.code, 'PLUGIN_MACOS_DEPLOYMENT_TARGET_ABOVE_APP');
      expect(
          fromTarget.message,
          'Its podspec declares macOS 10.14, but CocoaPods resolves pods for '
          'macOS 10.11 (the app deployment target).');
      expect(
          fromTarget.evidence.last.description,
          'project Debug: MACOSX_DEPLOYMENT_TARGET = 10.11 (CocoaPods uses it '
          'when the Podfile sets no platform)');
      expect(fromTarget.suggestedAction,
          contains('Macs below macOS 10.14 can then no longer run the app'));

      expect(analyze('10.14', podfile: "platform :osx, '10.14'\n"), isEmpty);
      final fromPodfile =
          analyze('11.0', podfile: "platform :osx, '10.14'\n").single;
      expect(
          fromPodfile.message, contains('macOS 10.14 (the Podfile platform)'));
      expect(fromPodfile.evidence.last.description,
          "Podfile platform :osx, '10.14'");
    });

    test('unresolved projects are reported, not guessed', () {
      final files = MemoryProjectFileSystem({
        'pubspec.yaml': 'name: app\nenvironment:\n  sdk: ^3.4.0\n',
      });
      final project = _inspect(files);
      final findings = CompatibilityAnalyzer(knowledge).analyze(project,
          release: knowledge.latestStable,
          dependencies:
              DependencyInspector(_sources()).inspect(project, files));
      expect(findings.single.code, 'DEPENDENCIES_NOT_RESOLVED');
      expect(findings.single.severity, Severity.info);
    });
  });
}
