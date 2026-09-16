import 'package:meta/meta.dart';

import '../common/source.dart';
import '../parsing/gradle/gradle_script.dart';
import '../parsing/properties/properties_file.dart';
import '../parsing/xml/android_manifest.dart';
import '../version/tool_version.dart';
import 'declarations.dart';

/// How Flutter's Gradle plugins are applied.
enum GradlePluginStyle {
  /// `plugins { id "dev.flutter.flutter-plugin-loader" }` in settings and
  /// `plugins { id "dev.flutter.flutter-gradle-plugin" }` in the app module.
  declarative,

  /// `apply from: ".../app_plugin_loader.gradle"` and
  /// `apply from: ".../flutter.gradle"`.
  imperative,

  /// One file uses each style.
  mixed,

  /// Neither pattern was found (custom or unreadable build files).
  unknown,
}

@immutable
final class GradlePluginApplication {
  const GradlePluginApplication({
    required this.style,
    required this.settingsLoader,
    required this.appPlugin,
  });

  final GradlePluginStyle style;

  /// Style used in `settings.gradle(.kts)` for the plugin loader, if found.
  final GradlePluginStyle settingsLoader;

  /// Style used in `app/build.gradle(.kts)` for the Flutter Gradle plugin.
  final GradlePluginStyle appPlugin;

  Map<String, Object?> toJson() => {
        'style': style.name,
        'settingsLoader': settingsLoader.name,
        'appPlugin': appPlugin.name,
      };
}

@immutable
final class GradleWrapper {
  const GradleWrapper({
    required this.distributionUrl,
    required this.version,
    required this.distributionType,
    required this.hasChecksum,
    required this.location,
    required this.urlEditable,
  });

  final String distributionUrl;
  final ToolVersion? version;

  /// `bin` or `all`.
  final String? distributionType;

  /// Whether `distributionSha256Sum` pins the distribution.
  final bool hasChecksum;

  final SourceRef location;
  final EditableValue urlEditable;

  Map<String, Object?> toJson() => {
        'version': version?.toString(),
        'distributionType': distributionType,
        'distributionUrl': distributionUrl,
        'hasChecksum': hasChecksum,
        'location': location.toJson(),
      };
}

@immutable
final class AndroidToolchain {
  const AndroidToolchain({
    this.androidGradlePlugin,
    this.kotlin,
    this.gradleWrapper,
    this.gradleJavaHome,
    this.builtInKotlin,
    this.newDsl,
  });

  final VersionDeclaration? androidGradlePlugin;
  final VersionDeclaration? kotlin;
  final GradleWrapper? gradleWrapper;

  /// `org.gradle.java.home` from `gradle.properties`, when set.
  final String? gradleJavaHome;

  /// `android.builtInKotlin` from `gradle.properties` (AGP 9), when set.
  final bool? builtInKotlin;

  /// `android.newDsl` from `gradle.properties` (AGP 9), when set.
  final bool? newDsl;

  Map<String, Object?> toJson() => {
        'androidGradlePlugin': androidGradlePlugin?.toJson(),
        'kotlin': kotlin?.toJson(),
        'gradle': gradleWrapper?.toJson(),
        if (gradleJavaHome != null) 'gradleJavaHome': gradleJavaHome,
        if (builtInKotlin != null) 'builtInKotlin': builtInKotlin,
        if (newDsl != null) 'newDsl': newDsl,
      };
}

@immutable
final class AndroidManifestFile {
  const AndroidManifestFile(this.sourceSet, this.manifest);

  /// `main`, `debug`, `profile` or a flavor/build type name.
  final String sourceSet;
  final AndroidManifest manifest;
}

/// The Android application module (`android/app`).
@immutable
final class AndroidAppModule {
  const AndroidAppModule({
    required this.script,
    this.namespace,
    this.applicationId,
    this.compileSdk,
    this.minSdk,
    this.targetSdk,
    this.ndkVersion,
    this.productFlavors = const [],
    this.hasReleaseSigningConfig = false,
  });

  final GradleScript script;
  final ScriptValue? namespace;
  final ScriptValue? applicationId;
  final ScriptValue? compileSdk;
  final ScriptValue? minSdk;
  final ScriptValue? targetSdk;
  final ScriptValue? ndkVersion;
  final List<String> productFlavors;
  final bool hasReleaseSigningConfig;

  Map<String, Object?> toJson() => {
        'buildFile': script.path,
        'dsl': script.dialect.name,
        'namespace': namespace?.toJson(),
        'applicationId': applicationId?.toJson(),
        'compileSdk': compileSdk?.toJson(),
        'minSdk': minSdk?.toJson(),
        'targetSdk': targetSdk?.toJson(),
        'ndkVersion': ndkVersion?.toJson(),
        'productFlavors': productFlavors,
        'hasReleaseSigningConfig': hasReleaseSigningConfig,
      };
}

/// The Android host project of a Flutter app (`android/`).
@immutable
final class AndroidProject {
  const AndroidProject({
    required this.directory,
    required this.toolchain,
    required this.pluginApplication,
    this.settings,
    this.rootBuild,
    this.app,
    this.gradleProperties,
    this.wrapperProperties,
    this.manifests = const [],
    this.problems = const [],
  });

  /// Project-relative directory, normally `android`.
  final String directory;

  final GradleScript? settings;
  final GradleScript? rootBuild;
  final AndroidAppModule? app;
  final PropertiesFile? gradleProperties;
  final PropertiesFile? wrapperProperties;
  final List<AndroidManifestFile> manifests;
  final AndroidToolchain toolchain;
  final GradlePluginApplication pluginApplication;
  final List<ParseProblem> problems;

  AndroidManifestFile? get mainManifest =>
      manifests.where((m) => m.sourceSet == 'main').firstOrNull;

  /// Build scripts that were parsed.
  Iterable<GradleScript> get scripts =>
      [settings, rootBuild, app?.script].whereType<GradleScript>();

  Map<String, Object?> toJson() => {
        'directory': directory,
        'settingsFile': settings?.path,
        'rootBuildFile': rootBuild?.path,
        'dsl': (app?.script ?? settings)?.dialect.name,
        'pluginApplication': pluginApplication.toJson(),
        'toolchain': toolchain.toJson(),
        'app': app?.toJson(),
        'manifests': [
          for (final m in manifests)
            {
              'sourceSet': m.sourceSet,
              'path': m.manifest.path,
              if (m.manifest.packageAttribute != null)
                'packageAttribute': m.manifest.packageAttribute,
            },
        ],
        'unreliableScripts': [
          for (final s in scripts)
            if (!s.isReliable) s.path,
        ],
        'problems': [for (final p in problems) p.toJson()],
      };
}
