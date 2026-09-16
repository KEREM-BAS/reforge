// Generates lib/src/knowledge/data/flutter_releases.g.dart.
//
// Facts are extracted from primary sources only:
//  * the Flutter release manifest (versions, revisions, Dart versions, dates)
//  * flutter/flutter sources at each stable release tag (Gradle/AGP/Kotlin/
//    Java/minSdk floors, template toolchain and gradle.properties, Android
//    defaults, Android build migrations, iOS and macOS minimums, Xcode and
//    CocoaPods requirements, imperative Gradle apply behaviour)
//  * the AAR metadata (minCompileSdk) of the AndroidX libraries the Android
//    embedding depends on, read from the local Gradle cache (Flutter 3.29+,
//    whose engine sources are part of flutter/flutter)
//
// Usage:
//   curl -o /tmp/releases_macos.json \
//     https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json
//   dart run tool/generate_flutter_knowledge.dart \
//     --flutter <flutter git checkout with tags> \
//     --manifest /tmp/releases_macos.json \
//     [--gradle-cache ~/.gradle/caches/modules-2/files-2.1] [--download-aars]
//
// The AndroidX AARs are in the Gradle cache after building any app with the
// release. --download-aars fetches the missing ones from Google's Maven
// repository instead; otherwise the generator lists them.
//
// The output file is only rewritten when the knowledge changed, so its
// generation date says when Flutter's releases last changed it.
//
// Review the diff of the generated file before committing it.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:reforge_core/src/parsing/properties/properties_file.dart';

import 'src/generated_file.dart';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('flutter', mandatory: true, help: 'Flutter git checkout.')
    ..addOption('manifest', mandatory: true, help: 'releases_*.json path.')
    ..addOption('out',
        defaultsTo: 'lib/src/knowledge/data/flutter_releases.g.dart')
    ..addOption('min-version', defaultsTo: '3.0.0')
    ..addOption('gradle-cache',
        defaultsTo: '${Platform.environment['HOME']}/.gradle/caches/modules-2/'
            'files-2.1',
        help: 'Gradle module cache holding the AndroidX AARs.')
    ..addFlag('download-aars',
        help: 'Download AndroidX AARs missing from the Gradle cache from '
            '--maven-repository into --aar-cache.')
    ..addOption('maven-repository',
        defaultsTo: 'https://dl.google.com/android/maven2',
        help: 'Maven repository to download AndroidX AARs from.')
    ..addOption('aar-cache',
        defaultsTo: '${Directory.systemTemp.path}/reforge_aars',
        help: 'Directory for downloaded AARs.');
  final args = parser.parse(arguments);
  final checkout = args['flutter'] as String;
  final minVersion = Version.parse(args['min-version'] as String);

  final manifest =
      jsonDecode(File(args['manifest'] as String).readAsStringSync())
          as Map<String, Object?>;
  final releases = <String, Map<String, Object?>>{};
  // Releases before --min-version are only identified (version, revision).
  final older = <String, Map<String, Object?>>{};
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
    if (parsed.isPreRelease) continue;
    if (parsed < minVersion) {
      older.putIfAbsent(version, () => release);
      continue;
    }
    releases.putIfAbsent(version, () => release);
  }
  final versions = releases.keys.map(Version.parse).toList()..sort();

  final git = await _GitObjectReader.start(checkout);
  final aars = _AarSource(
    gradleCache: args['gradle-cache'] as String,
    downloadCache: args['aar-cache'] as String,
    repository: args['download-aars'] as bool
        ? args['maven-repository'] as String
        : null,
  );
  final missingAars = <String>{};
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

    // Whether Flutter's Gradle plugin applies the Kotlin Gradle plugin to app
    // and plugin modules that do not apply it (while built-in Kotlin is off).
    final pluginUtils = await git.read(tag,
            'packages/flutter_tools/gradle/src/main/kotlin/FlutterPluginUtils.kt') ??
        '';
    final appliesKotlinPlugin =
        pluginUtils.contains('pluginManager.apply("kotlin-android")');
    final templateAppKotlinPlugin = appBuild != null &&
        RegExp(r'''(['"])(kotlin-android|org\.jetbrains\.kotlin\.android)\1''')
            .hasMatch(appBuild);

    // Project migrations the tool runs before every Android Gradle build.
    final gradleDart = await git.read(
            tag, 'packages/flutter_tools/lib/src/android/gradle.dart') ??
        '';
    final migratorsStart = gradleDart.indexOf('<ProjectMigrator>[');
    final androidMigrations = migratorsStart == -1
        ? const <String>[]
        : [
            for (final match in RegExp(r'\b(\w+Migration)\(').allMatches(
                gradleDart.substring(
                    migratorsStart, gradleDart.indexOf('];', migratorsStart))))
              match.group(1)!,
          ];

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

    // Minimum deployment targets. darwin.dart (3.44+) declares them; the
    // deployment target migrations rewrite older values to them; before
    // Flutter had a macOS migration (3.7), the app template's value applies.
    final darwin = await git.read(
        tag, 'packages/flutter_tools/lib/src/darwin/darwin.dart');
    String? fromDarwin(String platform) {
      final match = darwin == null
          ? null
          : RegExp('\\b$platform\\s*=>\\s*Version\\((\\d+),\\s*(\\d+)')
              .firstMatch(darwin);
      return match == null ? null : '${match.group(1)}.${match.group(2)}';
    }

    Future<String?> fromMigration(List<String> paths, String setting) async {
      final migration = await git.firstOf(tag, paths);
      if (migration == null) return null;
      return RegExp(
              "deploymentTargetReplacement\\s*=\\s*'$setting = ([\\d.]+);'")
          .firstMatch(migration)
          ?.group(1);
    }

    Future<String?> fromTemplate(List<String> paths, String setting) async {
      final template = await git.firstOf(tag, paths);
      if (template == null) return null;
      final values = {
        for (final match
            in RegExp('$setting = ([\\d.]+);').allMatches(template))
          match.group(1)!,
      };
      if (values.length > 1) {
        warnings.add('$tag: the template sets $setting to $values.');
      }
      return values.length == 1 ? values.single : null;
    }

    String minimum(String platform, Map<String, String?> candidates) {
      final found = {
        for (final entry in candidates.entries)
          if (entry.value != null) entry.key: entry.value!,
      };
      if (found.isEmpty) {
        throw StateError('$tag: $platform minimum not found.');
      }
      if (found.values.toSet().length > 1) {
        warnings.add('$tag: $platform minimum differs between sources: '
            '$found.');
      }
      return found.values.first;
    }

    final iosMinimum = minimum('iOS', {
      'darwin.dart': fromDarwin('ios'),
      'migration': await fromMigration(const [
        'packages/flutter_tools/lib/src/ios/migrations/ios_deployment_target_migration.dart',
        'packages/flutter_tools/lib/src/ios/migrations/deployment_target_migration.dart',
      ], 'IPHONEOS_DEPLOYMENT_TARGET'),
    });
    final macosMinimum = minimum('macOS', {
      'darwin.dart': fromDarwin('macos'),
      'migration': await fromMigration(const [
        'packages/flutter_tools/lib/src/macos/migrations/macos_deployment_target_migration.dart',
      ], 'MACOSX_DEPLOYMENT_TARGET'),
      'template': await fromTemplate(const [
        'packages/flutter_tools/templates/app/macos.tmpl/Runner.xcodeproj/project.pbxproj.tmpl',
        'packages/flutter_tools/templates/app_shared/macos.tmpl/Runner.xcodeproj/project.pbxproj.tmpl',
      ], 'MACOSX_DEPLOYMENT_TARGET'),
    });

    // Apple toolchain versions the Flutter tool checks: Xcode before iOS
    // builds and in doctor, CocoaPods before pod install.
    final xcode = await git.read(
            tag, 'packages/flutter_tools/lib/src/macos/xcode.dart') ??
        '';
    String? xcodeVersion(String name) {
      final match = RegExp('$name\\s*=>\\s*'
              'Version\\((\\d+),\\s*(null|\\d+),\\s*(null|\\d+)\\)')
          .firstMatch(xcode);
      if (match == null) return null;
      return [
        match.group(1),
        if (match.group(2) != 'null') match.group(2),
        if (match.group(3) != 'null') match.group(3),
      ].join('.');
    }

    final xcodeRequired = xcodeVersion('xcodeRequiredVersion') ??
        (throw StateError('$tag: xcodeRequiredVersion not found.'));
    final xcodeRecommended = xcodeVersion('xcodeRecommendedVersion') ??
        (RegExp(r'xcodeRecommendedVersion\s*=>\s*xcodeRequiredVersion')
                .hasMatch(xcode)
            ? xcodeRequired
            : throw StateError('$tag: xcodeRecommendedVersion not found.'));
    final cocoapods = await git.read(
            tag, 'packages/flutter_tools/lib/src/macos/cocoapods.dart') ??
        '';
    String cocoapodsVersion(String name) =>
        RegExp("$name\\s*=\\s*Version\\.withText\\([^)]*'([\\d.]+)'\\)")
            .firstMatch(cocoapods)
            ?.group(1) ??
        (throw StateError('$tag: $name not found.'));

    // The compileSdk the Android embedding's AndroidX libraries require
    // (AGP fails builds that compile against less).
    final androidx =
        await git.read(tag, 'engine/src/flutter/tools/androidx/files.json');
    int? embeddingMinCompileSdk;
    var embeddingLibraries = const <String>[];
    if (androidx != null) {
      final requirements = <String, int>{};
      for (final entry
          in (jsonDecode(androidx) as List).cast<Map<String, Object?>>()) {
        if (!(entry['url']! as String).endsWith('.aar')) continue;
        final coordinate = entry['maven_dependency']! as String;
        final metadata = await aars.metadata(coordinate);
        if (metadata == null) {
          missingAars.add('$coordinate (${entry['url']})');
          continue;
        }
        final minCompileSdk = RegExp(r'^minCompileSdk=(\d+)', multiLine: true)
            .firstMatch(metadata)
            ?.group(1);
        if (minCompileSdk != null) {
          requirements[coordinate] = int.parse(minCompileSdk);
        }
      }
      if (requirements.isNotEmpty) {
        final maximum = requirements.values.reduce((a, b) => a > b ? a : b);
        embeddingMinCompileSdk = maximum;
        embeddingLibraries = [
          for (final entry in requirements.entries)
            if (entry.value == maximum) entry.key,
        ]..sort();
      }
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
    androidMigrations: [${androidMigrations.map((m) => "'$m'").join(', ')}],
    appliesKotlinPlugin: $appliesKotlinPlugin,
    templateAppKotlinPlugin: $templateAppKotlinPlugin,
    templateGradleProperties: {
${templateProperties.entries.map((e) => '      ${_dartString(e.key)}: ${_dartString(e.value)},\n').join()}    },
    compileSdk: ${sdkDefault('compileSdkVersion')},
    targetSdk: ${sdkDefault('targetSdkVersion')},
    minSdk: ${sdkDefault('minSdkVersion')},
    ndk: '${ndkMatch.group(1)}',
    imperativeApply: '$imperativeApply',
    iosMinimum: '$iosMinimum',
    macosMinimum: '$macosMinimum',
    xcodeFloor: '$xcodeRequired/$xcodeRecommended',
    cocoapodsFloor: '${cocoapodsVersion('cocoaPodsMinimumVersion')}/${cocoapodsVersion('cocoaPodsRecommendedVersion')}',
    embeddingMinCompileSdk: $embeddingMinCompileSdk,
    embeddingMinCompileSdkLibraries: [${embeddingLibraries.map((l) => "'$l'").join(', ')}],
  ),''');
  }
  await git.close();
  aars.close();
  if (missingAars.isNotEmpty) {
    stderr.writeln('AndroidX AARs of the Android embedding are missing from '
        '${aars.gradleCache}. Build an app with the releases once, or run '
        'with --download-aars:');
    for (final missing in missingAars.toList()..sort()) {
      stderr.writeln('  $missing');
    }
    exitCode = 1;
    return;
  }

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
    ..writeln('/// Stable Flutter releases before the ones described below, '
        'ascending,')
    ..writeln(
        '/// for identifying the SDK that created or last built a project.')
    ..writeln('const olderFlutterRevisions = <FlutterRevisionRecord>[')
    ..writeAll([
      for (final version in older.keys.map(Version.parse).toList()..sort())
        "  FlutterRevisionRecord('$version', "
            "'${older['$version']!['hash']}'),",
    ], '\n')
    ..writeln()
    ..writeln('];')
    ..writeln()
    ..writeln('/// Stable Flutter releases, ascending.')
    ..writeln('const flutterReleaseRecords = <FlutterReleaseRecord>[')
    ..writeAll(records, '\n')
    ..writeln()
    ..writeln('];');
  final written = await writeGeneratedDart(
    args['out'] as String,
    output.toString(),
    volatile: [
      RegExp(r'^//    \(checkout HEAD '),
      RegExp(r'^const flutterKnowledgeGeneratedOn = '),
    ],
  );
  for (final warning in warnings) {
    stderr.writeln('warning: $warning');
  }
  stdout.writeln(written
      ? 'Wrote ${records.length} releases to ${args['out']}.'
      : 'No knowledge changed; ${args['out']} is up to date.');
}

/// Finds AARs in the Gradle module cache, or downloads them.
final class _AarSource {
  _AarSource(
      {required this.gradleCache,
      required this.downloadCache,
      required this.repository});

  final String gradleCache;
  final String downloadCache;

  /// The Maven repository to download from, or `null` to only read caches.
  final String? repository;

  final HttpClient _client = HttpClient();

  /// `META-INF/com/android/build/gradle/aar-metadata.properties` of the AAR
  /// [coordinate] (`group:artifact:version`), or `null` when the AAR is not
  /// available. An AAR without metadata yields `''`.
  Future<String?> metadata(String coordinate) async {
    final aar = _cached(coordinate) ?? await _download(coordinate);
    if (aar == null) return null;
    final result = Process.runSync('unzip', [
      '-p',
      aar.path,
      'META-INF/com/android/build/gradle/aar-metadata.properties',
    ]);
    return result.exitCode == 0 ? result.stdout as String : '';
  }

  File? _cached(String coordinate) {
    final [group, artifact, version] = coordinate.split(':');
    final directory = Directory('$gradleCache/$group/$artifact/$version');
    final fromGradle = directory.existsSync()
        ? directory
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('/$artifact-$version.aar'))
            .firstOrNull
        : null;
    final downloaded = File('$downloadCache/$group/$artifact-$version.aar');
    return fromGradle ?? (downloaded.existsSync() ? downloaded : null);
  }

  Future<File?> _download(String coordinate) async {
    final repository = this.repository;
    if (repository == null) return null;
    final [group, artifact, version] = coordinate.split(':');
    final url = Uri.parse('$repository/${group.replaceAll('.', '/')}/'
        '$artifact/$version/$artifact-$version.aar');
    final request = await _client.getUrl(url);
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      stderr.writeln('warning: GET $url returned ${response.statusCode}.');
      return null;
    }
    final file = File('$downloadCache/$group/$artifact-$version.aar')
      ..parent.createSync(recursive: true);
    await response.pipe(file.openWrite());
    return file;
  }

  void close() => _client.close();
}

/// A single-quoted Dart string literal with the value of [value].
String _dartString(String value) {
  final escaped = value
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$');
  return "'$escaped'";
}

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
