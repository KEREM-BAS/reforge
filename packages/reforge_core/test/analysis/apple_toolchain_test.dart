import 'package:reforge_core/reforge_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

final knowledge = KnowledgeBase.bundled;

Environment environment(
        {required String xcode, required String pod, String os = 'macos'}) =>
    Environment(
      operatingSystem: os,
      operatingSystemVersion: '26.5',
      flutter: null,
      flutterError: null,
      javaCandidates: const [],
      xcode: ToolInfo('Xcode', version: xcode),
      cocoapods: ToolInfo('CocoaPods', version: pod),
      git: null,
    );

const pubspec = 'name: app\nenvironment:\n  sdk: ^3.4.0\n';

List<Finding> findings(Map<String, String> files, Environment environment,
    {String target = '3.47.4'}) {
  final project =
      ProjectInspector(MemoryProjectFileSystem(files), knowledge: knowledge)
          .inspectProject('');
  return CompatibilityAnalyzer(knowledge)
      .analyze(project,
          release: knowledge.resolveFlutterVersion(target),
          environment: environment)
      .where((f) =>
          f.code.startsWith('ENV_XCODE_') ||
          f.code.startsWith('ENV_COCOAPODS_'))
      .toList();
}

void main() {
  final iosApp = {
    'pubspec.yaml': pubspec,
    'ios/Runner.xcodeproj/project.pbxproj':
        readFixture('flutter_3_3_app', 'ios/Runner.xcodeproj/project.pbxproj'),
    'ios/Podfile': readFixture('flutter_3_3_app', 'ios/Podfile'),
  };

  test('Xcode below the version Flutter requires or recommends', () {
    final below =
        findings(iosApp, environment(xcode: '14.3.1', pod: '1.16.2')).single;
    expect(below.code, 'ENV_XCODE_BELOW_FLUTTER_MINIMUM');
    expect(below.severity, Severity.error);
    expect(below.message, 'Flutter 3.47.4 requires Xcode 15 or newer.');
    expect(below.impact,
        contains('"Xcode 15 or greater is required to develop for iOS"'));
    expect(below.evidence.last.source!.url,
        endsWith('/3.47.4/packages/flutter_tools/lib/src/macos/xcode.dart'));

    final recommended =
        findings(iosApp, environment(xcode: '15.4', pod: '1.16.2')).single;
    expect(recommended.code, 'ENV_XCODE_BELOW_FLUTTER_RECOMMENDED');
    expect(recommended.severity, Severity.warning);

    expect(
        findings(iosApp, environment(xcode: '26.5', pod: '1.16.2')), isEmpty);
    expect(
        findings(iosApp, environment(xcode: '14.3.1', pod: '1.16.2'),
                target: '3.41.0')
            .single
            .code,
        'ENV_XCODE_BELOW_FLUTTER_RECOMMENDED');
  });

  test('a macOS-only app does not fail to build with an old Xcode', () {
    final macosApp = {
      'pubspec.yaml': pubspec,
      'macos/Runner.xcodeproj/project.pbxproj': readFixture(
          'flutter_3_3_app', 'macos/Runner.xcodeproj/project.pbxproj'),
    };
    final below =
        findings(macosApp, environment(xcode: '14.3.1', pod: '1.16.2')).single;
    expect(below.severity, Severity.warning);
    expect(below.impact, '`flutter doctor` reports an error.');
  });

  test('CocoaPods is checked when a host uses it', () {
    final minimum =
        findings(iosApp, environment(xcode: '26.5', pod: '1.9.3')).single;
    expect(minimum.code, 'ENV_COCOAPODS_BELOW_FLUTTER_MINIMUM');
    expect(minimum.severity, Severity.error);
    expect(
        minimum.message, 'Flutter 3.47.4 requires CocoaPods 1.10.0 or newer.');

    final recommended =
        findings(iosApp, environment(xcode: '26.5', pod: '1.15.2')).single;
    expect(recommended.code, 'ENV_COCOAPODS_BELOW_FLUTTER_RECOMMENDED');
    expect(recommended.suggestedAction, 'Update CocoaPods to 1.16.2 or newer.');

    final withoutPodfile = Map.of(iosApp)..remove('ios/Podfile');
    expect(findings(withoutPodfile, environment(xcode: '26.5', pod: '1.9.3')),
        isEmpty,
        reason: 'no Podfile and no plugins, so pod install does not run');
  });

  test('other operating systems and projects without Apple hosts', () {
    expect(
        findings(iosApp, environment(xcode: '14.0', pod: '1.9.0', os: 'linux')),
        isEmpty);
    expect(
        findings({'pubspec.yaml': pubspec, 'android/build.gradle': ''},
            environment(xcode: '14.0', pod: '1.9.0')),
        isEmpty);
  });
}
