import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:reforge_core/src/common/errors.dart';
import 'package:reforge_core/src/fs/project_file_system.dart';
import 'package:test/test.dart';

void main() {
  group('normalizeProjectPath', () {
    test('normalizes separators and dots', () {
      expect(normalizeProjectPath(r'android\app\build.gradle'),
          'android/app/build.gradle');
      expect(normalizeProjectPath('./ios/../ios/Podfile'), 'ios/Podfile');
      expect(normalizeProjectPath('.'), '');
    });

    test('rejects paths escaping the project', () {
      expect(() => normalizeProjectPath('../secret'),
          throwsA(isA<InternalException>()));
      expect(() => normalizeProjectPath('/etc/passwd'),
          throwsA(isA<InternalException>()));
      expect(() => normalizeProjectPath('a/../../b'),
          throwsA(isA<InternalException>()));
    });
  });

  group('OverlayFileSystem', () {
    test('reads through to the base and records observations', () {
      final base = MemoryProjectFileSystem({
        'pubspec.yaml': 'name: app\n',
        'android/build.gradle': 'x',
      });
      final overlay = OverlayFileSystem(base);
      expect(overlay.readString('pubspec.yaml'), 'name: app\n');
      expect(overlay.readString('missing.txt'), isNull);
      expect(overlay.observedInputs.keys,
          containsAll(['pubspec.yaml', 'missing.txt']));
      expect(overlay.observedInputs['missing.txt'], isNull);
      expect(overlay.observedInputs['pubspec.yaml'],
          contentHash('name: app\n'));
    });

    test('exposes writes without touching the base', () {
      final base = MemoryProjectFileSystem({'a/b.txt': 'old'});
      final overlay = OverlayFileSystem(base)
        ..writeString('a/b.txt', 'new')
        ..writeString('a/c/d.txt', 'created');
      expect(overlay.readString('a/b.txt'), 'new');
      expect(base.readString('a/b.txt'), 'old');
      expect(overlay.listDirectory('a'), ['a/b.txt', 'a/c']);
      expect(overlay.directoryExists('a/c'), isTrue);
      expect(overlay.changedFiles, {'a/b.txt': 'new', 'a/c/d.txt': 'created'});
    });

    test('writes identical to the base are not changes', () {
      final base = MemoryProjectFileSystem({'f': 'same'});
      final overlay = OverlayFileSystem(base)..writeString('f', 'same');
      expect(overlay.changedFiles, isEmpty);
    });

    test('forks are independent', () {
      final overlay = OverlayFileSystem(MemoryProjectFileSystem({'f': '1'}));
      final fork = overlay.fork()..writeString('f', '2');
      expect(overlay.readString('f'), '1');
      expect(fork.readString('f'), '2');
    });
  });

  group('LocalProjectFileSystem', () {
    late Directory temp;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('reforge_fs_test');
    });

    tearDown(() {
      temp.deleteSync(recursive: true);
    });

    test('reads files and lists directories deterministically', () {
      File(p.join(temp.path, 'b.txt')).writeAsStringSync('b');
      File(p.join(temp.path, 'a.txt')).writeAsStringSync('a');
      Directory(p.join(temp.path, 'dir')).createSync();
      final fs = LocalProjectFileSystem(temp.path);
      expect(fs.readString('a.txt'), 'a');
      expect(fs.readString('nope.txt'), isNull);
      expect(fs.listDirectory(''), ['a.txt', 'b.txt', 'dir']);
      expect(fs.fileExists('a.txt'), isTrue);
      expect(fs.directoryExists('dir'), isTrue);
    });

    test('refuses symbolic links that leave the project', () {
      final outside = Directory.systemTemp.createTempSync('reforge_outside');
      addTearDown(() => outside.deleteSync(recursive: true));
      File(p.join(outside.path, 'secret.txt')).writeAsStringSync('secret');
      Link(p.join(temp.path, 'leak.txt'))
          .createSync(p.join(outside.path, 'secret.txt'));
      final fs = LocalProjectFileSystem(temp.path);
      expect(() => fs.readString('leak.txt'),
          throwsA(isA<FileReadException>()));
    });

    test('follows symbolic links inside the project', () {
      File(p.join(temp.path, 'real.txt')).writeAsStringSync('real');
      Link(p.join(temp.path, 'alias.txt'))
          .createSync(p.join(temp.path, 'real.txt'));
      final fs = LocalProjectFileSystem(temp.path);
      expect(fs.readString('alias.txt'), 'real');
    });

    test('rejects invalid UTF-8', () {
      File(p.join(temp.path, 'bin.dat')).writeAsBytesSync([0xff, 0xfe, 0x00]);
      final fs = LocalProjectFileSystem(temp.path);
      expect(() => fs.readString('bin.dat'),
          throwsA(isA<FileReadException>()));
    });
  });
}
