import 'package:reforge_core/reforge_core.dart';

import '../exit_codes.dart';
import '../render/findings_renderer.dart';
import '../render/project_renderer.dart';
import 'env_command.dart';
import 'reforge_command.dart';

final class InspectCommand extends ReforgeCommand {
  InspectCommand(super.context) {
    argParser.addFlag(
      'env',
      defaultsTo: true,
      help: 'Probe the local toolchain (flutter, java, xcode, pod, git) and '
          'check it against the project. Use --no-env for file-only '
          'analysis.',
    );
  }

  @override
  String get name => 'inspect';

  @override
  String get description =>
      'Analyze a Flutter project: toolchain declarations, platform '
      'configuration, dependencies and compatibility problems. Read-only.';

  @override
  Future<int> run() async {
    final probeEnvironment = argResults!['env'] as bool;
    final environmentFuture = probeEnvironment
        ? context.probeEnvironment()
        : Future<Environment?>.value();
    final workspace = inspectWorkspace();
    final environment = await environmentFuture;

    final analyzer = CompatibilityAnalyzer(context.knowledge);
    final reports = <ProjectReport>[];
    for (final project in workspace.projects) {
      if (project.kind == FlutterProjectKind.dartPackage) continue;
      final current = resolveCurrentFlutterVersion(project,
          environment: environment, knowledge: context.knowledge);
      reports.add(ProjectReport(
        project,
        current,
        analyzer.analyze(project,
            release: current?.release, environment: environment),
      ));
    }

    final findings = [for (final r in reports) ...r.findings];
    if (format == OutputFormat.json) {
      writeJson({
        'workspace': {
          'root': workspace.rootPath,
          'layout': workspace.layout,
          'problems': [for (final p in workspace.problems) p.toJson()],
        },
        'projects': [
          for (final report in reports)
            {
              ...report.project.toJson(),
              'currentFlutter': report.current?.toJson(),
            },
        ],
        'environment': environment?.toJson(),
        'findings': [for (final f in findings) f.toJson()],
        'summary': findingSummary(findings),
      });
    } else {
      terminal.line(terminal.bold('Reforge project analysis'));
      terminal.line(terminal.dim(workspace.rootPath));
      if (workspace.layout != 'single') {
        terminal.line(terminal.dim(
            '${workspace.layout == 'melos' ? 'Melos' : 'Pub'} workspace with '
            '${reports.length} Flutter projects'));
      }
      for (final report in reports) {
        renderProject(terminal, report, context.knowledge, verbose: verbose);
      }
      if (environment != null) {
        renderEnvironment(terminal, environment, context);
      }
      renderFindings(terminal, findings, verbose: verbose);
    }
    return ExitCodes.success;
  }
}

final class ProjectReport {
  ProjectReport(this.project, this.current, this.findings);

  final FlutterProject project;
  final CurrentFlutterVersion? current;
  final List<Finding> findings;
}

Map<String, int> findingSummary(List<Finding> findings) => {
      for (final severity in Severity.values)
        severity.name: findings.where((f) => f.severity == severity).length,
    };
