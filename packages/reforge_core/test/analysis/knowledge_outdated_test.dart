import 'package:reforge_core/reforge_core.dart';
import 'package:test/test.dart';

final knowledge = KnowledgeBase.bundled;

Environment environment(String flutter) => Environment(
      operatingSystem: 'linux',
      operatingSystemVersion: '6.8',
      flutter: FlutterSdkInfo(
        version: Version.parse(flutter),
        channel: 'stable',
        frameworkRevision: null,
        dartVersion: null,
        root: null,
      ),
      flutterError: null,
      javaCandidates: const [],
      xcode: null,
      cocoapods: null,
      git: null,
    );

List<Finding> outdated(Map<String, String> files, {Environment? env}) {
  final project =
      ProjectInspector(MemoryProjectFileSystem(files), knowledge: knowledge)
          .inspectProject('');
  return CompatibilityAnalyzer(knowledge)
      .analyze(project, environment: env)
      .where((f) => f.code == 'REFORGE_KNOWLEDGE_OUTDATED')
      .toList();
}

void main() {
  const pubspec = 'name: app\nenvironment:\n  sdk: ^3.4.0\n'
      'dependencies:\n  flutter:\n    sdk: flutter\n';

  test('the knowledge base knows how old it is', () {
    expect(knowledge.generatedOn, DateTime.utc(2026, 9, 16));
    expect(knowledge.ageInDays(DateTime.utc(2026, 12, 16, 12)), 91);
    expect(knowledge.isNewerThanKnown(Version(3, 50, 0)), isTrue);
    expect(knowledge.isNewerThanKnown(knowledge.latestStable.version), isFalse);
    expect(knowledge.isNewerThanKnown(Version.parse('3.51.0-0.1.pre')), isFalse,
        reason: 'beta releases are not stable releases Reforge could know');
  });

  test('a newer Flutter on PATH or pinned by the project is reported', () {
    final fromPath =
        outdated({'pubspec.yaml': pubspec}, env: environment('3.50.0')).single;
    expect(fromPath.severity, Severity.warning);
    expect(fromPath.title, 'This Reforge does not know Flutter 3.50.0');
    expect(
        fromPath.message,
        'Flutter 3.50.0 is newer than the releases this Reforge knows: the '
        'latest is ${knowledge.latestStable.version} (knowledge base '
        '${knowledge.version}).');
    expect(fromPath.evidence.first.kind, EvidenceKind.environment);

    final pinned = outdated({
      'pubspec.yaml': pubspec,
      '.fvmrc': '{"flutter": "3.50.1"}',
    }, env: environment('3.50.0'))
        .single;
    expect(pinned.title, 'This Reforge does not know Flutter 3.50.1');
    expect(pinned.evidence.map((e) => e.kind),
        containsAll([EvidenceKind.environment, EvidenceKind.projectFile]));

    expect(
        outdated({'pubspec.yaml': pubspec},
            env: environment('${knowledge.latestStable.version}')),
        isEmpty);
    expect(
        outdated({'pubspec.yaml': pubspec}, env: environment('3.51.0-0.1.pre')),
        isEmpty);
  });
}
