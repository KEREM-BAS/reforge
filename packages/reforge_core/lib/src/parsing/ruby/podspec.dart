import '../../common/source.dart';
import '../parse_diagnostic.dart';
import 'ruby_syntax.dart';

/// A minimum deployment target declared by a podspec.
final class PodspecPlatform {
  const PodspecPlatform(this.name, this.version, this.location);

  /// `ios`, `osx`, `tvos`, ...
  final String name;

  /// The version as written, or `null` when the platform has no minimum.
  final String? version;

  final SourceRef location;
}

/// A CocoaPods podspec (`Pod::Spec.new do |s| ... end`), read for the
/// platforms and minimum deployment targets a pod declares.
///
/// Recognized declarations, with any name for the spec variable:
/// - `s.platform = :ios, '12.0'`
/// - `s.ios.deployment_target = '12.0'`
/// - `s.platforms = { :ios => '12.0', :osx => '10.14' }` (also `ios: '12.0'`)
///
/// Values computed by Ruby code are not evaluated.
final class Podspec {
  Podspec._(this.path, this.platforms, this.diagnostics);

  factory Podspec.parse(String path, String source) {
    final document = RubyDocument.parse(source);
    final lines = LineIndex(source);
    final platforms = <String, PodspecPlatform>{};

    void add(String name, RubyToken? version, RubyToken at) {
      platforms[name] = PodspecPlatform(
          name, version?.stringValue, lines.refFor(path, at.offset));
    }

    for (final statement in document.allStatements) {
      final t = statement.tokens;
      bool member(int index, String name) =>
          index + 1 < t.length &&
          t[index].isPunctuation('.') &&
          t[index + 1].isWord(name);
      if (t.length < 3 || t.first.kind != RubyTokenKind.identifier) continue;

      // s.platform = :ios, '12.0'
      if (member(1, 'platform') &&
          t.length >= 5 &&
          t[3].isPunctuation('=') &&
          t[4].kind == RubyTokenKind.symbol) {
        final version = t.length >= 7 &&
                t[5].isPunctuation(',') &&
                t[6].kind == RubyTokenKind.string
            ? t[6]
            : null;
        add(t[4].text.substring(1), version, t.first);
        continue;
      }

      // s.ios.deployment_target = '12.0'
      if (t.length >= 7 &&
          t[1].isPunctuation('.') &&
          t[2].kind == RubyTokenKind.identifier &&
          member(3, 'deployment_target') &&
          t[5].isPunctuation('=') &&
          t[6].kind == RubyTokenKind.string) {
        add(t[2].text, t[6], t.first);
        continue;
      }

      // s.platforms = { :ios => '12.0' } (the braces parse as a block).
      if (member(1, 'platforms') &&
          t.length >= 4 &&
          t[3].isPunctuation('=') &&
          statement.blocks.isNotEmpty) {
        final entries = [
          for (final inner in statement.blocks.first.statements)
            ...inner.tokens,
        ];
        for (var i = 0; i < entries.length; i++) {
          final token = entries[i];
          // :ios => '12.0'
          if (token.kind == RubyTokenKind.symbol &&
              i + 2 < entries.length &&
              entries[i + 1].isPunctuation('=>') &&
              entries[i + 2].kind == RubyTokenKind.string) {
            add(token.text.substring(1), entries[i + 2], t.first);
          }
          // ios: '12.0'
          if (token.kind == RubyTokenKind.identifier &&
              i + 2 < entries.length &&
              entries[i + 1].isPunctuation(':') &&
              entries[i + 2].kind == RubyTokenKind.string) {
            add(token.text, entries[i + 2], t.first);
          }
        }
      }
    }
    return Podspec._(path, Map.unmodifiable(platforms), document.diagnostics);
  }

  final String path;

  /// Declared platforms by name (`ios`, `osx`).
  final Map<String, PodspecPlatform> platforms;

  final List<ParseDiagnostic> diagnostics;

  bool get isReliable => diagnostics.isEmpty;
}
