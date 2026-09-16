import '../../../knowledge/knowledge_base.dart';
import '../../../model/finding.dart';
import '../../../parsing/gradle/gradle_script.dart';
import '../../../parsing/gradle/gradle_semantics.dart';
import '../../../text/text_edit.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';
import '../recipe_support.dart';

/// Replaces the JCenter repository in the Android build scripts with Maven
/// Central.
///
/// Gradle 9 removed `jcenter()` (deprecated since Gradle 7.0). JCenter has
/// redirected to Maven Central since August 2024, so `mavenCentral()`
/// resolves the same artifacts. Flutter's app templates declared `jcenter()`
/// until Flutter 2.5.
final class JcenterRecipe extends MigrationRecipe {
  const JcenterRecipe();

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidJcenter,
        title: 'Replace the JCenter repository with Maven Central',
        summary: 'Replaces jcenter(), which Gradle 9 removed, with '
            'mavenCentral() in the Android build scripts, or removes it where '
            'the same repositories block declares mavenCentral().',
        category: RecipeCategory.android,
        runsAfter: [
          RecipeIds.androidFlutterGradlePluginDsl,
          RecipeIds.androidGradleWrapper,
        ],
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final android = context.project.android;
    if (android == null) {
      return const NotApplicable('The project has no Android host.');
    }
    final found = [
      for (final script in android.scripts)
        if (script.isReliable)
          for (final repository in jcenterRepositories(script))
            (script, repository),
    ];
    if (found.isEmpty) {
      final unreliable = android.scripts.where((s) => !s.isReliable);
      return NotApplicable(unreliable.isEmpty
          ? 'The Android build scripts do not declare jcenter().'
          : 'The readable Android build scripts do not declare jcenter(); '
              '${unreliable.map((s) => s.path).join(', ')} could not be '
              'parsed reliably (see PROJECT_FILE_UNREADABLE).');
    }

    final gradle = android.toolchain.gradleWrapper;
    final removed = gradle?.version != null && gradle!.version!.major >= 9;
    final edits = <String, List<TextEdit>>{};
    var removals = 0;
    for (final (script, repository) in found) {
      final statement = repository.statement;
      final TextEdit edit;
      if (statement.blocks.isEmpty &&
          repository.alongsideMavenCentral &&
          _standsAlone(script, statement)) {
        edit = TextEdit.replace(
            removalRange(script, statement.start, statement.end), '');
        removals++;
      } else {
        edit = TextEdit.replace(repository.name.range, 'mavenCentral');
      }
      edits.putIfAbsent(script.path, () => []).add(edit);
    }
    final paths = edits.keys.join(', ');

    return Proposal(
      status: StepStatus.auto,
      necessity: removed ? Necessity.required : Necessity.recommended,
      summary: 'Replace jcenter() with mavenCentral() in $paths.',
      rationale: 'Gradle 9 removed the jcenter() repository method, deprecated '
          'since Gradle 7.0. JCenter has redirected to Maven Central since '
          'August 2024, so mavenCentral() resolves the same artifacts.',
      impact: removed
          ? 'Gradle ${gradle.version} fails to configure the Android build: '
              'jcenter() no longer exists.'
          : 'Gradle prints a deprecation warning, and the build fails once the '
              'project upgrades to Gradle 9.',
      evidence: [
        for (final (script, repository) in found)
          Evidence.file('jcenter() in a repositories block',
              script.refAt(repository.statement.start)),
        if (removed)
          Evidence.file(
              'The Gradle wrapper uses ${gradle.version}', gradle.location),
        const Evidence.knowledge(
            'Gradle 9.0.0 removed jcenter(); mavenCentral() is the closest '
            'direct replacement',
            KnowledgeBase.gradle9JcenterRemovalSource),
        const Evidence.knowledge(
            "Flutter's app templates replaced jcenter() with mavenCentral() in "
            'Flutter 2.5',
            KnowledgeBase.flutterTemplateJcenterRemovalSource),
      ],
      edits: [
        for (final entry in edits.entries) FileEdit(entry.key, entry.value),
      ],
      notes: [
        if (removals > 0)
          'jcenter() is removed where the same repositories block already '
              'declares mavenCentral().',
        'Plugins that declare jcenter() in their own build scripts fail with '
            'Gradle 9 too (see PLUGIN_GRADLE_JCENTER); they need newer '
            'versions.',
      ],
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.androidBuild,
      ],
      details: {'declarations': found.length},
    );
  }

  /// Whether [statement] is the only code on its lines, so removing the lines
  /// removes nothing else (`repositories { google(); jcenter() }` is not).
  static bool _standsAlone(GradleScript script, GradleStatement statement) {
    final lines = script.lineIndex;
    final source = script.source;
    final first = lines.lineOf(statement.start);
    final last = lines.lineOf(statement.end - 1);
    final before =
        source.substring(lines.lineStart(first), statement.start).trim();
    final after = source.substring(statement.end, lines.lineEnd(last)).trim();
    return before.isEmpty &&
        (after.isEmpty || after == ';' || after.startsWith('//'));
  }
}
