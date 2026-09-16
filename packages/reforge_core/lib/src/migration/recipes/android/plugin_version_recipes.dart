import '../../../fs/project_file_system.dart';
import '../../../model/android_project.dart';
import '../../../model/declarations.dart';
import '../../../model/finding.dart';
import '../../../parsing/gradle/gradle_semantics.dart';
import '../../../text/text_edit.dart';
import '../../../version/tool_version.dart';
import '../../android_toolchain_targets.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';
import '../recipe_support.dart';

/// Upgrades the Android Gradle Plugin declaration.
final class AgpVersionRecipe extends MigrationRecipe {
  const AgpVersionRecipe();

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidAgpVersion,
        title: 'Upgrade the Android Gradle Plugin',
        summary: 'Moves the Android Gradle Plugin to the earliest release '
            'supported by the target Flutter release, wherever the version is '
            'declared (plugins block, buildscript classpath, ext variable or '
            'gradle.properties).',
        category: RecipeCategory.android,
        runsAfter: [
          RecipeIds.androidFlutterGradlePluginDsl,
          RecipeIds.androidGradleWrapper,
        ],
        requires: [RecipeIds.androidGradleWrapper],
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final android = context.project.android;
    if (android == null) {
      return const NotApplicable('The project has no Android host.');
    }
    final targets = AndroidToolchainTargets(
      android: android,
      release: context.target,
      knowledge: context.knowledge,
      includeRecommended: context.options.includeRecommended,
    );
    final result = _evaluateVersionBump(
      context: context,
      name: 'Android Gradle Plugin',
      declaration: android.toolchain.androidGradlePlugin,
      target: targets.agp,
      floorError: context.target.androidRequirements.androidGradlePlugin?.error,
      majorUpgradeNotes: (from, to) => [
        if (from.major < 8 && to.major >= 8) ...[
          'Android Gradle Plugin 8 requires JDK 17 to run Gradle.',
          if (android.app != null && android.app!.namespace == null)
            'Android Gradle Plugin 8 requires android.namespace in the app '
                'module (see ${RecipeIds.androidNamespace}).',
          'Android Gradle Plugin 8 no longer generates BuildConfig by default '
              'and makes R classes non-transitive by default.',
          ..._buildConfigUsage(context.files, android),
        ],
        if (from.major < 9 && to.major >= 9)
          'Android Gradle Plugin 9 enables built-in Kotlin and the new DSL by '
              "default. Flutter's Gradle plugin requires both to be disabled "
              '(android.builtInKotlin=false, android.newDsl=false), and '
              'plugins that use removed Android Gradle Plugin APIs fail to '
              'build.',
      ],
    );
    return _disableAgp9Defaults(android, result);
  }

  /// Flutter apps built with Android Gradle Plugin 9 must disable built-in
  /// Kotlin and the new DSL. Flutter 3.44+ adds these properties during the
  /// build (DisableBuiltInKotlinMigration, DisableNewDslMigration); Reforge
  /// adds them explicitly so the change is part of the reviewed plan.
  static RecipeResult _disableAgp9Defaults(
      AndroidProject android, RecipeResult result) {
    final to = result is Proposal ? result.details['to'] : null;
    final from = result is Proposal ? result.details['from'] : null;
    if (result is! Proposal || to is! String || from is! String) return result;
    final toVersion = ToolVersion.tryParse(to);
    final fromVersion = ToolVersion.tryParse(from);
    if (toVersion == null ||
        fromVersion == null ||
        toVersion.major < 9 ||
        fromVersion.major >= 9) {
      return result;
    }
    final properties = android.gradleProperties;
    if (properties == null) {
      return result.withStatus(StepStatus.manual, extraManualSteps: [
        'Create ${android.directory}/gradle.properties with '
            'android.newDsl=false and android.builtInKotlin=false, then '
            'upgrade the Android Gradle Plugin to $to.',
      ]);
    }
    final source = properties.source;
    final eol = eolOf(source);
    final lines = StringBuffer();
    if (source.isNotEmpty && !source.endsWith('\n')) lines.write(eol);
    for (final key in const ['android.newDsl', 'android.builtInKotlin']) {
      if (properties.containsKey(key)) continue;
      lines
        ..write('# Required by the Flutter Gradle plugin with Android Gradle '
            'Plugin 9 (added by Reforge)$eol')
        ..write('$key=false$eol');
    }
    if (lines.isEmpty) return result;
    return result.withEdits([
      FileEdit(properties.path, [TextEdit.insert(source.length, '$lines')]),
    ], extraNotes: [
      'android.newDsl=false and android.builtInKotlin=false are added to '
          '${properties.path}.',
    ]);
  }

  /// Lists Kotlin and Java sources of the app module that mention BuildConfig.
  static List<String> _buildConfigUsage(
      ProjectFileSystem files, AndroidProject android) {
    final hits = <String>[];
    void walk(String directory, int depth) {
      if (depth > 12 || hits.length >= 5) return;
      for (final entry in files.listDirectory(directory)) {
        if (entry.endsWith('.kt') || entry.endsWith('.java')) {
          try {
            final content = files.readString(entry);
            if (content != null &&
                RegExp(r'\bBuildConfig\b').hasMatch(content)) {
              hits.add(entry);
            }
          } on FileReadException {
            continue;
          }
        } else if (files.directoryExists(entry)) {
          walk(entry, depth + 1);
        }
      }
    }

    walk('${android.directory}/app/src', 0);
    return [
      if (hits.isNotEmpty)
        'These sources reference BuildConfig and need '
            'buildFeatures { buildConfig true } with AGP 8: ${hits.join(', ')}.',
    ];
  }
}

/// Upgrades the Kotlin Gradle plugin declaration.
final class KotlinVersionRecipe extends MigrationRecipe {
  const KotlinVersionRecipe();

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidKotlinVersion,
        title: 'Upgrade the Kotlin Gradle plugin',
        summary: 'Moves the Kotlin Gradle plugin to the earliest release '
            'supported by the target Flutter release.',
        category: RecipeCategory.android,
        runsAfter: [RecipeIds.androidFlutterGradlePluginDsl],
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final android = context.project.android;
    if (android == null) {
      return const NotApplicable('The project has no Android host.');
    }
    final targets = AndroidToolchainTargets(
      android: android,
      release: context.target,
      knowledge: context.knowledge,
      includeRecommended: context.options.includeRecommended,
    );
    final result = _evaluateVersionBump(
      context: context,
      name: 'Kotlin Gradle plugin',
      declaration: android.toolchain.kotlin,
      target: targets.kotlin,
      floorError: context.target.androidRequirements.kotlin?.error,
      majorUpgradeNotes: (from, to) => [
        if (from.major < 2 && to.major >= 2)
          'Kotlin 2 compiles with the K2 compiler by default. Kotlin sources '
              'in the app module and Kotlin-based plugins should be rebuilt '
              'and tested.',
      ],
    );
    return _syncKotlinVersionProperty(android, result);
  }

  /// Keeps `ext.kotlin_version` aligned with the Kotlin plugin.
  ///
  /// After migrating to plugins {} blocks, the root build file may still
  /// define `kotlin_version` for dependencies such as kotlin-reflect. When it
  /// matched the plugin version before the upgrade, it is upgraded too, so
  /// Kotlin libraries and the compiler stay on the same version.
  static RecipeResult _syncKotlinVersionProperty(
      AndroidProject android, RecipeResult result) {
    final declaration = android.toolchain.kotlin;
    final root = android.rootBuild;
    final app = android.app?.script;
    if (result is! Proposal ||
        result.edits.isEmpty ||
        declaration == null ||
        root == null ||
        !root.isReliable) {
      return result;
    }
    final definitions = findVariableDefinitions(root, 'kotlin_version');
    if (definitions.length != 1) return result;
    final definition = definitions.single;
    final token = definition.literalToken;
    final literal = token?.string;
    if (literal == null ||
        definition.literalValue != '${declaration.version}') {
      return result;
    }
    final editable = declaration.editable;
    if (editable != null &&
        editable.path == root.path &&
        editable.range == literal.contentRange) {
      return result; // The property is the declaration being upgraded.
    }
    final used = isReferenced(root, 'kotlin_version',
            excluding: {definition.statement}) ||
        (app != null && isReferenced(app, 'kotlin_version'));
    if (!used) return result;
    final to = result.details['to'];
    return result.withEdits([
      FileEdit(root.path, [TextEdit.replace(literal.contentRange, '$to')]),
    ], extraNotes: [
      'kotlin_version in ${root.path} matched the Kotlin plugin version and '
          'is still used by dependencies; it is upgraded to $to as well.',
    ]);
  }
}

RecipeResult _evaluateVersionBump({
  required RecipeContext context,
  required String name,
  required VersionDeclaration? declaration,
  required ToolchainTarget? target,
  required ToolVersion? floorError,
  required List<String> Function(ToolVersion from, ToolVersion to)
      majorUpgradeNotes,
}) {
  final release = context.target;
  if (declaration == null) {
    return NotApplicable('The project does not declare the $name.');
  }
  if (declaration.version == null) {
    if (floorError == null) {
      return NotApplicable('The $name version could not be determined '
          '(${declaration.note ?? declaration.rawText}).');
    }
    return Proposal(
      status: StepStatus.manual,
      necessity: Necessity.required,
      summary: 'Check the $name version.',
      rationale: 'Flutter ${release.version} requires $name $floorError or '
          'newer, but Reforge could not determine the declared version.',
      confidence: Confidence.low,
      evidence: [declarationEvidence(name, declaration)],
      manualSteps: [
        'Make sure the $name is $floorError or newer'
            '${declaration.note == null ? '' : ' (${declaration.note})'}.',
      ],
    );
  }
  if (target == null) {
    return NotApplicable('$name ${declaration.version} already satisfies '
        'Flutter ${release.version}.');
  }

  final from = declaration.version!;
  final evidence = [declarationEvidence(name, declaration), ...target.reasons];
  final rationale = '$name $from is below ${target.minimum}: '
      '${target.reasons.map((r) => r.description).join('; ')}.';
  final to = target.target;
  if (to == null) {
    return Proposal(
      status: StepStatus.blocked,
      necessity: target.necessity,
      summary: 'Upgrade the $name to ${target.minimum} or newer.',
      rationale: '$rationale No published release at or above '
          '${target.minimum} is known to this version of Reforge.',
      evidence: evidence,
      manualSteps: const ['Upgrade Reforge, or edit the version manually.'],
    );
  }
  final editable = declaration.editable;
  if (editable == null) {
    return Proposal(
      status: StepStatus.manual,
      necessity: target.necessity,
      summary: 'Upgrade the $name from $from to $to.',
      rationale: rationale,
      confidence: confidenceOf(declaration),
      evidence: evidence,
      manualSteps: [
        'Change the $name version to $to at ${(declaration.definition ?? declaration.usage).display}'
            '${declaration.note == null ? '' : ' (${declaration.note})'}.',
      ],
    );
  }

  final notes = <String>[];
  var status = StepStatus.auto;
  if (crossesMajor(from, to)) {
    status = StepStatus.review;
    notes.add('This is a major version upgrade ($from to $to).');
    notes.addAll(majorUpgradeNotes(from, to));
  }
  if (declaration.resolution == ValueResolution.variable ||
      declaration.resolution == ValueResolution.gradleProperty) {
    notes.add('The version is defined by ${declaration.rawText}; every use of '
        'that value changes.');
  }

  return Proposal(
    status: status,
    necessity: target.necessity,
    summary: 'Upgrade the $name from $from to $to.',
    rationale: rationale,
    impact: target.necessity == Necessity.required
        ? 'Android builds fail in Flutter\'s dependency version check.'
        : 'Builds print deprecation warnings.',
    confidence: confidenceOf(declaration),
    evidence: evidence,
    edits: [replaceValue(editable, '$to')],
    notes: notes,
    verification: const [
      VerificationCheck.staticAnalysis,
      VerificationCheck.androidBuild,
    ],
    details: {'from': '$from', 'to': '$to', 'minimum': '${target.minimum}'},
  );
}
