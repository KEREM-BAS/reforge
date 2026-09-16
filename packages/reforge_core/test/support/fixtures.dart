import 'dart:io';

import 'package:path/path.dart' as p;

/// The repository root, found by walking up from the current directory.
String repositoryRoot() {
  var directory = Directory.current.absolute;
  while (true) {
    if (Directory(p.join(directory.path, 'fixtures', 'projects'))
        .existsSync()) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Could not locate the Reforge repository root.');
    }
    directory = parent;
  }
}

/// Absolute path of the fixture project [name].
String fixtureProject(String name) =>
    p.join(repositoryRoot(), 'fixtures', 'projects', name);

/// Reads a file from a fixture project.
String readFixture(String project, String relativePath) =>
    File(p.join(fixtureProject(project), relativePath)).readAsStringSync();

/// Copies a fixture project into a fresh temporary directory.
Directory copyFixtureToTemp(String name) {
  final target = Directory.systemTemp.createTempSync('reforge_$name');
  final source = Directory(fixtureProject(name));
  for (final entity in source.listSync(recursive: true, followLinks: false)) {
    final relative = p.relative(entity.path, from: source.path);
    final destination = p.join(target.path, relative);
    if (entity is Directory) {
      Directory(destination).createSync(recursive: true);
    } else if (entity is File) {
      File(destination).parent.createSync(recursive: true);
      entity.copySync(destination);
    }
  }
  return target;
}
