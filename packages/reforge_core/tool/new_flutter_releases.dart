// Lists the stable Flutter releases in the release manifest that the bundled
// knowledge base does not describe yet, one per line, ascending. Prints
// nothing when the knowledge base is current.
//
// Usage:
//   curl -o /tmp/releases_macos.json \
//     https://storage.googleapis.com/flutter_infra_release/releases/releases_macos.json
//   dart run tool/new_flutter_releases.dart --manifest /tmp/releases_macos.json
//
// Releases are selected like tool/generate_flutter_knowledge.dart does:
// stable channel, semantic versions, no pre-releases, --min-version and
// newer.

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:reforge_core/src/knowledge/data/flutter_releases.g.dart';

void main(List<String> arguments) {
  final parser = ArgParser()
    ..addOption('manifest', mandatory: true, help: 'releases_*.json path.')
    ..addOption('min-version', defaultsTo: '3.0.0');
  final args = parser.parse(arguments);
  final minimum = Version.parse(args['min-version'] as String);
  final manifest =
      jsonDecode(File(args['manifest'] as String).readAsStringSync())
          as Map<String, Object?>;
  final known = {for (final record in flutterReleaseRecords) record.version};

  final missing = <Version>{};
  for (final release
      in (manifest['releases']! as List).cast<Map<String, Object?>>()) {
    if (release['channel'] != 'stable') continue;
    final Version version;
    try {
      version = Version.parse(release['version']! as String);
    } on FormatException {
      continue;
    }
    if (version.isPreRelease || version < minimum) continue;
    if (!known.contains('$version')) missing.add(version);
  }
  for (final version in missing.toList()..sort()) {
    stdout.writeln(version);
  }
}
