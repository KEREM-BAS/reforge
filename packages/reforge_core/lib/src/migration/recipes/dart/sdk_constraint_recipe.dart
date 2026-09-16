import 'package:pub_semver/pub_semver.dart';

import '../../../common/source.dart';
import '../../../knowledge/flutter_release.dart';
import '../../../model/finding.dart';
import '../../../parsing/pub/sdk_constraint.dart';
import '../../../text/text_edit.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';

export '../../../parsing/pub/sdk_constraint.dart'
    show effectiveDartSdkConstraint;

/// Makes `environment.sdk` in pubspec.yaml accept the Dart version of the
/// target Flutter release without changing the language version.
final class DartSdkConstraintRecipe extends MigrationRecipe {
  const DartSdkConstraintRecipe();

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.dartSdkConstraint,
        title: 'Allow the target Dart SDK',
        summary: 'Raises the upper bound of environment.sdk so pub accepts '
            'the Dart version bundled with the target Flutter release, keeping '
            'the lower bound (and therefore the language version) unchanged.',
        category: RecipeCategory.dart,
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final pubspec = context.project.pubspec;
    final dart = context.target.dartVersion;
    final scalar = pubspec.sdkConstraint;
    final location = scalar?.location;
    if (scalar == null || location == null || location.range == null) {
      return Proposal(
        status: StepStatus.manual,
        necessity: Necessity.required,
        summary: 'Declare environment.sdk in ${pubspec.path}.',
        rationale: 'Dart 3 requires every package to declare an SDK '
            'constraint.',
        evidence: [
          Evidence.file(
              'No environment.sdk', location ?? SourceRef(pubspec.path)),
        ],
        manualSteps: [
          'Add environment: sdk: with the lowest Dart version the code '
              'supports, for example ">=${dart.major}.0.0 <${dart.major + 1}.0.0".',
        ],
      );
    }
    final VersionConstraint parsed;
    try {
      parsed = VersionConstraint.parse(scalar.value);
    } on FormatException {
      return Proposal(
        status: StepStatus.manual,
        necessity: Necessity.required,
        summary: 'Fix environment.sdk in ${pubspec.path}.',
        rationale: '"${scalar.value}" is not a valid version constraint.',
        evidence: [Evidence.file('environment.sdk: ${scalar.value}', location)],
        manualSteps: const ['Write a valid SDK constraint.'],
      );
    }
    final effective = effectiveDartSdkConstraint(parsed, dart);
    if (effective.allows(dart)) {
      return NotApplicable('environment.sdk "${scalar.value}" allows Dart $dart'
          '${identical(effective, parsed) ? '' : ' (pub reads the <3.0.0 upper bound as <4.0.0)'}.');
    }
    final evidence = [
      Evidence.file('environment.sdk: ${scalar.value}', location),
      Evidence.knowledge('Flutter ${context.target.version} bundles Dart $dart',
          FlutterRelease.releaseManifestSource),
    ];
    if (parsed is! VersionRange) {
      return Proposal(
        status: StepStatus.manual,
        necessity: Necessity.required,
        summary: 'Allow Dart $dart in environment.sdk.',
        rationale: '"${scalar.value}" does not allow Dart $dart.',
        evidence: evidence,
        manualSteps: const [
          'Rewrite environment.sdk as a single version range.'
        ],
      );
    }
    final min = parsed.min;
    if (min == null || min < Version(2, 12, 0)) {
      return Proposal(
        status: StepStatus.manual,
        necessity: Necessity.required,
        summary: 'Migrate ${pubspec.name} to sound null safety.',
        rationale:
            'The lower bound ${min ?? 'none'} predates null safety. Dart 3 '
            'only runs null-safe code, and Flutter ${context.target.version} '
            'uses Dart $dart.',
        impact: '`flutter pub get` fails and the code does not compile.',
        evidence: evidence,
        manualSteps: const [
          'Migrate the package and its dependencies to null safety with Dart '
              '2.19 (the last SDK with `dart migrate`), then raise the SDK '
              'constraint.',
        ],
      );
    }
    if (min > dart) {
      return Proposal(
        status: StepStatus.blocked,
        necessity: Necessity.required,
        summary: 'The project requires Dart $min or newer.',
        rationale:
            'Flutter ${context.target.version} bundles Dart $dart, which '
            'is older than the lower bound of environment.sdk.',
        evidence: evidence,
        manualSteps: const [
          'Choose a newer Flutter release, or lower the SDK constraint if the '
              'code does not use newer language features.',
        ],
      );
    }

    final upper = Version(dart.major + 1, 0, 0);
    final replacement = '${parsed.includeMin ? '>=' : '>'}$min <$upper';
    final raw = location.range!;
    final original = scalar.value;
    // Keep the original quoting style.
    final quoted =
        _quoteLike(context.files.readString(pubspec.path)!, raw, replacement);
    return Proposal(
      status: StepStatus.auto,
      necessity: Necessity.required,
      summary: 'Change environment.sdk from "$original" to "$replacement".',
      rationale: '"$original" does not allow Dart $dart, the Dart version of '
          'Flutter ${context.target.version}. The lower bound is kept, so the '
          'language version of the package does not change.',
      impact: '`flutter pub get` fails with "The current Dart SDK version is '
          '$dart" until the constraint allows it.',
      evidence: evidence,
      edits: [
        FileEdit(pubspec.path, [TextEdit.replace(raw, quoted)]),
      ],
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.pubGet,
      ],
      details: {'from': original, 'to': replacement},
    );
  }

  static String _quoteLike(String source, TextRange range, String value) {
    final text = range.textOf(source);
    if (text.startsWith('"')) return '"$value"';
    return "'$value'";
  }
}
