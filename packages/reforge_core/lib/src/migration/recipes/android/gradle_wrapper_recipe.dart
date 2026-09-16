import '../../../knowledge/knowledge_base.dart';
import '../../../model/finding.dart';
import '../../../text/text_edit.dart';
import '../../android_toolchain_targets.dart';
import '../../recipe.dart';
import '../../recipe_ids.dart';

/// Upgrades the Gradle version in `gradle-wrapper.properties`.
final class GradleWrapperRecipe extends MigrationRecipe {
  const GradleWrapperRecipe();

  @override
  RecipeDescriptor get descriptor => const RecipeDescriptor(
        id: RecipeIds.androidGradleWrapper,
        title: 'Upgrade the Gradle wrapper',
        summary: 'Moves distributionUrl (and distributionSha256Sum, when '
            'pinned) to the Gradle release required by the target Flutter '
            'release and Android Gradle Plugin.',
        category: RecipeCategory.android,
        runsAfter: [RecipeIds.androidFlutterGradlePluginDsl],
      );

  @override
  RecipeResult evaluate(RecipeContext context) {
    final android = context.project.android;
    if (android == null) {
      return const NotApplicable('The project has no Android host.');
    }
    final wrapper = android.toolchain.gradleWrapper;
    final properties = android.wrapperProperties;
    if (wrapper == null || properties == null) {
      return const NotApplicable(
          'No gradle-wrapper.properties with a distributionUrl.');
    }
    final release = context.target;
    if (wrapper.version == null) {
      final floor = release.androidRequirements.gradle;
      if (floor == null) {
        return const NotApplicable(
            'The Gradle version could not be read from distributionUrl.');
      }
      return Proposal(
        status: StepStatus.manual,
        necessity: Necessity.required,
        summary: 'Check the Gradle wrapper version.',
        rationale:
            'Flutter ${release.version} requires Gradle ${floor.error} or '
            'newer, but Reforge could not read the version from '
            '"${wrapper.distributionUrl}".',
        confidence: Confidence.low,
        evidence: [Evidence.file('distributionUrl', wrapper.location)],
        manualSteps: [
          'Make sure distributionUrl points to Gradle ${floor.error} or newer.',
        ],
      );
    }

    final targets = AndroidToolchainTargets(
      android: android,
      release: release,
      knowledge: context.knowledge,
      includeRecommended: context.options.includeRecommended,
    );
    final target = targets.gradle;
    if (target == null) {
      return NotApplicable('Gradle ${wrapper.version} already satisfies '
          'Flutter ${release.version}'
          '${targets.effectiveAgp == null ? '' : ' and Android Gradle Plugin ${targets.effectiveAgp}'}.');
    }
    final evidence = [
      Evidence.file(
          'The wrapper uses Gradle ${wrapper.version}', wrapper.location),
      ...target.reasons,
    ];
    final rationale = 'Gradle ${wrapper.version} is below ${target.minimum}, '
        'the minimum required by '
        '${target.reasons.map((r) => r.description).join('; ')}.';
    final to = target.target;
    if (to == null) {
      return Proposal(
        status: StepStatus.blocked,
        necessity: target.necessity,
        summary: 'Upgrade Gradle to ${target.minimum} or newer.',
        rationale: '$rationale No published Gradle release at or above '
            '${target.minimum} is known to this version of Reforge.',
        evidence: evidence,
        manualSteps: ['Upgrade Reforge, or edit distributionUrl manually.'],
      );
    }

    final source = properties.source;
    final entry = properties.entry('distributionUrl')!;
    final raw = entry.rawValueRange.textOf(source);
    final oldName = 'gradle-${wrapper.version}-${wrapper.distributionType}.zip';
    final nameIndex = raw.lastIndexOf(oldName);
    if (wrapper.distributionType == null ||
        nameIndex == -1 ||
        nameIndex + oldName.length != raw.length) {
      return Proposal(
        status: StepStatus.manual,
        necessity: target.necessity,
        summary: 'Upgrade Gradle to $to.',
        rationale: rationale,
        evidence: evidence,
        manualSteps: [
          'Set distributionUrl in ${properties.path} to Gradle $to '
              '(the current URL has a format Reforge does not edit).',
        ],
      );
    }

    final notes = <String>[];
    var status = StepStatus.auto;
    final host = Uri.tryParse(wrapper.distributionUrl)?.host;
    if (host != 'services.gradle.org') {
      status = StepStatus.review;
      notes.add('The distribution is downloaded from "$host" instead of '
          'services.gradle.org. Make sure that host provides '
          'gradle-$to-${wrapper.distributionType}.zip.');
    }

    final versionStart =
        entry.rawValueRange.offset + nameIndex + 'gradle-'.length;
    final edits = <TextEdit>[
      TextEdit(versionStart, '${wrapper.version}'.length, '$to'),
    ];
    final checksumEntry = properties.entry('distributionSha256Sum');
    if (checksumEntry != null) {
      final record = context.knowledge.gradleRelease(to);
      final checksum = record == null
          ? null
          : (wrapper.distributionType == 'all' ? record.all : record.bin);
      if (checksum == null) {
        status = StepStatus.review;
        notes.add('distributionSha256Sum is pinned but the checksum of Gradle '
            '$to is unknown to Reforge; update it from '
            'https://gradle.org/release-checksums/.');
      } else {
        edits.add(TextEdit.replace(checksumEntry.rawValueRange, checksum));
        evidence.add(Evidence.knowledge(
            'SHA-256 of gradle-$to-${wrapper.distributionType}.zip is $checksum',
            KnowledgeBase.gradleReleasesSource));
      }
    }

    return Proposal(
      status: status,
      necessity: target.necessity,
      summary: 'Upgrade the Gradle wrapper from ${wrapper.version} to $to.',
      rationale: rationale,
      impact: 'Android builds fail until Gradle is upgraded.',
      evidence: evidence,
      edits: [FileEdit(properties.path, edits)],
      notes: [
        ...notes,
        'Only the distribution is changed. The wrapper JAR and gradlew '
            'scripts keep working; `./gradlew wrapper` can refresh them later.',
      ],
      verification: const [
        VerificationCheck.staticAnalysis,
        VerificationCheck.androidBuild,
      ],
      details: {'from': '${wrapper.version}', 'to': '$to'},
    );
  }
}
