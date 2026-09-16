import 'package:reforge_core/src/common/errors.dart';
import 'package:reforge_core/src/common/source.dart';
import 'package:reforge_core/src/text/text_edit.dart';
import 'package:reforge_core/src/text/unified_diff.dart';
import 'package:test/test.dart';

void main() {
  group('applyTextEdits', () {
    test('applies edits in any order', () {
      const source = 'hello brave new world';
      final result = applyTextEdits(source, const [
        TextEdit(16, 5, 'planet'),
        TextEdit(0, 5, 'goodbye'),
      ]);
      expect(result, 'goodbye brave new planet');
    });

    test('keeps list order for insertions at the same offset', () {
      final result = applyTextEdits('ac', const [
        TextEdit.insert(1, 'b'),
        TextEdit.insert(1, 'B'),
      ]);
      expect(result, 'abBc');
    });

    test('insertion before a replacement at the same offset', () {
      final result = applyTextEdits('abc', const [
        TextEdit(1, 1, 'X'),
        TextEdit.insert(1, '>'),
      ]);
      expect(result, 'a>Xc');
    });

    test('rejects overlapping edits', () {
      expect(
        () => applyTextEdits('abcdef', const [
          TextEdit(0, 3, 'x'),
          TextEdit(2, 2, 'y'),
        ]),
        throwsA(isA<InternalException>()),
      );
    });

    test('rejects edits beyond the source', () {
      expect(
        () => applyTextEdits('abc', const [TextEdit(2, 5, 'x')]),
        throwsA(isA<InternalException>()),
      );
    });
  });

  group('minimalEdit', () {
    test('returns null for identical text', () {
      expect(minimalEdit('same', 'same'), isNull);
    });

    test('reduces a whole-document change to the changed range', () {
      const before = 'environment:\n  sdk: ">=2.12.0 <3.0.0"\n';
      const after = 'environment:\n  sdk: ">=2.12.0 <4.0.0"\n';
      final edit = minimalEdit(before, after)!;
      expect(edit.length, 1);
      expect(edit.replacement, '4');
      expect(applyTextEdits(before, [edit]), after);
    });
  });

  group('LineIndex', () {
    test('maps offsets to lines and columns', () {
      final index = LineIndex('one\ntwo\r\nthree');
      expect(index.lineOf(0), 1);
      expect(index.lineOf(4), 2);
      expect(index.columnOf(5), 2);
      expect(index.lineOf(9), 3);
      expect(index.lineEnd(2), 7);
      expect(index.lineEndIncludingTerminator(2), 9);
      expect(index.lineEnd(3), 14);
    });

    test('reports indentation', () {
      final index = LineIndex('a\n    b\n\tc');
      expect(index.indentationOf(2), '    ');
      expect(index.indentationOf(3), '\t');
    });
  });

  group('LineEnding', () {
    test('detects CRLF files', () {
      expect(LineEnding.detect('a\r\nb\r\nc\n'), LineEnding.crlf);
      expect(LineEnding.detect('a\nb\n'), LineEnding.lf);
      expect(LineEnding.detect('no newline'), LineEnding.lf);
    });
  });

  group('unifiedDiff', () {
    test('is empty for identical content', () {
      expect(unifiedDiff(path: 'a', before: 'x\n', after: 'x\n'), isEmpty);
    });

    test('renders a single changed line with context', () {
      final diff = unifiedDiff(
        path: 'android/gradle/wrapper/gradle-wrapper.properties',
        before: 'a\nb\nc\nd\ne\nf\ng\n',
        after: 'a\nb\nc\nD\ne\nf\ng\n',
      );
      expect(
        diff,
        '--- a/android/gradle/wrapper/gradle-wrapper.properties\n'
        '+++ b/android/gradle/wrapper/gradle-wrapper.properties\n'
        '@@ -1,7 +1,7 @@\n'
        ' a\n'
        ' b\n'
        ' c\n'
        '-d\n'
        '+D\n'
        ' e\n'
        ' f\n'
        ' g\n',
      );
    });

    test('splits distant changes into separate hunks', () {
      final before = List.generate(20, (i) => 'line $i\n').join();
      final after = before
          .replaceFirst('line 1\n', 'line one\n')
          .replaceFirst('line 18\n', 'line eighteen\n');
      final diff = unifiedDiff(path: 'f', before: before, after: after);
      expect(RegExp('^@@', multiLine: true).allMatches(diff), hasLength(2));
      expect(diff, contains('@@ -1,5 +1,5 @@'));
      expect(diff, contains('@@ -16,5 +16,5 @@'));
    });

    test('marks a missing trailing newline', () {
      final diff = unifiedDiff(path: 'f', before: 'a\nb', after: 'a\nb\n');
      expect(diff, contains('-b\n\\ No newline at end of file\n+b\n'));
    });

    test('handles created and deleted files', () {
      expect(
        unifiedDiff(path: 'new.txt', before: null, after: 'x\n'),
        '--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+x\n',
      );
      expect(
        unifiedDiff(path: 'old.txt', before: 'x\n', after: null),
        '--- a/old.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-x\n',
      );
    });

    test('pure insertion hunk header', () {
      final diff = unifiedDiff(
        path: 'f',
        before: 'a\nb\nc\nd\ne\nf\ng\nh\n',
        after: 'a\nb\nc\nd\nNEW\ne\nf\ng\nh\n',
      );
      expect(diff, contains('@@ -2,6 +2,7 @@'));
    });

    test('diffStat counts changed lines', () {
      final stat = diffStat('a\nb\nc\n', 'a\nB\nc\nd\n');
      expect(stat.added, 2);
      expect(stat.removed, 1);
    });
  });
}
