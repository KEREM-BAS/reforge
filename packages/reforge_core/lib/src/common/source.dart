import 'package:meta/meta.dart';

/// A half-open range `[offset, offset + length)` in a text buffer.
@immutable
final class TextRange {
  const TextRange(this.offset, this.length)
      : assert(offset >= 0),
        assert(length >= 0);

  const TextRange.fromBounds(int start, int end)
      : offset = start,
        length = end - start;

  final int offset;
  final int length;

  int get end => offset + length;

  bool contains(int position) => position >= offset && position < end;

  bool intersects(TextRange other) =>
      offset < other.end && other.offset < end;

  String textOf(String source) => source.substring(offset, end);

  @override
  bool operator ==(Object other) =>
      other is TextRange && other.offset == offset && other.length == length;

  @override
  int get hashCode => Object.hash(offset, length);

  @override
  String toString() => '[$offset, $end)';
}

/// A location inside a project file.
///
/// [path] is always project-relative and uses `/` separators, so reports are
/// portable and never contain absolute paths of the machine that produced
/// them.
@immutable
final class SourceRef {
  const SourceRef(this.path, {this.line, this.column, this.range});

  final String path;

  /// 1-based line number, when known.
  final int? line;

  /// 1-based column number, when known.
  final int? column;

  /// Character range in the decoded file content, when known.
  final TextRange? range;

  String get display => line == null ? path : '$path:$line';

  Map<String, Object?> toJson() => {
        'path': path,
        if (line != null) 'line': line,
        if (column != null) 'column': column,
      };

  @override
  bool operator ==(Object other) =>
      other is SourceRef &&
      other.path == path &&
      other.line == line &&
      other.column == column &&
      other.range == range;

  @override
  int get hashCode => Object.hash(path, line, column, range);

  @override
  String toString() => display;
}

/// Converts character offsets to 1-based line and column numbers.
final class LineIndex {
  LineIndex(this.source) : _lineStarts = _computeLineStarts(source);

  final String source;
  final List<int> _lineStarts;

  static List<int> _computeLineStarts(String source) {
    final starts = <int>[0];
    for (var i = 0; i < source.length; i++) {
      if (source.codeUnitAt(i) == 0x0A) {
        starts.add(i + 1);
      }
    }
    return starts;
  }

  int get lineCount => _lineStarts.length;

  /// 1-based line containing [offset].
  int lineOf(int offset) {
    var low = 0;
    var high = _lineStarts.length - 1;
    while (low < high) {
      final mid = (low + high + 1) >> 1;
      if (_lineStarts[mid] <= offset) {
        low = mid;
      } else {
        high = mid - 1;
      }
    }
    return low + 1;
  }

  /// 1-based column of [offset] within its line.
  int columnOf(int offset) => offset - _lineStarts[lineOf(offset) - 1] + 1;

  /// Offset of the first character of the 1-based [line].
  int lineStart(int line) => _lineStarts[line - 1];

  /// Offset just past the end of the 1-based [line], excluding its line
  /// terminator.
  int lineEnd(int line) {
    if (line >= _lineStarts.length) {
      return source.length;
    }
    var end = _lineStarts[line] - 1; // points at '\n'
    if (end > 0 && source.codeUnitAt(end - 1) == 0x0D) {
      end--;
    }
    return end;
  }

  /// Offset just past the line terminator of the 1-based [line] (or the end of
  /// the source for the last line).
  int lineEndIncludingTerminator(int line) =>
      line >= _lineStarts.length ? source.length : _lineStarts[line];

  SourceRef refFor(String path, int offset, [int length = 0]) => SourceRef(
        path,
        line: lineOf(offset),
        column: columnOf(offset),
        range: TextRange(offset, length),
      );

  /// The leading whitespace of the 1-based [line].
  String indentationOf(int line) {
    final start = lineStart(line);
    var i = start;
    while (i < source.length) {
      final c = source.codeUnitAt(i);
      if (c != 0x20 && c != 0x09) break;
      i++;
    }
    return source.substring(start, i);
  }
}

/// The line terminator style used by a text file.
enum LineEnding {
  lf('\n'),
  crlf('\r\n');

  const LineEnding(this.sequence);

  final String sequence;

  /// Detects the dominant line ending of [content]; defaults to LF.
  static LineEnding detect(String content) {
    var crlf = 0;
    var lf = 0;
    for (var i = 0; i < content.length; i++) {
      if (content.codeUnitAt(i) == 0x0A) {
        if (i > 0 && content.codeUnitAt(i - 1) == 0x0D) {
          crlf++;
        } else {
          lf++;
        }
      }
    }
    return crlf > lf ? LineEnding.crlf : LineEnding.lf;
  }

  /// Rewrites `\n` line breaks in [text] (which must use LF) to this style.
  String apply(String text) =>
      this == LineEnding.lf ? text : text.replaceAll('\n', '\r\n');
}
