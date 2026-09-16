import 'dart:math';

import 'package:reforge_core/src/text/unified_diff.dart';
import 'package:test/test.dart';

/// Applies a unified diff produced by [unifiedDiff] to [before].
String applyPatch(String before, String patch) {
  final oldLines = <String>[];
  var start = 0;
  for (var i = 0; i < before.length; i++) {
    if (before.codeUnitAt(i) == 0x0A) {
      oldLines.add(before.substring(start, i + 1));
      start = i + 1;
    }
  }
  if (start < before.length) oldLines.add(before.substring(start));

  final patchLines = patch.split('\n');
  final result = <String>[];
  var oldCursor = 0;
  var i = 2; // skip headers
  final header = RegExp(r'^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@$');
  while (i < patchLines.length && patchLines[i].isNotEmpty) {
    final match = header.firstMatch(patchLines[i])!;
    final oldStart = int.parse(match.group(1)!);
    final oldCount = int.parse(match.group(2) ?? '1');
    final firstOldIndex = oldCount == 0 ? oldStart : oldStart - 1;
    while (oldCursor < firstOldIndex) {
      result.add(oldLines[oldCursor++]);
    }
    i++;
    while (i < patchLines.length &&
        patchLines[i].isNotEmpty &&
        !patchLines[i].startsWith('@@')) {
      final line = patchLines[i];
      final noNewline = i + 1 < patchLines.length &&
          patchLines[i + 1] == r'\ No newline at end of file';
      final text = line.substring(1) + (noNewline ? '' : '\n');
      switch (line[0]) {
        case ' ':
          expect(oldLines[oldCursor], text, reason: 'context mismatch');
          result.add(text);
          oldCursor++;
        case '-':
          expect(oldLines[oldCursor], text, reason: 'deletion mismatch');
          oldCursor++;
        case '+':
          result.add(text);
      }
      i += noNewline ? 2 : 1;
    }
  }
  while (oldCursor < oldLines.length) {
    result.add(oldLines[oldCursor++]);
  }
  return result.join();
}

void main() {
  test('diffs round-trip through a patch applier', () {
    final random = Random(20260916);
    const alphabet = ['a', 'b', 'c', 'd', 'e'];
    String randomDocument() {
      final lineCount = random.nextInt(30);
      final buffer = StringBuffer();
      for (var i = 0; i < lineCount; i++) {
        buffer.write(alphabet[random.nextInt(alphabet.length)]);
        if (i < lineCount - 1 || random.nextBool()) buffer.write('\n');
      }
      return buffer.toString();
    }

    for (var iteration = 0; iteration < 2000; iteration++) {
      final before = randomDocument();
      final after = randomDocument();
      final patch = unifiedDiff(
        path: 'f',
        before: before,
        after: after,
        context: random.nextInt(4),
      );
      if (before == after) {
        expect(patch, isEmpty);
        continue;
      }
      expect(applyPatch(before, patch), after,
          reason: 'before=${before.codeUnits} after=${after.codeUnits}');
    }
  });
}
