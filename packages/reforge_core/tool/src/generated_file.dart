import 'dart:convert';
import 'dart:io';

/// Formats [source] like the rest of the repository and writes it to [path],
/// unless the file already has this content apart from lines matching
/// [volatile] (generation dates, source revisions).
///
/// Keeping unchanged files untouched makes regeneration reproducible: the
/// generation date only moves when the knowledge does. Returns whether the
/// file was written.
Future<bool> writeGeneratedDart(String path, String source,
    {List<RegExp> volatile = const []}) async {
  final formatted = await _format(path, source);
  final file = File(path);
  if (file.existsSync()) {
    String stable(String text) => const LineSplitter()
        .convert(text)
        .where((line) => !volatile.any((pattern) => pattern.hasMatch(line)))
        .join('\n');
    if (stable(file.readAsStringSync()) == stable(formatted)) return false;
  }
  file.writeAsStringSync(formatted);
  return true;
}

Future<String> _format(String path, String source) async {
  final process = await Process.start('dart', ['format', '--stdin-name', path],
      runInShell: Platform.isWindows);
  // Read both streams before writing, so a large output cannot block.
  final output = process.stdout.transform(utf8.decoder).join();
  final errors = process.stderr.transform(utf8.decoder).join();
  process.stdin.write(source);
  await process.stdin.close();
  if (await process.exitCode != 0) {
    throw StateError('dart format failed for $path: ${await errors}');
  }
  return output;
}
