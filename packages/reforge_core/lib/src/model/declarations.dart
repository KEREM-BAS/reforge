import 'package:meta/meta.dart';

import '../common/source.dart';
import '../version/tool_version.dart';

/// Where a toolchain version is declared.
enum DeclarationSite {
  /// `plugins {}` in `settings.gradle(.kts)`.
  settingsPlugins,

  /// `plugins {}` in the root `build.gradle(.kts)`.
  rootBuildPlugins,

  /// `buildscript { dependencies { classpath ... } }` in the root build file.
  buildscriptClasspath,

  /// A Gradle version catalog (`gradle/libs.versions.toml`).
  versionCatalog,

  /// `distributionUrl` in `gradle-wrapper.properties`.
  gradleWrapper,
}

/// How the declared value was obtained.
enum ValueResolution {
  /// A literal at the declaration site.
  literal,

  /// Resolved through a variable or extra property defined in a build script.
  variable,

  /// Resolved through `gradle.properties`.
  gradleProperty,

  /// The value could not be determined statically.
  unresolved,
}

/// A text range inside a project file that holds a value and may be edited
/// to change it.
@immutable
final class EditableValue {
  const EditableValue(this.path, this.range);

  final String path;
  final TextRange range;
}

/// A toolchain version declared by a project, with provenance.
@immutable
final class VersionDeclaration {
  const VersionDeclaration({
    required this.site,
    required this.resolution,
    required this.rawText,
    required this.usage,
    this.version,
    this.editable,
    this.definition,
    this.note,
  });

  final DeclarationSite site;
  final ValueResolution resolution;

  /// The value as written at the usage site, e.g. `7.3.0` or
  /// `$kotlin_version`.
  final String rawText;

  /// The parsed version, when resolvable.
  final ToolVersion? version;

  /// Where the version is used (the plugin declaration or classpath line).
  final SourceRef usage;

  /// Where the effective value is defined, if different from [usage].
  final SourceRef? definition;

  /// The exact range to edit to change the version, when safe to edit.
  final EditableValue? editable;

  final String? note;

  Map<String, Object?> toJson() => {
        'version': version?.toString(),
        'rawText': rawText,
        'site': site.name,
        'resolution': resolution.name,
        'usage': usage.toJson(),
        if (definition != null) 'definition': definition!.toJson(),
        if (note != null) 'note': note,
      };
}

/// A value from a build script: a literal, a reference to a Flutter-provided
/// default (`flutter.compileSdkVersion`), or another expression.
sealed class ScriptValue {
  const ScriptValue(this.text, this.location);

  /// The expression as written.
  final String text;
  final SourceRef location;

  Map<String, Object?> toJson();
}

final class LiteralInt extends ScriptValue {
  const LiteralInt(this.value, super.text, super.location);

  final int value;

  @override
  Map<String, Object?> toJson() =>
      {'kind': 'literal', 'value': value, 'location': location.toJson()};
}

final class LiteralString extends ScriptValue {
  const LiteralString(this.value, super.text, super.location, {this.editable});

  final String value;
  final EditableValue? editable;

  @override
  Map<String, Object?> toJson() =>
      {'kind': 'literal', 'value': value, 'location': location.toJson()};
}

/// `flutter.compileSdkVersion`, `flutter.minSdkVersion`, ...
final class FlutterDefaultReference extends ScriptValue {
  const FlutterDefaultReference(this.property, super.text, super.location);

  /// `compileSdkVersion`, `targetSdkVersion`, `minSdkVersion`, `ndkVersion`.
  final String property;

  @override
  Map<String, Object?> toJson() => {
        'kind': 'flutterDefault',
        'property': property,
        'location': location.toJson(),
      };
}

final class OtherExpression extends ScriptValue {
  const OtherExpression(super.text, super.location);

  @override
  Map<String, Object?> toJson() =>
      {'kind': 'expression', 'text': text, 'location': location.toJson()};
}

/// A problem reading or parsing a project file.
@immutable
final class ParseProblem {
  const ParseProblem(this.path, this.message, {this.line});

  final String path;
  final String message;
  final int? line;

  Map<String, Object?> toJson() =>
      {'path': path, 'message': message, if (line != null) 'line': line};
}
