import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge/reforge.dart';
import 'package:reforge_core/reforge_core.dart';
import 'package:test/test.dart';

import 'support/cli_harness.dart';

const _pluginFailure = '''
/home/dev/.pub-cache/hosted/pub.dev/legacy_camera_plugin-0.5.8/android/src/main/java/com/example/legacycamera/LegacyCameraPlugin.java:9: error: cannot find symbol
import io.flutter.plugin.common.PluginRegistry.Registrar;
  symbol:   class Registrar
FAILURE: Build failed with an exception.
* What went wrong:
Execution failed for task ':legacy_camera_plugin:compileDebugJavaWithJavac'.
''';

final class _FailingBuild implements ProcessRunner {
  _FailingBuild(this.output);

  final String output;

  @override
  Future<CommandResult> run(ExternalCommand command,
          {void Function(String line)? onOutput}) async =>
      CommandResult(
          command: command,
          exitCode: 1,
          stdout: output,
          stderr: '',
          elapsed: const Duration(seconds: 2));
}

void main() {
  late Directory temp;
  setUp(() => temp = Directory.systemTemp.createTempSync('reforge_diagnose'));
  tearDown(() => temp.deleteSync(recursive: true));

  test('explains a log and confirms the cause from the dependencies', () async {
    final log = File(p.join(temp.path, 'build.log'))
      ..writeAsStringSync(_pluginFailure);
    final project = fixtureProject('plugins_app');
    final text = await runCli([
      '-C', project, 'diagnose', '--log', log.path, '--to', '3.47.4', //
      '--no-env',
    ]);
    expect(text.exitCode, ExitCodes.success);
    expect(
        text.stdout, contains('Failing Gradle module: :legacy_camera_plugin'));
    expect(text.stdout, contains('PLUGIN_V1_EMBEDDING'));
    expect(text.stdout, contains('Confirmed by PLUGIN_ANDROID_V1_EMBEDDING'));
    expect(text.stdout, contains('LegacyCameraPlugin.java:9'));

    final json = await runCli([
      '-C', project, 'diagnose', '--log', log.path, '--to', '3.47.4', //
      '--no-env', '--format', 'json',
    ]);
    final result = json.json['result']! as Map<String, Object?>;
    final output = (result['outputs']! as List).single as Map;
    final diagnosis = (output['diagnoses']! as List).single as Map;
    expect(diagnosis['id'], 'PLUGIN_V1_EMBEDDING');
    expect(((diagnosis['confirmedBy']! as List).single as Map)['subject'],
        'legacy_camera_plugin');
  });

  test('runs a build when no log is given', () async {
    final project = copyFixture('flutter_3_3_app');
    addTearDown(() => project.deleteSync(recursive: true));
    final run = await runCli(
      ['-C', project.path, 'diagnose', '--to', '3.47.4'],
      processRunner: _FailingBuild(
          "Error: Your project's Kotlin version (1.6.10) is lower than "
          "Flutter's minimum supported version of 2.2.20. Please upgrade"),
    );
    expect(run.exitCode, ExitCodes.failed);
    expect(run.stdout, contains('flutter build apk --debug failed'));
    expect(run.stdout,
        contains('Confirmed by ANDROID_KOTLIN_BELOW_FLUTTER_MINIMUM'));
    expect(run.stdout, contains('Recipes: ANDROID_KOTLIN_VERSION'));
    expect(File(p.join(project.path, '.reforge', '.gitignore')).existsSync(),
        isTrue,
        reason: 'logs are written below a self-ignoring .reforge');
  });

  test('rejects conflicting inputs and missing logs', () async {
    final project = fixtureProject('flutter_3_3_app');
    final both = await runCli([
      '-C', project, 'diagnose', '--log', 'a.log', '--check', 'android', //
    ]);
    expect(both.exitCode, ExitCodes.usage);
    expect(both.stderr, contains('DIAGNOSE_INPUT_CONFLICT'));

    final missing = await runCli(
        ['-C', project, 'diagnose', '--log', p.join(temp.path, 'none.log')]);
    expect(missing.exitCode, ExitCodes.usage);
    expect(missing.stderr, contains('LOG_NOT_FOUND'));
  });
}
