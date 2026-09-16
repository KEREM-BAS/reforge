import 'gradle_lexer.dart';
import 'gradle_script.dart';

/// How a plugin is declared inside a `plugins {}` block.
enum GradlePluginSyntax {
  /// `id "com.android.application" version "8.1.0" apply false`
  idCommand,

  /// `id("com.android.application") version "8.1.0" apply false`
  idCall,

  /// `kotlin("android") version "1.9.0"`
  kotlinShorthand,

  /// `alias(libs.plugins.android.application)`
  versionCatalogAlias,

  /// `java`, `` `kotlin-dsl` ``
  builtIn,
}

/// A plugin declared in a `plugins {}` block.
final class GradlePluginDeclaration {
  const GradlePluginDeclaration({
    required this.statement,
    required this.syntax,
    this.id,
    this.idToken,
    this.versionToken,
    this.apply,
    this.catalogAlias,
  });

  final GradleStatement statement;
  final GradlePluginSyntax syntax;

  /// The fully qualified plugin id, when statically known.
  final String? id;

  /// The string token holding the id (or the Kotlin shorthand argument).
  final GradleToken? idToken;

  /// The string token holding the version, when declared.
  final GradleToken? versionToken;

  /// The value of `apply true|false`, when declared.
  final bool? apply;

  /// For version catalog aliases, the accessor path such as
  /// `libs.plugins.android.application`.
  final String? catalogAlias;

  String? get version => versionToken?.string?.constantValue;
}

/// Parses the plugin declarations of a `plugins {}` block.
///
/// Statements that are not recognized plugin declarations are returned in
/// [PluginsBlockContents.unrecognized] so callers can treat them as
/// customizations rather than silently ignoring them.
PluginsBlockContents parsePluginsBlock(GradleBlock block) {
  final declarations = <GradlePluginDeclaration>[];
  final unrecognized = <GradleStatement>[];
  for (final statement in block.statements) {
    final declaration = parsePluginDeclaration(statement);
    if (declaration == null) {
      unrecognized.add(statement);
    } else {
      declarations.add(declaration);
    }
  }
  return PluginsBlockContents(declarations, unrecognized);
}

final class PluginsBlockContents {
  const PluginsBlockContents(this.declarations, this.unrecognized);

  final List<GradlePluginDeclaration> declarations;
  final List<GradleStatement> unrecognized;

  GradlePluginDeclaration? byId(String id) =>
      declarations.where((d) => d.id == id).firstOrNull;
}

GradlePluginDeclaration? parsePluginDeclaration(GradleStatement statement) {
  if (statement.blocks.isNotEmpty || statement.innerBlocks.isNotEmpty) {
    return null;
  }
  final tokens = statement.tokens;
  if (tokens.isEmpty) return null;
  final first = tokens.first;
  var index = 1;
  GradlePluginSyntax syntax;
  GradleToken? idToken;
  String? id;
  String? alias;

  if (first.isIdentifier('id') && tokens.length >= 2) {
    if (_isConstantString(tokens[1])) {
      syntax = GradlePluginSyntax.idCommand;
      idToken = tokens[1];
      index = 2;
    } else if (tokens.length >= 4 &&
        tokens[1].isPunctuation('(') &&
        _isConstantString(tokens[2]) &&
        tokens[3].isPunctuation(')')) {
      syntax = GradlePluginSyntax.idCall;
      idToken = tokens[2];
      index = 4;
    } else {
      return null;
    }
    id = idToken.string!.constantValue;
  } else if (first.isIdentifier('kotlin') &&
      tokens.length >= 4 &&
      tokens[1].isPunctuation('(') &&
      _isConstantString(tokens[2]) &&
      tokens[3].isPunctuation(')')) {
    syntax = GradlePluginSyntax.kotlinShorthand;
    idToken = tokens[2];
    id = 'org.jetbrains.kotlin.${idToken.string!.constantValue}';
    index = 4;
  } else if (first.isIdentifier('alias') &&
      tokens.length >= 4 &&
      tokens[1].isPunctuation('(')) {
    final close = tokens.indexWhere((t) => t.isPunctuation(')'), 2);
    if (close == -1) return null;
    alias = tokens.sublist(2, close).map((t) => t.text).join();
    syntax = GradlePluginSyntax.versionCatalogAlias;
    index = close + 1;
  } else if (first.kind == GradleTokenKind.identifier && tokens.length == 1) {
    return GradlePluginDeclaration(
      statement: statement,
      syntax: GradlePluginSyntax.builtIn,
      id: first.identifierName,
    );
  } else {
    return null;
  }

  GradleToken? versionToken;
  bool? apply;
  while (index < tokens.length) {
    final token = tokens[index];
    // Infix form: `version "x"` / `apply false`.
    if (token.isIdentifier('version') &&
        index + 1 < tokens.length &&
        _isConstantString(tokens[index + 1])) {
      versionToken = tokens[index + 1];
      index += 2;
      continue;
    }
    if (token.isIdentifier('apply') && index + 1 < tokens.length) {
      final value = _booleanOf(tokens[index + 1]);
      if (value == null) return null;
      apply = value;
      index += 2;
      continue;
    }
    // Chained call form: `.version("x")` / `.apply(false)`.
    if (token.isPunctuation('.') &&
        index + 4 < tokens.length &&
        tokens[index + 2].isPunctuation('(') &&
        tokens[index + 4].isPunctuation(')')) {
      final name = tokens[index + 1];
      final argument = tokens[index + 3];
      if (name.isIdentifier('version') && _isConstantString(argument)) {
        versionToken = argument;
        index += 5;
        continue;
      }
      if (name.isIdentifier('apply') && _booleanOf(argument) != null) {
        apply = _booleanOf(argument);
        index += 5;
        continue;
      }
    }
    // Infix with parentheses: `version("x")` without a dot (Kotlin infix).
    if ((token.isIdentifier('version') || token.isIdentifier('apply')) &&
        index + 3 < tokens.length &&
        tokens[index + 1].isPunctuation('(') &&
        tokens[index + 3].isPunctuation(')')) {
      final argument = tokens[index + 2];
      if (token.isIdentifier('version') && _isConstantString(argument)) {
        versionToken = argument;
        index += 4;
        continue;
      }
      final value = _booleanOf(argument);
      if (token.isIdentifier('apply') && value != null) {
        apply = value;
        index += 4;
        continue;
      }
    }
    return null;
  }

  return GradlePluginDeclaration(
    statement: statement,
    syntax: syntax,
    id: id,
    idToken: idToken,
    versionToken: versionToken,
    apply: apply,
    catalogAlias: alias,
  );
}

bool _isConstantString(GradleToken token) =>
    token.kind == GradleTokenKind.string && token.string!.constantValue != null;

bool? _booleanOf(GradleToken token) {
  if (token.isIdentifier('true')) return true;
  if (token.isIdentifier('false')) return false;
  return null;
}

/// Plugin ids of the Kotlin Android Gradle plugin.
const kotlinAndroidPluginIds = {
  'kotlin-android',
  'org.jetbrains.kotlin.android'
};

/// How a build script applies the Kotlin Android Gradle plugin.
enum KotlinPluginApplication {
  /// The script does not apply it.
  none,

  /// Only inside a condition, typically `if (agpMajor < 9 || !builtInKotlin)`:
  /// the script supports built-in Kotlin.
  conditional,

  /// Unconditionally, at the top level.
  always,
}

/// How [script] applies the Kotlin Android Gradle plugin, looking at
/// `apply plugin:` statements at any depth (a nested one is conditional)
/// and at top-level `plugins {}` blocks.
KotlinPluginApplication kotlinPluginApplication(GradleScript script) {
  if (kotlinAndroidPluginApplications(script).isNotEmpty) {
    return KotlinPluginApplication.always;
  }
  for (final statement in script.allStatements) {
    final apply = parseApplyStatement(statement);
    if (apply != null &&
        apply.kind == 'plugin' &&
        kotlinAndroidPluginIds.contains(apply.value?.constantValue)) {
      return KotlinPluginApplication.conditional;
    }
  }
  return KotlinPluginApplication.none;
}

/// Top-level statements of [script] that apply the Kotlin Android Gradle
/// plugin: `plugins {}` declarations (including `kotlin("android")` and the
/// `libs.plugins.kotlin.android` catalog alias, but not `apply false`) and
/// `apply plugin:` statements.
List<GradleStatement> kotlinAndroidPluginApplications(GradleScript script) {
  final found = <GradleStatement>[];
  for (final statement in script.statements) {
    if (statement.isBlockNamed('plugins')) {
      for (final block in statement.blocks) {
        for (final declaration in parsePluginsBlock(block).declarations) {
          final kotlin = kotlinAndroidPluginIds.contains(declaration.id) ||
              declaration.catalogAlias == 'libs.plugins.kotlin.android';
          if (kotlin && declaration.apply != false) {
            found.add(declaration.statement);
          }
        }
      }
    }
    final apply = parseApplyStatement(statement);
    if (apply != null &&
        apply.kind == 'plugin' &&
        kotlinAndroidPluginIds.contains(apply.value?.constantValue)) {
      found.add(statement);
    }
  }
  return found;
}

/// `apply plugin: 'x'`, `apply from: 'x'` (Groovy) or
/// `apply(plugin = "x")`, `apply(from = "x")` (Kotlin).
final class GradleApplyStatement {
  const GradleApplyStatement(this.statement, this.kind, this.valueToken);

  final GradleStatement statement;

  /// `plugin` or `from`.
  final String kind;

  /// The string argument, or `null` when the argument is not a string (for
  /// example a plugin class reference).
  final GradleToken? valueToken;

  GradleStringLiteral? get value => valueToken?.string;
}

GradleApplyStatement? parseApplyStatement(GradleStatement statement) {
  final tokens = statement.tokens;
  if (statement.blocks.isNotEmpty || tokens.isEmpty) return null;
  if (!tokens.first.isIdentifier('apply')) return null;
  var arguments = tokens.sublist(1);
  if (arguments.length >= 2 &&
      arguments.first.isPunctuation('(') &&
      arguments.last.isPunctuation(')')) {
    arguments = arguments.sublist(1, arguments.length - 1);
  }
  if (arguments.length != 3) return null;
  final key = arguments[0];
  final separator = arguments[1];
  if (!(separator.isPunctuation(':') || separator.isPunctuation('='))) {
    return null;
  }
  if (!key.isIdentifier('plugin') && !key.isIdentifier('from')) return null;
  final value = arguments[2];
  return GradleApplyStatement(
    statement,
    key.identifierName,
    value.kind == GradleTokenKind.string ? value : null,
  );
}

/// A Maven coordinate string such as `com.android.tools.build:gradle:8.1.0`.
final class GradleDependencyNotation {
  const GradleDependencyNotation(
      this.statement, this.configuration, this.token);

  final GradleStatement statement;

  /// `classpath`, `implementation`, ...
  final String configuration;

  /// The string token holding the notation.
  final GradleToken token;

  GradleStringLiteral get literal => token.string!;

  /// `group:name` part of the notation (always constant in practice).
  String? get module {
    final parts = literal.templateText.split(':');
    return parts.length >= 2 ? '${parts[0]}:${parts[1]}' : null;
  }

  /// The version segment as written (may be an interpolation such as
  /// `$kotlin_version`).
  String? get versionText {
    final parts = literal.templateText.split(':');
    return parts.length >= 3 ? parts.sublist(2).join(':') : null;
  }
}

/// Parses `configuration "g:n:v"` and `configuration("g:n:v")`.
GradleDependencyNotation? parseDependencyNotation(GradleStatement statement) {
  final tokens = statement.tokens;
  if (statement.blocks.isNotEmpty || tokens.isEmpty) return null;
  final first = tokens.first;
  if (!first.isIdentifier()) return null;
  GradleToken? literal;
  if (tokens.length == 2 && tokens[1].kind == GradleTokenKind.string) {
    literal = tokens[1];
  } else if (tokens.length == 4 &&
      tokens[1].isPunctuation('(') &&
      tokens[2].kind == GradleTokenKind.string &&
      tokens[3].isPunctuation(')')) {
    literal = tokens[2];
  }
  if (literal == null) return null;
  if (!literal.string!.templateText.contains(':')) return null;
  return GradleDependencyNotation(statement, first.identifierName, literal);
}

/// A literal definition of a script variable or extra property.
final class GradleVariableDefinition {
  const GradleVariableDefinition(this.statement, this.name, this.valueTokens);

  final GradleStatement statement;
  final String name;

  /// Tokens of the assigned value.
  final List<GradleToken> valueTokens;

  /// The constant string or number value, when the definition is a literal.
  GradleToken? get literalToken {
    if (valueTokens.length != 1) return null;
    final token = valueTokens.single;
    if (token.kind == GradleTokenKind.number) return token;
    if (token.kind == GradleTokenKind.string &&
        token.string!.constantValue != null) {
      return token;
    }
    return null;
  }

  String? get literalValue {
    final token = literalToken;
    if (token == null) return null;
    return token.kind == GradleTokenKind.number
        ? token.text
        : token.string!.constantValue;
  }
}

/// Finds definitions of variable or extra property [name] anywhere in
/// [script]:
///
/// - `def name = ...`, `val name = ...`, `var name = ...`
/// - `ext.name = ...`, `project.ext.name = ...`, `rootProject.ext.name = ...`
/// - `ext { name = ... }`
/// - Kotlin `extra["name"] = ...` and `extra.set("name", ...)`
List<GradleVariableDefinition> findVariableDefinitions(
    GradleScript script, String name) {
  final definitions = <GradleVariableDefinition>[];

  void visit(List<GradleStatement> statements, {required bool insideExt}) {
    for (final statement in statements) {
      final head = statement.head;
      if (head.length >= 3 &&
          (head[0].isIdentifier('def') ||
              head[0].isIdentifier('val') ||
              head[0].isIdentifier('var')) &&
          head[1].isIdentifier(name)) {
        var equals = 2;
        // Kotlin type annotation: `val name: String = ...`
        if (head[2].isPunctuation(':')) {
          equals = head.indexWhere((t) => t.isPunctuation('='), 3);
        }
        if (equals > 0 &&
            equals < head.length - 1 &&
            head[equals].isPunctuation('=') &&
            statement.blocks.isEmpty) {
          definitions.add(GradleVariableDefinition(
              statement, name, head.sublist(equals + 1)));
        }
      }
      for (final prefix in const ['ext', 'project.ext', 'rootProject.ext']) {
        final value = statement.assignmentValue('$prefix.$name');
        if (value != null && statement.blocks.isEmpty) {
          definitions.add(GradleVariableDefinition(statement, name, value));
        }
      }
      if (insideExt && statement.blocks.isEmpty) {
        final value = statement.assignmentValue(name);
        if (value != null) {
          definitions.add(GradleVariableDefinition(statement, name, value));
        }
      }
      // extra["name"] = value
      final tokens = statement.tokens;
      if (tokens.length >= 6 &&
          tokens[0].isIdentifier('extra') &&
          tokens[1].isPunctuation('[') &&
          tokens[2].string?.constantValue == name &&
          tokens[3].isPunctuation(']') &&
          tokens[4].isPunctuation('=')) {
        definitions
            .add(GradleVariableDefinition(statement, name, tokens.sublist(5)));
      }
      // extra.set("name", value)
      if (tokens.length >= 8 &&
          tokens[0].isIdentifier('extra') &&
          tokens[1].isPunctuation('.') &&
          tokens[2].isIdentifier('set') &&
          tokens[3].isPunctuation('(') &&
          tokens[4].string?.constantValue == name &&
          tokens[5].isPunctuation(',') &&
          tokens.last.isPunctuation(')')) {
        definitions.add(GradleVariableDefinition(
            statement, name, tokens.sublist(6, tokens.length - 1)));
      }
      for (final block in statement.blocks) {
        visit(block.statements, insideExt: statement.isBlockNamed('ext'));
      }
    }
  }

  visit(script.statements, insideExt: false);
  return definitions;
}

/// A normalized rendering of [statement] that ignores whitespace, comments,
/// line breaks and the quote style of constant strings.
///
/// Two statements with equal fingerprints are structurally identical, which
/// lets recipes recognize code generated by Flutter templates regardless of
/// formatting.
String statementFingerprint(GradleStatement statement) {
  final parts = <(int, String)>[
    for (final token in statement.tokens)
      (token.offset, _tokenFingerprint(token)),
    for (final block in [...statement.blocks, ...statement.innerBlocks])
      (block.openBrace, _blockFingerprint(block)),
  ]..sort((a, b) => a.$1.compareTo(b.$1));
  return parts.map((p) => p.$2).join(' ');
}

String _tokenFingerprint(GradleToken token) {
  final literal = token.string;
  if (literal == null) return token.text;
  return '"${literal.templateText}"';
}

String _blockFingerprint(GradleBlock block) {
  final parameters =
      block.parameters.isEmpty ? '' : '${block.parameters.join(' , ')} -> ';
  return '{ $parameters${block.statements.map(statementFingerprint).join(' ; ')} }';
}

/// The JVM targets an Android module's build script declares for Java and
/// Kotlin.
final class JvmTargets {
  const JvmTargets({
    required this.android,
    required this.compileOptions,
    required this.javaTarget,
    required this.javaTargetText,
    required this.kotlinConfigured,
    required this.kotlinBlock,
  });

  /// The top-level `android {}` statement, when present.
  final GradleStatement? android;

  /// `android { compileOptions {} }`, when present.
  final GradleStatement? compileOptions;

  /// `targetCompatibility` normalized to `1.8`, `11`, `17`, ..., or `null`
  /// when it is not set or not a recognized constant.
  final String? javaTarget;

  /// `targetCompatibility` as written, when it is set.
  final String? javaTargetText;

  /// Whether the script configures the Kotlin JVM target or a JVM toolchain
  /// anywhere (`jvmTarget`, `jvmToolchain`, `toolchain`).
  final bool kotlinConfigured;

  /// A top-level `kotlin {}` block, when present.
  final GradleStatement? kotlinBlock;
}

/// Reads the Java and Kotlin JVM target declarations of [script].
JvmTargets jvmTargets(GradleScript script) {
  final android =
      script.statements.where((s) => s.isBlockNamed('android')).firstOrNull;
  final compileOptions = android?.blocks.first.statements
      .where((s) => s.isBlockNamed('compileOptions'))
      .firstOrNull;
  List<GradleToken>? value;
  for (final statement
      in compileOptions?.blocks.first.statements ?? const <GradleStatement>[]) {
    value = statement.propertyValue('targetCompatibility') ?? value;
  }
  String? javaTarget;
  if (value != null) {
    String? normalize(String version) => switch (version) {
          '1.8' || '8' || '1_8' => '1.8',
          _ when RegExp(r'^(9|[1-9]\d)$').hasMatch(version) => version,
          _ => null,
        };
    if (value.length == 3 &&
        value[0].isIdentifier('JavaVersion') &&
        value[1].isPunctuation('.') &&
        value[2].identifierName.startsWith('VERSION_')) {
      javaTarget = normalize(value[2].identifierName.substring(8));
    } else if (value.length == 1) {
      final token = value.single;
      javaTarget = normalize(token.string?.constantValue ??
          (token.kind == GradleTokenKind.number ? token.text : ''));
    }
  }
  return JvmTargets(
    android: android,
    compileOptions: compileOptions,
    javaTarget: javaTarget,
    javaTargetText: value?.map((t) => t.text).join(),
    kotlinConfigured: script.tokens.any((t) =>
        t.isIdentifier('jvmTarget') ||
        t.isIdentifier('jvmToolchain') ||
        t.isIdentifier('toolchain')),
    kotlinBlock:
        script.statements.where((s) => s.isBlockNamed('kotlin')).firstOrNull,
  );
}

/// A `jcenter()` (or `jcenter { }`) declaration in a `repositories {}` block.
/// Gradle 9 removed the method.
final class JcenterRepository {
  const JcenterRepository(this.statement, this.repositories);

  final GradleStatement statement;

  /// The enclosing `repositories {}` block.
  final GradleBlock repositories;

  /// The `jcenter` identifier.
  GradleToken get name => statement.tokens.first;

  /// Whether the same block also declares `mavenCentral()`.
  bool get alongsideMavenCentral => repositories.statements.any((s) =>
      s.tokens.isNotEmpty && s.tokens.first.isIdentifier('mavenCentral'));
}

/// The `jcenter()` declarations in `repositories {}` blocks of [script], at
/// any depth (`buildscript`, `allprojects`, `pluginManagement`, ...).
List<JcenterRepository> jcenterRepositories(GradleScript script) => [
      for (final statement in script.allStatements)
        if (statement.isBlockNamed('repositories'))
          for (final inner in statement.blocks.first.statements)
            if (inner.tokens.isNotEmpty &&
                inner.tokens.first.isIdentifier('jcenter') &&
                (inner.tokens.length == 1 ||
                    inner.tokens[1].isPunctuation('(')))
              JcenterRepository(inner, statement.blocks.first),
    ];

/// Returns true when [name] is referenced anywhere in [script] other than in
/// the given [excluding] statements: as an identifier token or inside a
/// string interpolation.
bool isReferenced(GradleScript script, String name,
    {Set<GradleStatement> excluding = const {}}) {
  final excludedRanges = excluding.map((s) => s.range).toList();
  bool excluded(int offset) => excludedRanges.any((r) => r.contains(offset));

  for (final token in script.tokens) {
    if (excluded(token.offset)) continue;
    if (token.isIdentifier(name)) return true;
    final literal = token.string;
    if (literal == null) continue;
    for (final part in literal.parts) {
      if (part is GradleInterpolation) {
        final reference = part.reference;
        if (reference == null) {
          // Complex interpolation: look for the name as a word.
          if (RegExp('\\b${RegExp.escape(name)}\\b')
              .hasMatch(part.sourceText)) {
            return true;
          }
        } else if (reference == name || reference.startsWith('$name.')) {
          return true;
        }
      }
    }
  }
  return false;
}
