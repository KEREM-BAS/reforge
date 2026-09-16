import 'package:path/path.dart' as p;

import '../knowledge/flutter_release.dart';
import '../migration/recipe_ids.dart';

/// A recognized failure in tool output, with an explanation.
final class FailureDiagnosis {
  const FailureDiagnosis({
    required this.id,
    required this.explanation,
    required this.suggestion,
    required this.evidence,
    this.relatedRecipes = const [],
  });

  /// Stable identifier of the signature, e.g. `GRADLE_JDK_INCOMPATIBLE`.
  final String id;
  final String explanation;
  final String suggestion;

  /// The output line that matched.
  final String evidence;

  final List<String> relatedRecipes;

  Map<String, Object?> toJson() => {
        'id': id,
        'explanation': explanation,
        'suggestion': suggestion,
        'evidence': evidence,
        if (relatedRecipes.isNotEmpty) 'relatedRecipes': relatedRecipes,
      };
}

final class _Signature {
  const _Signature(this.id, this.pattern, this.describe);

  final String id;
  final RegExp pattern;

  /// Explains a matching [line]; `null` when the whole [output] shows that
  /// the line means something else.
  final FailureDiagnosis? Function(
      RegExpMatch match, String line, _FailureContext context) describe;
}

final class _FailureContext {
  const _FailureContext(this.output, this.target);

  final String output;

  /// The Flutter release the project was migrated to, when known.
  final FlutterRelease? target;
}

const _jetifierFailure = 'Jetifier failed to transform';

/// Known failure messages of Flutter, Gradle, the Android Gradle Plugin, pub
/// and CocoaPods.
///
/// Signatures only explain output; they never change files. A failure that
/// matches no signature is reported as unexplained rather than guessed.
final List<_Signature> _signatures = [
  _Signature(
    'GRADLE_JDK_TOO_NEW',
    RegExp(r'Unsupported class file major version (\d+)'),
    (match, line, context) {
      // Jetifier reports class files it cannot read with the same message.
      if (context.output.contains(_jetifierFailure)) return null;
      final java = int.parse(match.group(1)!) - 44;
      return FailureDiagnosis(
        id: 'GRADLE_JDK_TOO_NEW',
        explanation: 'Gradle cannot read classes compiled for Java $java: the '
            'JDK used for the build is newer than the Gradle version supports.',
        suggestion: 'Upgrade the Gradle wrapper, or select an older JDK with '
            '`flutter config --jdk-dir=<path>`.',
        evidence: line,
        relatedRecipes: const [RecipeIds.androidGradleWrapper],
      );
    },
  ),
  _Signature(
    'JETIFIER_TRANSFORM_FAILED',
    RegExp('$_jetifierFailure: (.+)'),
    (match, line, context) {
      final classFile = RegExp(r'Unsupported class file major version (\d+)')
          .firstMatch(context.output);
      final file =
          p.posix.basename(match.group(1)!.trim().replaceAll(r'\', '/'));
      return FailureDiagnosis(
        id: 'JETIFIER_TRANSFORM_FAILED',
        explanation: classFile == null
            ? 'Jetifier could not rewrite $file.'
            : 'Jetifier could not rewrite $file: it cannot read classes '
                'compiled for Java ${int.parse(classFile.group(1)!) - 44}.',
        suggestion: 'Jetifier (android.enableJetifier=true) is only needed '
            'for dependencies that use the Android Support Library. Stop '
            'using Jetifier if no dependency needs it; Flutter templates no '
            'longer enable it.',
        evidence: line,
        relatedRecipes: const [RecipeIds.androidJetifier],
      );
    },
  ),
  _Signature(
    'GRADLE_OUT_OF_MEMORY',
    // Not a bare "OutOfMemoryError": JVM options such as
    // -XX:+HeapDumpOnOutOfMemoryError are echoed in build output.
    RegExp(r'java\.lang\.OutOfMemoryError|Java heap space|'
        r'GC overhead limit exceeded|^\s*>\s*Metaspace\s*$'),
    (match, line, context) {
      final jetifier = context.output.contains('JetifyTransform');
      final template =
          context.target?.template.gradleProperties['org.gradle.jvmargs'];
      return FailureDiagnosis(
        id: 'GRADLE_OUT_OF_MEMORY',
        explanation: 'The Gradle build ran out of memory'
            '${jetifier ? ' while Jetifier rewrote a dependency' : ''}.',
        suggestion: [
          'Raise the memory limits in org.gradle.jvmargs '
              '(android/gradle.properties)'
              '${template == null ? '.' : '; Flutter ${context.target!.version} generates "$template".'}',
          if (jetifier)
            'Jetifier needs a lot of memory; if no dependency uses the Android '
                'Support Library, stop using it.',
        ].join(' '),
        evidence: line,
        relatedRecipes: [
          RecipeIds.androidGradleJvmArgs,
          if (jetifier) RecipeIds.androidJetifier,
        ],
      );
    },
  ),
  _Signature(
    'AGP_JDK_TOO_OLD',
    RegExp(
        r'Android Gradle plugin requires Java (\d+) to run\. You are currently using Java (\d+)'),
    (match, line, context) => FailureDiagnosis(
      id: 'AGP_JDK_TOO_OLD',
      explanation: 'The Android Gradle Plugin requires Java ${match.group(1)}, '
          'but the build ran with Java ${match.group(2)}.',
      suggestion: 'Install JDK ${match.group(1)} and select it with '
          '`flutter config --jdk-dir=<path>`.',
      evidence: line,
    ),
  ),
  _Signature(
    'FLUTTER_DEPENDENCY_BELOW_MINIMUM',
    RegExp(
        r"Your project's (.+?) version \(([^)]+)\) is lower than Flutter's minimum supported version of ([\w.]+)"),
    (match, line, context) {
      final name = match.group(1)!;
      final recipe = switch (name) {
        'Gradle' => RecipeIds.androidGradleWrapper,
        'Android Gradle Plugin' => RecipeIds.androidAgpVersion,
        'Kotlin' => RecipeIds.androidKotlinVersion,
        _ => null,
      };
      return FailureDiagnosis(
        id: 'FLUTTER_DEPENDENCY_BELOW_MINIMUM',
        explanation: "Flutter's dependency check rejected $name "
            '${match.group(2)}; the minimum is ${match.group(3)}.',
        suggestion: 'Upgrade $name to ${match.group(3)} or newer.',
        evidence: line,
        relatedRecipes: [if (recipe != null) recipe],
      );
    },
  ),
  _Signature(
    'GRADLE_TOO_OLD_FOR_AGP',
    RegExp(
        r'Minimum supported Gradle version is ([\w.]+)\. Current version is ([\w.]+)'),
    (match, line, context) => FailureDiagnosis(
      id: 'GRADLE_TOO_OLD_FOR_AGP',
      explanation: 'The Android Gradle Plugin needs Gradle ${match.group(1)}, '
          'but the wrapper provides ${match.group(2)}.',
      suggestion: 'Upgrade the Gradle wrapper to ${match.group(1)} or newer.',
      evidence: line,
      relatedRecipes: const [RecipeIds.androidGradleWrapper],
    ),
  ),
  _Signature(
    'IMPERATIVE_GRADLE_APPLY',
    RegExp(
        r"You are applying Flutter's (main|app_plugin_loader) Gradle plugin\s+imperatively"),
    (match, line, context) => FailureDiagnosis(
      id: 'IMPERATIVE_GRADLE_APPLY',
      explanation: "Flutter's Gradle plugins are applied with the removed "
          'imperative `apply from:` mechanism.',
      suggestion: 'Migrate to plugins {} blocks.',
      evidence: line,
      relatedRecipes: const [RecipeIds.androidFlutterGradlePluginDsl],
    ),
  ),
  _Signature(
    'ANDROID_NAMESPACE_MISSING',
    RegExp(r'Namespace not specified'),
    (match, line, context) => FailureDiagnosis(
      id: 'ANDROID_NAMESPACE_MISSING',
      explanation: 'A module does not declare android.namespace, which Android '
          'Gradle Plugin 8 requires.',
      suggestion: 'Declare the namespace. If the module is a plugin, upgrade '
          'the plugin.',
      evidence: line,
      relatedRecipes: const [RecipeIds.androidNamespace],
    ),
  ),
  _Signature(
    'ANDROID_MANIFEST_PACKAGE',
    RegExp(r'Incorrect package="([^"]+)" found in source AndroidManifest\.xml'),
    (match, line, context) => FailureDiagnosis(
      id: 'ANDROID_MANIFEST_PACKAGE',
      explanation:
          'An AndroidManifest.xml still declares package="${match.group(1)}".',
      suggestion: 'Remove the package attribute and declare android.namespace. '
          'If the manifest belongs to a plugin, upgrade the plugin.',
      evidence: line,
      relatedRecipes: const [RecipeIds.androidNamespace],
    ),
  ),
  _Signature(
    'JVM_TARGET_MISMATCH',
    RegExp(
        r"Inconsistent JVM-target compatibility detected for tasks '([^']+)' \(([^)]+)\) and '([^']+)' \(([^)]+)\)"),
    (match, line, context) => FailureDiagnosis(
      id: 'JVM_TARGET_MISMATCH',
      explanation: 'Java and Kotlin compile to different JVM targets '
          '(${match.group(2)} and ${match.group(4)}) in a module.',
      suggestion: 'If the failing task belongs to a plugin, upgrade the '
          'plugin; otherwise align compileOptions and the Kotlin jvmTarget.',
      evidence: line,
    ),
  ),
  _Signature(
    'DART_SDK_CONSTRAINT',
    RegExp(r'The current Dart SDK version is ([\w.\-]+)'),
    (match, line, context) => FailureDiagnosis(
      id: 'DART_SDK_CONSTRAINT',
      explanation: 'A package does not allow Dart ${match.group(1)}.',
      suggestion: 'Upgrade the package, or fix environment.sdk if it is this '
          'project.',
      evidence: line,
      relatedRecipes: const [RecipeIds.dartSdkConstraint],
    ),
  ),
  _Signature(
    'COCOAPODS_DEPLOYMENT_TARGET',
    RegExp(r'required a higher minimum deployment target'),
    (match, line, context) => FailureDiagnosis(
      id: 'COCOAPODS_DEPLOYMENT_TARGET',
      explanation: 'A pod requires a newer iOS deployment target than the '
          'Podfile platform.',
      suggestion: 'Raise the iOS deployment target and the Podfile platform.',
      evidence: line,
      relatedRecipes: const [RecipeIds.iosDeploymentTarget],
    ),
  ),
  _Signature(
    'COCOAPODS_INCOMPATIBLE',
    RegExp(r'CocoaPods could not find compatible versions for pod "([^"]+)"'),
    (match, line, context) => FailureDiagnosis(
      id: 'COCOAPODS_INCOMPATIBLE',
      explanation: 'CocoaPods could not resolve pod ${match.group(1)}.',
      suggestion: 'Run `pod repo update` and check the pod deployment target '
          'and version constraints.',
      evidence: line,
    ),
  ),
];

final _failedTask = RegExp(r"Execution failed for task '(:[^']+)'");

final _dartError = RegExp(r'^(\S+\.dart):(\d+):(\d+): Error: (.+)$');

/// Explains known failures in [output], in the order they appear.
///
/// [target] is the Flutter release the project was migrated to; when given,
/// suggestions refer to its values.
List<FailureDiagnosis> diagnoseFailure(String output,
    {FlutterRelease? target}) {
  final context = _FailureContext(output, target);
  final results = <FailureDiagnosis>[];
  final seen = <String>{};
  final dartErrors = <RegExpMatch>[];
  for (final line in output.split('\n')) {
    final dartError = _dartError.firstMatch(line.trim());
    if (dartError != null) dartErrors.add(dartError);
    for (final signature in _signatures) {
      final match = signature.pattern.firstMatch(line);
      if (match == null) continue;
      final diagnosis = signature.describe(match, line.trim(), context);
      // The same failure is often repeated in several lines of Gradle output.
      if (diagnosis != null &&
          seen.add('${diagnosis.id}:${diagnosis.explanation}')) {
        results.add(diagnosis);
      }
    }
  }
  if (dartErrors.isNotEmpty) {
    final first = dartErrors.first;
    final removedApi = dartErrors.any((m) =>
        m.group(4)!.contains("isn't defined") ||
        m.group(4)!.contains('Method not found') ||
        m.group(4)!.contains('No named parameter'));
    results.add(FailureDiagnosis(
      id: 'DART_COMPILATION_ERROR',
      explanation: 'The Dart code does not compile with this Flutter SDK '
          '(${dartErrors.length} error(s)); the first is in '
          '${first.group(1)}:${first.group(2)}: ${first.group(4)}',
      suggestion: removedApi
          ? 'The code uses APIs that are not available in this Flutter '
              'release. Run `dart fix --apply` (Flutter ships automated fixes '
              'for many removed APIs), then fix the remaining errors.'
          : 'Fix the compilation errors reported by `flutter analyze`.',
      evidence: first.group(0)!,
    ));
  }
  return results;
}

/// The Gradle project path of the first failing task, e.g. `:app` or
/// `:camera_android`, which identifies the module (often a plugin) that
/// failed.
String? failingGradleModule(String output) {
  final match = _failedTask.firstMatch(output);
  if (match == null) return null;
  final task = match.group(1)!;
  final lastColon = task.lastIndexOf(':');
  return lastColon <= 0 ? ':' : task.substring(0, lastColon);
}
