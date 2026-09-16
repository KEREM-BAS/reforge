import 'package:meta/meta.dart';

import '../common/source.dart';
import '../parsing/ruby/podfile.dart';
import '../parsing/xcode/pbxproj.dart';
import '../version/tool_version.dart';
import 'declarations.dart';

enum DarwinDependencyManager { cocoapods, swiftPackageManager, both, none }

/// The Apple platforms a Flutter app can target.
enum DarwinPlatform {
  ios(
    displayName: 'iOS',
    directory: 'ios',
    deploymentTargetSetting: 'IPHONEOS_DEPLOYMENT_TARGET',
    podfilePlatform: 'ios',
  ),
  macos(
    displayName: 'macOS',
    directory: 'macos',
    deploymentTargetSetting: 'MACOSX_DEPLOYMENT_TARGET',
    podfilePlatform: 'osx',
  );

  const DarwinPlatform({
    required this.displayName,
    required this.directory,
    required this.deploymentTargetSetting,
    required this.podfilePlatform,
  });

  final String displayName;

  /// The host project directory, `ios` or `macos`.
  final String directory;

  /// The Xcode build setting holding the deployment target.
  final String deploymentTargetSetting;

  /// The CocoaPods platform name (`platform :osx, '12.0'`).
  final String podfilePlatform;
}

/// A deployment target build setting (`IPHONEOS_DEPLOYMENT_TARGET` or
/// `MACOSX_DEPLOYMENT_TARGET`).
@immutable
final class DeploymentTargetSetting {
  const DeploymentTargetSetting({
    required this.owner,
    required this.configuration,
    required this.value,
    required this.version,
    required this.location,
    required this.editable,
    required this.isApplicationTarget,
  });

  /// `project` for project-level settings, otherwise the target name.
  final String owner;

  /// `Debug`, `Release`, `Profile`, ...
  final String configuration;

  final String value;
  final ToolVersion? version;
  final SourceRef location;
  final EditableValue editable;

  /// Whether the setting belongs to the project level or to an application
  /// target (as opposed to extensions or test bundles).
  final bool isApplicationTarget;

  Map<String, Object?> toJson() => {
        'owner': owner,
        'configuration': configuration,
        'value': value,
        'location': location.toJson(),
      };
}

/// The iOS (`ios/`) or macOS (`macos/`) host project of a Flutter app.
@immutable
final class DarwinProject {
  const DarwinProject({
    required this.platform,
    required this.directory,
    required this.dependencyManager,
    this.podfile,
    this.xcodeProject,
    this.hasPodfileLock = false,
    this.hasWorkspace = false,
    this.deploymentTargets = const [],
    this.appFrameworkMinimumOsVersion,
    this.appDelegateLanguage,
    this.problems = const [],
  });

  final DarwinPlatform platform;
  final String directory;
  final Podfile? podfile;
  final XcodeProject? xcodeProject;
  final bool hasPodfileLock;
  final bool hasWorkspace;
  final DarwinDependencyManager dependencyManager;
  final List<DeploymentTargetSetting> deploymentTargets;

  /// `MinimumOSVersion` in `ios/Flutter/AppFrameworkInfo.plist` (iOS, older
  /// templates only).
  final String? appFrameworkMinimumOsVersion;

  /// `swift` or `objc`.
  final String? appDelegateLanguage;

  final List<ParseProblem> problems;

  /// The lowest deployment target among the project level and application
  /// targets.
  ToolVersion? get effectiveDeploymentTarget {
    final versions = deploymentTargets
        .where((s) => s.isApplicationTarget)
        .map((s) => s.version)
        .whereType<ToolVersion>()
        .toList()
      ..sort();
    return versions.isEmpty ? null : versions.first;
  }

  Map<String, Object?> toJson() => {
        'directory': directory,
        'dependencyManager': dependencyManager.name,
        'podfile': podfile == null
            ? null
            : {
                'path': podfile!.path,
                'platform': podfile!.platform?.version,
                'platformCommentedOut': podfile!.platform == null &&
                    podfile!.commentedPlatform != null,
                'usesFrameworks': podfile!.usesFrameworks,
                'hasPostInstall': podfile!.hasPostInstall,
                'customBuildSettings': [
                  for (final a in podfile!.buildSettingAssignments)
                    {
                      'setting': a.setting,
                      if (a.value != null) 'value': a.value,
                      'location': a.location.toJson(),
                    },
                ],
                'pods': podfile!.pods,
                'reliable': podfile!.isReliable,
              },
        'hasPodfileLock': hasPodfileLock,
        'hasWorkspace': hasWorkspace,
        'deploymentTarget': effectiveDeploymentTarget?.toString(),
        'deploymentTargets': [for (final s in deploymentTargets) s.toJson()],
        'targets': [
          for (final t in xcodeProject?.targets ?? const <XcodeTarget>[])
            {'name': t.name, 'productType': t.productType},
        ],
        if (appFrameworkMinimumOsVersion != null)
          'appFrameworkMinimumOsVersion': appFrameworkMinimumOsVersion,
        'appDelegateLanguage': appDelegateLanguage,
        'problems': [for (final p in problems) p.toJson()],
      };
}
