import '../../../knowledge/knowledge_base.dart';
import '../../../model/finding.dart';
import '../../../parsing/gradle/gradle_script.dart';
import '../../../parsing/gradle/gradle_semantics.dart';
import '../../../text/text_edit.dart';
import '../../../version/tool_version.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';
import '../recipe_support.dart';

/// Declares the Kotlin JVM target of the app module, matching its Java
/// target, when the build script does not set it.
///
/// Without a declared `jvmTarget`, the Kotlin Gradle plugin compiles to the
/// JVM Gradle runs on, while Java compiles to `compileOptions`
/// (`targetCompatibility`, Java 8 when absent). On Gradle 8 the plugin fails
/// the build when the two differ. Flutter 3.22 app templates did not set the
/// Kotlin target (flutter/flutter#147185), nor did templates before
/// Flutter 2.5; Flutter 3.24 templates set it again.
final class KotlinJvmTargetRecipe extends MigrationRecipe {
  const KotlinJvmTargetRecipe();

  /// The Java target of an Android module without `compileOptions`, as
  /// observed with Android Gradle Plugin 8.11.1.
  static const _defaultJavaTarget = '1.8';

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidKotlinJvmTarget,
        title: 'Align the Kotlin JVM target with Java',
        summary: 'Declares the Kotlin jvmTarget of the app module to match its '
            'Java targetCompatibility, as Flutter 3.24+ templates do, when the '
            'build script does not set it.',
        category: RecipeCategory.android,
        runsAfter: [
          RecipeIds.androidFlutterGradlePluginDsl,
          RecipeIds.androidGradleWrapper,
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
    final script = app.script;
    if (!script.isReliable) {
      return NotApplicable('${script.path} could not be parsed reliably '
          '(see PROJECT_FILE_UNREADABLE).');
    }
    if (kotlinAndroidPluginApplications(script).isEmpty) {
      return const NotApplicable(
          'The app module does not apply the Kotlin Gradle plugin.');
    }
    final targets = jvmTargets(script);
    if (targets.kotlinConfigured) {
      return NotApplicable('${script.path} configures the Kotlin JVM target '
          'or a JVM toolchain.');
    }
    final mode = android.gradleProperties?['kotlin.jvm.target.validation.mode'];
    if (mode != null && mode != 'error') {
      return NotApplicable('gradle.properties sets '
          'kotlin.jvm.target.validation.mode=$mode.');
    }
    final androidBlock = targets.android;
    if (androidBlock == null) {
      return NotApplicable('${script.path} has no android {} block.');
    }

    final gradle = android.toolchain.gradleWrapper?.version;
    final kotlin = android.toolchain.kotlin?.version;
    final fails = gradle != null &&
        gradle.major >= 8 &&
        kotlin != null &&
        kotlin >= KnowledgeBase.kotlinJvmTargetFailureSince;
    final necessity = fails ? Necessity.required : Necessity.recommended;
    final evidence = [
      Evidence.file(
          targets.compileOptions == null
              ? 'android {} sets no compileOptions and no Kotlin jvmTarget'
              : 'compileOptions targetCompatibility '
                  '${targets.javaTargetText ?? '(not set)'}; no Kotlin '
                  'jvmTarget',
          script.refAt((targets.compileOptions ?? androidBlock).start)),
      if (fails) ...[
        Evidence.file('Gradle wrapper uses $gradle',
            android.toolchain.gradleWrapper!.location),
        Evidence.file(
            'Kotlin Gradle plugin $kotlin', android.toolchain.kotlin!.usage),
      ],
      const Evidence.knowledge(
          'The Kotlin Gradle plugin fails builds on Gradle 8.0+ when Java and '
          'Kotlin compile to different JVM targets',
          KnowledgeBase.kotlinJvmTargetValidationSource),
      const Evidence.knowledge(
          'Flutter 3.24 app templates set the Kotlin jvmTarget again after new '
          'Flutter 3.22 projects failed with Kotlin 1.9.23 and Gradle 8.6',
          KnowledgeBase.flutterTemplateJvmTargetSource),
    ];
    const rationale = 'Without a declared jvmTarget, the Kotlin Gradle plugin '
        'compiles to the JVM Gradle runs on (17 or later with Android Gradle '
        'Plugin 8), while Java compiles to targetCompatibility. On Gradle 8 '
        'the Kotlin Gradle plugin fails the build when they differ.';
    final impact = fails
        ? 'Android builds fail: "Inconsistent JVM-target compatibility '
            "detected for tasks 'compileDebugJavaWithJavac' and "
            "'compileDebugKotlin'\"."
        : 'Builds warn about inconsistent JVM targets, and fail once the '
            'project uses Gradle 8 and Kotlin ${KnowledgeBase.kotlinJvmTargetFailureSince} '
            'or later.';

    final javaTarget = targets.compileOptions == null
        ? _defaultJavaTarget
        : targets.javaTarget;
    if (javaTarget == null) {
      return Proposal(
        status: StepStatus.manual,
        necessity: necessity,
        summary: 'Set the Kotlin jvmTarget of ${script.path} to its Java '
            'target.',
        rationale: rationale,
        impact: impact,
        evidence: evidence,
        manualSteps: [
          'targetCompatibility is "${targets.javaTargetText ?? ''}", which '
              'Reforge does not evaluate. Set the Kotlin jvmTarget to the same '
              'Java version.',
        ],
      );
    }
    final kotlin2 = kotlin != null && kotlin >= ToolVersion(2);
    if (kotlin2 && targets.kotlinBlock != null) {
      return Proposal(
        status: StepStatus.manual,
        necessity: necessity,
        summary: 'Set the Kotlin jvmTarget of ${script.path} to $javaTarget.',
        rationale: rationale,
        impact: impact,
        evidence: evidence,
        manualSteps: [
          '${script.path} already has a kotlin {} block: add compilerOptions '
              '{ jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.'
              '${_jvmTargetConstant(javaTarget)} } to it.',
        ],
      );
    }

    final eol = eolOf(script.source);
    final indent = indentationAt(script, androidBlock.start);
    final unit = _indentUnit(script, androidBlock) ?? '    ';
    final javaVersion =
        'JavaVersion.VERSION_${javaTarget.replaceAll('.', '_')}';
    final kotlinOptions = '$indent${unit}kotlinOptions {$eol'
        '$indent$unit${unit}jvmTarget = $javaVersion.toString()$eol'
        '$indent$unit}';
    final edits = <TextEdit>[];
    final block = androidBlock.blocks.first;
    if (targets.compileOptions case final compileOptions?) {
      if (!kotlin2) {
        edits
            .add(TextEdit.insert(compileOptions.end, '$eol$eol$kotlinOptions'));
      }
    } else {
      // Before defaultConfig, where Flutter templates declare compileOptions.
      final defaultConfig = block.statements
          .where((s) => s.isBlockNamed('defaultConfig'))
          .firstOrNull;
      final declarations = [
        '$indent${unit}compileOptions {$eol'
            '$indent$unit${unit}sourceCompatibility = $javaVersion$eol'
            '$indent$unit${unit}targetCompatibility = $javaVersion$eol'
            '$indent$unit}',
        if (!kotlin2) kotlinOptions,
      ].join('$eol$eol');
      final line =
          script.lineIndex.lineOf(defaultConfig?.start ?? block.closeBrace);
      edits.add(TextEdit.insert(
          script.lineIndex.lineStart(line),
          defaultConfig == null
              ? '$eol$declarations$eol'
              : '$declarations$eol$eol'));
    }
    if (kotlin2) {
      edits.add(TextEdit.insert(
          androidBlock.end,
          '$eol${eol}kotlin {$eol'
          '${unit}compilerOptions {$eol'
          '$unit${unit}jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.'
          '${_jvmTargetConstant(javaTarget)}$eol'
          '$unit}$eol'
          '}'));
    }

    return Proposal(
      status: StepStatus.review,
      necessity: necessity,
      summary: targets.compileOptions == null
          ? 'Declare Java and Kotlin JVM target $javaTarget in ${script.path}.'
          : 'Set the Kotlin jvmTarget of ${script.path} to $javaTarget, its '
              'Java target.',
      rationale: rationale,
      impact: impact,
      evidence: evidence,
      edits: [FileEdit(script.path, edits)],
      notes: [
        if (targets.compileOptions == null)
          'compileOptions makes the Java target the module already compiles '
              'to explicit ($javaTarget).',
        'Kotlin code that inlines functions compiled for a newer JVM target '
            'fails to compile with an older target; raise both targets '
            'together if that happens.',
      ],
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.androidBuild,
      ],
      details: {'jvmTarget': javaTarget},
    );
  }

  static String _jvmTargetConstant(String target) =>
      target == '1.8' ? 'JVM_1_8' : 'JVM_$target';

  /// The indentation step used inside [statement]'s block.
  static String? _indentUnit(GradleScript script, GradleStatement statement) {
    final inner = statement.blocks.first.statements.firstOrNull;
    if (inner == null) return null;
    final outer = indentationAt(script, statement.start);
    final nested = indentationAt(script, inner.start);
    return nested.length > outer.length ? nested.substring(outer.length) : null;
  }
}
