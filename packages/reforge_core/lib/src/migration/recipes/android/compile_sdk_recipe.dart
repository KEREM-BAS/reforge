import '../../../model/declarations.dart';
import '../../../model/dependencies.dart';
import '../../../model/finding.dart';
import '../../../text/text_edit.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';

/// Raises a literal `compileSdk` of the app module that is lower than the
/// target release's `flutter.compileSdkVersion` or than the Android SDK the
/// project's plugins compile against.
///
/// Flutter's Gradle plugin warns when plugins compile against a higher
/// Android SDK than the app, and Android libraries fail the build when they
/// require a higher compileSdk. compileSdk only selects the APIs available at
/// compile time; targetSdk, which changes runtime behavior, is not touched.
final class CompileSdkRecipe extends MigrationRecipe {
  const CompileSdkRecipe();

  static const _replacement = 'flutter.compileSdkVersion';

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidCompileSdk,
        title: 'Compile against the Android SDK Flutter and plugins use',
        summary: 'Replaces a literal compileSdk lower than the target Flutter '
            "release's flutter.compileSdkVersion, or than the Android SDK the "
            "project's plugins compile against.",
        category: RecipeCategory.android,
        runsAfter: [RecipeIds.androidFlutterGradlePluginDsl],
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final app = context.project.android?.app;
    if (app == null) {
      return const NotApplicable('The project has no Android app module.');
    }
    if (!app.script.isReliable) {
      return NotApplicable('${app.script.path} could not be parsed reliably '
          '(see PROJECT_FILE_UNREADABLE).');
    }
    final release = context.target;
    final flutterDefault = release.androidDefaults.compileSdk;
    final plugins = [
      for (final package
          in context.dependencies?.packages ?? const <ResolvedPackage>[])
        if (package.android?.compileSdk case final sdk?) (package, sdk),
    ];
    final pluginMaximum = plugins.isEmpty
        ? null
        : plugins.map((p) => p.$2).reduce((a, b) => a > b ? a : b);

    final value = app.compileSdk;
    if (value == null) {
      return const NotApplicable('The app module does not set compileSdk.');
    }
    final int current;
    final EditableValue? editable;
    switch (value) {
      case LiteralInt(value: final literal, editable: final range):
        current = literal;
        editable = range;
      case FlutterDefaultReference(property: 'compileSdkVersion'):
        if (pluginMaximum == null || pluginMaximum <= flutterDefault) {
          return NotApplicable('compileSdk uses $_replacement '
              '($flutterDefault in Flutter ${release.version}).');
        }
        current = flutterDefault;
        editable = null;
      default:
        return NotApplicable('compileSdk is set by "${value.text}", which '
            'Reforge does not evaluate.');
    }

    final required = pluginMaximum != null && pluginMaximum > flutterDefault
        ? pluginMaximum
        : flutterDefault;
    if (current >= required) {
      return NotApplicable('compileSdk $current is at least $_replacement '
          '($flutterDefault) and the plugins\' compileSdk.');
    }
    final replacement = required == flutterDefault ? _replacement : '$required';
    final higherPlugins = [
      for (final (package, sdk) in plugins)
        if (sdk > current) (package, sdk),
    ];

    final evidence = [
      Evidence.file('compileSdk ${value.text}', value.location),
      Evidence.knowledge(
          '$_replacement is $flutterDefault in Flutter ${release.version}',
          release.androidDefaultsSource),
      for (final (package, sdk) in higherPlugins)
        Evidence(EvidenceKind.dependencyFile,
            '${package.name} compiles against Android SDK $sdk',
            location: package.android!.buildFile),
      if (higherPlugins.isNotEmpty)
        Evidence.knowledge(
            "Flutter's Gradle plugin warns when plugins compile against a "
            'higher Android SDK than the app',
            release.pluginCompileSdkCheckSource),
    ];
    final rationale = [
      'The app compiles against Android SDK $current; Flutter '
          '${release.version} projects compile against $_replacement '
          '($flutterDefault).',
      if (higherPlugins.isNotEmpty)
        '${higherPlugins.map((p) => '${p.$1.name} (${p.$2})').join(', ')} '
            'compile against a higher Android SDK, which Flutter\'s Gradle '
            'plugin reports during builds.',
    ].join(' ');

    return Proposal(
      status: editable == null ? StepStatus.manual : StepStatus.review,
      necessity: Necessity.recommended,
      summary: 'Raise compileSdk from $current to $replacement'
          '${replacement == _replacement ? ' ($flutterDefault)' : ''}.',
      rationale: rationale,
      impact: 'Builds print warnings, and fail when an Android library the '
          'app or its plugins use requires a higher compileSdk.',
      evidence: evidence,
      edits: [
        if (editable != null)
          FileEdit(
              editable.path, [TextEdit.replace(editable.range, replacement)]),
      ],
      manualSteps: [
        if (editable == null)
          'Set compileSdk in ${app.script.path} to $required: '
              '$_replacement is lower than what the plugins need.',
      ],
      notes: const [
        'compileSdk only selects the Android APIs available when compiling; '
            'targetSdk and the runtime behavior of the app do not change. '
            'New deprecation warnings can appear in Java and Kotlin sources.',
      ],
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.androidBuild,
      ],
      details: {'from': current, 'to': required},
    );
  }
}
