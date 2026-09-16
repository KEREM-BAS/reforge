import 'package:meta/meta.dart';

import '../common/errors.dart';
import '../common/source.dart';

/// A surgical change to a text buffer: replace [length] characters at
/// [offset] with [replacement].
///
/// All Reforge mutations are expressed as text edits derived from parser
/// source ranges, so bytes outside the edited ranges (comments, formatting,
/// unrelated code) are preserved exactly.
@immutable
final class TextEdit {
  const TextEdit(this.offset, this.length, this.replacement)
      : assert(offset >= 0),
        assert(length >= 0);

  const TextEdit.insert(this.offset, this.replacement) : length = 0;

  const TextEdit.delete(this.offset, this.length) : replacement = '';

  TextEdit.replace(TextRange range, this.replacement)
      : offset = range.offset,
        length = range.length;

  final int offset;
  final int length;
  final String replacement;

  int get end => offset + length;

  bool get isInsertion => length == 0;

  @override
  bool operator ==(Object other) =>
      other is TextEdit &&
      other.offset == offset &&
      other.length == length &&
      other.replacement == replacement;

  @override
  int get hashCode => Object.hash(offset, length, replacement);

  @override
  String toString() =>
      'TextEdit($offset, $length, ${replacement.length} chars)';
}

/// Applies [edits] to [source].
///
/// Edits refer to offsets in the original [source]. They may be given in any
/// order; insertions at the same offset are applied in list order. Overlapping
/// edits indicate a defect in the code that produced them and throw an
/// [InternalException].
String applyTextEdits(String source, Iterable<TextEdit> edits) {
  final indexed = edits.toList().asMap().entries.toList()
    ..sort((a, b) {
      final byOffset = a.value.offset.compareTo(b.value.offset);
      if (byOffset != 0) return byOffset;
      // Pure insertions come before a replacement starting at the same offset.
      final byLength = a.value.length.compareTo(b.value.length);
      if (byLength != 0) return byLength;
      return a.key.compareTo(b.key);
    });

  final buffer = StringBuffer();
  var cursor = 0;
  for (final entry in indexed) {
    final edit = entry.value;
    if (edit.end > source.length) {
      throw InternalException(
        'EDIT_OUT_OF_RANGE',
        'Edit $edit exceeds the source length ${source.length}.',
      );
    }
    if (edit.offset < cursor) {
      throw InternalException(
        'EDIT_OVERLAP',
        'Edit $edit overlaps a previous edit ending at $cursor.',
      );
    }
    buffer
      ..write(source.substring(cursor, edit.offset))
      ..write(edit.replacement);
    cursor = edit.end;
  }
  buffer.write(source.substring(cursor));
  return buffer.toString();
}

/// Computes the smallest single edit that transforms [before] into [after].
///
/// Useful when a structured editor returns a whole new document: the change
/// is reduced back to a minimal, reviewable edit.
TextEdit? minimalEdit(String before, String after) {
  if (before == after) return null;
  var prefix = 0;
  final maxPrefix = before.length < after.length ? before.length : after.length;
  while (prefix < maxPrefix &&
      before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < before.length - prefix &&
      suffix < after.length - prefix &&
      before.codeUnitAt(before.length - 1 - suffix) ==
          after.codeUnitAt(after.length - 1 - suffix)) {
    suffix++;
  }
  return TextEdit(
    prefix,
    before.length - prefix - suffix,
    after.substring(prefix, after.length - suffix),
  );
}
