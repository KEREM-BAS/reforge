// Runs Reforge's parsers over real files and reports the ones they cannot
// read reliably, to find gaps before users do.
//
// Usage (from packages/reforge_core):
//   dart run tool/check_parsers.dart ~/.pub-cache/hosted <flutter checkout> ...
//
// Scans Gradle scripts, properties files, Podfiles and podspecs below the
// given directories (skipping build output) and prints each unreliable file
// with its first diagnostic, then totals per kind.

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge_core/src/parsing/gradle/gradle_script.dart';
import 'package:reforge_core/src/parsing/ruby/podfile.dart';
import 'package:reforge_core/src/parsing/ruby/podspec.dart';

void main(List<String> directories) {
  if (directories.isEmpty) {
    stderr.writeln('Usage: dart run tool/check_parsers.dart <directory>...');
    exitCode = 64;
    return;
  }
  final totals = <String, (int, int)>{};
  void count(String kind, {required bool reliable}) {
    final (files, failures) = totals[kind] ?? (0, 0);
    totals[kind] = (files + 1, failures + (reliable ? 0 : 1));
  }

  for (final directory in directories) {
    final root = Directory(directory);
    if (!root.existsSync()) continue;
    for (final entity in root.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      final path = entity.path;
      final segments = p.split(path);
      if (segments.contains('build') || segments.contains('.dart_tool')) {
        continue;
      }
      final name = p.basename(path);
      final String source;
      try {
        if (!(name.endsWith('.gradle') ||
            name.endsWith('.gradle.kts') ||
            name == 'Podfile' ||
            name.endsWith('.podspec'))) {
          continue;
        }
        source = entity.readAsStringSync();
      } on FileSystemException {
        continue;
      } on FormatException {
        continue;
      }
      String? problem;
      final String kind;
      if (name.endsWith('.gradle') || name.endsWith('.gradle.kts')) {
        kind = name.endsWith('.kts') ? 'gradle (kts)' : 'gradle (groovy)';
        final script = GradleScript.parse(path, source);
        if (!script.isReliable) {
          final d = script.diagnostics.first;
          problem = '${script.lineIndex.lineOf(d.range.offset)}: ${d.message}';
        }
      } else if (name == 'Podfile') {
        kind = 'Podfile';
        final podfile = Podfile.parse(path, source);
        if (!podfile.isReliable) problem = podfile.diagnostics.first.message;
      } else {
        kind = 'podspec';
        final podspec = Podspec.parse(path, source);
        if (!podspec.isReliable) problem = podspec.diagnostics.first.message;
      }
      count(kind, reliable: problem == null);
      if (problem != null) stdout.writeln('$path:$problem');
    }
  }
  stdout.writeln();
  for (final entry in totals.entries) {
    final (files, failures) = entry.value;
    stdout.writeln('${entry.key}: $failures of $files unreliable');
  }
}
