import '../model/finding.dart';
import 'failure_signatures.dart';

/// A failure recognized in tool output, together with the inspection
/// findings that locate its cause in the project or its dependencies.
final class Diagnosis {
  const Diagnosis(this.failure, this.confirmedBy);

  final FailureDiagnosis failure;

  /// Findings that independently identify the cause. Empty when inspection
  /// found nothing to confirm the explanation.
  final List<Finding> confirmedBy;

  Map<String, Object?> toJson() => {
        ...failure.toJson(),
        'confirmedBy': [for (final finding in confirmedBy) finding.toJson()],
      };
}

/// Finding codes that describe the cause of each failure, when it is not a
/// dependency-specific failure.
const _findingCodes = <String, List<String>>{
  'GRADLE_JDK_TOO_NEW': ['ENV_JAVA_CANNOT_RUN_GRADLE'],
  'AGP_JDK_TOO_OLD': ['ENV_JAVA_TOO_OLD_FOR_AGP'],
  'GRADLE_TOO_OLD_FOR_AGP': ['ANDROID_GRADLE_TOO_OLD_FOR_AGP'],
  'IMPERATIVE_GRADLE_APPLY': ['ANDROID_IMPERATIVE_GRADLE_APPLY'],
  'COMPILE_SDK_REQUIRES_NEWER_AGP': ['ANDROID_COMPILE_SDK_REQUIRES_NEWER_AGP'],
};

/// Links [failures] recognized in the output of a build to [findings] from
/// inspecting the same workspace.
///
/// [failingModule] is the Gradle module of the first failing task (for
/// example `:camera_android`); plugin modules are named after their package.
List<Diagnosis> correlateFailures(
  List<FailureDiagnosis> failures,
  List<Finding> findings, {
  String? failingModule,
}) {
  Iterable<Finding> withCode(String code, {Set<String>? subjects}) =>
      findings.where((f) =>
          f.code == code && (subjects == null || subjects.contains(f.subject)));

  final module = failingModule?.replaceFirst(RegExp('^:'), '');
  return [
    for (final failure in failures)
      Diagnosis(failure, [
        ...switch (failure.id) {
          'ANDROID_NAMESPACE_MISSING' ||
          'ANDROID_MANIFEST_PACKAGE' =>
            module == null || module == 'app'
                ? [
                    ...withCode('ANDROID_NAMESPACE_MISSING'),
                    if (module == null)
                      ...withCode('PLUGIN_ANDROID_NAMESPACE_MISSING'),
                  ]
                : withCode('PLUGIN_ANDROID_NAMESPACE_MISSING',
                    subjects: {module}),
          'PLUGIN_V1_EMBEDDING' => withCode('PLUGIN_ANDROID_V1_EMBEDDING',
              subjects: failure.details['plugins']?.split(',').toSet()),
          'COCOAPODS_DEPLOYMENT_TARGET' => [
              ...withCode(
                  failure.details['platform'] == 'macos'
                      ? 'PLUGIN_MACOS_DEPLOYMENT_TARGET_ABOVE_APP'
                      : 'PLUGIN_IOS_DEPLOYMENT_TARGET_ABOVE_APP',
                  subjects: failure.details['pod'] == null
                      ? null
                      : {failure.details['pod']!}),
              ...withCode(failure.details['platform'] == 'macos'
                  ? 'MACOS_DEPLOYMENT_TARGET_BELOW_FLUTTER_MINIMUM'
                  : 'IOS_DEPLOYMENT_TARGET_BELOW_FLUTTER_MINIMUM'),
            ],
          'DART_SDK_CONSTRAINT' => withCode('DEPENDENCY_DART_SDK_INCOMPATIBLE',
              subjects: failure.details['package'] == null
                  ? null
                  : {failure.details['package']!}),
          'FLUTTER_DEPENDENCY_BELOW_MINIMUM' => switch (
                failure.details['dependency']) {
              'Gradle' => withCode('ANDROID_GRADLE_BELOW_FLUTTER_MINIMUM'),
              'Android Gradle Plugin' =>
                withCode('ANDROID_AGP_BELOW_FLUTTER_MINIMUM'),
              'Kotlin' => withCode('ANDROID_KOTLIN_BELOW_FLUTTER_MINIMUM'),
              final String name when name.startsWith('minimum Android SDK') =>
                withCode('ANDROID_MIN_SDK_BELOW_FLUTTER_MINIMUM'),
              _ => const <Finding>[],
            },
          final id => [
              for (final code in _findingCodes[id] ?? const <String>[])
                ...withCode(code),
            ],
        },
      ]),
  ];
}
