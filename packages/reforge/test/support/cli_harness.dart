import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge/reforge.dart';
import 'package:reforge_core/reforge_core.dart';

/// The Reforge repository root.
String repositoryRoot() {
  var directory = Directory.current.absolute;
  while (
      !Directory(p.join(directory.path, 'fixtures', 'projects')).existsSync()) {
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Could not locate the Reforge repository root.');
    }
    directory = parent;
  }
  return directory.path;
}

String fixtureProject(String name) =>
    p.join(repositoryRoot(), 'fixtures', 'projects', name);

/// Copies a fixture project into a temporary directory.
Directory copyFixture(String name) {
  final target = Directory.systemTemp.createTempSync('reforge_cli_$name');
  final source = Directory(fixtureProject(name));
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final destination = p.join(target.path, relative);
    if (entity is Directory) {
      Directory(destination).createSync(recursive: true);
    } else if (entity is File) {
      File(destination).parent.createSync(recursive: true);
      entity.copySync(destination);
    }
  }
  return target;
}

Environment fakeEnvironment({String flutter = '3.44.0', int java = 21}) =>
    Environment(
      operatingSystem: 'macos',
      operatingSystemVersion: '26.5',
      flutter: FlutterSdkInfo(
        version: Version.parse(flutter),
        channel: 'stable',
        frameworkRevision: null,
        dartVersion: Version.parse('3.12.0'),
        root: '/opt/flutter',
      ),
      flutterError: null,
      javaCandidates: [
        JavaInstallation(
          source: JavaSource.androidStudio,
          home: '/studio/jbr',
          executable: '/studio/jbr/bin/java',
          version: '$java.0.6',
          majorVersion: java,
        ),
      ],
      xcode: const ToolInfo('Xcode', version: '26.5'),
      cocoapods: const ToolInfo('CocoaPods', version: '1.16.2'),
      git: const ToolInfo('Git', version: '2.50.1'),
    );

final class CliRun {
  CliRun(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  Map<String, Object?> get json => jsonDecode(stdout) as Map<String, Object?>;
}

Future<CliRun> runCli(List<String> arguments,
    {Environment? environment,
    String? workingDirectory,
    ProcessRunner? processRunner,
    DateTime Function()? clock}) async {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = await runReforge(
    arguments,
    context: CliContext(
      out: out,
      err: err,
      workingDirectory: workingDirectory ?? repositoryRoot(),
      color: false,
      probeEnvironment: () async => environment ?? fakeEnvironment(),
      processRunner: processRunner,
      clock: clock,
    ),
  );
  return CliRun(code, out.toString(), err.toString());
}
