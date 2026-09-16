import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge/reforge.dart';
import 'package:test/test.dart';

import 'support/cli_harness.dart';

Map<String, String> snapshot(String root) => {
      for (final file in Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => !p.split(f.path).contains('.reforge')))
        p.relative(file.path, from: root): file.readAsStringSync(),
    };

void main() {
  late Directory project;

  setUp(() => project = copyFixture('flutter_3_3_app'));
  tearDown(() => project.deleteSync(recursive: true));

  test('plan explains pending reviews and supports CI gating', () async {
    final run = await runCli(
        ['-C', project.path, 'plan', '--to', '3.47.4', '--no-env']);
    expect(run.exitCode, ExitCodes.success);
    expect(run.stdout, contains('ANDROID_FLUTTER_GRADLE_PLUGIN_DSL'));
    expect(run.stdout, contains('Incomplete'));
    expect(run.stdout,
        contains('--accept ANDROID_AGP_VERSION,ANDROID_KOTLIN_VERSION'));

    final gated = await runCli([
      '-C', project.path, 'plan', '--to', '3.47.4', '--no-env', //
      '--fail-on', 'incomplete',
    ]);
    expect(gated.exitCode, ExitCodes.failed);

    final json = await runCli([
      '-C', project.path, 'plan', '--to', '3.47.4', '--no-env', //
      '--accept-all', '--format', 'json',
    ]);
    final result = json.json['result']! as Map<String, Object?>;
    expect((result['summary']! as Map)['complete'], isTrue);
    expect((result['target']! as Map)['flutter'], '3.47.4');
    final steps = result['steps']! as List;
    expect((steps.first as Map)['files'], isNotEmpty);
  });

  test('plan validates targets and recipe ids', () async {
    final missing = await runCli(['-C', project.path, 'plan', '--no-env']);
    expect(missing.exitCode, ExitCodes.usage);
    expect(missing.stderr, contains('TARGET_REQUIRED'));

    final unknown =
        await runCli(['-C', project.path, 'plan', '--to', '9.0', '--no-env']);
    expect(unknown.exitCode, ExitCodes.unsupported);

    final recipe = await runCli([
      '-C', project.path, 'plan', '--to', '3.47', '--no-env', //
      '--accept', 'NOT_A_RECIPE',
    ]);
    expect(recipe.exitCode, ExitCodes.usage);
  });

  test('apply refuses incomplete plans and requires confirmation', () async {
    final incomplete = await runCli(
        ['-C', project.path, 'apply', '--to', '3.47.4', '--no-env', '--yes']);
    expect(incomplete.exitCode, ExitCodes.migrationBlocked);
    expect(incomplete.stderr, contains('PLAN_INCOMPLETE'));

    final unconfirmed = await runCli([
      '-C',
      project.path,
      'apply',
      '--to',
      '3.47.4',
      '--accept-all',
      '--no-env'
    ]);
    expect(unconfirmed.exitCode, ExitCodes.usage);
    expect(unconfirmed.stderr, contains('CONFIRMATION_REQUIRED'));
    expect(Directory(p.join(project.path, '.reforge')).existsSync(), isFalse);
  });

  test('apply, history, static verify and rollback round-trip', () async {
    final original = snapshot(project.path);
    final applied = await runCli([
      '-C', project.path, 'apply', '--to', '3.47.4', '--accept-all', //
      '--yes', '--no-env',
    ]);
    expect(applied.exitCode, ExitCodes.success, reason: applied.stderr);
    expect(applied.stdout, contains('Applied 9 file change(s)'));
    expect(snapshot(project.path), isNot(original));

    final history =
        await runCli(['-C', project.path, 'history', '--format', 'json']);
    final sessions = (history.json['result']! as Map)['sessions']! as List;
    expect(sessions, hasLength(1));
    expect((sessions.single as Map)['status'], 'applied');

    final verified = await runCli([
      '-C',
      project.path,
      'verify',
      '--check',
      'static',
      '--format',
      'json'
    ]);
    expect(verified.exitCode, ExitCodes.success, reason: verified.stdout);
    final verification = verified.json['result']! as Map<String, Object?>;
    expect(verification['passed'], isTrue);
    expect(verification['evidenceForTarget'], isFalse,
        reason: 'The fake environment runs Flutter 3.44.0.');

    final again = await runCli([
      '-C', project.path, 'apply', '--to', '3.47.4', '--accept-all', //
      '--yes', '--no-env',
    ]);
    expect(again.exitCode, ExitCodes.success);
    expect(again.stdout, contains('Nothing to apply'));

    final rolledBack = await runCli(['-C', project.path, 'rollback']);
    expect(rolledBack.exitCode, ExitCodes.success, reason: rolledBack.stderr);
    expect(snapshot(project.path), original);

    final nothing = await runCli(['-C', project.path, 'rollback']);
    expect(nothing.exitCode, ExitCodes.journal);
  });

  test('apply with a reviewed plan file detects changes since review',
      () async {
    final planFile =
        p.join(project.path, '..', '${p.basename(project.path)}-plan.json');
    addTearDown(() {
      if (File(planFile).existsSync()) File(planFile).deleteSync();
    });
    final planned = await runCli([
      '-C', project.path, 'plan', '--to', '3.47.4', '--accept-all', //
      '--no-env', '--out', planFile,
    ]);
    expect(planned.exitCode, ExitCodes.success);

    File(p.join(project.path, 'android', 'gradle.properties'))
        .writeAsStringSync('org.gradle.caching=true\n', mode: FileMode.append);
    final stale = await runCli([
      '-C', project.path, 'apply', '--to', '3.47.4', '--accept-all', //
      '--yes', '--no-env', '--plan', planFile,
    ]);
    expect(stale.exitCode, ExitCodes.migrationBlocked);
    expect(stale.stderr, contains('PLAN_CHANGED'));
  });
}
