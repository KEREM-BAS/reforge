import '../../common/source.dart';

/// A Java `.properties` file (`gradle.properties`,
/// `gradle-wrapper.properties`, `local.properties`), parsed losslessly.
///
/// Follows the format of `java.util.Properties.load`: `#`/`!` comments,
/// `=`/`:`/whitespace separators, backslash escapes and line continuations.
/// Every entry keeps the source range of its raw value so edits replace
/// exactly that range.
final class PropertiesFile {
  PropertiesFile._(this.path, this.source, this.entries);

  factory PropertiesFile.parse(String path, String source) =>
      PropertiesFile._(path, source, List.unmodifiable(_parse(source)));

  final String path;
  final String source;

  /// Entries in source order. Keys may repeat; the last one wins.
  final List<PropertyEntry> entries;

  PropertyEntry? entry(String key) =>
      entries.lastWhereOrNull((e) => e.key == key);

  String? operator [](String key) => entry(key)?.value;

  bool containsKey(String key) => entry(key) != null;
}

final class PropertyEntry {
  const PropertyEntry({
    required this.key,
    required this.value,
    required this.rawValueRange,
    required this.lineRange,
    required this.line,
  });

  /// The decoded key.
  final String key;

  /// The decoded value.
  final String value;

  /// Range of the raw (escaped) value, possibly spanning continuation lines.
  final TextRange rawValueRange;

  /// Range of the whole logical line including its line terminator.
  final TextRange lineRange;

  /// 1-based line number where the entry starts.
  final int line;
}

extension<T> on List<T> {
  T? lastWhereOrNull(bool Function(T) test) {
    for (var i = length - 1; i >= 0; i--) {
      if (test(this[i])) return this[i];
    }
    return null;
  }
}

List<PropertyEntry> _parse(String source) {
  final entries = <PropertyEntry>[];
  var offset = source.startsWith('\uFEFF') ? 1 : 0;
  var lineNumber = 1;

  bool isWhitespace(int c) => c == 0x20 || c == 0x09 || c == 0x0C;

  while (offset < source.length) {
    final lineStart = offset;
    final startLineNumber = lineNumber;

    // Skip leading whitespace of the natural line.
    var i = offset;
    while (i < source.length && isWhitespace(source.codeUnitAt(i))) {
      i++;
    }

    int naturalLineEnd(int from) {
      var j = from;
      while (j < source.length &&
          source.codeUnitAt(j) != 0x0A &&
          source.codeUnitAt(j) != 0x0D) {
        j++;
      }
      return j;
    }

    int afterTerminator(int end) {
      if (end < source.length && source.codeUnitAt(end) == 0x0D) end++;
      if (end < source.length && source.codeUnitAt(end) == 0x0A) end++;
      return end;
    }

    final firstEnd = naturalLineEnd(i);
    if (i == firstEnd ||
        source.codeUnitAt(i) == 0x23 /* # */ ||
        source.codeUnitAt(i) == 0x21 /* ! */) {
      // Blank or comment line; comments never continue.
      offset = afterTerminator(firstEnd);
      lineNumber++;
      continue;
    }

    // Collect the logical line: natural lines joined while the line ends with
    // an odd number of backslashes. Keep a map from logical to raw offsets.
    final logical = StringBuffer();
    final rawOffsets = <int>[];
    var segmentStart = i;
    var segmentEnd = firstEnd;
    var rawEnd = firstEnd;
    while (true) {
      var backslashes = 0;
      var k = segmentEnd - 1;
      while (k >= segmentStart && source.codeUnitAt(k) == 0x5C) {
        backslashes++;
        k--;
      }
      final continues = backslashes.isOdd && segmentEnd < source.length;
      final contentEnd = continues ? segmentEnd - 1 : segmentEnd;
      for (var j = segmentStart; j < contentEnd; j++) {
        logical.writeCharCode(source.codeUnitAt(j));
        rawOffsets.add(j);
      }
      rawEnd = segmentEnd;
      if (!continues) break;
      var next = afterTerminator(segmentEnd);
      lineNumber++;
      while (next < source.length && isWhitespace(source.codeUnitAt(next))) {
        next++;
      }
      segmentStart = next;
      segmentEnd = naturalLineEnd(next);
    }
    rawOffsets.add(rawEnd);
    final text = logical.toString();

    // Key: up to the first unescaped separator or whitespace.
    var p = 0;
    final key = StringBuffer();
    while (p < text.length) {
      final c = text.codeUnitAt(p);
      if (c == 0x5C && p + 1 < text.length) {
        p = _decodeEscape(text, p, key);
        continue;
      }
      if (c == 0x3D || c == 0x3A || isWhitespace(c)) break;
      key.writeCharCode(c);
      p++;
    }
    // Separator: whitespace, then at most one '=' or ':', then whitespace.
    while (p < text.length && isWhitespace(text.codeUnitAt(p))) {
      p++;
    }
    if (p < text.length &&
        (text.codeUnitAt(p) == 0x3D || text.codeUnitAt(p) == 0x3A)) {
      p++;
    }
    while (p < text.length && isWhitespace(text.codeUnitAt(p))) {
      p++;
    }
    final valueLogicalStart = p;
    final value = StringBuffer();
    while (p < text.length) {
      if (text.codeUnitAt(p) == 0x5C && p + 1 < text.length) {
        p = _decodeEscape(text, p, value);
        continue;
      }
      value.writeCharCode(text.codeUnitAt(p));
      p++;
    }

    final lineEnd = afterTerminator(rawEnd);
    entries.add(PropertyEntry(
      key: key.toString(),
      value: value.toString(),
      rawValueRange:
          TextRange.fromBounds(rawOffsets[valueLogicalStart], rawEnd),
      lineRange: TextRange.fromBounds(lineStart, lineEnd),
      line: startLineNumber,
    ));
    offset = lineEnd;
    lineNumber++;
  }
  return entries;
}

int _decodeEscape(String text, int index, StringBuffer out) {
  final c = text.codeUnitAt(index + 1);
  switch (c) {
    case 0x74:
      out.write('\t');
      return index + 2;
    case 0x6E:
      out.write('\n');
      return index + 2;
    case 0x72:
      out.write('\r');
      return index + 2;
    case 0x66:
      out.write('\f');
      return index + 2;
    case 0x75:
      if (index + 6 <= text.length) {
        final code =
            int.tryParse(text.substring(index + 2, index + 6), radix: 16);
        if (code != null) {
          out.writeCharCode(code);
          return index + 6;
        }
      }
      out.write('u');
      return index + 2;
    default:
      out.writeCharCode(c);
      return index + 2;
  }
}

/// Escapes [value] for use as a property value.
///
/// When [escapeColons] is true, `:` is written as `\:` (the convention used
/// by Gradle-generated `gradle-wrapper.properties` files).
String escapePropertyValue(String value, {bool escapeColons = false}) {
  final buffer = StringBuffer();
  for (var i = 0; i < value.length; i++) {
    final c = value[i];
    switch (c) {
      case r'\':
        buffer.write(r'\\');
      case '\n':
        buffer.write(r'\n');
      case '\r':
        buffer.write(r'\r');
      case '\t':
        buffer.write(r'\t');
      case ':' when escapeColons:
        buffer.write(r'\:');
      case '=' when escapeColons:
        buffer.write(r'\=');
      case ' ' when i == 0:
        buffer.write(r'\ ');
      default:
        buffer.write(c);
    }
  }
  return buffer.toString();
}
