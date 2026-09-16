import '../common/source.dart';

/// A problem found while parsing a project file.
///
/// Parsers in Reforge are tolerant: they report diagnostics instead of
/// throwing, and consumers decide whether a file parsed reliably enough to be
/// analyzed or edited.
final class ParseDiagnostic {
  const ParseDiagnostic(this.range, this.message);

  final TextRange range;
  final String message;

  @override
  String toString() => '$message (at offset ${range.offset})';
}

/// A structured document (YAML, JSON, XML, plist) is malformed or does not
/// have the expected shape.
final class DocumentParseException implements Exception {
  const DocumentParseException(this.path, this.message, {this.line});

  /// Project-relative path of the document.
  final String path;
  final String message;

  /// 1-based line of the problem, when known.
  final int? line;

  @override
  String toString() =>
      line == null ? '$path: $message' : '$path:$line: $message';
}
