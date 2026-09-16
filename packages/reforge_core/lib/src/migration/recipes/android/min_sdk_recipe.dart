import '../../../model/declarations.dart';
import '../../../model/dependencies.dart';
import '../../../model/finding.dart';
import '../../../text/text_edit.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';

/// Raises literal `minSdk` values below the minimum Android API level of the
/// target release to `flutter.minSdkVersion`, or below the minSdk the
/// project's plugins declare to that level.
///
/// Flutter defines its minimum as `flutter.minSdkVersion`. Its Gradle plugin
/// fails builds below an error floor (Flutter 3.22+), and its tool replaces
/// too-low literal values with `flutter.minSdkVersion` before every Android
/// build (Flutter 3.16+). Android's manifest merger fails builds when a
/// plugin declares a higher minSdk than the app. Raising minSdk drops support
/// for devices, so the step is always reviewed.
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
    final flutterMinimum = release.androidDefaults.minSdk;
    // Android's manifest merger rejects an app whose minSdk is below a
    // plugin's.
    final plugins = [
      for (final package
          in context.dependencies?.packages ?? const <ResolvedPackage>[])
        if (package.android?.minSdk case final sdk? when sdk > flutterMinimum)
          (package, sdk),
    ];
    final minimum =
        plugins.fold(flutterMinimum, (max, p) => p.$2 > max ? p.$2 : max);
    final replacement = minimum == flutterMinimum ? _replacement : '$minimum';
    final declarations = app.minSdkDeclarations;
    final below = [
      for (final (label, value) in declarations)
        if (value is LiteralInt && value.value < minimum) (label, value),
    ];
    // flutter.minSdkVersion itself is below what plugins require.
    final defaultsBelow = [
      if (minimum > flutterMinimum)
        for (final (label, value) in declarations)
          if (value is FlutterDefaultReference) (label, value),
    ];
    if (below.isEmpty && defaultsBelow.isEmpty) {
      final unknown = declarations
          .where((d) => d.$2 is OtherExpression)
          .map((d) => '${d.$1} "${d.$2.text}"')
          .toList();
      if (unknown.isNotEmpty) {
        return NotApplicable('minSdk is set by an expression Reforge does not '
            'evaluate (${unknown.join(', ')}). Flutter ${release.version} '
            'supports API level $flutterMinimum and newer'
            '${plugins.isEmpty ? '' : ', and plugins require $minimum'}.');
      }
      if (declarations.isEmpty) {
        return const NotApplicable('The app module does not declare minSdk.');
      }
      final String reason;
      if (declarations.every((d) => d.$2 is FlutterDefaultReference)) {
        reason = 'minSdk uses $_replacement.';
      } else if (declarations.every((d) => d.$2 is LiteralInt)) {
        reason = plugins.isEmpty
            ? 'minSdk is API level $minimum or higher, as Flutter '
                '${release.version} requires.'
            : 'minSdk is API level $minimum or higher, as Flutter '
                '${release.version} and the plugins require.';
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

    final lowest = [
      for (final (_, value) in below) value.value,
      if (defaultsBelow.isNotEmpty) flutterMinimum,
    ].reduce((a, b) => a < b ? a : b);
    final floor = release.androidRequirements.minSdk;
    final migrates = release.runsAndroidMigration(_migration);
    final requiring = plugins.where((p) => p.$2 > lowest).toList();
    final pluginNames = requiring.map((p) => p.$1.name).join(', ');
    final target = replacement == _replacement
        ? '$_replacement, ${level(minimum)}'
        : level(minimum);
    final count = below.length + defaultsBelow.length;
    final summary = count == 1
        ? 'Raise minSdk from '
            '${below.isEmpty ? '$_replacement ($flutterMinimum)' : below.single.$2.value} '
            'to $target.'
        : 'Raise $count minSdk values to $target.';
    String dropped() {
      final from = knowledge.androidVersionOf(lowest)?.value;
      final to = knowledge.androidVersionOf(minimum - 1)?.value;
      if (lowest == minimum - 1) return level(lowest);
      final levels = 'API levels $lowest to ${minimum - 1}';
      return from == null || to == null
          ? levels
          : 'Android $from to $to ($levels)';
    }

    final String impact;
    if (requiring.isNotEmpty) {
      impact = "Android builds fail in Android's manifest merger: "
          '$pluginNames declare${requiring.length == 1 ? 's' : ''} a higher '
          'minSdk than the app.';
    } else if (migrates) {
      impact = 'The next Android build raises minSdk itself, outside the '
          'reviewed migration.';
    } else if (floor != null && lowest < floor.error.major) {
      impact = "Android builds fail in Flutter's dependency version check.";
    } else {
      impact = 'The app declares support for Android versions Flutter '
          '${release.version} does not support.';
    }

    final evidence = [
      for (final (label, value) in below)
        Evidence.file('$label minSdk is ${value.value}', value.location),
      for (final (label, value) in defaultsBelow)
        Evidence.file(
            '$label minSdk is $_replacement ($flutterMinimum in Flutter '
            '${release.version})',
            value.location),
      Evidence.knowledge(
          '$_replacement is $flutterMinimum in Flutter ${release.version}',
          release.androidDefaultsSource),
      if (floor != null && lowest < flutterMinimum)
        Evidence.knowledge(
            'Flutter ${release.version} fails builds below minSdk '
            '${floor.error.major} and warns below ${floor.warn.major}',
            release.dependencyCheckerSource),
      if (migrates && lowest < flutterMinimum)
        Evidence.knowledge(
            'Before every Android build, Flutter ${release.version} replaces '
            'too-low literal minSdk values with $_replacement ($_migration)',
            release.androidMigrationSource(_migration)),
      for (final (package, sdk) in requiring)
        Evidence(
            EvidenceKind.dependencyFile, '${package.name} declares minSdk $sdk',
            location: package.android!.buildFile),
      if (requiring.isNotEmpty)
        Evidence.knowledge(
            "Flutter's tool explains the manifest merger failure and asks for "
            "the plugin's minSdk in the app module",
            release.gradleErrorsSource),
    ];
    final rationale = [
      if (lowest < flutterMinimum) ...[
        'Flutter ${release.version} supports ${level(flutterMinimum)} and '
            'newer; $_replacement is $flutterMinimum.',
        if (floor != null)
          'Its Gradle plugin fails builds below API level ${floor.error.major} '
              'and warns below ${floor.warn.major}.',
        if (migrates)
          'Before every Android build, its tool replaces too-low literal '
              'minSdk values with $_replacement.',
      ],
      for (final (package, sdk) in requiring)
        '${package.name} declares minSdk $sdk.',
    ].join(' ');
    final notes = [
      'Devices running ${dropped()} can no longer install new versions of '
          'the app.',
      if (replacement == _replacement)
        '$_replacement follows future Flutter upgrades. Use a literal value of '
            '$minimum or higher instead if the app must keep a fixed minimum.'
      else
        'minSdk is set to $minimum, the highest minSdk of the plugins, because '
            '$_replacement ($flutterMinimum) is lower. Consider versions of '
            '$pluginNames that support older Android versions instead.',
    ];

    if (defaultsBelow.isNotEmpty) {
      return Proposal(
        status: StepStatus.manual,
        necessity: Necessity.required,
        summary: summary,
        rationale: rationale,
        impact: impact,
        evidence: evidence,
        manualSteps: [
          'Set minSdk in ${app.script.path} to $minimum: $_replacement is '
              '$flutterMinimum in Flutter ${release.version}, lower than '
              '$pluginNames require${requiring.length == 1 ? 's' : ''}.',
        ],
        notes: notes,
        details: {'from': lowest, 'to': minimum},
      );
    }
    return Proposal(
      status: StepStatus.review,
      necessity: Necessity.required,
      summary: summary,
      rationale: rationale,
      impact: impact,
      evidence: evidence,
      edits: [
        for (final (_, value) in below)
          if (value.editable case final editable?)
            FileEdit(
                editable.path, [TextEdit.replace(editable.range, replacement)]),
      ],
      notes: notes,
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.androidBuild,
      ],
      details: {'from': lowest, 'to': minimum},
    );
  }
}
