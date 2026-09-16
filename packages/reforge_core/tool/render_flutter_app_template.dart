// Renders the `flutter create` app template of a given Flutter release from a
// local Flutter git checkout, without needing that Flutter version installed.
//
// Reforge uses this to build fixture projects that match what historical
// Flutter releases actually generated.
//
// Usage:
//   dart run tool/render_flutter_app_template.dart \
//     --flutter ~/flutter --tag 3.3.0 --sdk-bounds "'>=2.18.0 <3.0.0'" \
//     --out ../../fixtures/projects/flutter_3_3_app [--name my_app] \
//     [--org com.example] [--podfile]
//
// Only Android (Kotlin) and iOS (Swift) files plus pubspec/lib are rendered;
// binary images and IDE files are skipped.

import 'dart:io';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption('flutter',
        help: 'Path to a Flutter git checkout.', mandatory: true)
    ..addOption('tag',
        help: 'Flutter release tag, e.g. 3.3.0.', mandatory: true)
    ..addOption('sdk-bounds',
        help: 'Value of environment.sdk exactly as flutter create wrote it.',
        mandatory: true)
    ..addOption('out', help: 'Output directory.', mandatory: true)
    ..addOption('name', defaultsTo: 'my_app')
    ..addOption('org', defaultsTo: 'com.example')
    ..addFlag('podfile', help: 'Also render the CocoaPods Podfile.');
  final args = parser.parse(arguments);

  final checkout = args['flutter'] as String;
  final tag = args['tag'] as String;
  final out = Directory(args['out'] as String);
  final name = args['name'] as String;
  final org = args['org'] as String;

  String git(List<String> command) {
    final result = Process.runSync('git', ['-C', checkout, ...command]);
    if (result.exitCode != 0) {
      throw StateError('git ${command.join(' ')} failed: ${result.stderr}');
    }
    return result.stdout as String;
  }

  final revision = git(['rev-parse', '$tag^{commit}']).trim();
  final gradleUtils = git([
    'show',
    '$tag:packages/flutter_tools/lib/src/android/gradle_utils.dart'
  ]);
  String constant(String name) {
    final match =
        RegExp("const (?:String )?$name = '([^']+)'").firstMatch(gradleUtils);
    if (match == null) throw StateError('Constant $name not found at $tag');
    return match.group(1)!;
  }

  final camelName = name
      .split('_')
      .indexed
      .map((e) =>
          e.$1 == 0 ? e.$2 : '${e.$2[0].toUpperCase()}${e.$2.substring(1)}')
      .join();

  final context = <String, Object>{
    'projectName': name,
    'titleCaseProjectName': name
        .split('_')
        .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
        .join(' '),
    'description': 'A new Flutter project.',
    'organization': org,
    'androidIdentifier': '$org.$name',
    'iosIdentifier': '$org.$camelName',
    'dartSdk': r'$FLUTTER_ROOT/bin/cache/dart-sdk',
    'dartSdkVersionBounds': args['sdk-bounds'] as String,
    'agpVersion': constant('templateAndroidGradlePluginVersion'),
    'kotlinVersion': constant('templateKotlinGradlePluginVersion'),
    'gradleVersion': constant('templateDefaultGradleVersion'),
    'flutterRevision': revision,
    'flutterChannel': 'stable',
    'withPlatformChannelPluginHook': false,
    'withFfiPluginHook': false,
    'withFfi': false,
    'withPluginHook': false,
    'withEmptyMain': false,
    'withSwiftPackageManager': false,
    'hasIosDevelopmentTeam': false,
    'iosDevelopmentTeam': '',
    'implementationTests': false,
    'android': true,
    'ios': true,
    'web': false,
    'linux': false,
    'macos': false,
    'windows': false,
  };

  const roots = [
    'packages/flutter_tools/templates/app_shared',
    'packages/flutter_tools/templates/app',
  ];
  const platformDirs = {
    'android.tmpl': 'android',
    'android-kotlin.tmpl': 'android',
    'ios.tmpl': 'ios',
    'ios-swift.tmpl': 'ios',
  };

  final files = git(['ls-tree', '-r', '--name-only', tag, '--', ...roots])
      .split('\n')
      .where((f) => f.isNotEmpty);
  var written = 0;
  for (final file in files) {
    final root = roots.firstWhere((r) => file.startsWith('$r/'));
    final relative = file.substring(root.length + 1);
    final segments = relative.split('/');
    if (segments.any((s) => s == '.idea' || s == 'test')) continue;
    if (file.endsWith('.img.tmpl') ||
        file.endsWith('.png') ||
        file.endsWith('.iml.tmpl')) {
      continue;
    }
    if (segments.length > 1 && !platformDirs.containsKey(segments.first)) {
      if (segments.first != 'lib') continue;
    }
    if (segments.length == 1 && segments.first.startsWith('README')) continue;

    final outputSegments = <String>[];
    for (final segment in segments) {
      if (platformDirs.containsKey(segment)) {
        outputSegments.add(platformDirs[segment]!);
      } else if (segment == 'androidIdentifier') {
        outputSegments.addAll('$org.$name'.split('.'));
      } else {
        outputSegments.add(segment.replaceAll('projectName', name));
      }
    }
    var outputName = outputSegments.removeLast();
    final isCopy = outputName.endsWith('.copy.tmpl');
    final isTemplate = outputName.endsWith('.tmpl');
    if (isCopy) {
      outputName =
          outputName.substring(0, outputName.length - '.copy.tmpl'.length);
    } else if (isTemplate) {
      outputName = outputName.substring(0, outputName.length - '.tmpl'.length);
    }
    final content = git(['show', '$tag:$file']);
    final rendered = isTemplate && !isCopy
        ? renderMustache(content, context, file)
        : content;
    final target = File(p.joinAll([out.path, ...outputSegments, outputName]));
    target.parent.createSync(recursive: true);
    target.writeAsStringSync(rendered);
    written++;
  }

  if (args['podfile'] as bool) {
    final candidates = ['Podfile-ios-swift', 'Podfile-ios'];
    for (final candidate in candidates) {
      final path = 'packages/flutter_tools/templates/cocoapods/$candidate';
      final result =
          Process.runSync('git', ['-C', checkout, 'show', '$tag:$path']);
      if (result.exitCode == 0) {
        File(p.join(out.path, 'ios', 'Podfile'))
            .writeAsStringSync(result.stdout as String);
        written++;
        break;
      }
    }
  }

  File(p.join(out.path, '.metadata')).writeAsStringSync('''
# This file tracks properties of this Flutter project.
# Used by Flutter tool to assess capabilities and perform upgrades etc.
#
# This file should be version controlled and should not be manually edited.

version:
  revision: $revision
  channel: stable

project_type: app
''');
  stdout.writeln(
      'Rendered ${written + 1} files for Flutter $tag ($revision) into ${out.path}');
}

/// Renders the subset of Mustache used by Flutter templates: variables,
/// sections and inverted sections, with standalone tag lines removed.
String renderMustache(
    String template, Map<String, Object> context, String file) {
  final lines = template.split('\n');
  final output = StringBuffer();
  final stack = <bool>[];
  final tagOnly = RegExp(r'^\s*\{\{([#^/])(\w+)\}\}\s*$');
  var first = true;

  bool active() => stack.every((v) => v);

  for (final line in lines) {
    final standalone = tagOnly.firstMatch(line);
    if (standalone != null) {
      _applySection(
          standalone.group(1)!, standalone.group(2)!, context, stack, file);
      continue;
    }
    // Inline sections and variables.
    final buffer = StringBuffer();
    var index = 0;
    final tag = RegExp(r'\{\{([#^/]?)(\w+)\}\}');
    for (final match in tag.allMatches(line)) {
      if (active()) buffer.write(line.substring(index, match.start));
      final kind = match.group(1)!;
      final name = match.group(2)!;
      if (kind.isEmpty) {
        if (active()) {
          final value = context[name];
          if (value == null) {
            throw StateError('Unknown template variable "$name" in $file');
          }
          buffer.write(value);
        }
      } else {
        _applySection(kind, name, context, stack, file);
      }
      index = match.end;
    }
    if (active()) buffer.write(line.substring(index));
    if (!active() && buffer.isEmpty) continue;
    if (!first) output.write('\n');
    output.write(buffer);
    first = false;
  }
  if (stack.isNotEmpty) throw StateError('Unclosed section in $file');
  return output.toString();
}

void _applySection(String kind, String name, Map<String, Object> context,
    List<bool> stack, String file) {
  if (kind == '/') {
    stack.removeLast();
    return;
  }
  final value = context[name];
  if (value is! bool) {
    throw StateError('Unknown or non-boolean section "$name" in $file');
  }
  stack.add(kind == '#' ? value : !value);
}
