import 'dart:io';

import 'package:path/path.dart' as p;

import '../environment/process_runner.dart';

/// The Git state relevant to a migration.
final class GitWorkingTree {
  const GitWorkingTree({
    required this.root,
    required this.branch,
    required this.changedPaths,
  });

  /// Absolute path of the repository root.
  final String root;

  final String? branch;

  /// Paths with uncommitted changes (modified, staged, untracked), relative
  /// to the project root. Paths outside the project are omitted.
  final Set<String> changedPaths;
}

/// Git configuration that must never take effect while Reforge inspects a
/// repository: `core.fsmonitor` can run arbitrary commands on `git status`.
const _safeGitConfig = [
  '-c', 'core.fsmonitor=false', //
  '-c', 'core.untrackedCache=false',
];

/// Reads the Git status of the repository containing [projectRoot].
///
/// Returns `null` when the project is not in a Git repository or Git is not
/// available.
Future<GitWorkingTree?> readGitWorkingTree(
    String projectRoot, ProcessRunner runner) async {
  Future<CommandResult> git(List<String> arguments, String workingDirectory) =>
      runner.run(ExternalCommand(
        'git',
        [..._safeGitConfig, ...arguments],
        workingDirectory: workingDirectory,
        environment: const {'GIT_OPTIONAL_LOCKS': '0'},
        timeout: const Duration(seconds: 30),
      ));

  final toplevel = await git(['rev-parse', '--show-toplevel'], projectRoot);
  if (!toplevel.succeeded) return null;
  final root = p.normalize(toplevel.stdout.trim());

  final status = await git(
      ['status', '--porcelain=v1', '-z', '--untracked-files=all'], root);
  if (!status.succeeded) return null;
  final branch = await git(['rev-parse', '--abbrev-ref', 'HEAD'], root);

  final changed = <String>{};
  final entries = status.stdout.split(String.fromCharCode(0));
  for (var i = 0; i < entries.length; i++) {
    final entry = entries[i];
    if (entry.length < 4) continue;
    final code = entry.substring(0, 2);
    final path = entry.substring(3);
    changed.add(path);
    // Renames and copies are followed by the original path.
    if (code.contains('R') || code.contains('C')) i++;
  }

  // Git reports resolved paths (for example /private/var on macOS).
  final normalizedProject =
      p.normalize(Directory(projectRoot).resolveSymbolicLinksSync());
  return GitWorkingTree(
    root: root,
    branch: branch.succeeded ? branch.stdout.trim() : null,
    changedPaths: {
      for (final path in changed)
        if (p.isWithin(normalizedProject, p.join(root, path)))
          p
              .relative(p.join(root, path), from: normalizedProject)
              .replaceAll(r'\', '/'),
    },
  );
}
