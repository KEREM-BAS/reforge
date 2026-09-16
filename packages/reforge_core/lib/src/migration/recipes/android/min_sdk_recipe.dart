import '../../../model/declarations.dart';
import '../../../model/finding.dart';
import '../../../text/text_edit.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';

/// Raises literal `minSdk` values below the minimum Android API level of the
/// target release to `flutter.minSdkVersion`.
///
/// Flutter defines its minimum as `flutter.minSdkVersion`. Its Gradle plugin
/// fails builds below an error floor (Flutter 3.22+), and its tool replaces
/// too-low literal values with `flutter.minSdkVersion` before every Android
/// build (Flutter 3.16+). Raising minSdk drops support for devices, so the
/// step is always reviewed.
final class MinSdkRecipe extends MigrationRecipe {
  const MinSdkRecipe();

  static const _migration = 'MinSdkVersionMigration';
  static const _replacement = 'flutter.minSdkVersion';

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidMinSdk,
        title: 'Raise minSdk to the Flutter minimum',
        summary: 'Replaces literal minSdk values (defaultConfig and product '
            'flavors) below the minimum Android API level of the target '
            'Flutter release with flutter.minSdkVersion.',
        category: RecipeCategory.android,
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final android = context.project.android;
    final app = android?.app;
    if (android == null || app == null) {
      return const NotApplicable('The project has no Android app module.');
    }
    final release = context.target;
    final minimum = release.androidDefaults.minSdk;
    final declarations = app.minSdkDeclarations;
    final below = [
      for (final (label, value) in declarations)
        if (value is LiteralInt && value.value < minimum) (label, value),
    ];
    if (below.isEmpty) {
      final unknown = declarations
          .where((d) => d.$2 is OtherExpression)
          .map((d) => '${d.$1} "${d.$2.text}"')
          .toList();
      if (unknown.isNotEmpty) {
        return NotApplicable('minSdk is set by an expression Reforge does not '
            'evaluate (${unknown.join(', ')}). Flutter ${release.version} '
            'supports API level $minimum and newer.');
      }
      if (declarations.isEmpty) {
        return const NotApplicable('The app module does not declare minSdk.');
      }
      final String reason;
      if (declarations.every((d) => d.$2 is FlutterDefaultReference)) {
        reason = 'minSdk uses $_replacement.';
      } else if (declarations.every((d) => d.$2 is LiteralInt)) {
        reason = 'minSdk is API level $minimum or higher, as Flutter '
            '${release.version} requires.';
      } else {
        reason = 'minSdk uses $_replacement or API level $minimum or higher.';
      }
      return NotApplicable(reason);
    }
    if (!app.script.isReliable) {
      return NotApplicable('${app.script.path} could not be parsed reliably, '
          'so Reforge does not edit minSdk (see PROJECT_FILE_UNREADABLE).');
    }

    final knowledge = context.knowledge;
    String level(int apiLevel) {
      final version = knowledge.androidVersionOf(apiLevel)?.value;
      return version == null
          ? 'API level $apiLevel'
          : 'API level $apiLevel (Android $version)';
    }

    final lowest = below.map((d) => d.$2.value).reduce((a, b) => a < b ? a : b);
    final floor = release.androidRequirements.minSdk;
    final migrates = release.runsAndroidMigration(_migration);
    final summary = below.length == 1
        ? 'Raise minSdk from ${below.single.$2.value} to $_replacement, '
            '${level(minimum)}.'
        : 'Raise ${below.length} minSdk values to $_replacement, '
            '${level(minimum)}.';
    String dropped() {
      final from = knowledge.androidVersionOf(lowest)?.value;
      final to = knowledge.androidVersionOf(minimum - 1)?.value;
      if (lowest == minimum - 1) return level(lowest);
      final levels = 'API levels $lowest to ${minimum - 1}';
      return from == null || to == null
          ? levels
          : 'Android $from to $to ($levels)';
    }

    return Proposal(
      status: StepStatus.review,
      necessity: Necessity.required,
      summary: summary,
      rationale: [
        'Flutter ${release.version} supports ${level(minimum)} and newer; '
            '$_replacement is $minimum.',
        if (floor != null)
          'Its Gradle plugin fails builds below API level ${floor.error.major} '
              'and warns below ${floor.warn.major}.',
        if (migrates)
          'Before every Android build, its tool replaces too-low literal '
              'minSdk values with $_replacement.',
      ].join(' '),
      impact: migrates
          ? 'The next Android build raises minSdk itself, outside the reviewed '
              'migration.'
          : floor != null && lowest < floor.error.major
              ? "Android builds fail in Flutter's dependency version check."
              : 'The app declares support for Android versions Flutter '
                  '${release.version} does not support.',
      evidence: [
        for (final (label, value) in below)
          Evidence.file('$label minSdk is ${value.value}', value.location),
        Evidence.knowledge(
            '$_replacement is $minimum in Flutter ${release.version}',
            release.androidDefaultsSource),
        if (floor != null)
          Evidence.knowledge(
              'Flutter ${release.version} fails builds below minSdk '
              '${floor.error.major} and warns below ${floor.warn.major}',
              release.dependencyCheckerSource),
        if (migrates)
          Evidence.knowledge(
              'Before every Android build, Flutter ${release.version} replaces '
              'too-low literal minSdk values with $_replacement ($_migration)',
              release.androidMigrationSource(_migration)),
      ],
      edits: [
        for (final (_, value) in below)
          if (value.editable case final editable?)
            FileEdit(editable.path,
                [TextEdit.replace(editable.range, _replacement)]),
      ],
      notes: [
        'Devices running ${dropped()} can no longer install new versions of '
            'the app.',
        '$_replacement follows future Flutter upgrades. Use a literal value of '
            '$minimum or higher instead if the app must keep a fixed minimum.',
      ],
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.androidBuild,
      ],
      details: {'from': lowest, 'to': minimum},
    );
  }
}
