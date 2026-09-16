import 'package:pub_semver/pub_semver.dart';
import 'package:xml/xml_events.dart';

import '../../../common/source.dart';
import '../../../fs/project_file_system.dart';
import '../../../model/finding.dart';
import '../../../text/text_edit.dart';
import '../../../version/tool_version.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';

/// Flutter 3.41 stopped keeping `MinimumOSVersion` in
/// `ios/Flutter/AppFrameworkInfo.plist`; its migration removes the key
/// (flutter/flutter#178253). Earlier releases set it to the minimum.
final _removesMinimumOsVersion = Version(3, 41, 0);

/// Raises the iOS deployment target to the minimum supported by the target
/// Flutter release.
final class IosDeploymentTargetRecipe extends MigrationRecipe {
  const IosDeploymentTargetRecipe();

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.iosDeploymentTarget,
        title: 'Raise the iOS deployment target',
        summary: 'Raises IPHONEOS_DEPLOYMENT_TARGET of the project and '
            'application targets, the Podfile platform and '
            'AppFrameworkInfo.plist to the minimum iOS version of the target '
            'Flutter release.',
        category: RecipeCategory.ios,
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final ios = context.project.ios;
    if (ios == null) return const NotApplicable('The project has no iOS host.');
    final release = context.target;
    final minimum = release.iosMinimumDeploymentTarget;
    final minimumText = '$minimum';

    final lowSettings = ios.deploymentTargets
        .where((s) =>
            s.isApplicationTarget && s.version != null && s.version! < minimum)
        .toList();
    final otherLow = ios.deploymentTargets
        .where((s) =>
            !s.isApplicationTarget && s.version != null && s.version! < minimum)
        .toList();
    final podfile = ios.podfile;
    final platform = podfile?.platform;
    final platformVersion = platform?.version == null
        ? null
        : ToolVersion.tryParse(platform!.version!);
    final lowPlatform = platform != null &&
        platform.name == 'ios' &&
        platformVersion != null &&
        platformVersion < minimum &&
        platform.versionContentRange != null;
    // Flutter's IOSDeploymentTargetMigration rewrites the template's
    // commented-out platform line too, so the line keeps documenting the
    // minimum.
    final commented = podfile?.commentedPlatform;
    final commentedVersion = commented?.version == null
        ? null
        : ToolVersion.tryParse(commented!.version!);
    final lowCommentedPlatform = platform == null &&
        commented != null &&
        commented.name == 'ios' &&
        commentedVersion != null &&
        commentedVersion < minimum &&
        commented.versionContentRange != null;
    final plist = _minimumOsVersion(context.files, ios.directory);
    final plistVersion =
        plist == null ? null : ToolVersion.tryParse(plist.value);
    final plistNeedsChange = plist != null &&
        (release.version >= _removesMinimumOsVersion ||
            (plistVersion != null && plistVersion < minimum));

    if (lowSettings.isEmpty &&
        !lowPlatform &&
        !lowCommentedPlatform &&
        !plistNeedsChange) {
      return NotApplicable('The iOS deployment target already meets the '
          'minimum of Flutter ${release.version} (iOS $minimumText).');
    }

    final edits = <String, List<TextEdit>>{};
    void add(String path, TextEdit edit) =>
        edits.putIfAbsent(path, () => []).add(edit);
    final evidence = <Evidence>[
      Evidence.knowledge(
          'Flutter ${release.version} supports iOS $minimumText and later',
          release.iosMinimumSource),
    ];
    for (final setting in lowSettings) {
      add(setting.editable.path,
          TextEdit.replace(setting.editable.range, minimumText));
      evidence.add(Evidence.file(
          '${setting.owner} ${setting.configuration}: '
          'IPHONEOS_DEPLOYMENT_TARGET = ${setting.value}',
          setting.location));
    }
    if (lowPlatform) {
      add(podfile!.path,
          TextEdit.replace(platform.versionContentRange!, minimumText));
      evidence.add(Evidence.file(
          "platform :ios, '${platform.version}'", platform.location));
    }
    if (lowCommentedPlatform) {
      add(podfile!.path,
          TextEdit.replace(commented.versionContentRange!, minimumText));
      evidence.add(Evidence.file(
          "# platform :ios, '${commented.version}' (commented out)",
          commented.location));
    }
    if (plistNeedsChange) {
      final removal = release.version >= _removesMinimumOsVersion;
      add(
          plist.path,
          removal
              ? TextEdit.replace(plist.entryLines, '')
              : TextEdit.replace(plist.valueRange, minimumText));
      evidence.add(Evidence.file(
          'MinimumOSVersion ${plist.value}', SourceRef(plist.path)));
    }

    final notes = <String>[
      for (final setting in otherLow)
        'Target "${setting.owner}" (${setting.configuration}) sets '
            'IPHONEOS_DEPLOYMENT_TARGET = ${setting.value}; it is not an app '
            'target and was left unchanged.',
      if (podfile != null)
        for (final assignment in podfile.buildSettingAssignments)
          if (assignment.setting == 'IPHONEOS_DEPLOYMENT_TARGET' &&
              assignment.value != null &&
              (ToolVersion.tryParse(assignment.value!) ?? minimum) < minimum)
            'The Podfile post_install hook forces pods to iOS '
                '${assignment.value} (${assignment.location.display}). Pods '
                'may target a lower version than the app; review whether the '
                'override is still needed.',
      if (podfile != null && !podfile.isReliable)
        'The Podfile could not be parsed reliably; check its platform line '
            'manually.',
      if (lowCommentedPlatform)
        'The commented-out platform line in the Podfile is updated too, as '
            "Flutter's build does.",
      if (plistNeedsChange && release.version >= _removesMinimumOsVersion)
        'MinimumOSVersion is removed from AppFrameworkInfo.plist, as Flutter '
            '${release.version} sets it when building App.framework.',
    ];

    return Proposal(
      status: podfile != null && !podfile.isReliable
          ? StepStatus.review
          : StepStatus.auto,
      necessity: Necessity.required,
      summary: 'Raise the iOS deployment target to $minimumText.',
      rationale: 'Flutter ${release.version} supports iOS $minimumText and '
          'later; the project targets '
          '${{
        ...lowSettings.map((s) => s.value),
        if (lowPlatform) platform.version
      }.join(', ')}.',
      impact: 'Plugins that require iOS $minimumText fail to resolve, and '
          'builds warn about or rewrite the deployment target.',
      evidence: evidence,
      edits: [
        for (final entry in edits.entries) FileEdit(entry.key, entry.value),
      ],
      notes: notes,
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.iosBuild,
      ],
      details: {'to': minimumText},
    );
  }

  static ({
    String path,
    String value,
    TextRange valueRange,
    TextRange entryLines
  })? _minimumOsVersion(ProjectFileSystem files, String iosDirectory) {
    final path = '$iosDirectory/Flutter/AppFrameworkInfo.plist';
    final String? source;
    try {
      source = files.readString(path);
    } on FileReadException {
      return null;
    }
    if (source == null) return null;
    final List<XmlEvent> events;
    try {
      events = parseEvents(source, withLocation: true).toList();
    } on Exception {
      return null;
    }
    final lines = LineIndex(source);
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      if (event is! XmlTextEvent || event.value != 'MinimumOSVersion') continue;
      final keyStart = events[i - 1];
      // Find the following <string>value</string>.
      for (var j = i + 1; j < events.length; j++) {
        final candidate = events[j];
        if (candidate is XmlStartElementEvent && candidate.name == 'string') {
          final text = j + 1 < events.length ? events[j + 1] : null;
          final end = j + 2 < events.length ? events[j + 2] : null;
          if (text is! XmlTextEvent || end is! XmlEndElementEvent) return null;
          final firstLine = lines.lineOf(keyStart.start!);
          final lastLine = lines.lineOf(end.stop! - 1);
          return (
            path: path,
            value: text.value.trim(),
            valueRange: TextRange.fromBounds(text.start!, text.stop!),
            entryLines: TextRange.fromBounds(lines.lineStart(firstLine),
                lines.lineEndIncludingTerminator(lastLine)),
          );
        }
        if (candidate is XmlStartElementEvent) return null;
      }
    }
    return null;
  }
}
