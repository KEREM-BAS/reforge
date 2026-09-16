import '../../../common/source.dart';
import '../../../knowledge/knowledge_base.dart';
import '../../../model/finding.dart';
import '../../../text/text_edit.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';
import '../recipe_support.dart';

// Recipes that make, ahead of time, the changes the Flutter tool of the
// target release applies to Android host projects before every Gradle build
// (`flutter build`, `flutter run`). Without them the first build after a
// migration silently changes files outside the reviewed plan, and rolling
// the migration back conflicts with those changes.

/// Adds `android.builtInKotlin=false` and `android.newDsl=false` to
/// `gradle.properties`, as Flutter's `DisableBuiltInKotlinMigration` and
/// `DisableNewDslMigration` do (Flutter 3.44+).
final class Agp9OptOutsRecipe extends MigrationRecipe {
  const Agp9OptOutsRecipe();

  static const _optOuts = [
    (key: 'android.builtInKotlin', migration: 'DisableBuiltInKotlinMigration'),
    (key: 'android.newDsl', migration: 'DisableNewDslMigration'),
  ];

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidAgp9OptOuts,
        title: 'Opt out of Android Gradle Plugin 9 defaults',
        summary: 'Adds android.builtInKotlin=false and android.newDsl=false to '
            'gradle.properties when the Flutter tool of the target release '
            'would add them during the next build.',
        category: RecipeCategory.android,
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final android = context.project.android;
    if (android == null) {
      return const NotApplicable('The project has no Android host.');
    }
    final release = context.target;
    final optOuts = [
      for (final optOut in _optOuts)
        if (release.runsAndroidMigration(optOut.migration)) optOut,
    ];
    if (optOuts.isEmpty) {
      return NotApplicable('The Flutter ${release.version} tool does not add '
          'Android Gradle Plugin 9 opt-outs to projects.');
    }
    final evidence = [
      for (final optOut in optOuts)
        Evidence.knowledge(
            'Before every Android build, Flutter ${release.version} adds '
            '${optOut.key}=false to gradle.properties when it is not set '
            '(${optOut.migration})',
            release.androidMigrationSource(optOut.migration)),
      const Evidence.knowledge(
          'Android Gradle Plugin 9 enables built-in Kotlin and the new DSL by '
          'default; setting the properties to false opts out',
          KnowledgeBase.agp9ReleaseNotesSource),
    ];
    const rationale = 'Android Gradle Plugin 9 enables built-in Kotlin and '
        'the new DSL by default. Flutter keeps existing projects on the '
        'previous behavior: before every Android build, its tool adds '
        'android.builtInKotlin=false and android.newDsl=false to '
        'gradle.properties when they are not set.';

    final properties = android.gradleProperties;
    if (properties == null) {
      final path = '${android.directory}/gradle.properties';
      return Proposal(
        status: StepStatus.manual,
        necessity: Necessity.flutterMigration,
        summary: 'Create $path with the Android Gradle Plugin 9 opt-outs.',
        rationale: rationale,
        evidence: evidence,
        manualSteps: [
          'Create $path containing '
              '${optOuts.map((o) => '${o.key}=false').join(' and ')}.',
        ],
      );
    }

    final missing = [
      for (final optOut in optOuts)
        if (!properties.containsKey(optOut.key)) optOut,
    ];
    if (missing.isEmpty) {
      return NotApplicable('${properties.path} already sets '
          '${optOuts.map((o) => o.key).join(' and ')}.');
    }
    final source = properties.source;
    final eol = eolOf(source);
    final lines = StringBuffer();
    if (source.isNotEmpty && !source.endsWith('\n')) lines.write(eol);
    for (final optOut in missing) {
      lines
        ..write("# Added by Reforge, as Flutter's ${optOut.migration} does$eol")
        ..write('${optOut.key}=false$eol');
    }
    final keys = missing.map((o) => '${o.key}=false').join(' and ');
    return Proposal(
      status: StepStatus.auto,
      necessity: Necessity.flutterMigration,
      summary: 'Add $keys to ${properties.path}.',
      rationale: rationale,
      impact: 'The first Android build with Flutter ${release.version} adds '
          'them itself, outside the reviewed migration'
          '${source.contains('\r\n') ? ', and rewrites ${properties.path} with LF line endings' : ''}.',
      evidence: [
        Evidence.file('${missing.map((o) => o.key).join(' and ')} not set',
            SourceRef(properties.path)),
        ...evidence,
      ],
      edits: [
        FileEdit(properties.path, [TextEdit.insert(source.length, '$lines')]),
      ],
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.androidBuild,
      ],
    );
  }
}

/// Replaces the eager `task clean(type: Delete)` declaration of older
/// templates with a lazily registered task, as Flutter's
/// `TopLevelGradleBuildFileMigration` does (Flutter 3.10+).
final class LazyCleanTaskRecipe extends MigrationRecipe {
  const LazyCleanTaskRecipe();

  static const _migration = 'TopLevelGradleBuildFileMigration';

  /// Flutter matches this exact text after normalizing line endings.
  static final _eagerCleanTask = RegExp(
      r'task clean\(type: Delete\) \{(\r?\n)    delete rootProject\.buildDir(\r?\n)\}(?=\r?\n|$)');

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidCleanTask,
        title: 'Register the clean task lazily',
        summary: 'Replaces the eager clean task of older templates in '
            'android/build.gradle with tasks.register, as the Flutter tool of '
            'the target release would during the next build.',
        category: RecipeCategory.android,
        runsAfter: [RecipeIds.androidFlutterGradlePluginDsl],
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final android = context.project.android;
    if (android == null) {
      return const NotApplicable('The project has no Android host.');
    }
    final release = context.target;
    if (!release.runsAndroidMigration(_migration)) {
      return NotApplicable('The Flutter ${release.version} tool does not '
          'migrate the clean task.');
    }
    final root = android.rootBuild;
    if (root == null || !root.path.endsWith('/build.gradle')) {
      return const NotApplicable(
          'The Flutter tool only migrates a Groovy android/build.gradle.');
    }
    final matches = _eagerCleanTask.allMatches(root.source).toList();
    if (matches.isEmpty) {
      return NotApplicable('${root.path} has no clean task in the form the '
          'Flutter tool migrates.');
    }
    return Proposal(
      status: StepStatus.auto,
      necessity: Necessity.flutterMigration,
      summary: 'Register the clean task lazily in ${root.path}.',
      rationale: 'Before every Android build, Flutter ${release.version} '
          'replaces the eager `task clean(type: Delete)` declaration of older '
          'templates with `tasks.register("clean", Delete)` using '
          'rootProject.layout.buildDirectory.',
      impact: 'The first Android build with Flutter ${release.version} makes '
          'this change itself, outside the reviewed migration'
          '${root.source.contains('\r\n') ? ', and rewrites ${root.path} with LF line endings' : ''}.',
      evidence: [
        for (final match in matches)
          Evidence.file('Eager clean task', root.refAt(match.start)),
        Evidence.knowledge(
            'Before every Android build, Flutter ${release.version} rewrites '
            'this declaration ($_migration)',
            release.androidMigrationSource(_migration)),
      ],
      edits: [
        FileEdit(root.path, [
          for (final match in matches)
            TextEdit(
                match.start,
                match.end - match.start,
                'tasks.register("clean", Delete) {${match[1]}'
                '    delete rootProject.layout.buildDirectory${match[2]}}'),
        ]),
      ],
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.androidBuild,
      ],
    );
  }
}
