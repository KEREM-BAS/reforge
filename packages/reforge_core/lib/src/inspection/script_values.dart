import '../model/declarations.dart';
import '../parsing/gradle/gradle_lexer.dart';
import '../parsing/gradle/gradle_script.dart';

/// Interprets the value tokens of a Gradle property assignment.
ScriptValue? interpretScriptValue(
    GradleScript script, GradleStatement statement, List<GradleToken>? tokens) {
  if (tokens == null || tokens.isEmpty) return null;
  final location = script.refAt(statement.start);
  final text = script.source.substring(tokens.first.offset, tokens.last.end);
  if (tokens.length == 1) {
    final token = tokens.single;
    if (token.kind == GradleTokenKind.number) {
      final value = int.tryParse(token.text);
      if (value != null) {
        return LiteralInt(value, text, location,
            editable: EditableValue(script.path, token.range));
      }
    }
    final literal = token.string;
    if (literal != null && literal.constantValue != null) {
      final raw = literal.contentRange.textOf(script.source);
      return LiteralString(
        literal.constantValue!,
        text,
        location,
        // Only offer an editable range when the raw text has no escapes, so
        // replacing it cannot change the meaning of other characters.
        editable: raw == literal.constantValue
            ? EditableValue(script.path, literal.contentRange)
            : null,
      );
    }
  }
  if (tokens.length == 3 &&
      tokens[0].isIdentifier('flutter') &&
      tokens[1].isPunctuation('.') &&
      tokens[2].isIdentifier()) {
    return FlutterDefaultReference(tokens[2].identifierName, text, location);
  }
  return OtherExpression(text, location);
}

/// Finds the first statement in [block] assigning or passing one of [names].
(GradleStatement, List<GradleToken>)? findProperty(
    GradleBlock? block, List<String> names) {
  if (block == null) return null;
  for (final statement in block.statements) {
    if (statement.blocks.isNotEmpty) continue;
    for (final name in names) {
      final value = statement.propertyValue(name);
      if (value != null) return (statement, value);
    }
  }
  return null;
}
