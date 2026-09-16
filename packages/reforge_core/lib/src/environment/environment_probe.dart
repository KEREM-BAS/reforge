import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'environment.dart';
import 'process_runner.dart';

/// Observes the local toolchain.
///
/// The probe runs well-known tools (`flutter`, `java`, `xcodebuild`, `pod`,
/// `git`) with version flags only. It never executes project code.
final class EnvironmentProbe {
  EnvironmentProbe({
    ProcessRunner? runner,
    Map<String, String>? environment,
    String? operatingSystem,
    bool Function(String path)? fileExists,
    String? Function(String path)? readFile,
  })  : _runner = runner ?? const LocalProcessRunner(),
        _environment = environment ?? Platform.environment,
        _os = operatingSystem ?? Platform.operatingSystem,
        _fileExists = fileExists ?? ((path) => File(path).existsSync()),
        _readFile = readFile ?? _readLocalFile;

  final ProcessRunner _runner;
  final Map<String, String> _environment;
  final String _os;
  final bool Function(String path) _fileExists;
  final String? Function(String path) _readFile;

  static String? _readLocalFile(String path) {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  Future<Environment> probe({String? flutterExecutable}) async {
    final flutterFuture = _probeFlutter(flutterExecutable ?? 'flutter');
    final javaFuture = _probeJava();
    final xcodeFuture = _os == 'macos'
        ? _probeTool('Xcode', 'xcodebuild', const ['-version'],
            RegExp(r'Xcode\s+([\d.]+)'))
        : Future<ToolInfo?>.value();
    final podFuture = _os == 'macos'
        ? _probeTool('CocoaPods', 'pod', const ['--version'],
            RegExp(r'^(\d+\.\d+(?:\.\d+)?)\s*$', multiLine: true))
        : Future<ToolInfo?>.value();
    final gitFuture = _probeTool(
        'Git', 'git', const ['--version'], RegExp(r'git version (\S+)'));

    final flutter = await flutterFuture;
    return Environment(
      operatingSystem: _os,
      operatingSystemVersion: Platform.operatingSystemVersion,
      flutter: flutter.$1,
      flutterError: flutter.$2,
      javaCandidates: await javaFuture,
      xcode: await xcodeFuture,
      cocoapods: await podFuture,
      git: await gitFuture,
    );
  }

  Future<(FlutterSdkInfo?, String?)> _probeFlutter(String executable) async {
    final result = await _runner.run(ExternalCommand(
      executable,
      const ['--version', '--machine'],
      environment: const {'FLUTTER_SUPPRESS_ANALYTICS': 'true'},
      timeout: const Duration(minutes: 3),
    ));
    if (!result.succeeded) {
      return (
        null,
        result.startError ??
            (result.timedOut
                ? 'flutter --version timed out.'
                : 'flutter --version exited with ${result.exitCode}.')
      );
    }
    final start = result.stdout.indexOf('{');
    final end = result.stdout.lastIndexOf('}');
    if (start == -1 || end < start) {
      return (null, 'Unexpected output from flutter --version --machine.');
    }
    try {
      final json = jsonDecode(result.stdout.substring(start, end + 1))
          as Map<String, Object?>;
      Version? version(Object? value) {
        if (value is! String) return null;
        try {
          return Version.parse(value.split(' ').first);
        } on FormatException {
          return null;
        }
      }

      return (
        FlutterSdkInfo(
          version: version(json['frameworkVersion'] ?? json['flutterVersion']),
          channel: json['channel'] as String?,
          frameworkRevision: json['frameworkRevision'] as String?,
          dartVersion: version(json['dartSdkVersion']),
          root: json['flutterRoot'] as String?,
        ),
        null
      );
    } on FormatException catch (e) {
      return (null, 'Could not parse flutter --version output: ${e.message}');
    }
  }

  Future<ToolInfo?> _probeTool(String name, String executable,
      List<String> arguments, RegExp versionPattern) async {
    final result = await _runner.run(ExternalCommand(
      executable,
      arguments,
      environment: const {'LANG': 'en_US.UTF-8'},
      timeout: const Duration(seconds: 30),
    ));
    if (result.startError != null) {
      return ToolInfo(name, error: result.startError);
    }
    final output = '${result.stdout}\n${result.stderr}';
    final match = versionPattern.firstMatch(output);
    if (!result.succeeded || match == null) {
      return ToolInfo(name,
          error:
              'Could not determine the version (exit code ${result.exitCode}).');
    }
    return ToolInfo(name, version: match.group(1));
  }

  /// JDK candidates in the order the Flutter tool considers them.
  Future<List<JavaInstallation>> _probeJava() async {
    final candidates = <(JavaSource, String?, String)>[];
    final javaBinary = _os == 'windows' ? 'java.exe' : 'java';

    final configured = _configuredJdkDir();
    if (configured != null) {
      candidates.add((
        JavaSource.flutterConfig,
        configured,
        p.join(configured, 'bin', javaBinary)
      ));
    }
    for (final home in _androidStudioJavaHomes()) {
      final executable = p.join(home, 'bin', javaBinary);
      if (_fileExists(executable)) {
        candidates.add((JavaSource.androidStudio, home, executable));
        break;
      }
    }
    final javaHome = _environment['JAVA_HOME'];
    if (javaHome != null && javaHome.isNotEmpty) {
      candidates.add(
          (JavaSource.javaHome, javaHome, p.join(javaHome, 'bin', javaBinary)));
    }
    final onPath = LocalProcessRunner.resolveExecutable(
      'java',
      environment: _environment,
      windows: _os == 'windows',
      fileExists: _fileExists,
    );
    if (onPath != null) {
      candidates.add((JavaSource.path, null, onPath));
    }

    return Future.wait([
      for (final (source, home, executable) in candidates)
        _javaVersion(source, home, executable),
    ]);
  }

  Future<JavaInstallation> _javaVersion(
      JavaSource source, String? home, String executable) async {
    final result = await _runner.run(ExternalCommand(
        executable, const ['-version'],
        timeout: const Duration(seconds: 30)));
    if (!result.succeeded) {
      return JavaInstallation(
        source: source,
        home: home,
        executable: executable,
        error: result.startError ??
            '"$executable -version" exited with ${result.exitCode}.',
      );
    }
    final output = '${result.stderr}\n${result.stdout}';
    final match = RegExp(r'version "([^"]+)"').firstMatch(output);
    final version = match?.group(1);
    return JavaInstallation(
      source: source,
      home: home,
      executable: executable,
      version: version,
      majorVersion: version == null ? null : parseJavaMajorVersion(version),
      error: version == null ? 'Unrecognized java -version output.' : null,
    );
  }

  /// `jdk-dir` from the Flutter tool's settings file. Only this key is read.
  String? _configuredJdkDir() {
    final String settingsPath;
    if (_os == 'windows') {
      final appData = _environment['APPDATA'];
      if (appData == null) return null;
      settingsPath = p.join(appData, '.flutter_settings');
    } else {
      final home = _environment['HOME'];
      if (home == null) return null;
      final legacy = p.join(home, '.flutter_settings');
      settingsPath = _fileExists(legacy)
          ? legacy
          : p.join(
              _environment['XDG_CONFIG_HOME'] ??
                  p.join(home, '.config', 'flutter'),
              'settings');
    }
    final content = _readFile(settingsPath);
    if (content == null) return null;
    try {
      final json = jsonDecode(content);
      final value = json is Map ? json['jdk-dir'] : null;
      return value is String && value.isNotEmpty ? value : null;
    } on FormatException {
      return null;
    }
  }

  List<String> _androidStudioJavaHomes() {
    final home = _environment['HOME'] ?? '';
    switch (_os) {
      case 'macos':
        final apps = [
          '/Applications/Android Studio.app',
          p.join(home, 'Applications', 'Android Studio.app'),
        ];
        return [
          for (final app in apps) ...[
            p.join(app, 'Contents', 'jbr', 'Contents', 'Home'),
            p.join(app, 'Contents', 'jre', 'Contents', 'Home'),
            p.join(app, 'Contents', 'jre', 'jdk', 'Contents', 'Home'),
          ],
        ];
      case 'linux':
        return [
          for (final base in [
            '/opt/android-studio',
            p.join(home, 'android-studio'),
            '/usr/local/android-studio',
            '/snap/android-studio/current/android-studio',
          ]) ...[
            p.join(base, 'jbr'),
            p.join(base, 'jre'),
          ],
        ];
      case 'windows':
        final programFiles =
            _environment['ProgramFiles'] ?? r'C:\Program Files';
        final localAppData = _environment['LOCALAPPDATA'];
        return [
          p.join(programFiles, 'Android', 'Android Studio', 'jbr'),
          p.join(programFiles, 'Android', 'Android Studio', 'jre'),
          if (localAppData != null)
            p.join(localAppData, 'Programs', 'Android Studio', 'jbr'),
        ];
      default:
        return const [];
    }
  }
}

/// Parses the major version from a `java -version` string: `1.8.0_481` is
/// Java 8, `17.0.10` is Java 17, `21` is Java 21.
int? parseJavaMajorVersion(String version) {
  final match = RegExp(r'^(\d+)(?:\.(\d+))?').firstMatch(version);
  if (match == null) return null;
  final first = int.parse(match.group(1)!);
  if (first == 1 && match.group(2) != null) return int.parse(match.group(2)!);
  return first;
}
