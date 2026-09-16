import '../common/source.dart';
import '../fs/project_file_system.dart';
import '../model/android_project.dart';
import '../model/declarations.dart';
import '../parsing/gradle/gradle_lexer.dart';
import '../parsing/gradle/gradle_script.dart';
import '../parsing/gradle/gradle_semantics.dart';
import '../parsing/parse_diagnostic.dart';
import '../parsing/properties/properties_file.dart';
import '../parsing/xml/android_manifest.dart';
import '../version/tool_version.dart';
import 'script_values.dart';

const flutterPluginLoaderId = 'dev.flutter.flutter-plugin-loader';
const flutterGradlePluginId = 'dev.flutter.flutter-gradle-plugin';
const androidApplicationPluginIds = {
  'com.android.application',
  'com.android.library',
};
const kotlinAndroidPluginIds = {'org.jetbrains.kotlin.android', 'kotlin-android'};
const agpClasspathModule = 'com.android.tools.build:gradle';
const kotlinClasspathModule = 'org.jetbrains.kotlin:kotlin-gradle-plugin';

/// Whether an `apply from:` value loads Flutter's legacy settings loader.
bool isImperativePluginLoader(GradleApplyStatement apply) =>
    apply.kind == 'from' &&
    (apply.value?.templateText
            .endsWith('packages/flutter_tools/gradle/app_plugin_loader.gradle') ??
        false);

/// Whether an `apply from:` value loads Flutter's legacy Gradle plugin.
bool isImperativeFlutterGradlePlugin(GradleApplyStatement apply) =>
    apply.kind == 'from' &&
    (apply.value?.templateText
            .endsWith('packages/flutter_tools/gradle/flutter.gradle') ??
        false);

/// Builds an [AndroidProject] model from `android/`.
final class AndroidInspector {
  AndroidInspector(this.files);

  final ProjectFileSystem files;

  AndroidProject? inspect(String projectPath) {
    final directory = _join(projectPath, 'android');
    if (!files.directoryExists(directory)) return null;
    final problems = <ParseProblem>[];

    final settings = _script(directory, 'settings', problems);
    final rootBuild = _script(directory, 'build', problems);
    final appScript = _script('$directory/app', 'build', problems);
    final gradleProperties =
        _properties('$directory/gradle.properties', problems);
    final wrapperProperties = _properties(
        '$directory/gradle/wrapper/gradle-wrapper.properties', problems);

    final manifests = <AndroidManifestFile>[];
    final srcDirectory = '$directory/app/src';
    for (final sourceSet in files.listDirectory(srcDirectory)) {
      final path = '$sourceSet/AndroidManifest.xml';
      if (!files.fileExists(path)) continue;
      try {
        final content = files.readString(path);
        if (content == null) continue;
        manifests.add(AndroidManifestFile(
            sourceSet.split('/').last, AndroidManifest.parse(path, content)));
      } on DocumentParseException catch (e) {
        problems.add(ParseProblem(path, e.message, line: e.line));
      } on FileReadException catch (e) {
        problems.add(ParseProblem(path, e.reason));
      }
    }

    return AndroidProject(
      directory: directory,
      settings: settings,
      rootBuild: rootBuild,
      app: appScript == null ? null : _appModule(appScript),
      gradleProperties: gradleProperties,
      wrapperProperties: wrapperProperties,
      manifests: manifests,
      toolchain: AndroidToolchain(
        androidGradlePlugin: _pluginVersion(
          settings: settings,
          rootBuild: rootBuild,
          gradleProperties: gradleProperties,
          pluginIds: androidApplicationPluginIds,
          classpathModule: agpClasspathModule,
        ),
        kotlin: _pluginVersion(
          settings: settings,
          rootBuild: rootBuild,
          gradleProperties: gradleProperties,
          pluginIds: kotlinAndroidPluginIds,
          classpathModule: kotlinClasspathModule,
        ),
        gradleWrapper: _gradleWrapper(wrapperProperties),
        gradleJavaHome: gradleProperties?['org.gradle.java.home'],
        builtInKotlin: _bool(gradleProperties?['android.builtInKotlin']),
        newDsl: _bool(gradleProperties?['android.newDsl']),
      ),
      pluginApplication: _pluginApplication(settings, appScript),
      problems: problems,
    );
  }

  static String _join(String base, String child) =>
      base.isEmpty ? child : '$base/$child';

  static bool? _bool(String? value) => switch (value?.trim()) {
        'true' => true,
        'false' => false,
        _ => null,
      };

  GradleScript? _script(
      String directory, String name, List<ParseProblem> problems) {
    final groovy = '$directory/$name.gradle';
    final kotlin = '$directory/$name.gradle.kts';
    final hasGroovy = files.fileExists(groovy);
    final hasKotlin = files.fileExists(kotlin);
    if (hasGroovy && hasKotlin) {
      problems.add(ParseProblem(groovy,
          'Both $name.gradle and $name.gradle.kts exist; Gradle uses $name.gradle.'));
    }
    final path = hasGroovy ? groovy : (hasKotlin ? kotlin : null);
    if (path == null) return null;
    try {
      final content = files.readString(path);
      if (content == null) return null;
      final script = GradleScript.parse(path, content);
      if (!script.isReliable) {
        final first = script.diagnostics.first;
        problems.add(ParseProblem(
          path,
          'The build script could not be parsed reliably: ${first.message}',
          line: script.lineIndex.lineOf(first.range.offset),
        ));
      }
      return script;
    } on FileReadException catch (e) {
      problems.add(ParseProblem(path, e.reason));
      return null;
    }
  }

  PropertiesFile? _properties(String path, List<ParseProblem> problems) {
    try {
      final content = files.readString(path);
      return content == null ? null : PropertiesFile.parse(path, content);
    } on FileReadException catch (e) {
      problems.add(ParseProblem(path, e.reason));
      return null;
    }
  }

  GradlePluginApplication _pluginApplication(
      GradleScript? settings, GradleScript? app) {
    GradlePluginStyle styleOf(GradleScript? script,
        {required String declarativeId,
        required bool Function(GradleApplyStatement) isImperative}) {
      if (script == null) return GradlePluginStyle.unknown;
      var declarative = false;
      var imperative = false;
      for (final block in script.blocksNamed('plugins')) {
        final plugins = parsePluginsBlock(block.blocks.first);
        if (plugins.byId(declarativeId) != null) declarative = true;
      }
      for (final statement in script.allStatements) {
        final apply = parseApplyStatement(statement);
        if (apply != null && isImperative(apply)) imperative = true;
      }
      if (declarative && imperative) return GradlePluginStyle.mixed;
      if (declarative) return GradlePluginStyle.declarative;
      if (imperative) return GradlePluginStyle.imperative;
      return GradlePluginStyle.unknown;
    }

    final loader = styleOf(settings,
        declarativeId: flutterPluginLoaderId,
        isImperative: isImperativePluginLoader);
    final plugin = styleOf(app,
        declarativeId: flutterGradlePluginId,
        isImperative: isImperativeFlutterGradlePlugin);

    final GradlePluginStyle overall;
    if (loader == plugin) {
      overall = loader;
    } else if (loader == GradlePluginStyle.unknown ||
        plugin == GradlePluginStyle.unknown) {
      overall = GradlePluginStyle.unknown;
    } else {
      overall = GradlePluginStyle.mixed;
    }
    return GradlePluginApplication(
        style: overall, settingsLoader: loader, appPlugin: plugin);
  }

  VersionDeclaration? _pluginVersion({
    required GradleScript? settings,
    required GradleScript? rootBuild,
    required PropertiesFile? gradleProperties,
    required Set<String> pluginIds,
    required String classpathModule,
  }) {
    VersionDeclaration? fromPluginsBlocks(
        GradleScript? script, DeclarationSite site) {
      if (script == null) return null;
      final blocks = [
        ...script.blocksNamed('plugins'),
        if (script.findBlock(['pluginManagement']) case final management?)
          ...management.blocksNamed('plugins'),
      ];
      final aliases = <String>[];
      GradleStatement? firstAlias;
      for (final statement in blocks) {
        for (final declaration
            in parsePluginsBlock(statement.blocks.first).declarations) {
          if (declaration.catalogAlias != null) {
            aliases.add(declaration.catalogAlias!);
            firstAlias ??= declaration.statement;
            continue;
          }
          if (!pluginIds.contains(declaration.id)) continue;
          final versionToken = declaration.versionToken;
          if (versionToken == null) continue;
          final literal = versionToken.string!;
          return VersionDeclaration(
            site: site,
            resolution: ValueResolution.literal,
            rawText: literal.constantValue!,
            version: ToolVersion.tryParse(literal.constantValue!),
            usage: script.refAt(declaration.statement.start),
            editable: literal.contentRange.textOf(script.source) ==
                    literal.constantValue
                ? EditableValue(script.path, literal.contentRange)
                : null,
          );
        }
      }
      if (firstAlias != null) {
        // Aliases are arbitrary names; never guess which one is this plugin.
        return VersionDeclaration(
          site: DeclarationSite.versionCatalog,
          resolution: ValueResolution.unresolved,
          rawText: aliases.join(', '),
          usage: script.refAt(firstAlias.start),
          note: 'The plugins block uses version catalog aliases '
              '(${aliases.join(', ')}); Reforge does not read version '
              'catalogs yet, so the declared version is unknown.',
        );
      }
      return null;
    }

    final declared = fromPluginsBlocks(settings, DeclarationSite.settingsPlugins) ??
        fromPluginsBlocks(rootBuild, DeclarationSite.rootBuildPlugins);
    if (declared != null) return declared;
    if (rootBuild == null) return null;

    final dependencies = rootBuild.findBlock(['buildscript', 'dependencies']);
    if (dependencies == null) return null;
    for (final statement in dependencies.statements) {
      final notation = parseDependencyNotation(statement);
      if (notation == null ||
          notation.configuration != 'classpath' ||
          notation.module != classpathModule) {
        continue;
      }
      return _classpathVersion(rootBuild, notation, gradleProperties);
    }
    return null;
  }

  VersionDeclaration _classpathVersion(GradleScript script,
      GradleDependencyNotation notation, PropertiesFile? gradleProperties) {
    final literal = notation.literal;
    final usage = script.refAt(notation.statement.start);
    final rawContent = literal.contentRange.textOf(script.source);

    // Literal: "group:name:1.2.3".
    if (!literal.hasInterpolation) {
      final value = literal.constantValue!;
      final colon = value.lastIndexOf(':');
      final versionText = value.substring(colon + 1);
      return VersionDeclaration(
        site: DeclarationSite.buildscriptClasspath,
        resolution: ValueResolution.literal,
        rawText: versionText,
        version: ToolVersion.tryParse(versionText),
        usage: usage,
        editable: rawContent == value && value.split(':').length == 3
            ? EditableValue(
                script.path,
                TextRange(literal.contentRange.offset + colon + 1,
                    versionText.length))
            : null,
      );
    }

    // Interpolated: "group:name:$variable".
    final parts = literal.parts;
    final variable = parts.length == 2 &&
            parts.first is GradleStringText &&
            (parts.first as GradleStringText).value.endsWith(':') &&
            parts.last is GradleInterpolation
        ? (parts.last as GradleInterpolation).reference
        : null;
    if (variable == null || variable.contains('.')) {
      return VersionDeclaration(
        site: DeclarationSite.buildscriptClasspath,
        resolution: ValueResolution.unresolved,
        rawText: notation.versionText ?? literal.templateText,
        usage: usage,
        note: 'The version is computed by an expression Reforge does not '
            'evaluate.',
      );
    }

    final definitions = findVariableDefinitions(script, variable);
    if (definitions.length == 1 && definitions.single.literalValue != null) {
      final definition = definitions.single;
      final token = definition.literalToken!;
      final value = definition.literalValue!;
      final range = token.kind == GradleTokenKind.string
          ? token.string!.contentRange
          : token.range;
      return VersionDeclaration(
        site: DeclarationSite.buildscriptClasspath,
        resolution: ValueResolution.variable,
        rawText: '\$$variable',
        version: ToolVersion.tryParse(value),
        usage: usage,
        definition: script.refAt(definition.statement.start),
        editable: range.textOf(script.source) == value
            ? EditableValue(script.path, range)
            : null,
        note: 'Defined by "$variable" in ${script.path}.',
      );
    }
    if (definitions.length > 1) {
      return VersionDeclaration(
        site: DeclarationSite.buildscriptClasspath,
        resolution: ValueResolution.unresolved,
        rawText: '\$$variable',
        usage: usage,
        note: '"$variable" is defined ${definitions.length} times in '
            '${script.path}.',
      );
    }
    final property = gradleProperties?.entry(variable);
    if (property != null && definitions.isEmpty) {
      return VersionDeclaration(
        site: DeclarationSite.buildscriptClasspath,
        resolution: ValueResolution.gradleProperty,
        rawText: '\$$variable',
        version: ToolVersion.tryParse(property.value),
        usage: usage,
        definition: SourceRef(gradleProperties!.path, line: property.line),
        editable: property.rawValueRange.textOf(gradleProperties.source) ==
                property.value
            ? EditableValue(gradleProperties.path, property.rawValueRange)
            : null,
        note: 'Defined by "$variable" in ${gradleProperties.path}.',
      );
    }
    return VersionDeclaration(
      site: DeclarationSite.buildscriptClasspath,
      resolution: ValueResolution.unresolved,
      rawText: '\$$variable',
      usage: usage,
      note: 'Could not find a literal definition of "$variable".',
    );
  }

  GradleWrapper? _gradleWrapper(PropertiesFile? properties) {
    final entry = properties?.entry('distributionUrl');
    if (properties == null || entry == null) return null;
    final url = entry.value;
    final fileName = url.split('/').last;
    final match =
        RegExp(r'^gradle-(.+)-(bin|all)\.zip$').firstMatch(fileName);
    return GradleWrapper(
      distributionUrl: url,
      version: match == null ? null : ToolVersion.tryParse(match.group(1)!),
      distributionType: match?.group(2),
      hasChecksum: properties.containsKey('distributionSha256Sum'),
      location: SourceRef(properties.path, line: entry.line),
      urlEditable: EditableValue(properties.path, entry.rawValueRange),
    );
  }

  AndroidAppModule _appModule(GradleScript script) {
    final android = script.findBlock(['android']);
    final defaultConfig = android?.findBlock(['defaultConfig']);

    ScriptValue? property(GradleBlock? block, List<String> names) {
      final found = findProperty(block, names);
      return found == null
          ? null
          : interpretScriptValue(script, found.$1, found.$2);
    }

    final flavors = <String>[];
    final flavorBlock = android?.findBlock(['productFlavors']);
    for (final statement in flavorBlock?.statements ?? const <GradleStatement>[]) {
      if (statement.blocks.isEmpty) continue;
      final name = _namedContainerElement(statement);
      if (name != null) flavors.add(name);
    }
    var releaseSigning = false;
    final signing = android?.findBlock(['signingConfigs']);
    for (final statement in signing?.statements ?? const <GradleStatement>[]) {
      if (statement.blocks.isNotEmpty &&
          _namedContainerElement(statement) == 'release') {
        releaseSigning = true;
      }
    }

    return AndroidAppModule(
      script: script,
      namespace: property(android, const ['namespace']),
      applicationId: property(defaultConfig, const ['applicationId']),
      compileSdk: property(android, const ['compileSdk', 'compileSdkVersion']),
      minSdk: property(defaultConfig, const ['minSdk', 'minSdkVersion']),
      targetSdk:
          property(defaultConfig, const ['targetSdk', 'targetSdkVersion']),
      ndkVersion: property(android, const ['ndkVersion']),
      productFlavors: flavors,
      hasReleaseSigningConfig: releaseSigning,
    );
  }

  /// `dev { }` (Groovy) or `create("dev") { }` / `register("dev") { }`
  /// (Kotlin DSL).
  static String? _namedContainerElement(GradleStatement statement) {
    final head = statement.head;
    if (head.length == 1 && head.single.isIdentifier()) {
      return head.single.identifierName;
    }
    if (head.length == 4 &&
        (head[0].isIdentifier('create') ||
            head[0].isIdentifier('register') ||
            head[0].isIdentifier('getByName') ||
            head[0].isIdentifier('maybeCreate')) &&
        head[1].isPunctuation('(') &&
        head[3].isPunctuation(')')) {
      return head[2].string?.constantValue;
    }
    return null;
  }
}
