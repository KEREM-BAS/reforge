import 'package:reforge_core/reforge_core.dart';

import '../cli_context.dart';
import '../exit_codes.dart';
import '../output/terminal.dart';
import 'reforge_command.dart';

final class EnvCommand extends ReforgeCommand {
  EnvCommand(super.context);

  @override
  String get name => 'env';

  @override
  String get description =>
      'Show the local toolchain Reforge observes: Flutter, Dart, the JDK '
      'Flutter uses for Android builds, Xcode, CocoaPods and Git.';

  @override
  Future<int> run() async {
    final environment = await context.probeEnvironment();
    if (format == OutputFormat.json) {
      writeJson(environment.toJson());
    } else {
      renderEnvironment(terminal, environment, context);
    }
    return ExitCodes.success;
  }
}

void renderEnvironment(
    Terminal t, Environment environment, CliContext context) {
  t.heading('Environment');
  t.field(
      'OS',
      '${environment.operatingSystem} '
          '${t.dim(environment.operatingSystemVersion)}');
  final flutter = environment.flutter;
  if (flutter == null) {
    t.field('Flutter', t.red('not available (${environment.flutterError})'));
  } else {
    final knowledge = context.knowledge;
    final version = flutter.version;
    final String note;
    if (version == null || knowledge.release(version) != null) {
      note = '';
    } else if (knowledge.isNewerThanKnown(version)) {
      note = t.yellow('  newer than the releases this Reforge knows; upgrade '
          'Reforge');
    } else if (version.isPreRelease) {
      note = t.yellow('  not a stable release');
    } else {
      note = t.yellow('  not a stable release known to Reforge');
    }
    t.field('Flutter',
        '${version ?? 'unknown'} ${t.dim('(${flutter.channel ?? '?'})')}$note');
    t.field('Dart', '${flutter.dartVersion ?? 'unknown'}');
    if (flutter.root != null) t.field('Flutter root', t.dim(flutter.root!));
  }
  final java = environment.javaForFlutter;
  if (java == null) {
    t.field('Java', t.yellow('no JDK found'));
  } else {
    t.field(
        'Java',
        '${java.majorVersion} ${t.dim('(${java.version})')} '
            '${t.dim('from ${_javaSource(java.source)}, '
                '${environment.javaForFlutterConfidence.name} confidence that Flutter uses it')}');
  }
  for (final candidate in environment.javaCandidates) {
    if (identical(candidate, java)) continue;
    t.field(
        '',
        t.dim('also: Java ${candidate.majorVersion ?? '?'} '
            'from ${_javaSource(candidate.source)} (${candidate.executable})'));
  }
  if (environment.isMacOS) {
    t.field('Xcode', environment.xcode?.version ?? t.yellow('not available'));
    t.field('CocoaPods',
        environment.cocoapods?.version ?? t.yellow('not available'));
  } else {
    t.field('Xcode', t.dim('not applicable on ${environment.operatingSystem}'));
  }
  t.field('Git', environment.git?.version ?? t.yellow('not available'));
  final knowledge = context.knowledge;
  final age = knowledge.ageInDays(context.clock());
  t.field(
      'Reforge',
      '$reforgeVersion ${t.dim('knowledge base ${knowledge.version}, latest '
              'Flutter ${knowledge.latestStable.version}')}'
          '${age > KnowledgeBase.staleAfterDays ? t.yellow('  $age days old; newer Flutter releases may exist') : ''}');
}

String _javaSource(JavaSource source) => switch (source) {
      JavaSource.flutterConfig => 'flutter config --jdk-dir',
      JavaSource.androidStudio => 'Android Studio',
      JavaSource.javaHome => 'JAVA_HOME',
      JavaSource.path => 'PATH',
    };
