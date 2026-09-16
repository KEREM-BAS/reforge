import '../../common/source.dart';
import '../parse_diagnostic.dart';
import 'gradle_lexer.dart';

/// A parsed Gradle build script (Groovy or Kotlin DSL).
///
/// The parser recovers the statement and block structure of a script - enough
/// to answer questions such as "which plugins does the `plugins {}` block
/// declare?" or "where is `namespace` assigned inside `android {}`?" - while
/// keeping exact source offsets for surgical edits. It does not attempt to
/// evaluate the script.
///
/// A script is [isReliable] only when lexing and structure recovery produced no
/// diagnostics. Reforge never edits an unreliable script.
final class GradleScript {
  GradleScript._(this.path, this.source, this.dialect, this.tokens,
      this.comments, this.statements, this.diagnostics)
      : lineIndex = LineIndex(source);

  factory GradleScript.parse(String path, String source,
      {GradleDialect? dialect}) {
    final resolvedDialect = dialect ?? GradleDialect.forPath(path);
    final lexed = GradleLexer(source, resolvedDialect).tokenize();
    final parser = _GradleParser(lexed.tokens);
    final statements = parser.parseStatements(inBlock: false);
    return GradleScript._(
      path,
      source,
      resolvedDialect,
      lexed.tokens,
      lexed.comments,
      statements,
      List.unmodifiable([...lexed.diagnostics, ...parser.diagnostics]),
    );
  }

  /// Project-relative path of the script.
  final String path;
  final String source;
  final GradleDialect dialect;
  final List<GradleToken> tokens;
  final List<TextRange> comments;
  final List<GradleStatement> statements;
  final List<ParseDiagnostic> diagnostics;
  final LineIndex lineIndex;

  bool get isReliable => diagnostics.isEmpty;

  SourceRef refAt(int offset, [int length = 0]) =>
      lineIndex.refFor(path, offset, length);

  /// Top-level statements named [name] that have a block, e.g. `android {}`.
  Iterable<GradleStatement> blocksNamed(String name) =>
      statements.where((s) => s.isBlockNamed(name));

  /// Finds a nested block by a path of block names, e.g.
  /// `['android', 'defaultConfig']`. Returns the first match.
  GradleBlock? findBlock(List<String> path) {
    var candidates = statements;
    GradleBlock? found;
    for (final name in path) {
      final statement =
          candidates.where((s) => s.isBlockNamed(name)).firstOrNull;
      if (statement == null) return null;
      found = statement.blocks.first;
      candidates = found.statements;
    }
    return found;
  }

  /// Every statement in the script, depth-first, including nested blocks.
  Iterable<GradleStatement> get allStatements sync* {
    Iterable<GradleStatement> walk(List<GradleStatement> list) sync* {
      for (final statement in list) {
        yield statement;
        for (final block in [...statement.blocks, ...statement.innerBlocks]) {
          yield* walk(block.statements);
        }
      }
    }

    yield* walk(statements);
  }

  /// Whether [offset] lies inside a comment.
  bool isInComment(int offset) => comments.any((c) => c.contains(offset));
}

/// A block delimited by braces: a Groovy closure or Kotlin lambda body.
final class GradleBlock {
  GradleBlock(
      this.openBrace, this.closeBrace, this.parameters, this.statements);

  /// Offset of `{`.
  final int openBrace;

  /// Offset of `}` (or the end of the source when unterminated).
  final int closeBrace;

  /// Closure/lambda parameter names declared before `->`.
  final List<String> parameters;

  final List<GradleStatement> statements;

  Iterable<GradleStatement> blocksNamed(String name) =>
      statements.where((s) => s.isBlockNamed(name));

  GradleBlock? findBlock(List<String> path) {
    GradleBlock? current = this;
    for (final name in path) {
      final statement =
          current!.statements.where((s) => s.isBlockNamed(name)).firstOrNull;
      if (statement == null) return null;
      current = statement.blocks.first;
    }
    return current;
  }
}

/// A statement: tokens up to the end of the logical line, plus any blocks
/// attached to it (`android { ... }`, `if (x) { } else { }`).
final class GradleStatement {
  GradleStatement(
      this.tokens, this.blocks, this.innerBlocks, this.start, this.end);

  /// Tokens of the statement outside of its blocks (no newline tokens).
  final List<GradleToken> tokens;

  /// Blocks at the statement's top level, in source order.
  final List<GradleBlock> blocks;

  /// Blocks nested inside parentheses or brackets, e.g. `foo({ ... })`.
  final List<GradleBlock> innerBlocks;

  /// Offset of the first token.
  final int start;

  /// Offset just past the last token or closing brace.
  final int end;

  TextRange get range => TextRange.fromBounds(start, end);

  /// Tokens before the first top-level block.
  List<GradleToken> get head {
    if (blocks.isEmpty) return tokens;
    final firstBlock = blocks.first.openBrace;
    return tokens.where((t) => t.offset < firstBlock).toList();
  }

  /// The leading dotted identifier path, e.g. `android`, `tasks.register`,
  /// `ext.kotlin_version`. Empty when the statement does not start with an
  /// identifier.
  String get leadingPath {
    final buffer = StringBuffer();
    var expectIdentifier = true;
    for (final token in tokens) {
      if (expectIdentifier) {
        if (!token.isIdentifier()) break;
        buffer.write(token.identifierName);
      } else {
        if (!token.isPunctuation('.')) break;
        buffer.write('.');
      }
      expectIdentifier = !expectIdentifier;
    }
    final text = buffer.toString();
    return text.endsWith('.') ? text.substring(0, text.length - 1) : text;
  }

  /// Whether this is `name { ... }` (optionally `name(...) { ... }` is not
  /// matched; use [leadingPath] for calls with arguments).
  bool isBlockNamed(String name) {
    if (blocks.isEmpty) return false;
    final head = this.head;
    if (head.isEmpty) return false;
    final parts = name.split('.');
    if (head.length != parts.length * 2 - 1) return false;
    for (var i = 0; i < head.length; i++) {
      final token = head[i];
      if (i.isEven) {
        if (!token.isIdentifier(parts[i ~/ 2])) return false;
      } else if (!token.isPunctuation('.')) {
        return false;
      }
    }
    return true;
  }

  /// For `name = value` statements: the assigned tokens. Returns `null` when
  /// the statement is not a simple assignment to [name].
  List<GradleToken>? assignmentValue(String name) {
    final head = this.head;
    final parts = name.split('.');
    final nameTokenCount = parts.length * 2 - 1;
    if (head.length <= nameTokenCount + 1) return null;
    for (var i = 0; i < nameTokenCount; i++) {
      final token = head[i];
      if (i.isEven) {
        if (!token.isIdentifier(parts[i ~/ 2])) return null;
      } else if (!token.isPunctuation('.')) {
        return null;
      }
    }
    if (!head[nameTokenCount].isPunctuation('=')) return null;
    return head.sublist(nameTokenCount + 1);
  }

  /// For Groovy command-style statements `name value` (e.g.
  /// `compileSdkVersion 33`) and call-style `name(value)`: the argument
  /// tokens. Returns `null` when the statement has a different shape.
  List<GradleToken>? commandArguments(String name) {
    final head = this.head;
    if (head.length < 2 || !head.first.isIdentifier(name)) return null;
    final second = head[1];
    if (second.isPunctuation('(')) {
      if (!head.last.isPunctuation(')')) return null;
      // Make sure the closing parenthesis matches the opening one.
      var depth = 0;
      for (var i = 1; i < head.length; i++) {
        if (head[i].isPunctuation('(')) depth++;
        if (head[i].isPunctuation(')')) {
          depth--;
          if (depth == 0 && i != head.length - 1) return null;
        }
      }
      return head.sublist(2, head.length - 1);
    }
    if (second.kind == GradleTokenKind.punctuation &&
        !second.isPunctuation('-') &&
        !second.isPunctuation('[')) {
      return null;
    }
    return head.sublist(1);
  }

  /// The value assigned or passed to [property], supporting `name = value`,
  /// `name value` and `name(value)`.
  List<GradleToken>? propertyValue(String property) =>
      assignmentValue(property) ?? commandArguments(property);
}

final class _GradleParser {
  _GradleParser(this._tokens);

  final List<GradleToken> _tokens;
  final List<ParseDiagnostic> diagnostics = [];
  int _pos = 0;

  GradleToken get _peek => _tokens[_pos];

  GradleToken _peekAt(int index) =>
      index < _tokens.length ? _tokens[index] : _tokens.last;

  static const _continuationEnders = {
    '.', '?.', ',', '=', '+=', '-=', '*=', '/=', '->', '&&', '||', '+', //
    '-', '*', '/', '%', '?:', '?', ':', '==', '!=', '<', '>', '<=', '>=',
    '&', '|', '=~', '(', '[', '..', '..<', '::', '!',
  };

  static const _continuationStarters = {'.', '?.', '?:', '&&', '||'};

  static const _blockContinuationKeywords = {'else', 'catch', 'finally'};

  List<GradleStatement> parseStatements({required bool inBlock}) {
    final statements = <GradleStatement>[];
    while (true) {
      _skipSeparators();
      final token = _peek;
      if (token.kind == GradleTokenKind.eof) {
        break;
      }
      if (token.isPunctuation('}')) {
        if (inBlock) break;
        diagnostics.add(ParseDiagnostic(token.range, 'Unexpected "}".'));
        _pos++;
        continue;
      }
      if (token.isPunctuation(')') || token.isPunctuation(']')) {
        diagnostics
            .add(ParseDiagnostic(token.range, 'Unexpected "${token.text}".'));
        _pos++;
        continue;
      }
      statements.add(_parseStatement());
    }
    return statements;
  }

  void _skipSeparators() {
    while (_peek.kind == GradleTokenKind.newline || _peek.isPunctuation(';')) {
      _pos++;
    }
  }

  GradleStatement _parseStatement() {
    final tokens = <GradleToken>[];
    final blocks = <GradleBlock>[];
    final innerBlocks = <GradleBlock>[];
    final start = _peek.offset;
    var end = start;
    final delimiters = <String>[];

    while (true) {
      final token = _peek;
      if (token.kind == GradleTokenKind.eof) {
        if (delimiters.isNotEmpty) {
          diagnostics.add(ParseDiagnostic(TextRange(start, 0),
              'Unclosed "${delimiters.last}" in statement.'));
        }
        break;
      }
      if (delimiters.isEmpty) {
        if (token.isPunctuation(';')) break;
        if (token.kind == GradleTokenKind.newline) {
          if (_continuesAfterNewline(tokens, blocks)) {
            _pos++;
            continue;
          }
          break;
        }
        if (token.isPunctuation('}') ||
            token.isPunctuation(')') ||
            token.isPunctuation(']')) {
          break;
        }
        if (token.isPunctuation('{')) {
          final block = _parseBlock();
          blocks.add(block);
          end = block.closeBrace + 1;
          if (_continuesAfterBlock()) {
            continue;
          }
          break;
        }
      } else {
        if (token.kind == GradleTokenKind.newline) {
          _pos++;
          continue;
        }
        if (token.isPunctuation('{')) {
          final block = _parseBlock();
          innerBlocks.add(block);
          end = block.closeBrace + 1;
          continue;
        }
        if (token.isPunctuation('}')) {
          diagnostics.add(ParseDiagnostic(token.range,
              'Unexpected "}" while "${delimiters.last}" is open.'));
          break;
        }
      }

      if (token.isPunctuation('(') ||
          token.isPunctuation('[') ||
          token.isPunctuation('?[')) {
        delimiters.add(token.text == '(' ? ')' : ']');
      } else if (token.isPunctuation(')') || token.isPunctuation(']')) {
        if (delimiters.isEmpty || delimiters.last != token.text) {
          diagnostics
              .add(ParseDiagnostic(token.range, 'Mismatched "${token.text}".'));
          if (delimiters.isNotEmpty) delimiters.removeLast();
        } else {
          delimiters.removeLast();
        }
      }
      tokens.add(token);
      end = token.end;
      _pos++;
    }
    return GradleStatement(List.unmodifiable(tokens), List.unmodifiable(blocks),
        List.unmodifiable(innerBlocks), start, end);
  }

  bool _continuesAfterNewline(
      List<GradleToken> tokens, List<GradleBlock> blocks) {
    // Find the last significant token of the statement so far.
    GradleToken? last = tokens.isEmpty ? null : tokens.last;
    if (blocks.isNotEmpty &&
        (last == null || last.offset < blocks.last.closeBrace)) {
      last = null; // statement ended with a block
    }
    if (last != null &&
        last.kind == GradleTokenKind.punctuation &&
        _continuationEnders.contains(last.text)) {
      return true;
    }
    var index = _pos;
    while (_peekAt(index).kind == GradleTokenKind.newline) {
      index++;
    }
    final next = _peekAt(index);
    if (next.kind == GradleTokenKind.punctuation &&
        _continuationStarters.contains(next.text)) {
      _pos = index - 1;
      return true;
    }
    return false;
  }

  bool _continuesAfterBlock() {
    final next = _peek;
    if (next.isPunctuation('(') ||
        next.isPunctuation('.') ||
        next.isPunctuation('?.')) {
      return true;
    }
    if (next.isIdentifier() && _blockContinuationKeywords.contains(next.text)) {
      return true;
    }
    if (next.kind == GradleTokenKind.newline) {
      var index = _pos;
      while (_peekAt(index).kind == GradleTokenKind.newline) {
        index++;
      }
      final following = _peekAt(index);
      if ((following.isIdentifier() &&
              _blockContinuationKeywords.contains(following.text)) ||
          following.isPunctuation('.') ||
          following.isPunctuation('?.')) {
        _pos = index;
        return true;
      }
    }
    return false;
  }

  GradleBlock _parseBlock() {
    final open = _peek;
    _pos++;
    final parameters = _parseClosureParameters();
    final statements = parseStatements(inBlock: true);
    final close = _peek;
    if (close.isPunctuation('}')) {
      _pos++;
      return GradleBlock(open.offset, close.offset, parameters, statements);
    }
    diagnostics.add(ParseDiagnostic(open.range, 'Unterminated block.'));
    return GradleBlock(open.offset, close.offset, parameters, statements);
  }

  /// Recognizes `a, b ->` (and Kotlin `(a: T) ->`) at the start of a block.
  List<String> _parseClosureParameters() {
    var index = _pos;
    while (_peekAt(index).kind == GradleTokenKind.newline) {
      index++;
    }
    final names = <String>[];
    var sawArrow = false;
    for (var i = index; i < _tokens.length; i++) {
      final token = _tokens[i];
      if (token.isPunctuation('->')) {
        sawArrow = true;
        index = i + 1;
        break;
      }
      if (token.kind == GradleTokenKind.identifier) {
        names.add(token.identifierName);
        continue;
      }
      if (token.isPunctuation(',') ||
          token.isPunctuation(':') ||
          token.isPunctuation('.') ||
          token.isPunctuation('(') ||
          token.isPunctuation(')') ||
          token.isPunctuation('<') ||
          token.isPunctuation('>') ||
          token.isPunctuation('?')) {
        continue;
      }
      break;
    }
    if (!sawArrow) return const [];
    _pos = index;
    return List.unmodifiable(names);
  }
}
