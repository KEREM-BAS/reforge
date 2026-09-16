import '../../common/source.dart';
import '../parse_diagnostic.dart';

/// The Gradle build script language.
enum GradleDialect {
  groovy,
  kotlin;

  static GradleDialect forPath(String path) =>
      path.endsWith('.kts') ? GradleDialect.kotlin : GradleDialect.groovy;
}

enum GradleTokenKind { identifier, number, string, punctuation, newline, eof }

/// A lexical token of a Gradle build script.
final class GradleToken {
  const GradleToken(this.kind, this.offset, this.end, this.text, {this.string});

  final GradleTokenKind kind;
  final int offset;
  final int end;

  /// The exact source text of the token.
  final String text;

  /// Details for [GradleTokenKind.string] tokens.
  final GradleStringLiteral? string;

  TextRange get range => TextRange.fromBounds(offset, end);

  bool isPunctuation(String value) =>
      kind == GradleTokenKind.punctuation && text == value;

  bool isIdentifier([String? name]) =>
      kind == GradleTokenKind.identifier &&
      (name == null || identifierName == name);

  /// The identifier name without Kotlin backticks.
  String get identifierName =>
      text.length > 1 && text.startsWith('`') && text.endsWith('`')
          ? text.substring(1, text.length - 1)
          : text;

  @override
  String toString() =>
      '$kind(${kind == GradleTokenKind.newline ? r'\n' : text})';
}

/// A string literal with its decoded parts.
final class GradleStringLiteral {
  const GradleStringLiteral({
    required this.quote,
    required this.contentRange,
    required this.parts,
  });

  /// The opening delimiter: `'`, `"`, `'''`, `"""`, `/` or `$/`.
  final String quote;

  /// Range of the content between the delimiters.
  final TextRange contentRange;

  final List<GradleStringPart> parts;

  bool get hasInterpolation => parts.any((p) => p is GradleInterpolation);

  /// The decoded value when the literal has no interpolation.
  String? get constantValue => hasInterpolation
      ? null
      : parts.whereType<GradleStringText>().map((p) => p.value).join();

  /// A display form where interpolations keep their source text.
  String get templateText => parts
      .map((p) => switch (p) {
            GradleStringText(:final value) => value,
            GradleInterpolation(:final sourceText) => sourceText,
          })
      .join();
}

sealed class GradleStringPart {
  const GradleStringPart(this.range);

  final TextRange range;
}

final class GradleStringText extends GradleStringPart {
  const GradleStringText(super.range, this.value);

  /// The decoded text (escape sequences resolved).
  final String value;
}

final class GradleInterpolation extends GradleStringPart {
  const GradleInterpolation(super.range, this.sourceText, this.reference);

  /// The interpolation as written, for example `$kotlin_version` or
  /// `${rootProject.buildDir}`.
  final String sourceText;

  /// The referenced variable or property path when the interpolation is a
  /// plain reference (`$name`, `${name}`, `${a.b}`), otherwise `null`.
  final String? reference;
}

final class GradleLexResult {
  const GradleLexResult(this.tokens, this.comments, this.diagnostics);

  /// Tokens excluding comments; always terminated by an EOF token.
  final List<GradleToken> tokens;

  /// Ranges of comments.
  final List<TextRange> comments;

  final List<ParseDiagnostic> diagnostics;
}

const _groovyStartsExpression = {
  'return', 'case', 'in', 'assert', 'if', 'while', 'else', 'throw', 'and', //
};

/// Tokenizes Groovy and Kotlin DSL build scripts.
///
/// The lexer is deliberately tolerant: it recognizes the lexical structure
/// needed to find statements, blocks, strings and comments reliably, and it
/// reports anything it cannot tokenize as a diagnostic instead of guessing.
final class GradleLexer {
  GradleLexer(this.source, this.dialect);

  final String source;
  final GradleDialect dialect;

  final List<GradleToken> _tokens = [];
  final List<TextRange> _comments = [];
  final List<ParseDiagnostic> _diagnostics = [];
  int _pos = 0;

  static const _punctuation = [
    '===', '!==', '..<', '?.', '?:', '?[', '::', '..', '->', '=>', '==', //
    '!=', '<=', '>=', '&&', '||', '++', '--', '+=', '-=', '*=', '/=', '%=',
    '=~', '<<', '>>', '**', '!!', '*.', '.&', '{', '}', '(', ')', '[', ']',
    ',', ';', '.', ':', '=', '+', '-', '*', '/', '%', '<', '>', '!', '?',
    '&', '|', '^', '~', '@', '#',
  ];

  GradleLexResult tokenize() {
    if (source.startsWith('\uFEFF')) _pos = 1;
    if (source.startsWith('#!', _pos)) {
      _skipLineComment();
    }
    while (_pos < source.length) {
      _scanToken();
    }
    _tokens.add(
        GradleToken(GradleTokenKind.eof, source.length, source.length, ''));
    return GradleLexResult(List.unmodifiable(_tokens),
        List.unmodifiable(_comments), List.unmodifiable(_diagnostics));
  }

  int _char(int index) => index < source.length ? source.codeUnitAt(index) : -1;

  void _error(int offset, String message) {
    _diagnostics.add(ParseDiagnostic(TextRange(offset, 0), message));
  }

  void _scanToken() {
    final c = _char(_pos);
    // Whitespace (a lone CR is whitespace; LF produces a newline token).
    if (c == 0x20 || c == 0x09 || c == 0x0C || c == 0x0D) {
      _pos++;
      return;
    }
    if (c == 0x0A) {
      _tokens.add(GradleToken(GradleTokenKind.newline, _pos, _pos + 1, '\n'));
      _pos++;
      return;
    }
    // Backslash line continuation.
    if (c == 0x5C &&
        (_char(_pos + 1) == 0x0A ||
            (_char(_pos + 1) == 0x0D && _char(_pos + 2) == 0x0A))) {
      _pos += _char(_pos + 1) == 0x0A ? 2 : 3;
      return;
    }
    if (c == 0x2F /* / */) {
      if (_char(_pos + 1) == 0x2F) {
        _skipLineComment();
        return;
      }
      if (_char(_pos + 1) == 0x2A) {
        _skipBlockComment();
        return;
      }
      if (dialect == GradleDialect.groovy && _slashyStringAllowed()) {
        _scanSlashyString();
        return;
      }
    }
    if (c == 0x24 /* $ */ &&
        _char(_pos + 1) == 0x2F &&
        dialect == GradleDialect.groovy) {
      _scanDollarSlashyString();
      return;
    }
    if (c == 0x22 /* " */ || c == 0x27 /* ' */) {
      _scanString();
      return;
    }
    if (c == 0x60 /* ` */) {
      _scanBacktickIdentifier();
      return;
    }
    if (_isIdentifierStart(c)) {
      final start = _pos;
      while (_isIdentifierPart(_char(_pos))) {
        _pos++;
      }
      _tokens.add(GradleToken(GradleTokenKind.identifier, start, _pos,
          source.substring(start, _pos)));
      return;
    }
    if (_isDigit(c)) {
      _scanNumber();
      return;
    }
    for (final punctuation in _punctuation) {
      if (source.startsWith(punctuation, _pos)) {
        _tokens.add(GradleToken(GradleTokenKind.punctuation, _pos,
            _pos + punctuation.length, punctuation));
        _pos += punctuation.length;
        return;
      }
    }
    _error(_pos, 'Unexpected character "${String.fromCharCode(c)}".');
    _pos++;
  }

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  static bool _isIdentifierStart(int c) =>
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F ||
      c == 0x24 ||
      c > 0x7F;

  static bool _isIdentifierPart(int c) => _isIdentifierStart(c) || _isDigit(c);

  void _skipLineComment() {
    final start = _pos;
    while (_pos < source.length && _char(_pos) != 0x0A) {
      _pos++;
    }
    _comments.add(TextRange.fromBounds(start, _pos));
  }

  void _skipBlockComment() {
    final start = _pos;
    _pos += 2;
    var depth = 1;
    while (_pos < source.length) {
      if (_char(_pos) == 0x2A && _char(_pos + 1) == 0x2F) {
        _pos += 2;
        depth--;
        if (depth == 0) {
          _comments.add(TextRange.fromBounds(start, _pos));
          return;
        }
        continue;
      }
      // Kotlin block comments nest; Groovy ones do not.
      if (dialect == GradleDialect.kotlin &&
          _char(_pos) == 0x2F &&
          _char(_pos + 1) == 0x2A) {
        _pos += 2;
        depth++;
        continue;
      }
      _pos++;
    }
    _comments.add(TextRange.fromBounds(start, _pos));
    _error(start, 'Unterminated block comment.');
  }

  /// Groovy slashy strings (`/regex/`) are only possible where an expression
  /// may start; elsewhere `/` is division.
  bool _slashyStringAllowed() {
    final next = _char(_pos + 1);
    if (next == 0x3D /* = */ || next == 0x20 || next == 0x0A || next == -1) {
      return false;
    }
    if (_tokens.isEmpty) return true;
    final previous = _tokens.last;
    switch (previous.kind) {
      case GradleTokenKind.newline:
        return true;
      case GradleTokenKind.identifier:
        return _groovyStartsExpression.contains(previous.text);
      case GradleTokenKind.number:
      case GradleTokenKind.string:
        return false;
      case GradleTokenKind.punctuation:
        return !const {')', ']', '}', '++', '--', '!!'}.contains(previous.text);
      case GradleTokenKind.eof:
        return false;
    }
  }

  void _scanSlashyString() {
    final start = _pos;
    _pos++;
    final contentStart = _pos;
    final parts = <GradleStringPart>[];
    final text = StringBuffer();
    var textStart = _pos;
    while (_pos < source.length) {
      final c = _char(_pos);
      if (c == 0x2F) {
        break;
      }
      if (c == 0x0A) {
        // Slashy strings may be multiline, but a newline right after a
        // suspected division is far more likely; treat as unterminated.
        break;
      }
      if (c == 0x5C && _char(_pos + 1) == 0x2F) {
        text.write('/');
        _pos += 2;
        continue;
      }
      if (c == 0x24 && _interpolationStartsAt(_pos)) {
        if (_pos > textStart) {
          parts.add(GradleStringText(
              TextRange.fromBounds(textStart, _pos), text.toString()));
          text.clear();
        }
        parts.add(_scanInterpolation());
        textStart = _pos;
        continue;
      }
      text.writeCharCode(c);
      _pos++;
    }
    if (_char(_pos) != 0x2F) {
      // Not a slashy string after all: emit '/' as punctuation and rescan.
      _pos = start + 1;
      _tokens
          .add(GradleToken(GradleTokenKind.punctuation, start, start + 1, '/'));
      return;
    }
    if (_pos > textStart || parts.isEmpty) {
      parts.add(GradleStringText(
          TextRange.fromBounds(textStart, _pos), text.toString()));
    }
    final contentEnd = _pos;
    _pos++;
    _tokens.add(GradleToken(
      GradleTokenKind.string,
      start,
      _pos,
      source.substring(start, _pos),
      string: GradleStringLiteral(
        quote: '/',
        contentRange: TextRange.fromBounds(contentStart, contentEnd),
        parts: List.unmodifiable(parts),
      ),
    ));
  }

  void _scanDollarSlashyString() {
    final start = _pos;
    _pos += 2;
    final contentStart = _pos;
    final end = source.indexOf(r'/$', _pos);
    if (end == -1) {
      _error(start, 'Unterminated dollar-slashy string.');
      _pos = source.length;
      return;
    }
    _pos = end + 2;
    _tokens.add(GradleToken(
      GradleTokenKind.string,
      start,
      _pos,
      source.substring(start, _pos),
      string: GradleStringLiteral(
        quote: r'$/',
        contentRange: TextRange.fromBounds(contentStart, end),
        parts: [
          GradleStringText(TextRange.fromBounds(contentStart, end),
              source.substring(contentStart, end)),
        ],
      ),
    ));
  }

  void _scanBacktickIdentifier() {
    final start = _pos;
    _pos++;
    while (_pos < source.length && _char(_pos) != 0x60 && _char(_pos) != 0x0A) {
      _pos++;
    }
    if (_char(_pos) != 0x60) {
      _error(start, 'Unterminated backtick identifier.');
      return;
    }
    _pos++;
    _tokens.add(GradleToken(GradleTokenKind.identifier, start, _pos,
        source.substring(start, _pos)));
  }

  void _scanNumber() {
    final start = _pos;
    if (_char(_pos) == 0x30 &&
        (_char(_pos + 1) == 0x78 || _char(_pos + 1) == 0x58)) {
      _pos += 2;
      while (_isHex(_char(_pos)) || _char(_pos) == 0x5F) {
        _pos++;
      }
    } else {
      while (_isDigit(_char(_pos)) || _char(_pos) == 0x5F) {
        _pos++;
      }
      if (_char(_pos) == 0x2E && _isDigit(_char(_pos + 1))) {
        _pos++;
        while (_isDigit(_char(_pos)) || _char(_pos) == 0x5F) {
          _pos++;
        }
      }
      if (_char(_pos) == 0x65 || _char(_pos) == 0x45) {
        final save = _pos;
        _pos++;
        if (_char(_pos) == 0x2B || _char(_pos) == 0x2D) _pos++;
        if (_isDigit(_char(_pos))) {
          while (_isDigit(_char(_pos))) {
            _pos++;
          }
        } else {
          _pos = save;
        }
      }
    }
    const suffixes = 'LlFfDdGgIi';
    if (_pos < source.length && suffixes.contains(source[_pos])) {
      _pos++;
    }
    _tokens.add(GradleToken(
        GradleTokenKind.number, start, _pos, source.substring(start, _pos)));
  }

  static bool _isHex(int c) =>
      _isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66);

  bool _interpolationStartsAt(int index) {
    final next = _char(index + 1);
    return next == 0x7B /* { */ || (_isIdentifierStart(next) && next != 0x24);
  }

  void _scanString() {
    final start = _pos;
    final quoteChar = _char(_pos);
    final triple = _char(_pos + 1) == quoteChar && _char(_pos + 2) == quoteChar;
    final quote = String.fromCharCode(quoteChar) * (triple ? 3 : 1);
    _pos += quote.length;
    final contentStart = _pos;

    final isDouble = quoteChar == 0x22;
    final interpolates = isDouble;
    // Kotlin raw strings ("""...""") do not process escape sequences.
    final processesEscapes = !(dialect == GradleDialect.kotlin && triple);

    final parts = <GradleStringPart>[];
    final text = StringBuffer();
    var textStart = _pos;
    var terminated = false;

    while (_pos < source.length) {
      if (source.startsWith(quote, _pos)) {
        // For triple quotes, extra quote characters belong to the content:
        // """a"""" ends with the last three quotes.
        if (triple) {
          while (_char(_pos + 3) == quoteChar) {
            text.writeCharCode(quoteChar);
            _pos++;
          }
        }
        terminated = true;
        break;
      }
      final c = _char(_pos);
      if (!triple && c == 0x0A) {
        break;
      }
      if (c == 0x5C && processesEscapes) {
        _pos++;
        text.write(_decodeEscape());
        continue;
      }
      if (c == 0x24 && interpolates && _interpolationStartsAt(_pos)) {
        if (_pos > textStart) {
          parts.add(GradleStringText(
              TextRange.fromBounds(textStart, _pos), text.toString()));
          text.clear();
        }
        parts.add(_scanInterpolation());
        textStart = _pos;
        continue;
      }
      text.writeCharCode(c);
      _pos++;
    }

    final contentEnd = _pos;
    if (terminated) {
      if (_pos > textStart || parts.isEmpty) {
        parts.add(GradleStringText(
            TextRange.fromBounds(textStart, _pos), text.toString()));
      }
      _pos += quote.length;
    } else {
      _error(start, 'Unterminated string literal.');
    }
    _tokens.add(GradleToken(
      GradleTokenKind.string,
      start,
      _pos,
      source.substring(start, _pos),
      string: GradleStringLiteral(
        quote: quote,
        contentRange: TextRange.fromBounds(contentStart, contentEnd),
        parts: List.unmodifiable(parts),
      ),
    ));
  }

  String _decodeEscape() {
    final c = _char(_pos);
    if (c == -1) return '';
    _pos++;
    switch (c) {
      case 0x6E:
        return '\n';
      case 0x74:
        return '\t';
      case 0x72:
        return '\r';
      case 0x62:
        return '\b';
      case 0x66:
        return '\f';
      case 0x30:
        return '\u0000';
      case 0x75: // \uXXXX
        final hex =
            _pos + 4 <= source.length ? source.substring(_pos, _pos + 4) : '';
        final value = int.tryParse(hex, radix: 16);
        if (value != null) {
          _pos += 4;
          return String.fromCharCode(value);
        }
        return 'u';
      case 0x0A: // line continuation inside a string
        return '';
      default:
        return String.fromCharCode(c);
    }
  }

  GradleInterpolation _scanInterpolation() {
    final start = _pos;
    _pos++; // $
    if (_char(_pos) == 0x7B) {
      _pos++;
      final nested = GradleLexer(source, dialect).._pos = _pos;
      var depth = 1;
      while (nested._pos < source.length) {
        final before = nested._tokens.length;
        final c = nested._char(nested._pos);
        if (c == 0x7D && depth == 1) {
          break;
        }
        nested._scanToken();
        for (var i = before; i < nested._tokens.length; i++) {
          final token = nested._tokens[i];
          if (token.isPunctuation('{')) depth++;
          if (token.isPunctuation('}')) depth--;
        }
        if (depth == 0) break;
      }
      _diagnostics.addAll(nested._diagnostics);
      _pos = nested._pos;
      if (_char(_pos) == 0x7D) {
        _pos++;
      } else {
        _error(start, 'Unterminated string interpolation.');
      }
      final expressionTokens = nested._tokens
          .where((t) => t.kind != GradleTokenKind.newline)
          .toList();
      return GradleInterpolation(
        TextRange.fromBounds(start, _pos),
        source.substring(start, _pos),
        _referenceOf(expressionTokens),
      );
    }
    // $name (Groovy additionally allows dotted property paths: $a.b.c)
    final nameStart = _pos;
    while (_isIdentifierPart(_char(_pos)) && _char(_pos) != 0x24) {
      _pos++;
    }
    if (dialect == GradleDialect.groovy) {
      while (_char(_pos) == 0x2E &&
          _isIdentifierStart(_char(_pos + 1)) &&
          _char(_pos + 1) != 0x24) {
        _pos++;
        while (_isIdentifierPart(_char(_pos)) && _char(_pos) != 0x24) {
          _pos++;
        }
      }
    }
    return GradleInterpolation(
      TextRange.fromBounds(start, _pos),
      source.substring(start, _pos),
      source.substring(nameStart, _pos),
    );
  }

  static String? _referenceOf(List<GradleToken> tokens) {
    if (tokens.isEmpty || tokens.length.isEven) return null;
    for (var i = 0; i < tokens.length; i++) {
      final token = tokens[i];
      if (i.isEven) {
        if (!token.isIdentifier()) return null;
      } else if (!token.isPunctuation('.')) {
        return null;
      }
    }
    return tokens.map((t) => t.text).join();
  }
}
