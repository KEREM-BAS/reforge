import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge_core/reforge_core.dart';

import '../exit_codes.dart';
import 'reforge_command.dart';

const _checkNames = {
  'pub-get': VerificationCheck.pubGet,
  'analyze': VerificationCheck.analyze,
  'android': VerificationCheck.androidBuild,
  'ios': VerificationCheck.iosBuild,
  'macos': VerificationCheck.macosBuild,
};

/// Build output to explain: a log file or a check that was run.
final class _Output {
  _Output({required this.label, required this.text, this.check});

  final String label;
  final String text;
  final CheckResult? check;

  late final String? failingModule = failingGradleModule(text);
}

final class DiagnoseCommand extends ReforgeCommand {
  DiagnoseCommand(super.context) {
    argParser
      ..addMultiOption('log',
          valueHelp: 'file',
          help: 'Explain the failures in these build logs instead of running '
              'a build.')
      ..addMultiOption('check',
          allowed: _checkNames.keys,
          help: 'Run these checks and explain their failures. Default: '
              "android, which runs the project's Gradle build logic.")
      ..addOption('to',
          valueHelp: 'version',
          help: 'Explain failures against this Flutter release instead of '
              'the release the project uses.')
      ..addOption('flutter',
          valueHelp: 'executable',
          defaultsTo: 'flutter',
          help: 'The flutter executable to run checks with.')
      ..addFlag('env',
          defaultsTo: true,
          help: 'Probe the local toolchain (Flutter, JDK) to confirm '
              'environment problems.');
  }

  @override
  String get name => 'diagnose';

  @override
  String get description =>
      'Explain why a build fails: recognize known failures in its output and '
      'confirm their cause from the project, its dependencies and the '
      'environment. Reads build logs, or runs the build.';

  @override
  Future<int> run() async {
    final logs = argResults!['log'] as List<String>;
    final checkNames = argResults!['check'] as List<String>;
    if (logs.isNotEmpty && checkNames.isNotEmpty) {
      throw const InvalidUsageException('DIAGNOSE_INPUT_CONFLICT',
          'Use either --log (explain existing output) or --check (run a build).');
    }
    final environment =
        argResults!['env'] as bool ? await context.probeEnvironment() : null;

    final workspace = inspectWorkspace();
    final files = LocalProjectFileSystem(projectDirectory);
    final projects = workspace.projects
        .where((p) => p.kind != FlutterProjectKind.dartPackage)
        .toList();
    final targetText = argResults!['to'] as String?;
    final FlutterRelease? release = targetText != null
        ? context.knowledge.resolveFlutterVersion(targetText)
        : projects.isEmpty
            ? null
            : resolveCurrentFlutterVersion(projects.first,
                    environment: environment, knowledge: context.knowledge)
                ?.release;

    final analyzer = CompatibilityAnalyzer(context.knowledge);
    final dependencies = DependencyInspector(const LocalPackageSources());
    final findings = [
      for (final project in projects)
        ...analyzer.analyze(
          project,
          release: release,
          environment: environment,
          dependencies:
              release == null ? null : dependencies.inspect(project, files),
        ),
    ];

    final outputs = <_Output>[];
    for (final log in logs) {
      final file =
          File(p.isAbsolute(log) ? log : p.join(context.workingDirectory, log));
      if (!file.existsSync()) {
        throw InvalidUsageException(
            'LOG_NOT_FOUND', 'No log file at ${file.path}.');
      }
      outputs.add(_Output(label: log, text: file.readAsStringSync()));
    }
    if (logs.isEmpty) {
      final journal = Journal(projectDirectory)..ensureCreated();
      final verifier = Verifier(
        projectRoot: projectDirectory,
        knowledge: context.knowledge,
        planner: MigrationPlanner(
          knowledge: context.knowledge,
          recipes: builtInRecipes(),
          reforgeVersion: reforgeVersion,
        ),
        runner: context.processRunner,
        operatingSystem:
            environment?.operatingSystem ?? Platform.operatingSystem,
      );
      final checks = checkNames.isEmpty
          ? const [VerificationCheck.androidBuild]
          : [for (final name in checkNames) _checkNames[name]!];
      for (final check in checks) {
        if (format == OutputFormat.text) {
          terminal.line(terminal.dim('Running ${_label(check)}...'));
        }
        final result = await verifier.runToolCheck(
          check,
          flutterExecutable: argResults!['flutter'] as String,
          logDirectory: p.join(journal.directory, 'logs'),
          target: release,
        );
        final logFile = result.logFile;
        outputs.add(_Output(
          label: result.command ?? _label(check),
          text: logFile == null ? '' : File(logFile).readAsStringSync(),
          check: result,
        ));
      }
    }

    final reports = [
      for (final output in outputs)
        (
          output: output,
          diagnoses: output.check?.status == CheckStatus.passed ||
                  output.check?.status == CheckStatus.skipped
              ? const <Diagnosis>[]
              : correlateFailures(
                  diagnoseFailure(output.text, target: release),
                  findings,
                  failingModule: output.failingModule,
                ),
        ),
    ];
    final failedChecks =
        outputs.where((o) => o.check?.status == CheckStatus.failed).length;

    if (format == OutputFormat.sarif) {
      final sarif = sarifBuilder();
      for (final report in reports) {
        for (final diagnosis in report.diagnoses) {
          sarif.addDiagnosis(diagnosis, output: report.output.label);
        }
      }
      findings.forEach(sarif.addFinding);
      writeSarif(sarif);
    } else if (format == OutputFormat.json) {
      writeJson({
        'flutter': release == null ? null : '${release.version}',
        'outputs': [
          for (final report in reports)
            {
              if (report.output.check == null)
                'log': report.output.label
              else
                'check': report.output.check!.toJson(),
              if (report.output.failingModule != null)
                'failingModule': report.output.failingModule,
              'diagnoses': [for (final d in report.diagnoses) d.toJson()],
            },
        ],
        'findings': [for (final f in findings) f.toJson()],
      });
    } else {
      _render(reports, release);
    }
    return failedChecks > 0 ? ExitCodes.failed : ExitCodes.success;
  }

  void _render(List<({_Output output, List<Diagnosis> diagnoses})> reports,
      FlutterRelease? release) {
    final t = terminal;
    for (final (:output, :diagnoses) in reports) {
      final check = output.check;
      t.heading('Diagnosis ${t.dim(output.label)}');
      if (release != null) {
        t.line(t.dim('  Explained for Flutter ${release.version}'));
      }
      if (check != null) {
        final symbol = switch (check.status) {
          CheckStatus.passed => t.green(t.ok),
          CheckStatus.failed => t.red(t.fail),
          CheckStatus.skipped => t.dim('-'),
        };
        t.line('  $symbol ${check.summary}');
        if (check.status != CheckStatus.failed) continue;
      }
      if (output.failingModule != null) {
        t.line('  Failing Gradle module: ${t.bold(output.failingModule!)}');
      }
      if (diagnoses.isEmpty) {
        t.line();
        t.line('  ${t.yellow(t.warn)} No known failure was recognized. '
            'The last lines of the output:');
        final lines = output.text
            .split('\n')
            .map((l) => l.trimRight())
            .where((l) => l.isNotEmpty)
            .toList();
        for (final line
            in lines.skip(lines.length > 15 ? lines.length - 15 : 0)) {
          t.line('    ${t.dim(line)}');
        }
        continue;
      }
      for (final diagnosis in diagnoses) {
        final failure = diagnosis.failure;
        t.line();
        t.line('  ${t.red(t.fail)} ${t.bold(failure.id)}');
        t.paragraph(failure.explanation);
        t.paragraph(t.dim('Output: ${failure.evidence}'));
        final confirmed = diagnosis.confirmedBy;
        for (final finding in confirmed) {
          t.paragraph(
              '${t.green(t.ok)} Confirmed by ${t.bold(finding.code)}: '
              '${finding.title}',
              hanging: 2);
          for (final evidence in finding.evidence) {
            final where = evidence.location?.display;
            if (where != null) t.line('        ${t.dim(where)}');
          }
        }
        final actions = confirmed.isEmpty
            ? [failure.suggestion]
            : {
                for (final finding in confirmed)
                  if (finding.suggestedAction != null) finding.suggestedAction!,
              }.toList();
        for (final action in actions) {
          t.paragraph('Suggested: $action', hanging: 2);
        }
        final recipes = confirmed.isEmpty
            ? failure.relatedRecipes
            : {for (final f in confirmed) ...f.relatedRecipes}.toList();
        if (recipes.isNotEmpty) {
          t.line('    ${t.dim('Recipes: ${recipes.join(', ')}')}');
        }
        if (verbose && failure.source != null) {
          t.line('    ${t.dim('Recognized from: ${failure.source!.title}')}');
        }
      }
    }
  }
}

String _label(VerificationCheck check) => switch (check) {
      VerificationCheck.staticAnalysis => 'static checks',
      VerificationCheck.pubGet => 'flutter pub get',
      VerificationCheck.analyze => 'flutter analyze',
      VerificationCheck.androidBuild => 'the Android build',
      VerificationCheck.iosBuild => 'the iOS build',
      VerificationCheck.macosBuild => 'the macOS build',
    };
