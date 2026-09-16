// Generates lib/src/knowledge/data/flutter_releases.g.dart.
//
// Facts are extracted from primary sources only:
//  * the Flutter release manifest (versions, revisions, Dart versions, dates)
//  * flutter/flutter sources at each stable release tag (Gradle/AGP/Kotlin/
//    Java/minSdk floors, template toolchain and gradle.properties, Android
//    defaults, iOS minimum, imperative Gradle apply behaviour)
//
// Usage:
//   curl -o /tmp/releases_macos.json \
//     https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json
//   dart run tool/generate_flutter_knowledge.dart \
//     --flutter <flutter git checkout with tags> \
//     --manifest /tmp/releases_macos.json
//
// Review the diff of the generated file before committing it.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:reforge_core/src/parsing/properties/properties_file.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('flutter', mandatory: true, help: 'Flutter git checkout.')
    ..addOption('manifest', mandatory: true, help: 'releases_*.json path.')
    ..addOption('out',
        defaultsTo: 'lib/src/knowledge/data/flutter_releases.g.dart')
    ..addOption('min-version', defaultsTo: '3.0.0');
  final args = parser.parse(arguments);
  final checkout = args['flutter'] as String;
  final minVersion = Version.parse(args['min-version'] as String);

  final manifest =
      jsonDecode(File(args['manifest'] as String).readAsStringSync())
          as Map<String, Object?>;
  final releases = <String, Map<String, Object?>>{};
  for (final release
      in (manifest['releases']! as List).cast<Map<String, Object?>>()) {
    if (release['channel'] != 'stable') continue;
    final version = release['version']! as String;
    final Version parsed;
    try {
      parsed = Version.parse(version);
    } on FormatException {
      continue;
    }
    if (parsed < minVersion || parsed.isPreRelease) continue;
    releases.putIfAbsent(version, () => release);
  }
  final versions = releases.keys.map(Version.parse).toList()..sort();

  final git = await _GitObjectReader.start(checkout);
  final records = <String>[];
  final warnings = <String>[];
  for (final version in versions) {
    final release = releases['$version']!;
    final tag = '$version';
    final gradleUtils = await git.read(
        tag, 'packages/flutter_tools/lib/src/android/gradle_utils.dart');
    if (gradleUtils == null) {
      warnings.add('Skipping $tag: tag not found in checkout.');
      continue;
    }
    final checker = await git.firstOf(tag, const [
      'packages/flutter_tools/gradle/src/main/kotlin/DependencyVersionChecker.kt',
      'packages/flutter_tools/gradle/src/main/kotlin_scripts/dependency_version_checker.gradle.kts',
      'packages/flutter_tools/gradle/src/main/kotlin/dependency_version_checker.gradle.kts',
    ]);
    String? floor(String name) {
      if (checker == null) return null;
      final pattern = RegExp(
          '(error|warn)${name}Version\\s*:\\s*\\w+\\s*=\\s*\\w+\\((\\d+),\\s*(\\d+),\\s*(\\d+)\\)');
      final values = <String, String>{};
      for (final match in pattern.allMatches(checker)) {
        values[match.group(1)!] =
            '${match.group(2)}.${match.group(3)}.${match.group(4)}';
      }
      if (values.length != 2) {
        warnings.add('$tag: could not read $name floors.');
        return null;
      }
      return '${values['error']}/${values['warn']}';
    }

    String? javaFloor() {
      if (checker == null) return null;
      final pattern = RegExp(
          r'(error|warn)JavaVersion\s*:\s*JavaVersion\s*=\s*JavaVersion\.VERSION_(\d+)(?:_(\d+))?');
      final values = <String, String>{};
      for (final match in pattern.allMatches(checker)) {
        final major = match.group(2)!;
        final minor = match.group(3);
        values[match.group(1)!] = major == '1' && minor != null ? minor : major;
      }
      return values.length == 2 ? '${values['error']}/${values['warn']}' : null;
    }

    String? minSdkFloor() {
      if (checker == null) return null;
      final pattern =
          RegExp(r'(error|warn)MinSdkVersion\s*:\s*Int\s*=\s*(\d+)');
      final values = <String, String>{
        for (final match in pattern.allMatches(checker))
          match.group(1)!: match.group(2)!,
      };
      return values.length == 2 ? '${values['error']}/${values['warn']}' : null;
    }

    String templateConstant(String name) {
      final match =
          RegExp("const (?:String )?$name = '([^']+)'").firstMatch(gradleUtils);
      if (match == null) throw StateError('$tag: $name not found.');
      return match.group(1)!;
    }

    final defaultsSource = await git.firstOf(tag, const [
      'packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt',
      'packages/flutter_tools/gradle/src/main/groovy/flutter.groovy',
      'packages/flutter_tools/gradle/flutter.gradle',
    ]);
    int sdkDefault(String name) {
      final match = RegExp('$name(?::\\s*Int)?\\s*=\\s*(\\d+)')
          .firstMatch(defaultsSource ?? '');
      if (match == null) throw StateError('$tag: default $name not found.');
      return int.parse(match.group(1)!);
    }

    final ndkMatch = RegExp(r'ndkVersion(?::\s*String)?\s*=\s*"([^"]+)"')
        .firstMatch(defaultsSource ?? '');
    if (ndkMatch == null) throw StateError('$tag: ndkVersion not found.');

    final flutterGradle =
        await git.read(tag, 'packages/flutter_tools/gradle/flutter.gradle') ??
            '';
    final ktsSettings = await git.read(tag,
        'packages/flutter_tools/templates/app/android.tmpl/settings.gradle.kts.tmpl');
    final groovySettings = ktsSettings != null
        ? null
        : await git.firstOf(tag, const [
            'packages/flutter_tools/templates/app_shared/android.tmpl/settings.gradle.tmpl',
            'packages/flutter_tools/templates/app_shared/android.tmpl/settings.gradle',
            'packages/flutter_tools/templates/app/android.tmpl/settings.gradle.tmpl',
          ]);
    final settings = ktsSettings ?? groovySettings ?? '';
    final declarative = settings.contains('dev.flutter.flutter-plugin-loader');
    final appBuild = await git.firstOf(tag, const [
      'packages/flutter_tools/templates/app/android-kotlin.tmpl/app/build.gradle.kts.tmpl',
      'packages/flutter_tools/templates/app_shared/android-kotlin.tmpl/app/build.gradle.tmpl',
      'packages/flutter_tools/templates/app/android-kotlin.tmpl/app/build.gradle.tmpl',
    ]);
    final gradlePropertiesTemplate = await git.firstOf(tag, const [
      'packages/flutter_tools/templates/app/android.tmpl/gradle.properties.tmpl',
      'packages/flutter_tools/templates/app_shared/android.tmpl/gradle.properties.tmpl',
    ]);
    if (gradlePropertiesTemplate == null) {
      throw StateError('$tag: gradle.properties template not found.');
    }
    if (gradlePropertiesTemplate.contains('{{')) {
      warnings.add('$tag: the gradle.properties template has placeholders.');
    }
    final templateProperties = {
      for (final entry in PropertiesFile.parse(
              'gradle.properties.tmpl', gradlePropertiesTemplate)
          .entries)
        entry.key: entry.value,
    };

    final String imperativeApply;
    // Match Flutter's own messages, not incidental code: the pre-3.16 plugin
    // implementation also throws GradleExceptions for unrelated reasons.
    if (flutterGradle.contains('which is not possible anymore')) {
      imperativeApply = 'removed';
    } else if (flutterGradle
        .contains('apply script method, which is deprecated')) {
      imperativeApply = 'deprecated';
    } else if (declarative) {
      imperativeApply = 'supportedAlongsideDeclarative';
    } else {
      imperativeApply = 'supported';
    }

    String iosMinimum() {
      return _iosFromDarwin ??
          _iosFromMigration ??
          (throw StateError('$tag: iOS minimum not found.'));
    }

    final darwin = await git.read(
        tag, 'packages/flutter_tools/lib/src/darwin/darwin.dart');
    _iosFromDarwin = null;
    if (darwin != null) {
      final match =
          RegExp(r'ios\s*=>\s*Version\((\d+),\s*(\d+)').firstMatch(darwin);
      if (match != null) _iosFromDarwin = '${match.group(1)}.${match.group(2)}';
    }
    final migration = await git.firstOf(tag, const [
      'packages/flutter_tools/lib/src/ios/migrations/ios_deployment_target_migration.dart',
      'packages/flutter_tools/lib/src/ios/migrations/deployment_target_migration.dart',
    ]);
    _iosFromMigration = null;
    if (migration != null) {
      final match = RegExp(
              r"deploymentTargetReplacement\s*=\s*'IPHONEOS_DEPLOYMENT_TARGET = ([\d.]+);'")
          .firstMatch(migration);
      if (match != null) _iosFromMigration = match.group(1);
    }
    if (_iosFromDarwin != null &&
        _iosFromMigration != null &&
        _iosFromDarwin != _iosFromMigration) {
      warnings.add(
          '$tag: darwin.dart says iOS $_iosFromDarwin, migration says $_iosFromMigration.');
    }

    final dart = (release['dart_sdk_version']! as String).split(' ').first;
    final date = (release['release_date']! as String).substring(0, 10);
    String quote(String? value) => value == null ? 'null' : "'$value'";

    records.add('''
  FlutterReleaseRecord(
    version: '$version',
    revision: '${release['hash']}',
    dart: '$dart',
    date: '$date',
    gradleFloor: ${quote(floor('Gradle'))},
    agpFloor: ${quote(floor('AGP'))},
    kotlinFloor: ${quote(floor('KGP'))},
    javaFloor: ${quote(javaFloor())},
    minSdkFloor: ${quote(minSdkFloor())},
    templateGradle: '${templateConstant('templateDefaultGradleVersion')}',
    templateAgp: '${templateConstant('templateAndroidGradlePluginVersion')}',
    templateKotlin: '${templateConstant('templateKotlinGradlePluginVersion')}',
    templateDsl: '${ktsSettings != null ? 'kotlin' : 'groovy'}',
    templateDeclarativePlugins: $declarative,
    templateNamespace: ${appBuild?.contains('namespace') ?? false},
    templateGradleProperties: {
${templateProperties.entries.map((e) => '      ${_dartString(e.key)}: ${_dartString(e.value)},\n').join()}    },
    compileSdk: ${sdkDefault('compileSdkVersion')},
    targetSdk: ${sdkDefault('targetSdkVersion')},
    minSdk: ${sdkDefault('minSdkVersion')},
    ndk: '${ndkMatch.group(1)}',
    imperativeApply: '$imperativeApply',
    iosMinimum: '${iosMinimum()}',
  ),''');
  }
  await git.close();

  final checkoutHead =
      Process.runSync('git', ['-C', checkout, 'rev-parse', 'HEAD'])
          .stdout
          .toString()
          .trim();
  final output = StringBuffer()
    ..writeln(
        '// GENERATED by tool/generate_flutter_knowledge.dart. Do not edit by hand.')
    ..writeln('//')
    ..writeln('// Sources:')
    ..writeln(
        '//  * https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json')
    ..writeln('//  * https://github.com/flutter/flutter at each release tag')
    ..writeln('//    (checkout HEAD $checkoutHead)')
    ..writeln()
    ..writeln("import 'flutter_release_record.dart';")
    ..writeln()
    ..writeln('/// Date the knowledge below was generated.')
    ..writeln(
        "const flutterKnowledgeGeneratedOn = '${DateTime.now().toUtc().toIso8601String().substring(0, 10)}';")
    ..writeln()
    ..writeln('/// Stable Flutter releases, ascending.')
    ..writeln('const flutterReleaseRecords = <FlutterReleaseRecord>[')
    ..writeAll(records, '\n')
    ..writeln()
    ..writeln('];');
  File(args['out'] as String).writeAsStringSync(output.toString());
  for (final warning in warnings) {
    stderr.writeln('warning: $warning');
  }
  stdout.writeln('Wrote ${records.length} releases to ${args['out']}.');
}

/// A single-quoted Dart string literal with the value of [value].
String _dartString(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$');
  return "'$escaped'";
}

String? _iosFromDarwin;
String? _iosFromMigration;

/// Reads blobs through a single `git cat-file --batch` process.
final class _GitObjectReader {
  _GitObjectReader(this._process) {
    _process.stdout.listen(_buffer.addAll, onDone: () => _done = true);
  }

  static Future<_GitObjectReader> start(String checkout) async {
    final process =
        await Process.start('git', ['-C', checkout, 'cat-file', '--batch']);
    return _GitObjectReader(process);
  }

  final Process _process;
  final List<int> _buffer = [];
  bool _done = false;

  Future<String?> read(String tag, String path) async {
    _process.stdin.writeln('$tag:$path');
    await _process.stdin.flush();
    final header = await _readLine();
    if (header.endsWith('missing') || header.endsWith('ambiguous')) return null;
    final size = int.parse(header.split(' ').last);
    final bytes = await _readBytes(size + 1); // content + trailing newline
    return utf8.decode(bytes.sublist(0, size));
  }

  Future<String?> firstOf(String tag, List<String> paths) async {
    for (final path in paths) {
      final content = await read(tag, path);
      if (content != null) return content;
    }
    return null;
  }

  Future<String> _readLine() async {
    while (true) {
      final newline = _buffer.indexOf(10);
      if (newline != -1) {
        final line = utf8.decode(_buffer.sublist(0, newline));
        _buffer.removeRange(0, newline + 1);
        return line;
      }
      if (_done) throw StateError('git cat-file ended unexpectedly.');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  }

  Future<List<int>> _readBytes(int count) async {
    while (_buffer.length < count) {
      if (_done) throw StateError('git cat-file ended unexpectedly.');
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
    final bytes = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return bytes;
  }

  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode;
  }
}
