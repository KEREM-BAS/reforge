import 'package:meta/meta.dart';

import '../knowledge/flutter_release.dart';
import '../knowledge/knowledge_base.dart';
import '../knowledge/knowledge_source.dart';
import '../model/android_project.dart';
import '../model/declarations.dart';
import '../model/finding.dart';
import '../version/tool_version.dart';
import 'recipe.dart';
import 'recipe_ids.dart';

/// The version a toolchain component should move to, and why.
@immutable
final class ToolchainTarget {
  const ToolchainTarget({
    required this.current,
    required this.minimum,
    required this.target,
    required this.necessity,
    required this.reasons,
  });

  final ToolVersion current;

  /// The lowest acceptable version.
  final ToolVersion minimum;

  /// The published release Reforge proposes: the earliest one at or above
  /// [minimum]. `null` when no known release satisfies [minimum].
  final ToolVersion? target;

  final Necessity necessity;

  /// The facts that determine [minimum].
  final List<Evidence> reasons;
}

/// Computes the Android toolchain versions a project needs for [release].
///
/// Policy: when an upgrade is required, move to the earliest published release
/// that satisfies every requirement (Flutter's error floor and the
/// requirements between tools). This is the smallest change the Flutter team
/// declares as supported. Warning floors are recommended upgrades that are only
/// planned when the plan options include the recommended steps of the
/// component's recipe.
final class AndroidToolchainTargets {
  AndroidToolchainTargets({
    required this.android,
    required this.release,
    required this.knowledge,
    required PlanOptions options,
  })  : _recommendedAgp =
            options.includesRecommended(RecipeIds.androidAgpVersion),
        _recommendedGradle =
            options.includesRecommended(RecipeIds.androidGradleWrapper),
        _recommendedKotlin =
            options.includesRecommended(RecipeIds.androidKotlinVersion);

  final AndroidProject android;
  final FlutterRelease release;
  final KnowledgeBase knowledge;
  final bool _recommendedAgp;
  final bool _recommendedGradle;
  final bool _recommendedKotlin;

  late final ToolchainTarget? agp = _agp();
  late final ToolchainTarget? gradle = _gradle();
  late final ToolchainTarget? kotlin = _kotlin();

  /// The AGP version the project will use after planned upgrades.
  ToolVersion? get effectiveAgp =>
      agp?.target ?? android.toolchain.androidGradlePlugin?.version;

  ToolchainTarget? _agp() {
    final declared = android.toolchain.androidGradlePlugin?.version;
    if (declared == null) return null;
    final floor = release.androidRequirements.androidGradlePlugin;
    final reasons = <Evidence>[];
    var required = ToolVersion(0);
    var recommended = ToolVersion(0);
    if (floor != null) {
      required = floor.error;
      recommended = floor.warn;
      reasons.add(Evidence.knowledge(
          'Flutter ${release.version} requires Android Gradle Plugin '
          '${floor.error} and warns below ${floor.warn}',
          release.dependencyCheckerSource));
    }
    final compileSdk = _effectiveCompileSdk();
    if (compileSdk != null) {
      final minimum = knowledge.minimumAgpForCompileSdk(compileSdk);
      if (minimum != null && minimum.value > recommended) {
        recommended = minimum.value;
        reasons.add(Evidence.knowledge(
            'compileSdk $compileSdk is supported from Android Gradle Plugin '
            '${minimum.value}',
            minimum.source));
      }
    }
    return _choose(declared, required, recommended, reasons,
        knowledge.earliestAgpRelease, _recommendedAgp);
  }

  ToolchainTarget? _gradle() {
    final declared = android.toolchain.gradleWrapper?.version;
    if (declared == null) return null;
    final reasons = <Evidence>[];
    var required = ToolVersion(0);
    var recommended = ToolVersion(0);
    final floor = release.androidRequirements.gradle;
    if (floor != null) {
      required = floor.error;
      recommended = floor.warn;
      reasons.add(Evidence.knowledge(
          'Flutter ${release.version} requires Gradle ${floor.error} and warns '
          'below ${floor.warn}',
          release.dependencyCheckerSource));
    }
    final agpVersion = effectiveAgp;
    if (agpVersion != null) {
      final minimum = knowledge.minimumGradleForAgp(agpVersion);
      if (minimum != null) {
        if (minimum.value > required) required = minimum.value;
        if (minimum.value > recommended) recommended = minimum.value;
        reasons.add(Evidence.knowledge(
            'Android Gradle Plugin $agpVersion requires Gradle ${minimum.value}',
            minimum.source));
      }
    }
    return _choose(declared, required, recommended, reasons,
        knowledge.earliestGradleRelease, _recommendedGradle);
  }

  ToolchainTarget? _kotlin() {
    final declared = android.toolchain.kotlin?.version;
    if (declared == null) return null;
    final floor = release.androidRequirements.kotlin;
    if (floor == null) return null;
    return _choose(
      declared,
      floor.error,
      floor.warn,
      [
        Evidence.knowledge(
            'Flutter ${release.version} requires Kotlin ${floor.error} and '
            'warns below ${floor.warn}',
            release.dependencyCheckerSource),
      ],
      knowledge.earliestKotlinRelease,
      _recommendedKotlin,
    );
  }

  ToolchainTarget? _choose(
    ToolVersion current,
    ToolVersion required,
    ToolVersion recommended,
    List<Evidence> reasons,
    Fact<ToolVersion>? Function(ToolVersion) earliest,
    bool includeRecommended,
  ) {
    final ToolVersion minimum;
    final Necessity necessity;
    if (current < required) {
      minimum =
          includeRecommended && recommended > required ? recommended : required;
      necessity = Necessity.required;
    } else if (includeRecommended && current < recommended) {
      minimum = recommended;
      necessity = Necessity.recommended;
    } else {
      return null;
    }
    return ToolchainTarget(
      current: current,
      minimum: minimum,
      target: earliest(minimum)?.value,
      necessity: necessity,
      reasons: reasons,
    );
  }

  int? _effectiveCompileSdk() {
    final value = android.app?.compileSdk;
    return switch (value) {
      LiteralInt(:final value) => value,
      FlutterDefaultReference() => release.androidDefaults.compileSdk,
      _ => null,
    };
  }
}
