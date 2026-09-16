import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge_core/reforge_core.dart';
import 'package:test/test.dart';

import '../support/fixtures.dart';

/// Output of a real `flutter build apk --debug` (Flutter 3.44.0) on a Flutter
/// 3.3 project migrated with Reforge.
const realBuildOutput = '''
Running Gradle task 'assembleDebug'...
WARNING: Your Android app project: app located at: /tmp/app/android/app/build.gradle
applies the Kotlin Gradle Plugin, which will cause build failures in future versions of Flutter.
lib/main.dart:103:50: Error: The getter 'headline4' isn't defined for the type 'TextTheme'.
 - 'TextTheme' is from 'package:flutter/src/material/text_theme.dart'.
Try correcting the name to the name of an existing getter, or defining a getter or field named 'headline4'.
              style: Theme.of(context).textTheme.headline4,
                                                 ^^^^^^^^^
Target kernel_snapshot_program failed: Exception

FAILURE: Build failed with an exception.

* What went wrong:
Execution failed for task ':app:compileFlutterBuildDebug'.
> Process 'command '/opt/flutter/bin/flutter'' finished with non-zero exit value 1
''';

final class ScriptedRunner implements ProcessRunner {
  ScriptedRunner(this.handler);

  final CommandResult Function(ExternalCommand command) handler;

  @override
  Future<CommandResult> run(ExternalCommand command,
          {void Function(String line)? onOutput}) async =>
      handler(command);
}

void main() {
  group('failure signatures', () {
    test('explain the real build failure', () {
      final diagnoses = diagnoseFailure(realBuildOutput);
      final dart =
          diagnoses.singleWhere((d) => d.id == 'DART_COMPILATION_ERROR');
      expect(dart.explanation, contains('lib/main.dart:103'));
      expect(dart.suggestion, contains('dart fix --apply'));
      expect(failingGradleModule(realBuildOutput), ':app');
    });

    test('recognize toolchain failures', () {
      expect(
          diagnoseFailure('> Unsupported class file major version 65')
              .single
              .explanation,
          contains('Java 21'));
      expect(
          diagnoseFailure(
                  "Error: Your project's Gradle version (7.5) is lower than Flutter's minimum supported version of 8.14.0. Please upgrade")
              .single
              .relatedRecipes,
          [RecipeIds.androidGradleWrapper]);
      expect(
          diagnoseFailure(
                  'Minimum supported Gradle version is 8.13. Current version is 8.7.')
              .single
              .id,
          'GRADLE_TOO_OLD_FOR_AGP');
      expect(
          diagnoseFailure('Namespace not specified. Specify a namespace')
              .single
              .id,
          'ANDROID_NAMESPACE_MISSING');
      expect(
          failingGradleModule(
              "Execution failed for task ':camera_android:compileDebugKotlin'."),
          ':camera_android');
      expect(diagnoseFailure('BUILD SUCCESSFUL'), isEmpty);
    });
  });

  group('tool checks', () {
    late Directory project;
    setUp(() => project = copyFixtureToTemp('flutter_3_44_app'));
    tearDown(() => project.deleteSync(recursive: true));

    Verifier verifier(ProcessRunner runner, {String os = 'macos'}) => Verifier(
          projectRoot: project.path,
          knowledge: KnowledgeBase.bundled,
          planner: MigrationPlanner(
            knowledge: KnowledgeBase.bundled,
            recipes: builtInRecipes(),
            reforgeVersion: reforgeVersion,
          ),
          runner: runner,
          operatingSystem: os,
        );

    test('reports configuration files modified by the tool', () async {
      final runner = ScriptedRunner((command) {
        File(p.join(project.path, 'android', 'gradle.properties'))
            .writeAsStringSync('# added by the tool\n', mode: FileMode.append);
        return CommandResult(
            command: command,
            exitCode: 0,
            stdout: 'BUILD SUCCESSFUL',
            stderr: '',
            elapsed: const Duration(seconds: 3));
      });
      final result = await verifier(runner).runToolCheck(
        VerificationCheck.androidBuild,
        flutterExecutable: 'flutter',
        logDirectory: p.join(project.path, '.reforge', 'logs'),
      );
      expect(result.status, CheckStatus.passed);
      expect(result.modifiedFiles, ['android/gradle.properties']);
      expect(File(result.logFile!).readAsStringSync(),
          contains('flutter build apk --debug'));
    });

    test('diagnoses failures and skips iOS builds off macOS', () async {
      final runner = ScriptedRunner((command) => CommandResult(
          command: command,
          exitCode: 1,
          stdout: realBuildOutput,
          stderr: '',
          elapsed: const Duration(seconds: 20)));
      final failed = await verifier(runner).runToolCheck(
        VerificationCheck.androidBuild,
        flutterExecutable: 'flutter',
        logDirectory: p.join(project.path, '.reforge', 'logs'),
      );
      expect(failed.status, CheckStatus.failed);
      expect(failed.failingModule, ':app');
      expect(failed.diagnoses.map((d) => d.id),
          contains('DART_COMPILATION_ERROR'));

      final skipped = await verifier(runner, os: 'linux').runToolCheck(
        VerificationCheck.iosBuild,
        flutterExecutable: 'flutter',
        logDirectory: p.join(project.path, '.reforge', 'logs'),
      );
      expect(skipped.status, CheckStatus.skipped);
      expect(skipped.summary, contains('require macOS'));
    });
  });
}
