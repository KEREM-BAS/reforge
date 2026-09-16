import '../../common/source.dart';
import '../parse_diagnostic.dart';

enum RubyTokenKind {
  identifier,
  constant,
  symbol,
  string,
  number,
  punctuation,
  newline,
  eof
}

final class RubyToken {
  const RubyToken(this.kind, this.offset, this.end, this.text,
      {this.stringValue, this.contentRange});

  final RubyTokenKind kind;
  final int offset;
  final int end;
  final String text;

  /// Decoded value of string literals without interpolation.
  final String? stringValue;

  /// Range between the quotes of a string literal.
  final TextRange? contentRange;

  bool isWord(String word) =>
      (kind == RubyTokenKind.identifier || kind == RubyTokenKind.constant) &&
      text == word;

  bool isPunctuation(String value) =>
      kind == RubyTokenKind.punctuation && text == value;

  @override
  String toString() => '$kind($text)';
}

/// A Ruby statement with the `do ... end` / keyword `... end` / `{ ... }` blocks
/// attached to it.
final class RubyStatement {
  RubyStatement(this.tokens, this.blocks);

  final List<RubyToken> tokens;
  final List<RubyBlock> blocks;

  int get start => tokens.isEmpty ? 0 : tokens.first.offset;

  String? get firstWord =>
      tokens.isNotEmpty && tokens.first.kind == RubyTokenKind.identifier
          ? tokens.first.text
          : null;
}

final class RubyBlock {
  RubyBlock(this.opener, this.parameters, this.statements, this.endOffset);

  /// The token that opened the block (`do`, `if`, `{`, ...).
  final RubyToken opener;
  final List<String> parameters;
  final List<RubyStatement> statements;
  final int endOffset;

  Iterable<RubyStatement> get allStatements sync* {
    for (final statement in statements) {
      yield statement;
      for (final block in statement.blocks) {
        yield* block.allStatements;
      }
    }
  }
}

/// `platform :ios, '13.0'`.
final class PodfilePlatform {
  const PodfilePlatform({
    required this.name,
    required this.version,
    required this.versionContentRange,
    required this.location,
    required this.commentedOut,
  });

  final String name;
  final String? version;

  /// Range of the version text between quotes, for editing.
  final TextRange? versionContentRange;

  final SourceRef location;

  /// Whether this declaration only exists inside a comment (the Flutter
  /// template ships `# platform :ios, '13.0'`).
  final bool commentedOut;
}

/// `config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '12.0'` inside a
/// Podfile hook.
final class PodfileBuildSettingAssignment {
  const PodfileBuildSettingAssignment({
    required this.setting,
    required this.value,
    required this.valueContentRange,
    required this.location,
  });

  final String setting;

  /// The assigned string, or `null` when the value is not a literal.
  final String? value;
  final TextRange? valueContentRange;
  final SourceRef location;
}

final class PodfileTarget {
  const PodfileTarget(this.name, this.children, this.location);

  final String name;
  final List<PodfileTarget> children;
  final SourceRef location;
}

/// The facts Reforge needs from an iOS `Podfile`.
final class Podfile {
  Podfile._({
    required this.path,
    required this.platform,
    required this.commentedPlatform,
    required this.targets,
    required this.usesFrameworks,
    required this.usesModularHeaders,
    required this.installsFlutterPods,
    required this.callsFlutterPodfileSetup,
    required this.hasPostInstall,
    required this.postInstallStatementCount,
    required this.callsFlutterAdditionalBuildSettings,
    required this.buildSettingAssignments,
    required this.pods,
    required this.diagnostics,
  });

  factory Podfile.parse(String path, String source) {
    final lexer = _RubyLexer(source)..tokenize();
    final parser = _RubyParser(lexer.tokens);
    final statements = parser.parseStatements(topLevel: true);
    final diagnostics = [...lexer.diagnostics, ...parser.diagnostics];
    final lines = LineIndex(source);

    PodfilePlatform? platform;
    final pods = <String>[];
    var usesFrameworks = false;
    var usesModularHeaders = false;
    var installsFlutterPods = false;
    var callsSetup = false;
    var hasPostInstall = false;
    var postInstallCount = 0;
    var callsAdditionalSettings = false;
    final assignments = <PodfileBuildSettingAssignment>[];

    PodfileTarget? targetOf(RubyStatement statement) {
      final tokens = statement.tokens;
      if (statement.firstWord != 'target' ||
          tokens.length < 2 ||
          tokens[1].stringValue == null ||
          statement.blocks.isEmpty) {
        return null;
      }
      final children = <PodfileTarget>[];
      for (final child in statement.blocks.first.statements) {
        final nested = targetOf(child);
        if (nested != null) children.add(nested);
      }
      return PodfileTarget(tokens[1].stringValue!, children,
          lines.refFor(path, tokens.first.offset));
    }

    void visit(Iterable<RubyStatement> all, {required bool inPostInstall}) {
      for (final statement in all) {
        final tokens = statement.tokens;
        final word = statement.firstWord;
        switch (word) {
          case 'platform':
            if (tokens.length >= 4 &&
                tokens[1].kind == RubyTokenKind.symbol &&
                tokens[2].isPunctuation(',') &&
                tokens[3].kind == RubyTokenKind.string) {
              platform = PodfilePlatform(
                name: tokens[1].text.substring(1),
                version: tokens[3].stringValue,
                versionContentRange: tokens[3].contentRange,
                location: lines.refFor(path, tokens.first.offset),
                commentedOut: false,
              );
            } else if (tokens.length >= 2 &&
                tokens[1].kind == RubyTokenKind.symbol) {
              platform = PodfilePlatform(
                name: tokens[1].text.substring(1),
                version: null,
                versionContentRange: null,
                location: lines.refFor(path, tokens.first.offset),
                commentedOut: false,
              );
            }
          case 'use_frameworks!':
            usesFrameworks = true;
          case 'use_modular_headers!':
            usesModularHeaders = true;
          case 'flutter_install_all_ios_pods':
            installsFlutterPods = true;
          case 'flutter_ios_podfile_setup':
            callsSetup = true;
          case 'flutter_additional_ios_build_settings':
            callsAdditionalSettings = true;
          case 'pod':
            if (tokens.length >= 2 && tokens[1].stringValue != null) {
              pods.add(tokens[1].stringValue!);
            }
        }
        // build_settings['KEY'] = 'value'
        for (var i = 0; i + 4 < tokens.length; i++) {
          if (tokens[i].isWord('build_settings') &&
              tokens[i + 1].isPunctuation('[') &&
              tokens[i + 2].stringValue != null &&
              tokens[i + 3].isPunctuation(']') &&
              (tokens[i + 4].isPunctuation('=') ||
                  tokens[i + 4].isPunctuation('||='))) {
            final valueToken = i + 5 < tokens.length ? tokens[i + 5] : null;
            final literal = valueToken?.kind == RubyTokenKind.string &&
                    i + 6 == tokens.length
                ? valueToken
                : null;
            assignments.add(PodfileBuildSettingAssignment(
              setting: tokens[i + 2].stringValue!,
              value: literal?.stringValue,
              valueContentRange: literal?.contentRange,
              location: lines.refFor(path, tokens[i].offset),
            ));
          }
        }
        if (word == 'post_install' && statement.blocks.isNotEmpty) {
          hasPostInstall = true;
          postInstallCount += statement.blocks.first.allStatements.length;
        }
        for (final block in statement.blocks) {
          visit(block.statements,
              inPostInstall: inPostInstall || word == 'post_install');
        }
      }
    }

    visit(statements, inPostInstall: false);

    final targets = <PodfileTarget>[
      for (final statement in statements)
        if (targetOf(statement) case final target?) target,
    ];

    return Podfile._(
      path: path,
      platform: platform,
      commentedPlatform:
          _commentedPlatform(path, source, lexer.comments, lines),
      targets: targets,
      usesFrameworks: usesFrameworks,
      usesModularHeaders: usesModularHeaders,
      installsFlutterPods: installsFlutterPods,
      callsFlutterPodfileSetup: callsSetup,
      hasPostInstall: hasPostInstall,
      postInstallStatementCount: postInstallCount,
      callsFlutterAdditionalBuildSettings: callsAdditionalSettings,
      buildSettingAssignments: assignments,
      pods: pods,
      diagnostics: List.unmodifiable(diagnostics),
    );
  }

  final String path;

  /// The active `platform` declaration, if any.
  final PodfilePlatform? platform;

  /// A commented-out `# platform :ios, 'x'` line, if any.
  final PodfilePlatform? commentedPlatform;

  final List<PodfileTarget> targets;
  final bool usesFrameworks;
  final bool usesModularHeaders;
  final bool installsFlutterPods;
  final bool callsFlutterPodfileSetup;
  final bool hasPostInstall;

  /// Number of statements inside `post_install` (the template has 2).
  final int postInstallStatementCount;
  final bool callsFlutterAdditionalBuildSettings;

  /// Every `build_settings['X'] = ...` assignment in the file.
  final List<PodfileBuildSettingAssignment> buildSettingAssignments;

  /// Explicitly declared pods.
  final List<String> pods;

  final List<ParseDiagnostic> diagnostics;

  bool get isReliable => diagnostics.isEmpty;
}

PodfilePlatform? _commentedPlatform(
    String path, String source, List<TextRange> comments, LineIndex lines) {
  final pattern =
      RegExp(r'''^#\s*platform\s+:(\w+)\s*,\s*(['"])([^'"]+)\2\s*$''');
  for (final comment in comments) {
    final match = pattern.firstMatch(comment.textOf(source).trimRight());
    if (match == null) continue;
    return PodfilePlatform(
      name: match.group(1)!,
      version: match.group(3),
      versionContentRange: null,
      location: lines.refFor(path, comment.offset),
      commentedOut: true,
    );
  }
  return null;
}

const _blockKeywords = {'def', 'class', 'module', 'begin', 'case', 'for'};
const _conditionalKeywords = {'if', 'unless', 'while', 'until'};

final class _RubyLexer {
  _RubyLexer(this.source);

  final String source;
  final List<RubyToken> tokens = [];
  final List<TextRange> comments = [];
  final List<ParseDiagnostic> diagnostics = [];
  final List<({String terminator, bool squiggly})> _pendingHeredocs = [];
  int _pos = 0;

  int _char(int i) => i < source.length ? source.codeUnitAt(i) : -1;

  void _error(int offset, String message) =>
      diagnostics.add(ParseDiagnostic(TextRange(offset, 0), message));

  void tokenize() {
    if (_char(0) == 0xFEFF) _pos = 1;
    while (_pos < source.length) {
      final lineStart = _pos == 0 || _char(_pos - 1) == 0x0A;
      if (lineStart && source.startsWith('=begin', _pos)) {
        final end = source.indexOf('\n=end', _pos);
        final stop = end == -1 ? source.length : source.indexOf('\n', end + 1);
        comments
            .add(TextRange.fromBounds(_pos, stop == -1 ? source.length : stop));
        if (end == -1) _error(_pos, 'Unterminated =begin comment.');
        _pos = stop == -1 ? source.length : stop;
        continue;
      }
      _scan();
    }
    if (_pendingHeredocs.isNotEmpty) {
      _error(source.length, 'Unterminated heredoc.');
    }
    tokens.add(RubyToken(RubyTokenKind.eof, source.length, source.length, ''));
  }

  bool _isIdentStart(int c) =>
      (c >= 0x61 && c <= 0x7A) || c == 0x5F || c > 0x7F;
  bool _isConstStart(int c) => c >= 0x41 && c <= 0x5A;
  bool _isIdentPart(int c) =>
      _isIdentStart(c) || _isConstStart(c) || (c >= 0x30 && c <= 0x39);

  bool get _expressionStart {
    if (tokens.isEmpty) return true;
    final last = tokens.last;
    switch (last.kind) {
      case RubyTokenKind.newline:
        return true;
      case RubyTokenKind.punctuation:
        return !const {')', ']', '}'}.contains(last.text);
      case RubyTokenKind.identifier:
        return const {
          'if',
          'unless',
          'when',
          'and',
          'or',
          'not',
          'return',
          'match',
          'split',
          'gsub',
          'sub',
          'scan',
          'puts'
        }.contains(last.text);
      default:
        return false;
    }
  }

  void _scan() {
    final c = _char(_pos);
    if (c == 0x20 || c == 0x09 || c == 0x0D) {
      _pos++;
      return;
    }
    if (c == 0x5C && _char(_pos + 1) == 0x0A) {
      _pos += 2;
      return;
    }
    if (c == 0x0A) {
      tokens.add(RubyToken(RubyTokenKind.newline, _pos, _pos + 1, '\n'));
      _pos++;
      if (_pendingHeredocs.isNotEmpty) _consumeHeredocBodies();
      return;
    }
    if (c == 0x23 /* # */) {
      final start = _pos;
      while (_pos < source.length && _char(_pos) != 0x0A) {
        _pos++;
      }
      comments.add(TextRange.fromBounds(start, _pos));
      return;
    }
    if (c == 0x27 || c == 0x22 || c == 0x60) {
      _scanQuoted(c, c, interpolates: c != 0x27);
      return;
    }
    if (c == 0x25 /* % */ && _expressionStart) {
      if (_scanPercentLiteral()) return;
    }
    if (c == 0x3C && _char(_pos + 1) == 0x3C && _heredocAhead()) {
      return;
    }
    if (c == 0x2F /* / */ && _expressionStart) {
      _scanQuoted(0x2F, 0x2F, interpolates: true, regex: true);
      return;
    }
    if (c == 0x3A /* : */ &&
        (_isIdentStart(_char(_pos + 1)) || _isConstStart(_char(_pos + 1)))) {
      final start = _pos;
      _pos++;
      while (_isIdentPart(_char(_pos))) {
        _pos++;
      }
      if (_char(_pos) == 0x3F || _char(_pos) == 0x21) _pos++;
      tokens.add(RubyToken(
          RubyTokenKind.symbol, start, _pos, source.substring(start, _pos)));
      return;
    }
    if (_isIdentStart(c) || _isConstStart(c) || c == 0x40 || c == 0x24) {
      final start = _pos;
      _pos++;
      while (_isIdentPart(_char(_pos)) || _char(_pos) == 0x40) {
        _pos++;
      }
      final next = _char(_pos);
      if ((next == 0x3F || next == 0x21) && _char(_pos + 1) != 0x3D) {
        _pos++;
      }
      final text = source.substring(start, _pos);
      tokens.add(RubyToken(
          _isConstStart(c) ? RubyTokenKind.constant : RubyTokenKind.identifier,
          start,
          _pos,
          text));
      return;
    }
    if (c >= 0x30 && c <= 0x39) {
      final start = _pos;
      while (_isIdentPart(_char(_pos)) ||
          (_char(_pos) == 0x2E &&
              _char(_pos + 1) >= 0x30 &&
              _char(_pos + 1) <= 0x39)) {
        _pos++;
      }
      tokens.add(RubyToken(
          RubyTokenKind.number, start, _pos, source.substring(start, _pos)));
      return;
    }
    // Longest operators first.
    const multi = [
      '**=', '<=>', '===', '...', '||=', '&&=', '<<=', '>>=', '&&', '||', //
      '==', '!=', '>=', '<=', '=>', '->', '::', '..', '+=', '-=', '*=', '/=',
      '<<', '>>', '=~', '!~', '**',
    ];
    for (final op in multi) {
      if (source.startsWith(op, _pos)) {
        tokens.add(
            RubyToken(RubyTokenKind.punctuation, _pos, _pos + op.length, op));
        _pos += op.length;
        return;
      }
    }
    tokens.add(RubyToken(
        RubyTokenKind.punctuation, _pos, _pos + 1, String.fromCharCode(c)));
    _pos++;
  }

  bool _heredocAhead() {
    final match = RegExp(r'''<<([~-]?)(['"]?)([A-Z_][A-Z0-9_]*)\2''')
        .matchAsPrefix(source, _pos);
    if (match == null) return false;
    _pendingHeredocs.add(
        (terminator: match.group(3)!, squiggly: match.group(1)!.isNotEmpty));
    tokens.add(RubyToken(RubyTokenKind.string, _pos, match.end,
        source.substring(_pos, match.end)));
    _pos = match.end;
    return true;
  }

  void _consumeHeredocBodies() {
    for (final heredoc in List.of(_pendingHeredocs)) {
      var found = false;
      while (_pos < source.length) {
        final lineEnd = source.indexOf('\n', _pos);
        final end = lineEnd == -1 ? source.length : lineEnd;
        final line = source.substring(_pos, end);
        _pos = lineEnd == -1 ? source.length : lineEnd + 1;
        final candidate = heredoc.squiggly ? line.trim() : line.trimRight();
        if (candidate == heredoc.terminator) {
          found = true;
          break;
        }
      }
      if (!found) _error(_pos, 'Unterminated heredoc ${heredoc.terminator}.');
      _pendingHeredocs.remove(heredoc);
    }
  }

  bool _scanPercentLiteral() {
    var index = _pos + 1;
    final type = _char(index);
    if (const [0x77, 0x57, 0x69, 0x49, 0x71, 0x51, 0x72].contains(type)) {
      index++;
    }
    final open = _char(index);
    const pairs = {0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D, 0x3C: 0x3E};
    final close = pairs[open] ?? (open == 0x7C || open == 0x21 ? open : null);
    if (close == null) return false;
    _pos = index;
    _scanQuoted(open, close,
        interpolates: type != 0x71 && type != 0x77 && type != 0x69);
    return true;
  }

  void _scanQuoted(int open, int close,
      {required bool interpolates, bool regex = false}) {
    final start = _pos;
    _pos++;
    final contentStart = _pos;
    final value = StringBuffer();
    var hasInterpolation = false;
    var depth = 1;
    while (_pos < source.length) {
      final c = _char(_pos);
      if (c == 0x5C && _pos + 1 < source.length) {
        final next = _char(_pos + 1);
        if (open == 0x27) {
          // Single quotes only recognize \' and \\.
          if (next != 0x27 && next != 0x5C) value.writeCharCode(c);
          value.writeCharCode(next);
        } else {
          value.write(switch (next) {
            0x6E => '\n',
            0x74 => '\t',
            0x73 => ' ',
            _ => String.fromCharCode(next),
          });
        }
        _pos += 2;
        continue;
      }
      if (interpolates && c == 0x23 && _char(_pos + 1) == 0x7B) {
        hasInterpolation = true;
        var braces = 1;
        _pos += 2;
        while (_pos < source.length && braces > 0) {
          final d = _char(_pos);
          if (d == 0x7B) braces++;
          if (d == 0x7D) braces--;
          if (d == 0x22 || d == 0x27) {
            final quote = d;
            _pos++;
            while (_pos < source.length && _char(_pos) != quote) {
              if (_char(_pos) == 0x5C) _pos++;
              _pos++;
            }
          }
          _pos++;
        }
        continue;
      }
      if (open != close && c == open) depth++;
      if (c == close) {
        depth--;
        if (depth == 0) break;
      }
      value.writeCharCode(c);
      _pos++;
    }
    if (_pos >= source.length) {
      _error(start, 'Unterminated string literal.');
      tokens.add(RubyToken(
          RubyTokenKind.string, start, source.length, source.substring(start)));
      return;
    }
    final contentEnd = _pos;
    _pos++;
    if (regex) {
      while (_isIdentPart(_char(_pos))) {
        _pos++;
      }
    }
    tokens.add(RubyToken(
      RubyTokenKind.string,
      start,
      _pos,
      source.substring(start, _pos),
      stringValue: hasInterpolation || regex ? null : value.toString(),
      contentRange: TextRange.fromBounds(contentStart, contentEnd),
    ));
  }
}

final class _RubyParser {
  _RubyParser(this._tokens);

  final List<RubyToken> _tokens;
  final List<ParseDiagnostic> diagnostics = [];
  int _pos = 0;

  RubyToken get _peek => _tokens[_pos];

  List<RubyStatement> parseStatements(
      {required bool topLevel, bool braceBlock = false}) {
    final statements = <RubyStatement>[];
    while (true) {
      while (_peek.kind == RubyTokenKind.newline || _peek.isPunctuation(';')) {
        _pos++;
      }
      final token = _peek;
      if (token.kind == RubyTokenKind.eof) {
        if (!topLevel) {
          diagnostics.add(ParseDiagnostic(TextRange(token.offset, 0),
              'Missing "end" or "}" before the end of the file.'));
        }
        return statements;
      }
      if (!braceBlock && token.isWord('end')) {
        if (topLevel) {
          diagnostics.add(
              ParseDiagnostic(TextRange(token.offset, 3), 'Unexpected "end".'));
          _pos++;
          continue;
        }
        return statements;
      }
      if (braceBlock && token.isPunctuation('}')) {
        return statements;
      }
      statements.add(_parseStatement(braceBlock: braceBlock));
    }
  }

  RubyStatement _parseStatement({required bool braceBlock}) {
    final tokens = <RubyToken>[];
    final blocks = <RubyBlock>[];
    var parens = 0;
    var loopKeyword = false;
    while (true) {
      final token = _peek;
      if (token.kind == RubyTokenKind.eof) break;
      if (parens == 0 &&
          (token.kind == RubyTokenKind.newline || token.isPunctuation(';'))) {
        final last = tokens.isEmpty ? null : tokens.last;
        final continues = last != null &&
            last.kind == RubyTokenKind.punctuation &&
            const {
              ',',
              '.',
              '&&',
              '||',
              '+',
              '-',
              '*',
              '=',
              '=>',
              '(',
              '[',
              '|',
              '\\',
              '::',
              '?',
              ':'
            }.contains(last.text) &&
            token.kind == RubyTokenKind.newline;
        if (continues) {
          _pos++;
          continue;
        }
        break;
      }
      if (token.kind == RubyTokenKind.newline) {
        _pos++;
        continue;
      }
      final afterDot = tokens.isNotEmpty && tokens.last.isPunctuation('.');
      if (parens == 0 &&
          ((token.isWord('end') && !afterDot) ||
              (braceBlock && token.isPunctuation('}')))) {
        break;
      }
      final atStatementStart = tokens.isEmpty ||
          (tokens.last.kind == RubyTokenKind.punctuation &&
              const {'=', '(', ',', '||', '&&', '||=', '=>'}
                  .contains(tokens.last.text)) ||
          tokens.last.isWord('return');
      final opensKeywordBlock = token.kind == RubyTokenKind.identifier &&
          ((_blockKeywords.contains(token.text) && atStatementStart) ||
              (_conditionalKeywords.contains(token.text) && atStatementStart) ||
              (token.text == 'do' && !loopKeyword && !afterDot));
      if (opensKeywordBlock) {
        if (const {'while', 'until', 'for'}.contains(token.text)) {
          loopKeyword = true;
        }
        tokens.add(token);
        _pos++;
        final isDo = token.text == 'do';
        final parameters = isDo ? _blockParameters() : const <String>[];
        // For keyword blocks the rest of the line is part of the header.
        final body = parseStatements(topLevel: false);
        if (_peek.isWord('end')) {
          blocks.add(RubyBlock(token, parameters, body, _peek.end));
          _pos++;
          continue;
        }
        blocks.add(RubyBlock(token, parameters, body, _peek.offset));
        break;
      }
      if (token.isWord('do') && loopKeyword) {
        tokens.add(token);
        _pos++;
        continue;
      }
      if (token.isPunctuation('{')) {
        _pos++;
        final parameters = _blockParameters();
        final body = parseStatements(topLevel: false, braceBlock: true);
        if (_peek.isPunctuation('}')) {
          blocks.add(RubyBlock(token, parameters, body, _peek.end));
          _pos++;
        } else {
          diagnostics.add(
              ParseDiagnostic(TextRange(token.offset, 1), 'Unterminated "{".'));
          blocks.add(RubyBlock(token, parameters, body, _peek.offset));
        }
        continue;
      }
      if (token.isPunctuation('(') || token.isPunctuation('[')) parens++;
      if (token.isPunctuation(')') || token.isPunctuation(']')) {
        if (parens == 0) {
          diagnostics.add(ParseDiagnostic(
              TextRange(token.offset, 1), 'Unbalanced "${token.text}".'));
        } else {
          parens--;
        }
      }
      tokens.add(token);
      _pos++;
    }
    if (parens != 0) {
      diagnostics.add(ParseDiagnostic(
          TextRange(tokens.isEmpty ? 0 : tokens.first.offset, 0),
          'Unbalanced parentheses or brackets.'));
    }
    return RubyStatement(List.unmodifiable(tokens), List.unmodifiable(blocks));
  }

  List<String> _blockParameters() {
    var index = _pos;
    while (_tokens[index].kind == RubyTokenKind.newline) {
      index++;
    }
    if (!_tokens[index].isPunctuation('|')) return const [];
    final names = <String>[];
    index++;
    while (index < _tokens.length && !_tokens[index].isPunctuation('|')) {
      if (_tokens[index].kind == RubyTokenKind.identifier) {
        names.add(_tokens[index].text);
      }
      if (_tokens[index].kind == RubyTokenKind.newline ||
          _tokens[index].kind == RubyTokenKind.eof) {
        return const [];
      }
      index++;
    }
    _pos = index + 1;
    return names;
  }
}
