import 'dart:io';

import 'package:reforge/reforge.dart';
import 'package:test/test.dart';

import 'support/cli_harness.dart';

void main() {
  test('inspect text output explains problems for the current Flutter SDK',
      () async {
    final run =
        await runCli(['-C', fixtureProject('flutter_3_3_app'), 'inspect']);
    expect(run.exitCode, ExitCodes.success);
    expect(run.stdout, contains('legacy_app'));
    expect(run.stdout, contains('AGP          7.1.2 android/build.gradle:9'));
    expect(run.stdout, contains('ANDROID_IMPERATIVE_GRADLE_APPLY'));
    expect(run.stdout, contains('ENV_JAVA_CANNOT_RUN_GRADLE'));
    expect(run.stdout, isNot(contains('\x1B[')), reason: 'color disabled');
  });

  test('inspect JSON output is enveloped and machine readable', () async {
    final run = await runCli([
      '-C',
      fixtureProject('flutter_3_22_app'),
      'inspect',
      '--format',
      'json',
    ]);
    expect(run.exitCode, ExitCodes.success);
    final json = run.json;
    expect(json['schemaVersion'], 1);
    expect(json['command'], 'inspect');
    final result = json['result']! as Map<String, Object?>;
    final project =
        (result['projects']! as List).single as Map<String, Object?>;
    final android = project['android']! as Map<String, Object?>;
    final toolchain = android['toolchain']! as Map<String, Object?>;
    expect((toolchain['androidGradlePlugin']! as Map)['version'], '7.3.0');
    expect((project['currentFlutter']! as Map)['basis'], 'environment');
    final codes = [
      for (final finding in result['findings']! as List)
        (finding as Map)['code'],
    ];
    expect(codes, contains('ANDROID_AGP_BELOW_FLUTTER_MINIMUM'));
    expect(result['environment'], isNotNull);
  });

  test('--no-env analyzes files only', () async {
    final run = await runCli([
      '-C',
      fixtureProject('flutter_3_3_app'),
      'inspect',
      '--no-env',
      '--format=json',
    ]);
    final result = run.json['result']! as Map<String, Object?>;
    expect(result['environment'], isNull);
    final codes = [
      for (final finding in result['findings']! as List)
        (finding as Map)['code'],
    ];
    expect(codes, isNot(contains('ENV_JAVA_CANNOT_RUN_GRADLE')));
  });

  test('errors map to exit codes and JSON errors', () async {
    final empty = Directory.systemTemp.createTempSync('reforge_empty');
    addTearDown(() => empty.deleteSync(recursive: true));
    final missing = await runCli(
        ['-C', empty.path, 'inspect', '--format', 'json', '--no-env']);
    expect(missing.exitCode, ExitCodes.invalidProject);
    expect((missing.json['error']! as Map)['code'], 'PROJECT_NOT_FOUND');

    // The Reforge repository itself is a Dart workspace, not a Flutter one.
    final dartOnly = await runCli(
        ['-C', repositoryRoot(), 'inspect', '--format', 'json', '--no-env']);
    expect(dartOnly.exitCode, ExitCodes.invalidProject);
    expect((dartOnly.json['error']! as Map)['code'], 'PROJECT_NOT_FLUTTER');

    final usage = await runCli(['inspect', '--nope']);
    expect(usage.exitCode, ExitCodes.usage);
    expect(usage.stderr, contains('--nope'));

    final noDirectory = await runCli(['-C', '/does/not/exist', 'inspect']);
    expect(noDirectory.exitCode, ExitCodes.usage);
    expect(noDirectory.stderr, contains('PROJECT_DIRECTORY_MISSING'));
  });

  test('env command', () async {
    final run = await runCli(['env']);
    expect(run.exitCode, ExitCodes.success);
    expect(run.stdout, contains('Java         21'));
    final json = (await runCli(['env', '--format', 'json'])).json;
    expect(((json['result']! as Map)['flutter']! as Map)['version'], '3.44.0');
  });
}
