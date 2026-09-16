import '../../common/source.dart';
import '../../model/declarations.dart';
import '../../model/finding.dart';
import '../../parsing/gradle/gradle_script.dart';
import '../../text/text_edit.dart';
import '../../version/tool_version.dart';
import '../recipe.dart';

/// Replaces an editable value.
FileEdit replaceValue(EditableValue editable, String replacement) =>
    FileEdit(editable.path, [TextEdit.replace(editable.range, replacement)]);

/// Evidence describing where a toolchain version is declared.
Evidence declarationEvidence(String name, VersionDeclaration declaration) =>
    Evidence.file(
      '$name ${declaration.version ?? declaration.rawText} is declared here'
      '${declaration.note == null ? '' : ' (${declaration.note})'}',
      declaration.definition ?? declaration.usage,
    );

/// Confidence implied by how a declaration was resolved.
Confidence confidenceOf(VersionDeclaration declaration) =>
    switch (declaration.resolution) {
      ValueResolution.literal => Confidence.certain,
      ValueResolution.variable ||
      ValueResolution.gradleProperty =>
        Confidence.high,
      ValueResolution.unresolved => Confidence.low,
    };

bool crossesMajor(ToolVersion from, ToolVersion to) => from.major != to.major;

/// The range covering whole source lines of [statements] in [script]
/// (from the start of the first statement's line to the end of the last
/// statement's line, including its line terminator).
///
/// When the removed lines are surrounded by blank lines (or the start or end
/// of the file), one adjacent blank line is removed too, so removing a
/// paragraph does not leave a double blank line behind.
TextRange removalRange(GradleScript script, int start, int end) {
  final lines = script.lineIndex;
  final source = script.source;
  final firstLine = lines.lineOf(start);
  final lastLine = lines.lineOf(end == 0 ? 0 : end - 1);

  // A line exists when it has content or a terminator; the empty "line" after
  // a trailing newline does not count.
  bool exists(int line) =>
      line >= 1 &&
      line <= lines.lineCount &&
      !(line == lines.lineCount && lines.lineStart(line) == source.length);
  bool isBlank(int line) =>
      exists(line) &&
      source
          .substring(lines.lineStart(line), lines.lineEnd(line))
          .trim()
          .isEmpty;

  var rangeStart = lines.lineStart(firstLine);
  var rangeEnd = lines.lineEndIncludingTerminator(lastLine);
  final blankOrStartBefore = firstLine == 1 || isBlank(firstLine - 1);
  if (blankOrStartBefore && isBlank(lastLine + 1)) {
    rangeEnd = lines.lineEndIncludingTerminator(lastLine + 1);
  } else if (!exists(lastLine + 1) && firstLine > 1 && isBlank(firstLine - 1)) {
    // Removing the last paragraph of the file: drop the blank line before it.
    rangeStart = lines.lineStart(firstLine - 1);
  }
  return TextRange.fromBounds(rangeStart, rangeEnd);
}

/// Leading whitespace of the line containing [offset].
String indentationAt(GradleScript script, int offset) =>
    script.lineIndex.indentationOf(script.lineIndex.lineOf(offset));

/// The line ending style of [content].
String eolOf(String content) => LineEnding.detect(content).sequence;
