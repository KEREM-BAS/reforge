import '../../../knowledge/knowledge_base.dart';
import '../../../model/finding.dart';
import '../../../parsing/gradle/gradle_lexer.dart';
import '../../../parsing/gradle/gradle_script.dart';
import '../../../parsing/gradle/gradle_semantics.dart';
import '../../../text/text_edit.dart';
import '../../../version/tool_version.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';
import '../recipe_support.dart';

/// Stops applying the Kotlin Gradle plugin in the app module, which Flutter
/// 3.44 and later apply themselves while built-in Kotlin is disabled.
///
/// With Android Gradle Plugin 9, Flutter warns that apps applying the plugin
/// will fail to build in future versions, and with built-in Kotlin enabled
/// the build fails already. The change follows Flutter's app template and its
/// migration guide: the plugin application is removed, and a plain
/// `kotlinOptions { jvmTarget }` becomes `kotlin { compilerOptions { } }`.
final class AppKotlinPluginRecipe extends MigrationRecipe {
  const AppKotlinPluginRecipe();

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidAppKotlinPlugin,
        title: 'Stop applying the Kotlin Gradle plugin in the app module',
        summary: 'Removes the Kotlin Android plugin from the app module and '
            'moves jvmTarget from kotlinOptions to kotlin.compilerOptions, as '
            'in Flutter 3.44+ templates, when Flutter applies the plugin '
            'itself and the project uses Android Gradle Plugin 9.',
        category: RecipeCategory.android,
        runsAfter: [
          RecipeIds.androidFlutterGradlePluginDsl,
          RecipeIds.androidAgp9OptOuts,
          RecipeIds.androidAgpVersion,
          RecipeIds.androidKotlinVersion,
        ],
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final android = context.project.android;
    final app = android?.app;
    if (android == null || app == null) {
      return const NotApplicable('The project has no Android app module.');
    }
    final release = context.target;
    if (!release.appliesKotlinPlugin) {
      return NotApplicable('Flutter ${release.version} does not apply the '
          'Kotlin Gradle plugin itself, so the app module keeps applying it.');
    }
    final script = app.script;
    if (!script.isReliable) {
      return NotApplicable('${script.path} could not be parsed reliably '
          '(see PROJECT_FILE_UNREADABLE).');
    }
    final applications = kotlinAndroidPluginApplications(script);
    if (applications.isEmpty) {
      return const NotApplicable(
          'The app module does not apply the Kotlin Gradle plugin.');
    }
    final agp = android.toolchain.androidGradlePlugin?.version;
    if (agp == null || agp.major < 9) {
      return NotApplicable('Flutter ${release.version} only warns about apps '
          'applying the Kotlin Gradle plugin with Android Gradle Plugin 9 or '
          'later; this project uses ${agp ?? 'an unknown version'}.');
    }

    // Built-in Kotlin is on unless gradle.properties turns it off.
    final builtInKotlin = android.toolchain.builtInKotlin ?? true;
    final necessity =
        builtInKotlin ? Necessity.required : Necessity.recommended;
    final evidence = [
      for (final statement in applications)
        Evidence.file(
            'Applies the Kotlin Android plugin', script.refAt(statement.start)),
      Evidence.knowledge(
          'Flutter ${release.version} applies the Kotlin Gradle plugin to app '
          'and plugin modules that do not apply it while built-in Kotlin is '
          'disabled, and warns about apps that apply it with Android Gradle '
          'Plugin 9',
          release.appliesKotlinPluginSource),
      const Evidence.knowledge(
          'Flutter migration guide: remove the Kotlin Android plugin and '
          'kotlinOptions from the app module',
          KnowledgeBase.builtInKotlinGuideSource),
    ];
    final rationale = 'Flutter ${release.version} applies the Kotlin Gradle '
        'plugin to the app module itself while built-in Kotlin is disabled, '
        'and its app template no longer applies it. With Android Gradle '
        'Plugin 9, Flutter warns that apps applying the plugin will fail to '
        'build in future versions.';
    final impact = builtInKotlin
        ? 'Android builds fail: with built-in Kotlin enabled, Android Gradle '
            'Plugin 9 rejects applying the Kotlin Android plugin.'
        : 'Android builds print a warning that future Flutter versions will '
            'fail to build the app.';

    Proposal manual(String problem) => Proposal(
          status: StepStatus.manual,
          necessity: necessity,
          summary: 'Stop applying the Kotlin Gradle plugin in ${script.path}.',
          rationale: rationale,
          impact: impact,
          evidence: evidence,
          manualSteps: [
            problem,
            'Remove the Kotlin Android plugin from ${script.path} and move '
                'jvmTarget to kotlin { compilerOptions { jvmTarget = '
                'org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17 } } '
                '(${KnowledgeBase.builtInKotlinGuideSource.url}).',
          ],
        );

    final kotlin = android.toolchain.kotlin;
    if (kotlin == null) {
      return manual('The Kotlin Gradle plugin is not declared in settings or '
          'the root build file, so Flutter could not apply it after the app '
          'module stops applying it. Declare it there with `apply false` '
          'first.');
    }

    final edits = <TextEdit>[
      for (final statement in applications)
        TextEdit.replace(
            removalRange(script, statement.start, statement.end), ''),
    ];
    final notes = <String>[
      'The Kotlin Gradle plugin stays declared in '
          '${(kotlin.definition ?? kotlin.usage).path}, so Flutter can apply '
          'it.',
    ];

    final androidBlock =
        script.statements.where((s) => s.isBlockNamed('android')).firstOrNull;
    final kotlinOptions = androidBlock == null
        ? const <GradleStatement>[]
        : [
            for (final block in androidBlock.blocks)
              ...block.statements.where((s) => s.isBlockNamed('kotlinOptions')),
          ];
    if (kotlinOptions.length > 1) {
      return manual('android {} sets kotlinOptions more than once.');
    }
    if (kotlinOptions.length == 1) {
      final options = kotlinOptions.single;
      final statements = options.blocks.single.statements;
      final value = statements.length == 1
          ? statements.single.propertyValue('jvmTarget')
          : null;
      final constant = value == null ? null : _jvmTargetConstant(value);
      if (constant == null) {
        return manual('kotlinOptions sets more than a jvmTarget Reforge can '
            'convert; move those options to kotlin { compilerOptions { } }.');
      }
      final kotlinVersion = kotlin.version;
      if (kotlinVersion == null || kotlinVersion < ToolVersion(2)) {
        return manual('kotlin { compilerOptions { } } requires the Kotlin '
            'Gradle plugin 2.0.0 or later; this project uses '
            '${kotlinVersion ?? 'an unknown version'}.');
      }
      if (script.statements.any((s) => s.isBlockNamed('kotlin'))) {
        return manual('${script.path} already has a kotlin {} block; merge '
            'the jvmTarget from kotlinOptions into it.');
      }
      final eol = eolOf(script.source);
      final unit = indentationAt(script, options.start)
          .substring(indentationAt(script, androidBlock!.start).length);
      edits
        ..add(TextEdit.replace(
            removalRange(script, options.start, options.end), ''))
        ..add(TextEdit.insert(
            androidBlock.end,
            '$eol${eol}kotlin {$eol'
            '${unit}compilerOptions {$eol'
            '$unit${unit}jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.'
            '$constant$eol'
            '$unit}$eol'
            '}'));
      evidence.add(const Evidence.knowledge(
          'kotlinOptions is deprecated since Kotlin 2.0.0 in favor of '
          'compilerOptions',
          KnowledgeBase.kotlinCompilerOptionsSource));
      notes.add('kotlinOptions (deprecated since Kotlin 2.0.0) becomes '
          'kotlin { compilerOptions { jvmTarget = JvmTarget.$constant } }.');
    }
    notes.add(builtInKotlin
        ? 'Built-in Kotlin is enabled; plugins that still apply the Kotlin '
            'Gradle plugin fail to build with it.'
        : 'android.builtInKotlin stays false. Enabling built-in Kotlin needs '
            'Flutter 3.47 or later and plugins that support it.');

    return Proposal(
      status: StepStatus.review,
      necessity: necessity,
      summary: 'Stop applying the Kotlin Gradle plugin in ${script.path}; '
          'Flutter applies it.',
      rationale: rationale,
      impact: impact,
      evidence: evidence,
      edits: [FileEdit(script.path, edits)],
      notes: notes,
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.androidBuild,
      ],
    );
  }

  /// The `JvmTarget` constant for `jvmTarget` written as
  /// `JavaVersion.VERSION_17.toString()`, `JavaVersion.VERSION_1_8`, `'17'`
  /// or `"1.8"`.
  static String? _jvmTargetConstant(List<GradleToken> tokens) {
    String? version;
    if (tokens.length == 1) {
      version = tokens.single.string?.constantValue;
    } else if (tokens.length >= 3 &&
        tokens[0].isIdentifier('JavaVersion') &&
        tokens[1].isPunctuation('.') &&
        tokens[2].kind == GradleTokenKind.identifier) {
      final rest = tokens.sublist(3).map((t) => t.text).join();
      final match = RegExp(r'^VERSION_(\d+)(?:_(\d+))?$')
          .firstMatch(tokens[2].identifierName);
      if (match != null && (rest.isEmpty || rest == '.toString()')) {
        version = match.group(2) == null
            ? match.group(1)
            : '${match.group(1)}.${match.group(2)}';
      }
    }
    if (version == null) return null;
    if (version == '1.8' || version == '8') return 'JVM_1_8';
    return RegExp(r'^(9|[1-9]\d)$').hasMatch(version) ? 'JVM_$version' : null;
  }
}
