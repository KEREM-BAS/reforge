import 'package:path/path.dart' as p;

import '../knowledge/flutter_release.dart';
import '../knowledge/knowledge_source.dart';
import '../migration/recipe_ids.dart';

/// A recognized failure in tool output, with an explanation.
final class FailureDiagnosis {
  const FailureDiagnosis({
    required this.id,
    required this.explanation,
    required this.suggestion,
    required this.evidence,
    this.relatedRecipes = const [],
    this.details = const {},
    this.source,
  });

  /// Stable identifier of the signature, e.g. `GRADLE_JDK_TOO_NEW`.
  final String id;
  final String explanation;
  final String suggestion;

  /// The output line that matched.
  final String evidence;

  final List<String> relatedRecipes;

  /// Values read from the output, e.g. `{"plugin": "camera_android"}`.
  final Map<String, String> details;

  /// Where the knowledge that recognizes this failure comes from, when it is
  /// documented elsewhere (for example the Flutter tool's own handler).
  final KnowledgeSource? source;

  Map<String, Object?> toJson() => {
        'id': id,
        'explanation': explanation,
        'suggestion': suggestion,
        'evidence': evidence,
        if (relatedRecipes.isNotEmpty) 'relatedRecipes': relatedRecipes,
        if (details.isNotEmpty) 'details': details,
        if (source != null) 'source': source!.toJson(),
      };
}

final class _Signature {
  const _Signature(this.id, this.pattern, this.describe,
      {this.secondary = false});

  final String id;
  final RegExp pattern;

  /// Explains a matching [line]; `null` when the whole output shows that the
  /// line means something else.
  final FailureDiagnosis? Function(
      RegExpMatch match, String line, _FailureContext context) describe;

  /// Reported only when no other signature matches, because its message also
  /// appears as a consequence of other failures.
  final bool secondary;
}

final class _FailureContext {
  const _FailureContext(this.output, this.target);

  final String output;

  /// The Flutter release the project was migrated to, when known.
  final FlutterRelease? target;
}

/// The Flutter tool recognizes many Gradle failures itself; these signatures
/// follow its handlers in `gradle_errors.dart`.
KnowledgeSource _flutterHandler(String handler) => KnowledgeSource(
      title: 'Flutter tool Gradle error handler $handler (Flutter 3.47.4)',
      url: 'https://github.com/flutter/flutter/blob/3.47.4/packages/'
          'flutter_tools/lib/src/android/gradle_errors.dart',
    );

const _jetifierFailure = 'Jetifier failed to transform';

final _pubCachePlugin = RegExp(
    r'(?:pub\.dev|pub\.dartlang\.org)[/\\]([a-z][a-z0-9_]*)-(\d[^/\\]*)[/\\]android[/\\]');

/// Known failure messages of Flutter, Gradle, the Android Gradle Plugin, pub
/// and CocoaPods.
///
/// Signatures only explain output; they never change files. A failure that
/// matches no signature is reported as unexplained rather than guessed.
final List<_Signature> _signatures = [
  _Signature(
    'ANDROID_SDK_LICENSES_NOT_ACCEPTED',
    RegExp('You have not accepted the license agreements of the following SDK '
        r'components:\s*\[?([^\]]*)'),
    (match, line, context) => FailureDiagnosis(
      id: 'ANDROID_SDK_LICENSES_NOT_ACCEPTED',
      explanation: 'The build needs Android SDK components whose licenses '
          'have not been accepted'
          '${match.group(1)!.trim().isEmpty ? '' : ': ${match.group(1)!.trim()}'}.',
      suggestion: 'Run `flutter doctor --android-licenses`.',
      evidence: line,
      source: _flutterHandler('licenseNotAcceptedHandler'),
    ),
  ),
  _Signature(
    'GRADLE_JDK_TOO_NEW',
    RegExp(r'Unsupported class file major version\s+(\d+)'),
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
        details: {'java': '$java'},
        source: _flutterHandler('incompatibleJavaAndGradleVersionsHandler'),
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
        source: _flutterHandler('javaHeapSpaceHandler'),
      );
    },
  ),
  _Signature(
    'R8_BUG_AGP_7_3',
    RegExp(r'com\.android\.tools\.r8\.internal.*: Unused argument with users'),
    (match, line, context) => FailureDiagnosis(
      id: 'R8_BUG_AGP_7_3',
      explanation: 'Android Gradle Plugin 7.3 ships a version of R8 with a bug '
          'that fails dexing (issuetracker.google.com/issues/242308990).',
      suggestion: 'Upgrade the Android Gradle Plugin to 7.4.0 or newer.',
      evidence: line,
      relatedRecipes: const [RecipeIds.androidAgpVersion],
      details: const {'minimumAgp': '7.4.0'},
      source: _flutterHandler('r8DexingBugInAgp73Handler'),
    ),
  ),
  _Signature(
    'PLUGIN_MIN_SDK_HIGHER',
    RegExp(r'uses-sdk:minSdkVersion (\d+) cannot be smaller than version '
        r'(\d+) declared in library \[:?([^\]]+)\]'),
    (match, line, context) {
      final library = match.group(3)!;
      return FailureDiagnosis(
        id: 'PLUGIN_MIN_SDK_HIGHER',
        explanation: '$library requires Android API level ${match.group(2)}, '
            'but the app declares minSdk ${match.group(1)}.',
        suggestion: 'Raise minSdk to ${match.group(2)} in the app module '
            '(devices below API level ${match.group(2)} can then no longer '
            'install the app), or use a version of $library that supports '
            'API level ${match.group(1)}.',
        evidence: line,
        details: {
          'library': library,
          'declared': match.group(1)!,
          'required': match.group(2)!,
        },
        source: _flutterHandler('minSdkVersionHandler'),
      );
    },
  ),
  _Signature(
    'COMPILE_SDK_BELOW_DEPENDENCY_MINIMUM',
    RegExp(r'The minCompileSdk \((\d+)\) specified in a'),
    (match, line, context) => FailureDiagnosis(
      id: 'COMPILE_SDK_BELOW_DEPENDENCY_MINIMUM',
      explanation: 'A dependency requires compileSdk ${match.group(1)} or '
          'higher.',
      suggestion: 'Raise compileSdk to ${match.group(1)}. Projects using '
          'flutter.compileSdkVersion get newer values from newer Flutter '
          'releases.',
      evidence: line,
      details: {'required': match.group(1)!},
      source: _flutterHandler('minCompileSdkVersionHandler'),
    ),
  ),
  _Signature(
    'AGP_JDK_TOO_OLD',
    RegExp(r'Android Gradle plugin requires Java (\d+)(?:\.\d+)? to run\. '
        r'You are currently using Java (\d+)'),
    (match, line, context) => FailureDiagnosis(
      id: 'AGP_JDK_TOO_OLD',
      explanation: 'The Android Gradle Plugin requires Java ${match.group(1)}, '
          'but the build ran with Java ${match.group(2)}.',
      suggestion: 'Install JDK ${match.group(1)} and select it with '
          '`flutter config --jdk-dir=<path>`.',
      evidence: line,
      details: {'required': match.group(1)!, 'used': match.group(2)!},
      source: _flutterHandler('incompatibleJavaAndAgpVersionsHandler'),
    ),
  ),
  _Signature(
    'GRADLE_TOO_OLD_FOR_KOTLIN_PLUGIN',
    RegExp(r'The current Gradle version (\S+) is not compatible with the '
        'Kotlin Gradle plugin'),
    (match, line, context) => FailureDiagnosis(
      id: 'GRADLE_TOO_OLD_FOR_KOTLIN_PLUGIN',
      explanation: 'Gradle ${match.group(1)} is too old for the Kotlin Gradle '
          'plugin the project uses.',
      suggestion: 'Upgrade the Gradle wrapper (and the Android Gradle Plugin '
          'it requires).',
      evidence: line,
      relatedRecipes: const [
        RecipeIds.androidGradleWrapper,
        RecipeIds.androidAgpVersion,
      ],
      source: _flutterHandler('outdatedGradleHandler'),
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
        // "minimum Android SDK" or "minimum Android SDK (flavor='dev')".
        _ when name.startsWith('minimum Android SDK') =>
          RecipeIds.androidMinSdk,
        _ => null,
      };
      return FailureDiagnosis(
        id: 'FLUTTER_DEPENDENCY_BELOW_MINIMUM',
        explanation: "Flutter's dependency check rejected $name "
            '${match.group(2)}; the minimum is ${match.group(3)}.',
        suggestion: 'Upgrade $name to ${match.group(3)} or newer.',
        evidence: line,
        relatedRecipes: [if (recipe != null) recipe],
        details: {
          'dependency': name,
          'version': match.group(2)!,
          'minimum': match.group(3)!,
        },
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
      details: {'minimum': match.group(1)!, 'current': match.group(2)!},
    ),
  ),
  _Signature(
    'COMPILE_SDK_REQUIRES_NEWER_AGP',
    RegExp('RES_TABLE_TYPE_TYPE entry offsets overlap actual entry data'),
    (match, line, context) => FailureDiagnosis(
      id: 'COMPILE_SDK_REQUIRES_NEWER_AGP',
      explanation: 'Resource processing failed because the Android Gradle '
          'Plugin is too old for the compile SDK (the Flutter tool reports '
          'this for compileSdk 35 with Android Gradle Plugin below 8.1.0).',
      suggestion: 'Upgrade the Android Gradle Plugin.',
      evidence: line,
      relatedRecipes: const [RecipeIds.androidAgpVersion],
      source: _flutterHandler('incompatibleCompileSdk35AndAgpVersionHandler'),
    ),
  ),
  _Signature(
    'AGP_JLINK_JAVA21',
    RegExp(r'> Error while executing process .*jlink'),
    (match, line, context) => FailureDiagnosis(
      id: 'AGP_JLINK_JAVA21',
      explanation: 'Android Gradle Plugin versions below 8.2.1 fail running '
          'jlink with Java 21 or newer when a module sets sourceCompatibility '
          '(issuetracker.google.com/issues/294137077).',
      suggestion: 'Upgrade the Android Gradle Plugin to 8.2.1 or newer.',
      evidence: line,
      relatedRecipes: const [RecipeIds.androidAgpVersion],
      details: const {'minimumAgp': '8.2.1'},
      source: _flutterHandler('jlinkErrorWithJava21AndSourceCompatibility'),
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
    'PLUGIN_V1_EMBEDDING',
    RegExp(r'PluginRegistry\.Registrar registrar|symbol:\s+class Registrar'),
    (match, line, context) {
      final plugins = {
        for (final errorLine in context.output.split('\n'))
          if (errorLine.contains('error:'))
            if (_pubCachePlugin.firstMatch(errorLine) case final plugin?)
              plugin.group(1)!: plugin.group(2)!,
      };
      return FailureDiagnosis(
        id: 'PLUGIN_V1_EMBEDDING',
        explanation:
            '${plugins.isEmpty ? 'A plugin' : plugins.keys.join(', ')} '
            'still uses PluginRegistry.Registrar from the Android v1 '
            'embedding, which Flutter 3.29 removed.',
        suggestion: 'Upgrade '
            '${plugins.isEmpty ? 'the plugins that fail to compile' : plugins.keys.join(', ')} '
            '(`flutter pub outdated` lists newer versions).',
        evidence: line,
        details: {
          if (plugins.isNotEmpty) 'plugins': plugins.keys.join(','),
        },
        source: _flutterHandler('usageOfV1EmbeddingReferencesHandler'),
      );
    },
  ),
  _Signature(
    'KOTLIN_ANDROID_PLUGIN_WITH_BUILT_IN_KOTLIN',
    RegExp(r"The 'org\.jetbrains\.kotlin\.android' plugin is no longer "
        'required for Kotlin support since AGP 9.0'),
    (match, line, context) => FailureDiagnosis(
      id: 'KOTLIN_ANDROID_PLUGIN_WITH_BUILT_IN_KOTLIN',
      explanation: 'Android Gradle Plugin 9 enables built-in Kotlin, and a '
          'module still applies the Kotlin Android plugin.',
      suggestion:
          'Set android.builtInKotlin=false in android/gradle.properties '
          'as Flutter does for existing projects, or migrate to built-in Kotlin '
          '(https://docs.flutter.dev/release/breaking-changes/migrate-to-built-in-kotlin).',
      evidence: line,
      relatedRecipes: const [RecipeIds.androidAgp9OptOuts],
      source: _flutterHandler('applyingKotlinAndroidPluginErrorHandler'),
    ),
  ),
  _Signature(
    'AGP9_NEW_DSL',
    RegExp(r"> Failed to apply plugin 'dev\.flutter\.flutter-gradle-plugin'"),
    (match, line, context) {
      if (!context.output
          .contains('> java.lang.NullPointerException (no error message)')) {
        return null;
      }
      return FailureDiagnosis(
        id: 'AGP9_NEW_DSL',
        explanation: "Flutter's Gradle plugin failed to apply: with Android "
            'Gradle Plugin 9 only the new DSL is read, which this Flutter '
            'Gradle plugin does not support.',
        suggestion: 'Set android.newDsl=false in android/gradle.properties, as '
            'Flutter does for existing projects, or upgrade Flutter.',
        evidence: line,
        relatedRecipes: const [RecipeIds.androidAgp9OptOuts],
        source: _flutterHandler('useNewAgpDslErrorHandler'),
      );
    },
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
    RegExp(r'The current Dart SDK version is (\d+\.\d+\.\d+(?:-[\w.]*\w)?)'),
    (match, line, context) {
      final requirement = RegExp(
              r'\b([a-z][a-z0-9_]*) (?:[<>=^]*\d\S*\s+)*(?:which\s+)?requires SDK version ([^,]+),')
          .firstMatch(context.output);
      final package = requirement?.group(1);
      return FailureDiagnosis(
        id: 'DART_SDK_CONSTRAINT',
        explanation: package == null
            ? 'A package does not allow Dart ${match.group(1)}.'
            : '$package requires Dart ${requirement!.group(2)!.trim()}, which '
                'excludes Dart ${match.group(1)}.',
        suggestion: package == null
            ? 'Upgrade the package, or fix environment.sdk if it is this '
                'project.'
            : 'Upgrade $package (or the packages that depend on it), or fix '
                'environment.sdk if $package is this project.',
        evidence: line,
        relatedRecipes: const [RecipeIds.dartSdkConstraint],
        details: {
          'dart': match.group(1)!,
          if (package != null) 'package': package,
        },
      );
    },
  ),
  _Signature(
    'COCOAPODS_DEPLOYMENT_TARGET',
    RegExp(r'required a higher minimum deployment target'),
    (match, line, context) {
      final pod = RegExp(r'Specs satisfying the `([^\s`]+)').firstMatch(line) ??
          RegExp(r'compatible versions for pod "([^"]+)"')
              .firstMatch(context.output);
      return FailureDiagnosis(
        id: 'COCOAPODS_DEPLOYMENT_TARGET',
        explanation: '${pod == null ? 'A pod' : 'Pod ${pod.group(1)}'} '
            'requires a newer iOS deployment target than the platform '
            'CocoaPods resolves for.',
        suggestion: 'Raise the iOS deployment target and the Podfile '
            'platform, or use a version of the pod that supports the '
            "app's deployment target.",
        evidence: line,
        relatedRecipes: const [RecipeIds.iosDeploymentTarget],
        details: {if (pod != null) 'pod': pod.group(1)!},
      );
    },
  ),
  _Signature(
    'COCOAPODS_INCOMPATIBLE',
    RegExp(r'CocoaPods could not find compatible versions for pod "([^"]+)"'),
    (match, line, context) => context.output
            .contains('required a higher minimum deployment target')
        // COCOAPODS_DEPLOYMENT_TARGET explains this failure more precisely.
        ? null
        : FailureDiagnosis(
            id: 'COCOAPODS_INCOMPATIBLE',
            explanation: 'CocoaPods could not resolve pod ${match.group(1)}.',
            suggestion:
                'Run `pod repo update` and check the pod deployment target '
                'and version constraints.',
            evidence: line,
            details: {'pod': match.group(1)!},
          ),
  ),
  _Signature(
    'GRADLE_NETWORK_ERROR',
    RegExp(r"> Could not get resource 'http|"
        r'java\.net\.ConnectException: Connection timed out|'
        r'java\.net\.SocketException: Connection reset|'
        r'java\.io\.IOException: Unable to tunnel through proxy|'
        r'java\.io\.IOException: Server returned HTTP response code: 502'),
    (match, line, context) => FailureDiagnosis(
      id: 'GRADLE_NETWORK_ERROR',
      explanation: 'Gradle could not download artifacts from the network.',
      suggestion: 'Check the network and proxy settings, then retry the build.',
      evidence: line,
      source: _flutterHandler('networkErrorHandler'),
    ),
  ),
  _Signature(
    'KOTLIN_METADATA_INCOMPATIBLE',
    RegExp('was compiled with an incompatible version of Kotlin'),
    (match, line, context) => FailureDiagnosis(
      id: 'KOTLIN_METADATA_INCOMPATIBLE',
      explanation: 'A dependency was compiled with a newer Kotlin version than '
          "the project's Kotlin Gradle plugin can read.",
      suggestion: 'Upgrade the Kotlin Gradle plugin.',
      evidence: line,
      relatedRecipes: const [RecipeIds.androidKotlinVersion],
      source: _flutterHandler('incompatibleKotlinVersionHandler'),
    ),
    secondary: true,
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
  final primary = <FailureDiagnosis>[];
  final secondary = <FailureDiagnosis>[];
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
        (signature.secondary ? secondary : primary).add(diagnosis);
      }
    }
  }
  if (dartErrors.isNotEmpty) {
    final first = dartErrors.first;
    final removedApi = dartErrors.any((m) =>
        m.group(4)!.contains("isn't defined") ||
        m.group(4)!.contains('Method not found') ||
        m.group(4)!.contains('No named parameter'));
    primary.add(FailureDiagnosis(
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
      details: {'file': first.group(1)!, 'line': first.group(2)!},
    ));
  }
  return primary.isEmpty ? secondary : primary;
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
