import 'package:pub_semver/pub_semver.dart';

import '../common/source.dart';
import '../environment/environment.dart';
import '../knowledge/flutter_release.dart';
import '../knowledge/knowledge_base.dart';
import '../migration/recipe_ids.dart';
import '../model/android_project.dart';
import '../model/darwin_project.dart';
import '../model/declarations.dart';
import '../model/dependencies.dart';
import '../model/finding.dart';
import '../model/flutter_project.dart';
import '../parsing/gradle/gradle_semantics.dart';
import '../parsing/pub/pub_metadata.dart';
import '../parsing/pub/sdk_constraint.dart';
import '../version/tool_version.dart';

/// Finds compatibility problems in a project.
///
/// Checks fall into three groups:
/// - internal consistency of the project's own toolchain declarations
///   (for example Gradle too old for the declared Android Gradle Plugin);
/// - requirements of a Flutter [FlutterRelease];
/// - the observed [Environment] (for example a JDK that cannot run Gradle).
final class CompatibilityAnalyzer {
  CompatibilityAnalyzer(this.knowledge);

  final KnowledgeBase knowledge;

  /// Analyzes [project], against [release] when given. With [dependencies],
  /// the project's resolved packages are checked too.
  List<Finding> analyze(
    FlutterProject project, {
    FlutterRelease? release,
    Environment? environment,
    DependencyReport? dependencies,
  }) {
    final findings = <Finding>[];
    findings.addAll(_problems(project));
    if (dependencies != null && release != null) {
      findings.addAll(_dependencies(project, release, dependencies));
    }
    final android = project.android;
    if (android != null) {
      findings.addAll(_androidConsistency(android, release));
      if (release != null) findings.addAll(_androidRelease(android, release));
      if (environment != null) {
        findings.addAll(_androidEnvironment(android, environment, release));
      }
    }
    if (release != null) {
      for (final host in [project.ios, project.macos].nonNulls) {
        findings.addAll(_deploymentTarget(host, release));
      }
      if (environment != null) {
        findings.addAll(_darwinEnvironment(project, environment, release));
      }
    }
    if (environment?.flutter?.version != null &&
        project.pinnedFlutterVersion != null &&
        project.pinnedFlutterVersion!.version !=
            environment!.flutter!.version) {
      final pin = project.pinnedFlutterVersion!;
      findings.add(Finding(
        code: 'FLUTTER_VERSION_PIN_MISMATCH',
        severity: Severity.warning,
        title: 'The flutter on PATH differs from the pinned Flutter version',
        message: 'The project pins Flutter ${pin.value}, but `flutter` in this '
            'environment is ${environment.flutter!.version}.',
        impact: 'Commands run with `flutter` instead of the version manager '
            'use a different SDK than the team and CI.',
        suggestedAction: 'Run Flutter through the version manager (for '
            'example `fvm flutter`), or update the pin intentionally.',
        evidence: [
          Evidence.file('Pinned Flutter ${pin.value}', pin.location),
          Evidence(EvidenceKind.environment,
              '`flutter --version` reports ${environment.flutter!.version}'),
        ],
      ));
    }
    return [for (final finding in findings) finding.forProject(project.path)];
  }

  /// Xcode and CocoaPods on this machine against the versions [release]
  /// checks, for projects with an iOS or macOS host.
  Iterable<Finding> _darwinEnvironment(FlutterProject project,
      Environment environment, FlutterRelease release) sync* {
    final hosts = [project.ios, project.macos].nonNulls.toList();
    if (hosts.isEmpty || !environment.isMacOS) return;
    final requirements = release.darwinRequirements;

    final xcode = environment.xcode?.version;
    final xcodeVersion = xcode == null ? null : ToolVersion.tryParse(xcode);
    if (xcodeVersion != null) {
      final floor = requirements.xcode;
      final evidence = [
        Evidence(EvidenceKind.environment,
            '`xcodebuild -version` reports Xcode $xcode'),
        Evidence.knowledge(
            'Flutter ${release.version} requires Xcode ${floor.error} and '
            'recommends Xcode ${floor.warn}',
            release.xcodeRequirementsSource),
      ];
      switch (floor.statusOf(xcodeVersion)) {
        case FloorStatus.belowError:
          final ios = project.ios != null;
          yield Finding(
            code: 'ENV_XCODE_BELOW_FLUTTER_MINIMUM',
            severity: ios ? Severity.error : Severity.warning,
            title: 'Xcode $xcode is below the minimum of Flutter '
                '${release.version}',
            message: 'Flutter ${release.version} requires Xcode ${floor.error} '
                'or newer.',
            impact: ios
                ? 'iOS builds stop with "Xcode ${floor.error} or greater is '
                    'required to develop for iOS", and `flutter doctor` '
                    'reports an error.'
                : '`flutter doctor` reports an error.',
            suggestedAction: 'Install Xcode ${floor.warn} or newer and select '
                'it with `xcode-select --switch`.',
            evidence: evidence,
          );
        case FloorStatus.belowWarn:
          yield Finding(
            code: 'ENV_XCODE_BELOW_FLUTTER_RECOMMENDED',
            severity: Severity.warning,
            title: 'Xcode $xcode is below the version Flutter '
                '${release.version} recommends',
            message: 'Flutter ${release.version} recommends Xcode '
                '${floor.warn} or newer.',
            impact: '`flutter doctor` warns; a future Flutter release may '
                'require the newer Xcode.',
            suggestedAction: 'Install Xcode ${floor.warn} or newer.',
            evidence: evidence,
          );
        case FloorStatus.satisfied:
          break;
      }
    }

    // CocoaPods runs when a host has a Podfile, or when Flutter creates one
    // for plugins.
    final usesCocoaPods = hosts.any((host) => switch (host.dependencyManager) {
          DarwinDependencyManager.cocoapods ||
          DarwinDependencyManager.both =>
            true,
          DarwinDependencyManager.none =>
            project.pluginsFor(host.platform.name).isNotEmpty,
          DarwinDependencyManager.swiftPackageManager => false,
        });
    final pod = environment.cocoapods?.version;
    final podVersion = pod == null ? null : ToolVersion.tryParse(pod);
    if (usesCocoaPods && podVersion != null) {
      final floor = requirements.cocoapods;
      final evidence = [
        Evidence(EvidenceKind.environment, '`pod --version` reports $pod'),
        Evidence.knowledge(
            'Flutter ${release.version} requires CocoaPods ${floor.error} and '
            'recommends CocoaPods ${floor.warn}',
            release.cocoapodsRequirementsSource),
      ];
      switch (floor.statusOf(podVersion)) {
        case FloorStatus.belowError:
          yield Finding(
            code: 'ENV_COCOAPODS_BELOW_FLUTTER_MINIMUM',
            severity: Severity.error,
            title: 'CocoaPods $pod is below the minimum of Flutter '
                '${release.version}',
            message: 'Flutter ${release.version} requires CocoaPods '
                '${floor.error} or newer.',
            impact: 'Builds skip `pod install` and stop with "CocoaPods not '
                'installed or not in valid state."',
            suggestedAction: 'Update CocoaPods to ${floor.warn} or newer, the '
                'same way it was installed (for example with `gem` or '
                'Homebrew).',
            evidence: evidence,
          );
        case FloorStatus.belowWarn:
          yield Finding(
            code: 'ENV_COCOAPODS_BELOW_FLUTTER_RECOMMENDED',
            severity: Severity.warning,
            title: 'CocoaPods $pod is below the version Flutter '
                '${release.version} recommends',
            message: 'Flutter ${release.version} recommends CocoaPods '
                '${floor.warn} or newer.',
            impact: 'Builds warn that pods handling may fail on some projects '
                'involving plugins.',
            suggestedAction: 'Update CocoaPods to ${floor.warn} or newer.',
            evidence: evidence,
          );
        case FloorStatus.satisfied:
          break;
      }
    }
  }

  Iterable<Finding> _podsAboveApp(FlutterProject project, DarwinProject host,
      DependencyReport report) sync* {
    if (host.dependencyManager == DarwinDependencyManager.swiftPackageManager) {
      return;
    }
    final platform = host.platform;
    final name = platform.displayName;
    final code = switch (platform) {
      DarwinPlatform.ios => 'PLUGIN_IOS_DEPLOYMENT_TARGET_ABOVE_APP',
      DarwinPlatform.macos => 'PLUGIN_MACOS_DEPLOYMENT_TARGET_ABOVE_APP',
    };
    final declared = host.podfile?.platform;
    final declaredVersion = declared != null &&
            declared.name == platform.podfilePlatform &&
            declared.version != null
        ? ToolVersion.tryParse(declared.version!)
        : null;
    final appTarget = declaredVersion ?? host.effectiveDeploymentTarget;
    final Evidence? appEvidence;
    if (declaredVersion != null) {
      appEvidence = Evidence.file(
          "Podfile platform :${declared!.name}, '${declared.version}'",
          declared.location);
    } else {
      final setting = host.deploymentTargets
          .where((s) => s.isApplicationTarget && s.version == appTarget)
          .firstOrNull;
      appEvidence = setting == null
          ? null
          : Evidence.file(
              '${setting.owner} ${setting.configuration}: '
              '${platform.deploymentTargetSetting} = ${setting.value} '
              '(CocoaPods uses it when the Podfile sets no platform)',
              setting.location);
    }
    for (final package in report.packages) {
      final facts = package.darwin(platform);
      final minimum = facts?.minimumVersion == null
          ? null
          : ToolVersion.tryParse(facts!.minimumVersion!);
      if (appTarget == null || minimum == null || minimum <= appTarget) {
        continue;
      }
      final label =
          '${package.name}${package.version == null ? '' : ' ${package.version}'}';
      final consequence = switch (platform) {
        DarwinPlatform.ios => 'devices below iOS $minimum can then no longer '
            'install the app',
        DarwinPlatform.macos => 'Macs below macOS $minimum can then no longer '
            'run the app',
      };
      yield Finding(
        code: code,
        severity: Severity.error,
        title: 'Plugin $label requires $name $minimum',
        message: 'Its podspec declares $name $minimum, but CocoaPods resolves '
            'pods for $name $appTarget '
            '(${declaredVersion != null ? 'the Podfile platform' : 'the app deployment target'}).',
        impact: '`pod install` fails: the pod requires a higher minimum '
            'deployment target.',
        suggestedAction: 'Raise the $name deployment target'
            '${declaredVersion != null ? ' and the Podfile platform' : ''} '
            'to $minimum ($consequence), or use a version of ${package.name} '
            'that supports $name $appTarget.',
        evidence: [
          Evidence(EvidenceKind.dependencyFile,
              'The podspec declares $name ${facts!.minimumVersion}',
              location: facts.podspec),
          if (appEvidence != null) appEvidence,
        ],
        project: project.path,
        subject: package.name,
      );
    }
  }

  Iterable<Finding> _deploymentTarget(
      DarwinProject host, FlutterRelease release) sync* {
    final platform = host.platform;
    final name = platform.displayName;
    final setting = platform.deploymentTargetSetting;
    // Finding codes are spelled out so that they can be searched for.
    final (code, minimum, source, recipe) = switch (platform) {
      DarwinPlatform.ios => (
          'IOS_DEPLOYMENT_TARGET_BELOW_FLUTTER_MINIMUM',
          release.iosMinimumDeploymentTarget,
          release.iosMinimumSource,
          RecipeIds.iosDeploymentTarget,
        ),
      DarwinPlatform.macos => (
          'MACOS_DEPLOYMENT_TARGET_BELOW_FLUTTER_MINIMUM',
          release.macosMinimumDeploymentTarget,
          release.macosMinimumSource,
          RecipeIds.macosDeploymentTarget,
        ),
    };
    final below = host.deploymentTargets
        .where((s) =>
            s.isApplicationTarget && s.version != null && s.version! < minimum)
        .toList();
    if (below.isEmpty) return;
    yield Finding(
      code: code,
      severity: Severity.warning,
      title: '$name deployment target is below the minimum of Flutter '
          '${release.version}',
      message: 'The app targets $name ${below.first.value}, but Flutter '
          '${release.version} supports $name $minimum and later.',
      why: 'The Flutter engine for this release is built for $name $minimum '
          'and later.',
      impact: 'Builds print warnings or rewrite the setting, and plugins that '
          'require a newer $name version fail to resolve with CocoaPods or '
          'Swift Package Manager.',
      suggestedAction: 'Raise $setting (and the Podfile platform, if set) to '
          '$minimum.',
      evidence: [
        for (final low in below)
          Evidence.file(
              '${low.owner} ${low.configuration}: $setting = ${low.value}',
              low.location),
        Evidence.knowledge(
            'Flutter ${release.version} minimum $name deployment target is '
            '$minimum',
            source),
      ],
      relatedRecipes: [recipe],
    );
  }

  Iterable<Finding> _problems(FlutterProject project) sync* {
    for (final problem in project.problems) {
      yield Finding(
        code: 'PROJECT_FILE_UNREADABLE',
        severity: Severity.warning,
        title: 'A project file could not be analyzed',
        message: problem.message,
        impact: 'Reforge cannot verify or migrate configuration in this file '
            'and will require manual review for changes that touch it.',
        suggestedAction: 'Check the file for syntax errors.',
        evidence: [
          Evidence.file(
              'Unreadable file', SourceRef(problem.path, line: problem.line)),
        ],
      );
    }
  }

  Iterable<Finding> _androidConsistency(
      AndroidProject android, FlutterRelease? release) sync* {
    final agp = android.toolchain.androidGradlePlugin;
    final wrapper = android.toolchain.gradleWrapper;
    final agpVersion = agp?.version;
    final gradleVersion = wrapper?.version;

    if (agpVersion != null && gradleVersion != null) {
      final minimum = knowledge.minimumGradleForAgp(agpVersion);
      if (minimum != null && gradleVersion < minimum.value) {
        yield Finding(
          code: 'ANDROID_GRADLE_TOO_OLD_FOR_AGP',
          severity: Severity.error,
          title: 'Gradle $gradleVersion is too old for Android Gradle Plugin '
              '$agpVersion',
          message: 'Android Gradle Plugin $agpVersion requires Gradle '
              '${minimum.value} or newer, but the wrapper uses Gradle '
              '$gradleVersion.',
          impact: 'Android builds fail while configuring the project.',
          suggestedAction: 'Upgrade the Gradle wrapper to ${minimum.value} or '
              'newer.',
          confidence: _confidenceOf(agp!),
          evidence: [
            _declarationEvidence('Android Gradle Plugin', agp),
            Evidence.file(
                'Gradle wrapper uses Gradle $gradleVersion', wrapper!.location),
            Evidence.knowledge(
                'AGP ${agpVersion.major}.${agpVersion.minor} requires Gradle '
                '${minimum.value}',
                minimum.source),
          ],
          relatedRecipes: const [RecipeIds.androidGradleWrapper],
        );
      }
    }

    final app = android.app;
    if (app != null && app.script.isReliable && app.namespace == null) {
      final requiresNamespace =
          agpVersion != null && agpVersion >= ToolVersion(8, 0);
      final manifestPackage = android.mainManifest?.manifest.packageAttribute;
      yield Finding(
        code: 'ANDROID_NAMESPACE_MISSING',
        severity: requiresNamespace ? Severity.error : Severity.info,
        title: requiresNamespace
            ? 'The Android namespace is not declared'
            : 'The Android namespace is declared only in the manifest',
        message: 'android.namespace is not set in ${app.script.path}'
            '${manifestPackage == null ? '' : '; AndroidManifest.xml declares package="$manifestPackage"'}.',
        why: 'Android Gradle Plugin 8 removed support for the manifest '
            'package attribute as the namespace.',
        impact: requiresNamespace
            ? 'Android builds fail with "Namespace not specified".'
            : 'Upgrading to Android Gradle Plugin 8 or newer will fail until '
                'the namespace is declared.',
        suggestedAction: 'Declare namespace in the android block and remove '
            'the package attribute from AndroidManifest.xml files.',
        evidence: [
          Evidence.file(
              'No namespace in the android block', SourceRef(app.script.path)),
          if (agp != null) _declarationEvidence('Android Gradle Plugin', agp),
        ],
        relatedRecipes: const [RecipeIds.androidNamespace],
      );
    }

    if (app != null && agpVersion != null) {
      int? compileSdk;
      Evidence? compileEvidence;
      final value = app.compileSdk;
      if (value is LiteralInt) {
        compileSdk = value.value;
        compileEvidence =
            Evidence.file('compileSdk ${value.value}', value.location);
      } else if (value is FlutterDefaultReference && release != null) {
        compileSdk = release.androidDefaults.compileSdk;
        compileEvidence = Evidence.inference(
            '${value.text} resolves to $compileSdk with Flutter ${release.version}');
      }
      if (compileSdk != null) {
        final minimum = knowledge.minimumAgpForCompileSdk(compileSdk);
        if (minimum != null && agpVersion < minimum.value) {
          yield Finding(
            code: 'ANDROID_COMPILE_SDK_REQUIRES_NEWER_AGP',
            severity: Severity.warning,
            title: 'compileSdk $compileSdk needs a newer Android Gradle Plugin',
            message: 'API level $compileSdk is supported by Android Gradle '
                'Plugin ${minimum.value} and newer; the project uses '
                '$agpVersion.',
            impact: 'Builds warn that the compile SDK was not tested with '
                'this plugin version, and resource or manifest processing '
                'can fail.',
            suggestedAction: 'Upgrade the Android Gradle Plugin to '
                '${minimum.value} or newer.',
            confidence:
                value is LiteralInt ? Confidence.certain : Confidence.high,
            evidence: [
              compileEvidence!,
              _declarationEvidence('Android Gradle Plugin', agp!),
              Evidence.knowledge(
                  'API $compileSdk requires AGP ${minimum.value}',
                  minimum.source),
            ],
            relatedRecipes: const [RecipeIds.androidAgpVersion],
          );
        }
      }
    }
  }

  Iterable<Finding> _androidRelease(
      AndroidProject android, FlutterRelease release) sync* {
    final style = android.pluginApplication;
    final imperativeParts = [
      if (style.settingsLoader == GradlePluginStyle.imperative ||
          style.settingsLoader == GradlePluginStyle.mixed)
        'settings (app_plugin_loader.gradle)',
      if (style.appPlugin == GradlePluginStyle.imperative ||
          style.appPlugin == GradlePluginStyle.mixed)
        'app module (flutter.gradle)',
    ];
    if (imperativeParts.isNotEmpty) {
      final severity = switch (release.imperativeGradleApply) {
        ImperativeGradleApply.removed => Severity.error,
        ImperativeGradleApply.deprecated => Severity.warning,
        _ => Severity.info,
      };
      yield Finding(
        code: 'ANDROID_IMPERATIVE_GRADLE_APPLY',
        severity: severity,
        title: switch (release.imperativeGradleApply) {
          ImperativeGradleApply.removed =>
            "Flutter's Gradle plugins are applied imperatively, which Flutter ${release.version} no longer supports",
          ImperativeGradleApply.deprecated =>
            "Flutter's Gradle plugins are applied imperatively, which is deprecated",
          _ => "Flutter's Gradle plugins are applied imperatively",
        },
        message: 'The legacy `apply from:` mechanism is used in the '
            '${imperativeParts.join(' and ')}.',
        why: 'Flutter 3.16 introduced the declarative plugins {} block, '
            'deprecated imperative apply in 3.19 and removed it in 3.29.',
        impact: switch (release.imperativeGradleApply) {
          ImperativeGradleApply.removed =>
            'Android builds fail with "You are applying Flutter\'s main Gradle plugin imperatively".',
          ImperativeGradleApply.deprecated =>
            'Builds print a deprecation error; upgrading to Flutter 3.29 or newer will break the Android build.',
          _ =>
            'Upgrading to Flutter 3.29 or newer will break the Android build.',
        },
        suggestedAction: 'Migrate to the declarative plugins {} block.',
        evidence: [
          for (final script in [android.settings, android.app?.script])
            if (script != null)
              Evidence.file('Imperative apply', SourceRef(script.path)),
          Evidence.knowledge(
              'Flutter ${release.version} imperative apply support: '
              '${release.imperativeGradleApply.name}',
              release.gradleApplySource),
        ],
        relatedRecipes: const [RecipeIds.androidFlutterGradlePluginDsl],
      );
    }

    final requirements = release.androidRequirements;
    final checker = release.dependencyCheckerSource;
    Finding? floorFinding({
      required String name,
      required String codeName,
      required ToolVersion? version,
      required VersionFloor? floor,
      required Evidence? declarationEvidence,
      required Confidence confidence,
      required String recipe,
    }) {
      if (version == null || floor == null || declarationEvidence == null) {
        return null;
      }
      final status = floor.statusOf(version);
      if (status == FloorStatus.satisfied) return null;
      final isError = status == FloorStatus.belowError;
      return Finding(
        code: isError
            ? 'ANDROID_${codeName}_BELOW_FLUTTER_MINIMUM'
            : 'ANDROID_${codeName}_BELOW_FLUTTER_RECOMMENDED',
        severity: isError ? Severity.error : Severity.warning,
        title: isError
            ? '$name $version is below the minimum required by Flutter ${release.version}'
            : '$name $version will soon be unsupported by Flutter',
        message: isError
            ? 'Flutter ${release.version} requires $name ${floor.error} or newer.'
            : 'Flutter ${release.version} warns for $name versions below ${floor.warn}.',
        impact: isError
            ? 'Android builds fail in Flutter\'s dependency version check.'
            : 'Builds print a warning; a future Flutter release will fail.',
        suggestedAction:
            'Upgrade $name to ${isError ? floor.error : floor.warn} or newer.',
        confidence: confidence,
        evidence: [
          declarationEvidence,
          Evidence.knowledge(
              'Flutter ${release.version}: $name error below ${floor.error}, '
              'warning below ${floor.warn}',
              checker),
        ],
        relatedRecipes: [recipe],
      );
    }

    final agp = android.toolchain.androidGradlePlugin;
    final kotlin = android.toolchain.kotlin;
    final wrapper = android.toolchain.gradleWrapper;
    final results = [
      floorFinding(
        name: 'Android Gradle Plugin',
        codeName: 'AGP',
        version: agp?.version,
        floor: requirements.androidGradlePlugin,
        declarationEvidence: agp == null
            ? null
            : _declarationEvidence('Android Gradle Plugin', agp),
        confidence: agp == null ? Confidence.low : _confidenceOf(agp),
        recipe: RecipeIds.androidAgpVersion,
      ),
      floorFinding(
        name: 'Gradle',
        codeName: 'GRADLE',
        version: wrapper?.version,
        floor: requirements.gradle,
        declarationEvidence: wrapper == null
            ? null
            : Evidence.file(
                'Gradle wrapper uses ${wrapper.version}', wrapper.location),
        confidence: Confidence.certain,
        recipe: RecipeIds.androidGradleWrapper,
      ),
      floorFinding(
        name: 'Kotlin Gradle Plugin',
        codeName: 'KOTLIN',
        version: kotlin?.version,
        floor: requirements.kotlin,
        declarationEvidence:
            kotlin == null ? null : _declarationEvidence('Kotlin', kotlin),
        confidence: kotlin == null ? Confidence.low : _confidenceOf(kotlin),
        recipe: RecipeIds.androidKotlinVersion,
      ),
    ];
    yield* results.whereType<Finding>();

    final minSdk = _minSdkFinding(android, release);
    if (minSdk != null) yield minSdk;

    final agpVersion = android.toolchain.androidGradlePlugin?.version;
    final app = android.app;
    if (release.appliesKotlinPlugin &&
        agpVersion != null &&
        agpVersion.major >= 9 &&
        app != null &&
        app.script.isReliable) {
      final applications = kotlinAndroidPluginApplications(app.script);
      if (applications.isNotEmpty) {
        final builtIn = android.toolchain.builtInKotlin ?? true;
        yield Finding(
          code: 'ANDROID_APP_APPLIES_KOTLIN_PLUGIN',
          severity: builtIn ? Severity.error : Severity.warning,
          title: 'The app module applies the Kotlin Gradle plugin',
          message: builtIn
              ? 'Built-in Kotlin is enabled, and Android Gradle Plugin '
                  '$agpVersion rejects applying the Kotlin Android plugin.'
              : 'Flutter ${release.version} applies the plugin itself and '
                  'warns that apps applying it will fail to build in future '
                  'versions.',
          impact: builtIn
              ? 'Android builds fail.'
              : 'Builds print a warning; a future Flutter release will fail.',
          suggestedAction: 'Remove the Kotlin Android plugin from '
              '${app.script.path} and move kotlinOptions to '
              'kotlin { compilerOptions { } }.',
          evidence: [
            for (final statement in applications)
              Evidence.file('Applies the Kotlin Android plugin',
                  app.script.refAt(statement.start)),
            Evidence.knowledge(
                'Flutter ${release.version} applies the Kotlin Gradle plugin '
                'itself while built-in Kotlin is disabled',
                release.appliesKotlinPluginSource),
          ],
          relatedRecipes: const [RecipeIds.androidAppKotlinPlugin],
        );
      }
    }
  }

  Iterable<Finding> _dependencies(FlutterProject project,
      FlutterRelease release, DependencyReport report) sync* {
    if (!report.resolved) {
      yield Finding(
        code: 'DEPENDENCIES_NOT_RESOLVED',
        severity: Severity.info,
        title: 'Dependencies were not checked',
        message: '${project.file('.dart_tool/package_config.json')} does not '
            'exist, so Reforge could not read the packages this project uses.',
        suggestedAction: 'Run `flutter pub get`, then run Reforge again to '
            'check plugins and packages against Flutter ${release.version}.',
      );
      return;
    }
    if (report.unavailable.isNotEmpty) {
      yield Finding(
        code: 'DEPENDENCY_FILES_UNAVAILABLE',
        severity: Severity.info,
        title: '${report.unavailable.length} package(s) could not be read',
        message: 'The directories of ${_list(report.unavailable)} are missing '
            'or unreadable, so they were not checked.',
        suggestedAction: 'Run `flutter pub get` to restore them.',
      );
    }

    String upgradeAdvice(ResolvedPackage package) {
      final kind = package.locked?.kind;
      if (kind == LockedDependencyKind.directMain ||
          kind == LockedDependencyKind.directDev ||
          kind == LockedDependencyKind.directOverridden) {
        return 'Upgrade ${package.name} (a direct dependency): allow a newer '
            'version in pubspec.yaml; `flutter pub outdated` lists them.';
      }
      final dependents = report.dependentsOf(package.name).map((d) => d.name);
      return 'Upgrade the packages that depend on ${package.name}'
          '${dependents.isEmpty ? '' : ' (${_list(dependents.toList())})'} so '
          'that pub selects a newer ${package.name}; `flutter pub outdated` '
          'lists newer versions.';
    }

    // Dart SDK constraints of the locked versions.
    final dart = release.dartVersion;
    for (final package in report.packages) {
      final constraint = package.pubspec?.sdkConstraint;
      if (constraint == null) continue;
      final VersionConstraint parsed;
      try {
        parsed = VersionConstraint.parse(constraint.value);
      } on FormatException {
        continue;
      }
      if (effectiveDartSdkConstraint(parsed, dart).allows(dart)) continue;
      yield Finding(
        code: 'DEPENDENCY_DART_SDK_INCOMPATIBLE',
        severity: Severity.warning,
        title: '${package.name} ${package.version ?? ''} does not support '
                'Dart $dart'
            .replaceAll('  ', ' '),
        message: 'The locked version requires Dart "${constraint.value}"; '
            'Flutter ${release.version} bundles Dart $dart.',
        impact: '`flutter pub get` has to select another version of '
            '${package.name}. If none within the constraints supports Dart '
            '$dart, it fails.',
        suggestedAction: upgradeAdvice(package),
        evidence: [
          Evidence(EvidenceKind.dependencyFile,
              'environment.sdk: ${constraint.value}',
              location: SourceRef(package.displayPath('pubspec.yaml'),
                  line: constraint.location.line)),
          Evidence.knowledge('Flutter ${release.version} bundles Dart $dart',
              FlutterRelease.releaseManifestSource),
        ],
        project: project.path,
        subject: package.name,
      );
    }

    // Android plugins.
    final declaredAgp = project.android?.toolchain.androidGradlePlugin?.version;
    final agpMajor = declaredAgp?.major ??
        release.androidRequirements.androidGradlePlugin?.error.major;
    final v1Removal = KnowledgeBase.androidV1EmbeddingRemoval;
    for (final package in report.packages) {
      final android = package.android;
      if (android == null) continue;
      final label =
          '${package.name}${package.version == null ? '' : ' ${package.version}'}';
      if (android.declaresNamespace == false &&
          agpMajor != null &&
          agpMajor >= 8) {
        yield Finding(
          code: 'PLUGIN_ANDROID_NAMESPACE_MISSING',
          severity: Severity.error,
          title: 'Plugin $label does not declare an Android namespace',
          message: 'Its Android build script sets no namespace, which Android '
              'Gradle Plugin 8 and later require'
              '${declaredAgp == null ? '' : ' (this project uses $declaredAgp)'}.',
          impact: 'Android builds fail with "Namespace not specified" in the '
              ':${package.name} module.',
          suggestedAction: upgradeAdvice(package),
          evidence: [
            Evidence(EvidenceKind.dependencyFile,
                'The android block sets no namespace',
                location: android.buildFile),
            const Evidence.knowledge(
                'Android Gradle Plugin 8 requires namespace in the '
                'module-level build script',
                KnowledgeBase.agp8NamespaceSource),
          ],
          project: project.path,
          subject: package.name,
        );
      }
      if (android.v1EmbeddingReferences.isNotEmpty) {
        final removed = release.version >= v1Removal.value;
        yield Finding(
          code: 'PLUGIN_ANDROID_V1_EMBEDDING',
          severity: removed ? Severity.error : Severity.warning,
          title: removed
              ? 'Plugin $label uses the Android v1 embedding, which Flutter '
                  '${release.version} no longer has'
              : 'Plugin $label uses the Android v1 embedding, which Flutter '
                  '${v1Removal.value} removes',
          message: 'Its Android sources use PluginRegistry.Registrar.',
          impact: removed
              ? 'Android builds fail compiling ${package.name} ("cannot find '
                  'symbol ... Registrar").'
              : 'Upgrading to Flutter ${v1Removal.value} or later breaks the '
                  'Android build.',
          suggestedAction: upgradeAdvice(package),
          evidence: [
            for (final reference in android.v1EmbeddingReferences)
              Evidence(
                  EvidenceKind.dependencyFile, 'Uses PluginRegistry.Registrar',
                  location: reference),
            Evidence.knowledge(
                'Flutter ${v1Removal.value} removed PluginRegistry.Registrar',
                v1Removal.source),
          ],
          project: project.path,
          subject: package.name,
        );
      }
    }

    // Plugins compiling against a newer Android SDK than the app.
    final appModule = project.android?.app;
    final appCompileSdk = switch (appModule?.compileSdk) {
      LiteralInt(:final value) => value,
      FlutterDefaultReference(property: 'compileSdkVersion') =>
        release.androidDefaults.compileSdk,
      _ => null,
    };
    if (appModule != null && appCompileSdk != null) {
      final higher = [
        for (final package in report.packages)
          if (package.android?.compileSdk case final sdk?)
            if (sdk > appCompileSdk) (package, sdk),
      ];
      if (higher.isNotEmpty) {
        final maximum = higher.map((h) => h.$2).reduce((a, b) => a > b ? a : b);
        yield Finding(
          code: 'PLUGIN_COMPILE_SDK_ABOVE_APP',
          severity: Severity.warning,
          title: 'Plugins compile against Android SDK $maximum, the app '
              'against $appCompileSdk',
          message: '${_list([
                for (final (package, sdk) in higher) '${package.name} ($sdk)'
              ])} compile against a higher Android SDK than the app.',
          impact: "Flutter's Gradle plugin warns during builds, and the build "
              'fails when an Android library used by these plugins requires '
              'the higher compileSdk.',
          suggestedAction: 'Set compileSdk in ${appModule.script.path} to '
              '$maximum'
              '${maximum <= release.androidDefaults.compileSdk ? ' or flutter.compileSdkVersion' : ''}.',
          evidence: [
            for (final (package, sdk) in higher)
              Evidence(EvidenceKind.dependencyFile,
                  '${package.name} compiles against Android SDK $sdk',
                  location: package.android!.buildFile),
            if (appModule.compileSdk case final value?)
              Evidence.file('compileSdk ${value.text}', value.location),
            Evidence.knowledge(
                "Flutter's Gradle plugin warns when plugins compile against a "
                'higher Android SDK than the app',
                release.pluginCompileSdkCheckSource),
          ],
          relatedRecipes: const [RecipeIds.androidCompileSdk],
          project: project.path,
        );
      }
    }

    // Pods that need a newer OS version than the platform CocoaPods resolves
    // for.
    for (final host in [project.ios, project.macos].nonNulls) {
      yield* _podsAboveApp(project, host, report);
    }

    final kotlinPlugins = [
      for (final package in report.packages)
        if (package.android?.kotlinPlugin == KotlinPluginApplication.always)
          package,
    ];
    final conditionalKotlinPlugins = [
      for (final package in report.packages)
        if (package.android?.kotlinPlugin ==
            KotlinPluginApplication.conditional)
          package.name,
    ];
    if (kotlinPlugins.isNotEmpty &&
        release.appliesKotlinPlugin &&
        declaredAgp != null &&
        declaredAgp.major >= 9) {
      final names = [for (final plugin in kotlinPlugins) plugin.name];
      yield Finding(
        code: 'PLUGINS_APPLY_KOTLIN_GRADLE_PLUGIN',
        severity: Severity.warning,
        title: '${names.length} plugin(s) apply the Kotlin Gradle plugin',
        message: '${_list(names)} apply the Kotlin Gradle plugin. With '
            'Android Gradle Plugin 9, Flutter ${release.version} warns that '
            'future versions will fail to build apps using such plugins.'
            '${conditionalKotlinPlugins.isEmpty ? '' : ' ${_list(conditionalKotlinPlugins)} apply it only while built-in Kotlin is disabled; Flutter lists them too, but they already support built-in Kotlin.'}',
        impact: 'Builds print a warning; a future Flutter release will fail.',
        suggestedAction: 'Upgrade these plugins to versions that support '
            'built-in Kotlin (`flutter pub outdated` lists newer versions); '
            'report plugins without such a version to their authors.',
        evidence: [
          for (final plugin in kotlinPlugins)
            Evidence(
                EvidenceKind.dependencyFile, 'Applies the Kotlin Gradle plugin',
                location: plugin.android!.buildFile),
          Evidence.knowledge(
              'Flutter ${release.version} warns about plugins that apply the '
              'Kotlin Gradle plugin with Android Gradle Plugin 9',
              release.appliesKotlinPluginSource),
          const Evidence.knowledge('Migrating to built-in Kotlin',
              KnowledgeBase.builtInKotlinGuideSource),
        ],
        project: project.path,
      );
    }
  }

  static String _list(List<String> names) => names.length <= 5
      ? names.join(', ')
      : '${names.take(5).join(', ')} and ${names.length - 5} more';

  Finding? _minSdkFinding(AndroidProject android, FlutterRelease release) {
    final app = android.app;
    if (app == null) return null;
    final minimum = release.androidDefaults.minSdk;
    final below = [
      for (final (label, value) in app.minSdkDeclarations)
        if (value is LiteralInt && value.value < minimum) (label, value),
    ];
    if (below.isEmpty) return null;
    final lowest = below.map((d) => d.$2.value).reduce((a, b) => a < b ? a : b);
    final floor = release.androidRequirements.minSdk;
    final failsCheck = floor != null && lowest < floor.error.major;
    final migrates = release.runsAndroidMigration('MinSdkVersionMigration');
    return Finding(
      code: 'ANDROID_MIN_SDK_BELOW_FLUTTER_MINIMUM',
      severity: failsCheck ? Severity.error : Severity.warning,
      title:
          'minSdk $lowest is below the minimum of Flutter ${release.version}',
      message: 'Flutter ${release.version} supports Android API level '
          '$minimum and newer (flutter.minSdkVersion).',
      why: 'Flutter raises its minimum Android API level over time; '
          'flutter.minSdkVersion is $minimum in this release.',
      impact: [
        if (floor != null)
          "Flutter's Gradle plugin fails builds below API level "
              '${floor.error.major} and warns below ${floor.warn.major}.',
        if (migrates)
          'Before every Android build, the Flutter tool replaces too-low '
              'literal minSdk values with flutter.minSdkVersion.',
      ].join(' '),
      suggestedAction: 'Raise minSdk to flutter.minSdkVersion or $minimum. '
          'Devices below API level $minimum can no longer install the app.',
      evidence: [
        for (final (label, value) in below)
          Evidence.file('$label minSdk ${value.value}', value.location),
        Evidence.knowledge(
            'flutter.minSdkVersion is $minimum in Flutter ${release.version}',
            release.androidDefaultsSource),
      ],
      relatedRecipes: const [RecipeIds.androidMinSdk],
    );
  }

  Iterable<Finding> _androidEnvironment(AndroidProject android,
      Environment environment, FlutterRelease? release) sync* {
    final java = environment.javaForFlutter;
    final major = java?.majorVersion;
    if (java == null || major == null) return;
    final javaEvidence = Evidence(
        EvidenceKind.environment,
        'Flutter most likely uses Java ${java.version} from ${java.source.name} '
        '(${java.executable})');
    final confidence = environment.javaForFlutterConfidence;

    final gradle = android.toolchain.gradleWrapper;
    if (gradle?.version != null) {
      final runs = knowledge.gradleRunsOnJava(gradle!.version!, major);
      if (runs != null && !runs.value) {
        final minimum = knowledge.minimumGradleForJava(major);
        yield Finding(
          code: 'ENV_JAVA_CANNOT_RUN_GRADLE',
          severity: Severity.error,
          title: 'Gradle ${gradle.version} cannot run on Java $major',
          message: gradle.version! < ToolVersion(9)
              ? 'Gradle ${gradle.version} does not support Java $major'
                  '${minimum == null ? '' : '; Java $major is supported from Gradle ${minimum.value}'}.'
              : 'Gradle ${gradle.version} requires Java 17 or newer to run.',
          impact: 'Android builds fail before any task runs, typically with '
              '"Unsupported class file major version".',
          suggestedAction: gradle.version! < ToolVersion(9)
              ? 'Upgrade the Gradle wrapper, or point Flutter to a compatible '
                  'JDK with `flutter config --jdk-dir=<path>`.'
              : 'Point Flutter to JDK 17 or newer with `flutter config --jdk-dir=<path>`.',
          confidence: confidence,
          evidence: [
            javaEvidence,
            Evidence.file(
                'Gradle wrapper uses ${gradle.version}', gradle.location),
            Evidence.knowledge('Gradle/Java support matrix', runs.source),
          ],
          relatedRecipes: const [RecipeIds.androidGradleWrapper],
        );
      }
    }

    final agp = android.toolchain.androidGradlePlugin;
    if (agp?.version != null) {
      final minimum = knowledge.minimumJavaForAgp(agp!.version!);
      if (minimum != null && major < minimum.value) {
        yield Finding(
          code: 'ENV_JAVA_TOO_OLD_FOR_AGP',
          severity: Severity.error,
          title:
              'Android Gradle Plugin ${agp.version} requires Java ${minimum.value}',
          message: 'Flutter most likely builds with Java $major, but Android '
              'Gradle Plugin ${agp.version} requires Java ${minimum.value} or newer.',
          impact:
              'Android builds fail while applying the Android Gradle Plugin.',
          suggestedAction: 'Install JDK ${minimum.value} and select it with '
              '`flutter config --jdk-dir=<path>`.',
          confidence: confidence,
          evidence: [
            javaEvidence,
            _declarationEvidence('Android Gradle Plugin', agp),
            Evidence.knowledge('AGP Java requirements', minimum.source),
          ],
        );
      }
    }

    final javaFloor = release?.androidRequirements.java;
    if (javaFloor != null) {
      final status = javaFloor.statusOf(ToolVersion(major));
      if (status == FloorStatus.belowError) {
        yield Finding(
          code: 'ENV_JAVA_BELOW_FLUTTER_MINIMUM',
          severity: Severity.error,
          title:
              'Java $major is below the minimum of Flutter ${release!.version}',
          message:
              'Flutter ${release.version} requires Java ${javaFloor.error} or newer for Android builds.',
          impact: 'Android builds fail in Flutter\'s dependency version check.',
          suggestedAction:
              'Install JDK ${javaFloor.error} or newer and select it with `flutter config --jdk-dir=<path>`.',
          confidence: confidence,
          evidence: [
            javaEvidence,
            Evidence.knowledge('Flutter ${release.version} Java floor',
                release.dependencyCheckerSource),
          ],
        );
      }
    }
  }

  static Confidence _confidenceOf(VersionDeclaration declaration) =>
      switch (declaration.resolution) {
        ValueResolution.literal => Confidence.certain,
        ValueResolution.variable ||
        ValueResolution.gradleProperty =>
          Confidence.high,
        ValueResolution.unresolved => Confidence.low,
      };

  static Evidence _declarationEvidence(
      String name, VersionDeclaration declaration) {
    final how = switch (declaration.site) {
      DeclarationSite.settingsPlugins => 'plugins block in settings',
      DeclarationSite.rootBuildPlugins =>
        'plugins block in the root build file',
      DeclarationSite.buildscriptClasspath => 'buildscript classpath',
      DeclarationSite.versionCatalog => 'version catalog',
      DeclarationSite.gradleWrapper => 'Gradle wrapper',
    };
    return Evidence.file(
      '$name ${declaration.version ?? declaration.rawText} declared in the $how'
      '${declaration.note == null ? '' : ' (${declaration.note})'}',
      declaration.definition ?? declaration.usage,
    );
  }
}
