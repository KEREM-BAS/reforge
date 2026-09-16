import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge_core/reforge_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

MigrationPlan planProject(String root, {String target = '3.47.4'}) {
  final knowledge = KnowledgeBase.bundled;
  return MigrationPlanner(
    knowledge: knowledge,
    recipes: builtInRecipes(),
    reforgeVersion: reforgeVersion,
  ).plan(
    files: LocalProjectFileSystem(root),
    target: knowledge.resolveFlutterVersion(target),
    options: const PlanOptions(acceptAllReviews: true),
  );
}

Map<String, String> snapshot(String root) => {
      for (final file in Directory(root)
          .listSync(recursive: true)
          .whereType<File>()
          .where(
              (f) => !f.path.contains('${p.separator}.reforge${p.separator}')))
        p.relative(file.path, from: root): file.readAsStringSync(),
    };

void main() {
  late Directory project;

  setUp(() => project = copyFixtureToTemp('flutter_3_3_app'));
  tearDown(() => project.deleteSync(recursive: true));

  test('applies a plan, journals it, and rolls it back exactly', () {
    final original = snapshot(project.path);
    final plan = planProject(project.path);
    final applier = MigrationApplier(projectRoot: project.path);

    final session = applier.apply(plan);
    expect(session.status, SessionStatus.applied);
    expect(session.files, hasLength(plan.fileChanges.length));
    for (final change in plan.fileChanges) {
      expect(File(p.join(project.path, change.path)).readAsStringSync(),
          change.after);
    }
    expect(
        File(p.join(project.path, '.reforge', '.gitignore')).readAsStringSync(),
        contains('*'));
    expect(Journal(project.path).find(session.id).planId, plan.id);
    expect(
        File(p.join(project.path, '.reforge', 'lock')).existsSync(), isFalse);

    // Re-planning the migrated project applies nothing.
    final again = planProject(project.path);
    expect(again.fileChanges, isEmpty);

    final rolledBack = applier.rollback();
    expect(rolledBack.status, SessionStatus.rolledBack);
    expect(snapshot(project.path), original);
  });

  test('refuses a stale plan', () {
    final plan = planProject(project.path);
    File(p.join(project.path, 'android', 'build.gradle'))
        .writeAsStringSync('// edited after planning\n', mode: FileMode.append);
    expect(
      () => MigrationApplier(projectRoot: project.path).apply(plan),
      throwsA(isA<MigrationBlockedException>()
          .having((e) => e.code, 'code', 'STALE_PLAN')),
    );
    expect(Directory(p.join(project.path, '.reforge', 'sessions')).listSync(),
        isEmpty);
  });

  test('restores written files when a write fails mid-way', () {
    final original = snapshot(project.path);
    final plan = planProject(project.path);
    var writes = 0;
    final applier = MigrationApplier(
      projectRoot: project.path,
      writer: (path, content) {
        if (++writes == 3) throw const FileSystemException('disk full');
        writeFileAtomically(path, content);
      },
    );
    expect(
      () => applier.apply(plan),
      throwsA(isA<MigrationFailedException>()
          .having((e) => e.restored, 'restored', isTrue)),
    );
    expect(snapshot(project.path), original);
    final session = Journal(project.path).sessions().single;
    expect(session.status, SessionStatus.failed);
    expect(session.failure, contains('disk full'));
  });

  test('rollback refuses to overwrite later edits unless forced', () {
    final plan = planProject(project.path);
    final applier = MigrationApplier(projectRoot: project.path);
    applier.apply(plan);
    final edited = File(p.join(project.path, 'android', 'settings.gradle'));
    edited.writeAsStringSync('${edited.readAsStringSync()}// my change\n');

    expect(
      applier.rollback,
      throwsA(isA<JournalException>()
          .having((e) => e.code, 'code', 'ROLLBACK_CONFLICT')
          .having((e) => e.message, 'message', contains('settings.gradle'))),
    );
    final session = applier.rollback(force: true);
    expect(session.status, SessionStatus.rolledBack);
    expect(edited.readAsStringSync(), isNot(contains('my change')));
  });

  test('a concurrent run is locked out', () {
    final plan = planProject(project.path);
    final lock = File(p.join(project.path, '.reforge', 'lock'))
      ..createSync(recursive: true);
    expect(
      () => MigrationApplier(projectRoot: project.path).apply(plan),
      throwsA(isA<MigrationBlockedException>()
          .having((e) => e.code, 'code', 'PROJECT_LOCKED')),
    );
    expect(lock.existsSync(), isTrue);
  });

  test('git status reports changed project paths', () async {
    Future<void> git(List<String> args) async {
      final result =
          await Process.run('git', args, workingDirectory: project.path);
      expect(result.exitCode, 0, reason: '${result.stderr}');
    }

    await git(['init', '-q']);
    await git(
        ['-c', 'user.email=t@example.com', '-c', 'user.name=t', 'add', '.']);
    await git([
      '-c',
      'user.email=t@example.com',
      '-c',
      'user.name=t',
      'commit',
      '-q',
      '-m',
      'init'
    ]);
    File(p.join(project.path, 'android', 'build.gradle'))
        .writeAsStringSync('// dirty\n', mode: FileMode.append);
    File(p.join(project.path, 'new file.txt')).writeAsStringSync('x');

    final tree =
        await readGitWorkingTree(project.path, const LocalProcessRunner());
    expect(tree, isNotNull);
    expect(tree!.changedPaths, {'android/build.gradle', 'new file.txt'});

    final outside = Directory.systemTemp.createTempSync('reforge_no_git');
    addTearDown(() => outside.deleteSync(recursive: true));
    expect(await readGitWorkingTree(outside.path, const LocalProcessRunner()),
        isNull);
  });
}
