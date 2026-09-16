import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge_core/src/common/source.dart';
import 'package:reforge_core/src/parsing/gradle/gradle_script.dart';
import 'package:reforge_core/src/parsing/parse_diagnostic.dart';
import 'package:reforge_core/src/parsing/properties/properties_file.dart';
import 'package:reforge_core/src/parsing/pub/pub_metadata.dart';
import 'package:reforge_core/src/parsing/pub/pubspec.dart';
import 'package:reforge_core/src/parsing/ruby/podfile.dart';
import 'package:reforge_core/src/parsing/xcode/pbxproj.dart';
import 'package:reforge_core/src/parsing/xml/android_manifest.dart';
import 'package:reforge_core/src/text/text_edit.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

void main() {
  group('PropertiesFile', () {
    test('parses the Gradle wrapper file with escaped colons', () {
      final file = PropertiesFile.parse(
          'gradle-wrapper.properties',
          readFixture('flutter_3_3_app',
              'android/gradle/wrapper/gradle-wrapper.properties'));
      expect(file['distributionUrl'],
          'https://services.gradle.org/distributions/gradle-7.4-all.zip');
      final entry = file.entry('distributionUrl')!;
      expect(entry.rawValueRange.textOf(file.source),
          r'https\://services.gradle.org/distributions/gradle-7.4-all.zip');
      // The template's first line is a timestamp comment.
      expect(file.entries.first.key, 'distributionBase');
    });

    test('handles separators, continuations and CRLF', () {
      const source = 'a=1\r\n'
          'b : two words\r\n'
          'c   spaced\r\n'
          '# comment\r\n'
          'd = first \\\r\n'
          '    second\r\n'
          'e\\:key=value\r\n'
          'empty=\r\n';
      final file = PropertiesFile.parse('x.properties', source);
      expect(file['a'], '1');
      expect(file['b'], 'two words');
      expect(file['c'], 'spaced');
      expect(file['d'], 'first second');
      expect(file['e:key'], 'value');
      expect(file['empty'], '');
      final d = file.entry('d')!;
      expect(d.line, 5);
      expect(d.rawValueRange.textOf(source), 'first \\\r\n    second');
      final updated = applyTextEdits(
          source, [TextEdit.replace(file.entry('a')!.rawValueRange, '2')]);
      expect(PropertiesFile.parse('x', updated)['a'], '2');
      expect(file.entry('empty')!.rawValueRange.length, 0);
    });

    test('escapes values', () {
      expect(escapePropertyValue('https://x/y', escapeColons: true),
          r'https\://x/y');
      expect(escapePropertyValue(r'C:\dir'), r'C:\\dir');
    });
  });

  group('pub documents', () {
    test('pubspec of the Flutter 3.3 fixture', () {
      final pubspec = Pubspec.parse(
          'pubspec.yaml', readFixture('flutter_3_3_app', 'pubspec.yaml'));
      expect(pubspec.name, 'legacy_app');
      expect(pubspec.sdkConstraint!.value, '>=2.18.0 <3.0.0');
      expect(pubspec.sdkConstraint!.location.line, 23);
      expect(pubspec.dependsOnFlutter, isTrue);
      expect(pubspec.devDependencies.keys, contains('flutter_test'));
      expect(pubspec.plugin, isNull);
    });

    test('workspace pubspec', () {
      final pubspec = Pubspec.parse(
          'pubspec.yaml', readFixture('melos_workspace', 'pubspec.yaml'));
      expect(pubspec.workspace,
          ['apps/customer_app', 'apps/driver_app', 'packages/ui_kit']);
      expect(pubspec.dependsOnFlutter, isFalse);
    });

    test('dependency sources', () {
      final pubspec = Pubspec.parse('pubspec.yaml', '''
name: deps
dependencies:
  hosted: ^1.0.0
  bare:
  local:
    path: ../local
  remote:
    git:
      url: https://example.com/repo.git
      ref: main
  flutter:
    sdk: flutter
''');
      expect(pubspec.dependencies['hosted']!.source, isA<HostedDependency>());
      expect(
          (pubspec.dependencies['bare']!.source as HostedDependency)
              .constraintText,
          'any');
      expect(pubspec.dependencies['local']!.source, isA<PathDependency>());
      final git = pubspec.dependencies['remote']!.source as GitDependency;
      expect(git.ref, 'main');
    });

    test('invalid YAML is reported with a line', () {
      expect(
          () =>
              Pubspec.parse('pubspec.yaml', 'name: x\ndependencies:\n  a: [\n'),
          throwsA(isA<DocumentParseException>()));
      expect(() => Pubspec.parse('pubspec.yaml', 'description: no name\n'),
          throwsA(isA<DocumentParseException>()));
    });

    test('generated files of the real Flutter 3.44 app', () {
      final lock = PubspecLock.parse(
          'pubspec.lock', readFixture('flutter_3_44_app', 'pubspec.lock'));
      expect(lock.flutterSdkConstraint, '>=3.44.0');
      expect(lock.packages['shared_preferences']!.kind,
          LockedDependencyKind.directMain);
      expect(lock.packages['flutter']!.source, 'sdk');

      final config = PackageConfig.parse('.dart_tool/package_config.json',
          readFixture('flutter_3_44_app', '.dart_tool/package_config.json'));
      expect(config.flutterVersion, '3.44.0');
      expect(config.packages['real344']!.parsedLanguageVersion.toString(),
          '3.12.0');

      final plugins = FlutterPluginsDependencies.parse(
          '.flutter-plugins-dependencies',
          readFixture('flutter_3_44_app', '.flutter-plugins-dependencies'));
      expect(plugins.flutterVersion, '3.44.0');
      expect(plugins.pluginsByPlatform['android']!.map((p) => p.name),
          ['shared_preferences_android', 'url_launcher_android']);
      expect(plugins.swiftPackageManagerEnabled['ios'], isFalse);

      final metadata = FlutterProjectMetadata.parse(
          '.metadata', readFixture('flutter_3_44_app', '.metadata'));
      expect(metadata.revision, '559ffa3f75e7402d65a8def9c28389a9b2e6fe42');
      expect(metadata.projectType, 'app');
      expect(metadata.createRevisions['android'],
          '559ffa3f75e7402d65a8def9c28389a9b2e6fe42');
    });
  });

  group('AndroidManifest', () {
    test('locates the legacy package attribute for removal', () {
      const path = 'android/app/src/main/AndroidManifest.xml';
      final source = readFixture('flutter_3_3_app', path);
      final manifest = AndroidManifest.parse(path, source);
      expect(manifest.packageAttribute, 'com.example.legacy_app');
      final attribute = manifest.attribute('package')!;
      final updated = applyTextEdits(source, [
        TextEdit.delete(attribute.leadingWhitespaceStart,
            attribute.range.end - attribute.leadingWhitespaceStart)
      ]);
      expect(
          updated,
          startsWith(
              '<manifest xmlns:android="http://schemas.android.com/apk/res/android">\n'
              '   <application'));
      expect(AndroidManifest.parse(path, updated).packageAttribute, isNull);
    });

    test('modern manifests have no package attribute', () {
      const path = 'android/app/src/main/AndroidManifest.xml';
      final manifest =
          AndroidManifest.parse(path, readFixture('flutter_3_44_app', path));
      expect(manifest.packageAttribute, isNull);
      expect(manifest.applicationName, r'${applicationName}');
    });

    test('malformed XML is reported', () {
      expect(
          () => AndroidManifest.parse(
              'm.xml', '<manifest><application></manifest>'),
          throwsA(isA<DocumentParseException>()));
      expect(() => AndroidManifest.parse('m.xml', '<resources/>'),
          throwsA(isA<DocumentParseException>()));
    });
  });

  group('Xcode project', () {
    test('project-level deployment targets of the Flutter 3.3 template', () {
      const path = 'ios/Runner.xcodeproj/project.pbxproj';
      final source = readFixture('flutter_3_3_app', path);
      final project = XcodeProject.parse(path, source);
      expect(project.projectConfigurations.map((c) => c.name),
          unorderedEquals(['Debug', 'Release', 'Profile']));
      for (final configuration in project.projectConfigurations) {
        final target = configuration.setting('IPHONEOS_DEPLOYMENT_TARGET')!;
        expect(target.value, '11.0');
        expect(target.contentRange.textOf(source), '11.0');
      }
      expect(project.target('Runner')!.isApplication, isTrue);
      expect(project.usesFlutterSwiftPackage, isFalse);
    });

    test('the real Flutter 3.44 project', () {
      const path = 'ios/Runner.xcodeproj/project.pbxproj';
      final project =
          XcodeProject.parse(path, readFixture('flutter_3_44_app', path));
      expect(project.targets.map((t) => t.name),
          containsAll(['Runner', 'RunnerTests']));
      expect(
          project.projectConfigurations
              .map((c) => c.setting('IPHONEOS_DEPLOYMENT_TARGET')?.value)
              .toSet(),
          {'13.0'});
    });

    test('quoted strings and syntax errors', () {
      final value =
          parseOpenStepPlist('x', '{ a = "b \\"c\\""; d = (e, "f g",); }');
      expect(value, isA<PbxDict>());
      final dict = value as PbxDict;
      expect(dict.string('a'), 'b "c"');
      expect(dict.stringList('d'), ['e', 'f g']);
      expect(() => parseOpenStepPlist('x', '{ a = b }'),
          throwsA(isA<DocumentParseException>()));
    });
  });

  group('Podfile', () {
    test('Flutter template Podfile with a commented platform', () {
      final podfile = Podfile.parse(
          'ios/Podfile', readFixture('flutter_3_44_app', 'ios/Podfile'));
      expect(podfile.isReliable, isTrue, reason: '${podfile.diagnostics}');
      expect(podfile.platform, isNull);
      expect(podfile.commentedPlatform!.version, '13.0');
      expect(podfile.targets.single.name, 'Runner');
      expect(podfile.targets.single.children.single.name, 'RunnerTests');
      expect(podfile.usesFrameworks, isTrue);
      expect(podfile.installsFlutterPods, isTrue);
      expect(podfile.callsFlutterPodfileSetup, isTrue);
      expect(podfile.callsFlutterAdditionalBuildSettings, isTrue);
      expect(podfile.buildSettingAssignments, isEmpty);
      expect(podfile.postInstallStatementCount, 2);
    });

    test('macOS template Podfile', () {
      final podfile = Podfile.parse(
          'macos/Podfile', readFixture('flutter_3_3_app', 'macos/Podfile'));
      expect(podfile.isReliable, isTrue, reason: '${podfile.diagnostics}');
      expect(podfile.platform!.name, 'osx');
      expect(podfile.platform!.version, '10.11');
      expect(podfile.installsFlutterPods, isTrue);
      expect(podfile.callsFlutterPodfileSetup, isTrue);
      expect(podfile.callsFlutterAdditionalBuildSettings, isTrue);
    });

    test('customized Podfile with platform and deployment target override', () {
      final source = readFixture('firebase_flavors_app', 'ios/Podfile');
      final podfile = Podfile.parse('ios/Podfile', source);
      expect(podfile.isReliable, isTrue, reason: '${podfile.diagnostics}');
      expect(podfile.platform!.version, '12.0');
      expect(podfile.platform!.versionContentRange!.textOf(source), '12.0');
      final override = podfile.buildSettingAssignments
          .singleWhere((a) => a.setting == 'IPHONEOS_DEPLOYMENT_TARGET');
      expect(override.value, '12.0');
      expect(override.valueContentRange!.textOf(source), '12.0');
      expect(podfile.buildSettingAssignments.map((a) => a.setting),
          contains('GCC_PREPROCESSOR_DEFINITIONS'));
    });

    test('Ruby constructs that commonly break naive parsers', () {
      final podfile = Podfile.parse('Podfile', r'''
def helper(x)
  return x if x
  value = if x then 1 else 2 end
  y = x.nil? ? 'a' : "b#{x}"
  regex = line.match(/FOO\=(.*)/)
  list = %w[a b c]
  text = <<~TEXT
    end
    do
  TEXT
  [1, 2].each { |i| puts i }
end

target 'Runner' do
  pod 'Firebase', :modular_headers => true
end
''');
      expect(podfile.isReliable, isTrue, reason: '${podfile.diagnostics}');
      expect(podfile.targets.single.name, 'Runner');
      expect(podfile.pods, ['Firebase']);
    });

    test('unbalanced blocks are reported', () {
      final podfile =
          Podfile.parse('Podfile', "target 'Runner' do\n  use_frameworks!\n");
      expect(podfile.isReliable, isFalse);
    });
  });

  test(
      'every Gradle script in the fixtures parses reliably, except broken ones',
      () {
    final root = Directory(p.join(repositoryRoot(), 'fixtures', 'projects'));
    final scripts = root.listSync(recursive: true).whereType<File>().where(
        (f) => f.path.endsWith('.gradle') || f.path.endsWith('.gradle.kts'));
    expect(scripts, isNotEmpty);
    for (final file in scripts) {
      final relative = p.relative(file.path, from: root.path);
      final script = GradleScript.parse(relative, file.readAsStringSync());
      final expectReliable =
          !relative.startsWith('broken_gradle_app/android/app/');
      expect(script.isReliable, expectReliable,
          reason: '$relative: ${script.diagnostics}');
    }
  });

  test('LineIndex refs point at the right place', () {
    final index = LineIndex('a\nbc\n');
    final ref = index.refFor('f', 3);
    expect(ref.line, 2);
    expect(ref.column, 2);
  });
}
