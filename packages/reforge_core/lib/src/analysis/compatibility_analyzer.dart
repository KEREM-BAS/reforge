import '../common/source.dart';
import '../environment/environment.dart';
import '../knowledge/flutter_release.dart';
import '../knowledge/knowledge_base.dart';
import '../migration/recipe_ids.dart';
import '../model/android_project.dart';
import '../model/declarations.dart';
import '../model/finding.dart';
import '../model/flutter_project.dart';
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

  List<Finding> analyze(
    FlutterProject project, {
    FlutterRelease? release,
    Environment? environment,
  }) {
    final findings = <Finding>[];
    findings.addAll(_problems(project));
    final android = project.android;
    if (android != null) {
      findings.addAll(_androidConsistency(android, release));
      if (release != null) findings.addAll(_androidRelease(android, release));
      if (environment != null) {
        findings.addAll(_androidEnvironment(android, environment, release));
      }
    }
    final ios = project.ios;
    if (ios != null && release != null) {
      final minimum = release.iosMinimumDeploymentTarget;
      final below = ios.deploymentTargets
          .where((s) =>
              s.isApplicationTarget &&
              s.version != null &&
              s.version! < minimum)
          .toList();
      if (below.isNotEmpty) {
        findings.add(Finding(
          code: 'IOS_DEPLOYMENT_TARGET_BELOW_FLUTTER_MINIMUM',
          severity: Severity.warning,
          title: 'iOS deployment target is below the minimum of Flutter '
              '${release.version}',
          message: 'The app targets iOS ${below.first.value}, but Flutter '
              '${release.version} supports iOS $minimum and later.',
          why: 'The Flutter engine for this release is built for iOS $minimum '
              'and later.',
          impact: 'Builds print warnings or rewrite the setting, and plugins '
              'that require a newer iOS version fail to resolve with '
              'CocoaPods or Swift Package Manager.',
          suggestedAction: 'Raise IPHONEOS_DEPLOYMENT_TARGET (and the Podfile '
              'platform, if set) to $minimum.',
          evidence: [
            for (final setting in below)
              Evidence.file(
                  '${setting.owner} ${setting.configuration}: '
                  'IPHONEOS_DEPLOYMENT_TARGET = ${setting.value}',
                  setting.location),
            Evidence.knowledge(
                'Flutter ${release.version} minimum iOS deployment target is $minimum',
                release.iosMinimumSource),
          ],
          relatedRecipes: const [RecipeIds.iosDeploymentTarget],
        ));
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
  }

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
