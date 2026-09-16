import 'package:reforge_core/reforge_core.dart';
import 'package:test/test.dart';

import 'support/cli_harness.dart';

void main() {
  final knowledge = KnowledgeBase.bundled;
  final latest = knowledge.latestStable.version;

  test('plan says what stable resolves to, and when it may be outdated',
      () async {
    Future<String> planStable(DateTime now) async => (await runCli([
          '-C',
          fixtureProject('flutter_3_22_app'),
          'plan',
          '--to',
          'stable',
          '--no-env',
        ], clock: () => now))
            .stdout;

    final fresh = await planStable(DateTime.utc(2026, 9, 20));
    expect(
        fresh,
        contains('stable is Flutter $latest, the latest stable release this '
            'Reforge knows (knowledge base ${knowledge.version}).'));
    expect(fresh, isNot(contains('days old')));

    final old = await planStable(DateTime.utc(2027, 1, 20));
    expect(
        old,
        contains('The knowledge base is 126 days old; newer Flutter releases '
            'may exist. Upgrade Reforge to plan for them.'));
  });

  test('env and inspect point out a Flutter newer than the knowledge base',
      () async {
    final environment = fakeEnvironment(flutter: '3.50.0');
    final env = await runCli(['env'],
        environment: environment, clock: () => DateTime.utc(2026, 9, 20));
    expect(
        env.stdout,
        contains(
            'newer than the releases this Reforge knows; upgrade Reforge'));
    expect(env.stdout, contains('knowledge base ${knowledge.version}'));

    final inspect = await runCli(
        ['-C', fixtureProject('flutter_3_22_app'), 'inspect', '--format=json'],
        environment: environment);
    final codes = [
      for (final finding in (inspect.json['result']!
          as Map<String, Object?>)['findings']! as List)
        (finding as Map)['code'],
    ];
    expect(codes, contains('REFORGE_KNOWLEDGE_OUTDATED'));
  });
}
