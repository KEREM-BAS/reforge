import 'dart:convert';

import 'package:reforge/reforge.dart';
import 'package:test/test.dart';

import 'support/cli_harness.dart';

Map<String, Object?> sarifOf(CliRun run) =>
    jsonDecode(run.stdout) as Map<String, Object?>;

List<Map<String, Object?>> resultsOf(Map<String, Object?> sarif) => [
      for (final result
          in ((sarif['runs']! as List).single as Map)['results']! as List)
        result as Map<String, Object?>,
    ];

void main() {
  test('plan results point at the files each step changes', () async {
    final run = await runCli([
      '-C', fixtureProject('flutter_3_3_app'), '--format', 'sarif', //
      'plan', '--to', '3.47.4', '--no-env',
    ]);
    expect(run.exitCode, ExitCodes.success);
    final sarif = sarifOf(run);
    expect(sarif['version'], '2.1.0');
    final runInfo = (sarif['runs']! as List).single as Map;
    expect(((runInfo['tool']! as Map)['driver']! as Map)['name'], 'Reforge');
    expect((runInfo['automationDetails']! as Map)['id'], 'reforge/plan/');

    final results = resultsOf(sarif);
    final agp =
        results.singleWhere((r) => r['ruleId'] == 'ANDROID_AGP_VERSION');
    expect(agp['level'], 'warning', reason: 'a required review not accepted');
    final location =
        ((agp['locations']! as List).first as Map)['physicalLocation'] as Map;
    // Paths are relative to the working directory (the repository root here).
    expect((location['artifactLocation']! as Map)['uri'],
        'fixtures/projects/flutter_3_3_app/android/settings.gradle');
    expect((location['region']! as Map)['startLine'], isA<int>());

    final dsl = results
        .singleWhere((r) => r['ruleId'] == 'ANDROID_FLUTTER_GRADLE_PLUGIN_DSL');
    expect(dsl['level'], 'note');
  });

  test('inspect never locates results in dependency files', () async {
    final run = await runCli([
      '-C', fixtureProject('plugins_app'), '--format', 'sarif', 'inspect', //
      '--no-env',
    ]);
    final v1 = resultsOf(sarifOf(run))
        .singleWhere((r) => r['ruleId'] == 'PLUGIN_ANDROID_V1_EMBEDDING');
    expect(v1['level'], 'warning');
    expect(v1['locations'], isEmpty);
    expect((v1['message']! as Map)['text'], contains('legacy_camera_plugin'));
    expect((v1['properties']! as Map)['subject'], 'legacy_camera_plugin');
  });

  test('commands without SARIF output reject the format', () async {
    final run = await runCli([
      '-C',
      fixtureProject('flutter_3_3_app'),
      '--format',
      'sarif',
      'history',
    ]);
    expect(run.exitCode, ExitCodes.usage);
    expect(run.stderr, contains('FORMAT_UNSUPPORTED'));
  });
}
