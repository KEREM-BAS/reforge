import 'package:xml/xml_events.dart';

import '../common/source.dart';
import '../fs/project_file_system.dart';
import '../model/darwin_project.dart';
import '../model/declarations.dart';
import '../parsing/parse_diagnostic.dart';
import '../parsing/ruby/podfile.dart';
import '../parsing/xcode/pbxproj.dart';
import '../version/tool_version.dart';

/// Builds a [DarwinProject] model from `ios/` or `macos/`.
final class DarwinInspector {
  DarwinInspector(this.files, this.platform);

  final ProjectFileSystem files;
  final DarwinPlatform platform;

  DarwinProject? inspect(String projectPath) {
    final directory = projectPath.isEmpty
        ? platform.directory
        : '$projectPath/${platform.directory}';
    if (!files.directoryExists(directory)) return null;
    final problems = <ParseProblem>[];

    Podfile? podfile;
    final podfilePath = '$directory/Podfile';
    try {
      final content = files.readString(podfilePath);
      if (content != null) {
        podfile = Podfile.parse(podfilePath, content);
        if (!podfile.isReliable) {
          final first = podfile.diagnostics.first;
          problems.add(ParseProblem(
            podfilePath,
            'The Podfile could not be parsed reliably: ${first.message}',
            line: LineIndex(content).lineOf(first.range.offset),
          ));
        }
      }
    } on FileReadException catch (e) {
      problems.add(ParseProblem(podfilePath, e.reason));
    }

    XcodeProject? xcodeProject;
    final deploymentTargets = <DeploymentTargetSetting>[];
    final pbxprojPath = '$directory/Runner.xcodeproj/project.pbxproj';
    try {
      final content = files.readString(pbxprojPath);
      if (content != null) {
        xcodeProject = XcodeProject.parse(pbxprojPath, content);
        final lines = LineIndex(content);
        void collect(String owner, bool application,
            List<XcodeBuildConfiguration> configurations) {
          for (final configuration in configurations) {
            final setting =
                configuration.setting(platform.deploymentTargetSetting);
            if (setting == null) continue;
            deploymentTargets.add(DeploymentTargetSetting(
              owner: owner,
              configuration: configuration.name,
              value: setting.value,
              version: ToolVersion.tryParse(setting.value),
              location: lines.refFor(pbxprojPath, setting.range.offset),
              editable: EditableValue(pbxprojPath, setting.contentRange),
              isApplicationTarget: application,
            ));
          }
        }

        collect('project', true, xcodeProject.projectConfigurations);
        for (final target in xcodeProject.targets) {
          collect(target.name, target.isApplication, target.configurations);
        }
      }
    } on DocumentParseException catch (e) {
      problems.add(ParseProblem(pbxprojPath, e.message, line: e.line));
    } on FileReadException catch (e) {
      problems.add(ParseProblem(pbxprojPath, e.reason));
    }

    final usesSwiftPackages = xcodeProject?.usesFlutterSwiftPackage ?? false;
    final manager = switch ((podfile != null, usesSwiftPackages)) {
      (true, true) => DarwinDependencyManager.both,
      (true, false) => DarwinDependencyManager.cocoapods,
      (false, true) => DarwinDependencyManager.swiftPackageManager,
      (false, false) => DarwinDependencyManager.none,
    };

    String? language;
    if (files.fileExists('$directory/Runner/AppDelegate.swift')) {
      language = 'swift';
    } else if (files.fileExists('$directory/Runner/AppDelegate.m')) {
      language = 'objc';
    }

    return DarwinProject(
      platform: platform,
      directory: directory,
      podfile: podfile,
      xcodeProject: xcodeProject,
      hasPodfileLock: files.fileExists('$directory/Podfile.lock'),
      hasWorkspace: files.directoryExists('$directory/Runner.xcworkspace'),
      dependencyManager: manager,
      deploymentTargets: deploymentTargets,
      appFrameworkMinimumOsVersion: platform == DarwinPlatform.ios
          ? _appFrameworkMinimumOsVersion(
              '$directory/Flutter/AppFrameworkInfo.plist', problems)
          : null,
      appDelegateLanguage: language,
      problems: problems,
    );
  }

  String? _appFrameworkMinimumOsVersion(
      String path, List<ParseProblem> problems) {
    final String? content;
    try {
      content = files.readString(path);
    } on FileReadException catch (e) {
      problems.add(ParseProblem(path, e.reason));
      return null;
    }
    if (content == null) return null;
    try {
      var afterKey = false;
      for (final event in parseEvents(content)) {
        if (event is XmlTextEvent) {
          final text = event.value.trim();
          if (text.isEmpty) continue;
          if (afterKey) return text;
          afterKey = text == 'MinimumOSVersion';
        }
      }
    } on Exception catch (e) {
      problems.add(ParseProblem(path, 'Malformed property list: $e'));
    }
    return null;
  }
}
