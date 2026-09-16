import 'package:reforge_core/src/environment/environment.dart';
import 'package:reforge_core/src/environment/environment_probe.dart';
import 'package:reforge_core/src/environment/process_runner.dart';
import 'package:test/test.dart';

/// Answers commands from a table instead of running processes.
final class FakeRunner implements ProcessRunner {
  FakeRunner(this.responses);

  final Map<String, CommandResult Function(ExternalCommand)> responses;
  final List<String> invoked = [];

  @override
  Future<CommandResult> run(ExternalCommand command,
      {void Function(String line)? onOutput}) async {
    invoked.add(command.display);
    for (final entry in responses.entries) {
      if (command.display.startsWith(entry.key)) return entry.value(command);
    }
    return CommandResult(
      command: command,
      exitCode: -1,
      stdout: '',
      stderr: '',
      elapsed: Duration.zero,
      startError: 'not found',
    );
  }
}

CommandResult ok(ExternalCommand command,
        {String stdout = '', String stderr = ''}) =>
    CommandResult(
      command: command,
      exitCode: 0,
      stdout: stdout,
      stderr: stderr,
      elapsed: Duration.zero,
    );

void main() {
  test('parses Java major versions', () {
    expect(parseJavaMajorVersion('1.8.0_481'), 8);
    expect(parseJavaMajorVersion('17.0.10'), 17);
    expect(parseJavaMajorVersion('21'), 21);
    expect(parseJavaMajorVersion('garbage'), isNull);
  });

  test('mirrors Flutter JDK selection and parses tool versions', () async {
    const studioJava =
        '/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/java';
    final runner = FakeRunner({
      'flutter --version --machine': (c) => ok(c, stdout: '''
Waiting for another flutter command to release the startup lock...
{
  "frameworkVersion": "3.44.0",
  "channel": "stable",
  "frameworkRevision": "559ffa3f75e7402d65a8def9c28389a9b2e6fe42",
  "dartSdkVersion": "3.12.0",
  "flutterRoot": "/opt/flutter"
}'''),
      '"$studioJava" -version': (c) =>
          ok(c, stderr: 'openjdk version "21.0.6" 2025-01-21\nOpenJDK Runtime'),
      '/jdks/17/bin/java -version': (c) =>
          ok(c, stderr: 'openjdk version "17.0.12" 2024-07-16'),
      'xcodebuild -version': (c) =>
          ok(c, stdout: 'Xcode 26.5\nBuild version 17F42\n'),
      'pod --version': (c) => ok(c,
          stdout:
              'WARNING: CocoaPods requires your terminal to be using UTF-8 encoding.\n1.16.2\n'),
      'git --version': (c) => ok(c, stdout: 'git version 2.50.1\n'),
    });
    final probe = EnvironmentProbe(
      runner: runner,
      operatingSystem: 'macos',
      environment: const {'HOME': '/Users/dev', 'JAVA_HOME': '/jdks/17'},
      fileExists: (path) => path == studioJava,
      readFile: (path) => null,
    );
    final environment = await probe.probe();
    expect(environment.flutter!.version.toString(), '3.44.0');
    expect(environment.flutter!.dartVersion.toString(), '3.12.0');
    expect(environment.javaCandidates.map((c) => c.source),
        [JavaSource.androidStudio, JavaSource.javaHome]);
    expect(environment.javaForFlutter!.majorVersion, 21);
    expect(environment.xcode!.version, '26.5');
    expect(environment.cocoapods!.version, '1.16.2');
    expect(environment.git!.version, '2.50.1');
  });

  test('flutter config jdk-dir wins, and only that key is read', () async {
    final runner = FakeRunner({
      '/custom/jdk/bin/java -version': (c) =>
          ok(c, stderr: 'openjdk version "17.0.1"'),
    });
    final environment = await EnvironmentProbe(
      runner: runner,
      operatingSystem: 'linux',
      environment: const {'HOME': '/home/dev'},
      fileExists: (path) => false,
      readFile: (path) => path == '/home/dev/.config/flutter/settings'
          ? '{"jdk-dir": "/custom/jdk", "ios-signing-cert": "secret"}'
          : null,
    ).probe();
    expect(environment.javaForFlutter!.source, JavaSource.flutterConfig);
    expect(environment.toJson().toString(), isNot(contains('secret')));
    expect(environment.flutter, isNull);
    expect(environment.flutterError, contains('not found'));
    expect(environment.xcode, isNull);
  });
}
