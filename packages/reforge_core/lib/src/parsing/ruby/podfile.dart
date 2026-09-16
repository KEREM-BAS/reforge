import '../../common/source.dart';
import '../parse_diagnostic.dart';
import 'ruby_syntax.dart';

export 'ruby_syntax.dart'
    show RubyBlock, RubyStatement, RubyToken, RubyTokenKind;

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
    final document = RubyDocument.parse(source);
    final statements = document.statements;
    final diagnostics = document.diagnostics;
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
          case 'flutter_install_all_ios_pods' ||
                'flutter_install_all_macos_pods':
            installsFlutterPods = true;
          case 'flutter_ios_podfile_setup' || 'flutter_macos_podfile_setup':
            callsSetup = true;
          case 'flutter_additional_ios_build_settings' ||
                'flutter_additional_macos_build_settings':
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
          _commentedPlatform(path, source, document.comments, lines),
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
    final text = comment.textOf(source).trimRight();
    final match = pattern.firstMatch(text);
    if (match == null) continue;
    final quote = match.group(2)!;
    final version = match.group(3)!;
    final versionStart = text.lastIndexOf('$quote$version$quote') + 1;
    return PodfilePlatform(
      name: match.group(1)!,
      version: version,
      versionContentRange:
          TextRange(comment.offset + versionStart, version.length),
      location: lines.refFor(path, comment.offset),
      commentedOut: true,
    );
  }
  return null;
}
