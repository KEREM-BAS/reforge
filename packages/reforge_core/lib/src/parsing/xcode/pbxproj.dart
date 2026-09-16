import '../../common/source.dart';
import '../parse_diagnostic.dart';

/// A value in an OpenStep-style property list, as used by `project.pbxproj`.
sealed class PbxValue {
  const PbxValue(this.range);

  /// Source range of the value (including quotes for quoted strings).
  final TextRange range;
}

final class PbxString extends PbxValue {
  const PbxString(super.range, this.value, {required this.quoted});

  final String value;
  final bool quoted;

  /// Range of the characters between the quotes (equal to [range] for
  /// unquoted strings).
  TextRange get contentRange =>
      quoted ? TextRange(range.offset + 1, range.length - 2) : range;
}

final class PbxData extends PbxValue {
  const PbxData(super.range, this.hex);

  final String hex;
}

final class PbxArray extends PbxValue {
  const PbxArray(super.range, this.items);

  final List<PbxValue> items;
}

final class PbxEntry {
  const PbxEntry(this.key, this.value);

  final PbxString key;
  final PbxValue value;
}

final class PbxDict extends PbxValue {
  PbxDict(super.range, this.entries);

  final List<PbxEntry> entries;

  late final Map<String, PbxEntry> _byKey = {
    for (final entry in entries) entry.key.value: entry,
  };

  PbxValue? operator [](String key) => _byKey[key]?.value;

  PbxEntry? entry(String key) => _byKey[key];

  String? string(String key) {
    final value = this[key];
    return value is PbxString ? value.value : null;
  }

  PbxDict? dict(String key) {
    final value = this[key];
    return value is PbxDict ? value : null;
  }

  List<String> stringList(String key) {
    final value = this[key];
    if (value is! PbxArray) return const [];
    return value.items.whereType<PbxString>().map((s) => s.value).toList();
  }
}

/// Parses an OpenStep property list with exact source ranges for every value.
PbxValue parseOpenStepPlist(String path, String source) =>
    _PbxParser(path, source).parseDocument();

final class _PbxParser {
  _PbxParser(this.path, this.source) : _lines = LineIndex(source);

  final String path;
  final String source;
  final LineIndex _lines;
  int _pos = 0;

  Never _fail(String message) => throw DocumentParseException(path, message,
      line: _lines.lineOf(_pos < source.length ? _pos : source.length));

  PbxValue parseDocument() {
    if (source.isNotEmpty && source.codeUnitAt(0) == 0xFEFF) _pos = 1;
    _skipTrivia();
    final value = _parseValue();
    _skipTrivia();
    if (_pos != source.length) {
      _fail('Unexpected content after the root value.');
    }
    return value;
  }

  void _skipTrivia() {
    while (_pos < source.length) {
      final c = source.codeUnitAt(_pos);
      if (c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D) {
        _pos++;
      } else if (c == 0x2F && _peek(1) == 0x2A) {
        final end = source.indexOf('*/', _pos + 2);
        if (end == -1) _fail('Unterminated comment.');
        _pos = end + 2;
      } else if (c == 0x2F && _peek(1) == 0x2F) {
        while (_pos < source.length && source.codeUnitAt(_pos) != 0x0A) {
          _pos++;
        }
      } else {
        return;
      }
    }
  }

  int _peek(int ahead) =>
      _pos + ahead < source.length ? source.codeUnitAt(_pos + ahead) : -1;

  PbxValue _parseValue() {
    if (_pos >= source.length) _fail('Unexpected end of file.');
    final c = source.codeUnitAt(_pos);
    switch (c) {
      case 0x7B: // {
        return _parseDict();
      case 0x28: // (
        return _parseArray();
      case 0x22: // "
        return _parseQuoted();
      case 0x3C: // <
        return _parseData();
      default:
        return _parseUnquoted();
    }
  }

  PbxDict _parseDict() {
    final start = _pos;
    _pos++;
    final entries = <PbxEntry>[];
    while (true) {
      _skipTrivia();
      if (_pos >= source.length) _fail('Unterminated dictionary.');
      if (source.codeUnitAt(_pos) == 0x7D) {
        _pos++;
        return PbxDict(TextRange.fromBounds(start, _pos), entries);
      }
      final key = _parseValue();
      if (key is! PbxString) _fail('Dictionary keys must be strings.');
      _skipTrivia();
      if (_pos >= source.length || source.codeUnitAt(_pos) != 0x3D) {
        _fail('Expected "=" after key "${key.value}".');
      }
      _pos++;
      _skipTrivia();
      final value = _parseValue();
      _skipTrivia();
      if (_pos >= source.length || source.codeUnitAt(_pos) != 0x3B) {
        _fail('Expected ";" after value of "${key.value}".');
      }
      _pos++;
      entries.add(PbxEntry(key, value));
    }
  }

  PbxArray _parseArray() {
    final start = _pos;
    _pos++;
    final items = <PbxValue>[];
    while (true) {
      _skipTrivia();
      if (_pos >= source.length) _fail('Unterminated array.');
      if (source.codeUnitAt(_pos) == 0x29) {
        _pos++;
        return PbxArray(TextRange.fromBounds(start, _pos), items);
      }
      items.add(_parseValue());
      _skipTrivia();
      if (_pos < source.length && source.codeUnitAt(_pos) == 0x2C) {
        _pos++;
      } else if (_pos < source.length && source.codeUnitAt(_pos) != 0x29) {
        _fail('Expected "," or ")" in array.');
      }
    }
  }

  PbxString _parseQuoted() {
    final start = _pos;
    _pos++;
    final buffer = StringBuffer();
    while (true) {
      if (_pos >= source.length) _fail('Unterminated string.');
      final c = source.codeUnitAt(_pos);
      if (c == 0x22) {
        _pos++;
        return PbxString(TextRange.fromBounds(start, _pos), buffer.toString(),
            quoted: true);
      }
      if (c == 0x5C && _pos + 1 < source.length) {
        final next = source.codeUnitAt(_pos + 1);
        switch (next) {
          case 0x6E:
            buffer.write('\n');
          case 0x74:
            buffer.write('\t');
          case 0x72:
            buffer.write('\r');
          case 0x55: // \U####
            final hex = _pos + 6 <= source.length
                ? source.substring(_pos + 2, _pos + 6)
                : '';
            final code = int.tryParse(hex, radix: 16);
            if (code != null) {
              buffer.writeCharCode(code);
              _pos += 6;
              continue;
            }
            buffer.write('U');
          default:
            buffer.writeCharCode(next);
        }
        _pos += 2;
        continue;
      }
      buffer.writeCharCode(c);
      _pos++;
    }
  }

  PbxData _parseData() {
    final start = _pos;
    final end = source.indexOf('>', _pos);
    if (end == -1) _fail('Unterminated data value.');
    _pos = end + 1;
    return PbxData(TextRange.fromBounds(start, _pos),
        source.substring(start + 1, end).replaceAll(RegExp(r'\s'), ''));
  }

  PbxString _parseUnquoted() {
    final start = _pos;
    while (_pos < source.length && _isUnquotedChar(source.codeUnitAt(_pos))) {
      _pos++;
    }
    if (_pos == start) {
      _fail(
          'Unexpected character "${String.fromCharCode(source.codeUnitAt(_pos))}".');
    }
    return PbxString(
        TextRange.fromBounds(start, _pos), source.substring(start, _pos),
        quoted: false);
  }

  static bool _isUnquotedChar(int c) =>
      (c >= 0x30 && c <= 0x39) ||
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      c == 0x5F ||
      c == 0x24 ||
      c == 0x2B ||
      c == 0x2F ||
      c == 0x3A ||
      c == 0x2E ||
      c == 0x2D ||
      c == 0x40;
}

/// A build configuration (`XCBuildConfiguration`) with its settings.
final class XcodeBuildConfiguration {
  const XcodeBuildConfiguration(this.id, this.name, this.buildSettings);

  final String id;

  /// `Debug`, `Release`, `Profile`, ...
  final String name;

  final PbxDict? buildSettings;

  PbxString? setting(String key) {
    final value = buildSettings?[key];
    return value is PbxString ? value : null;
  }
}

/// A native target (`PBXNativeTarget`).
final class XcodeTarget {
  const XcodeTarget(this.id, this.name, this.productType, this.configurations);

  final String id;
  final String name;

  /// For example `com.apple.product-type.application` or
  /// `com.apple.product-type.app-extension`.
  final String? productType;

  final List<XcodeBuildConfiguration> configurations;

  bool get isApplication => productType == 'com.apple.product-type.application';
}

/// A Swift package referenced by the project.
final class XcodeSwiftPackageReference {
  const XcodeSwiftPackageReference(
      {required this.isLocal, required this.location});

  final bool isLocal;

  /// Relative path for local packages, repository URL for remote packages.
  final String location;
}

/// The facts Reforge needs from an Xcode `project.pbxproj`.
final class XcodeProject {
  const XcodeProject({
    required this.path,
    required this.projectConfigurations,
    required this.targets,
    required this.swiftPackageReferences,
    required this.swiftPackageProductNames,
    required this.objectVersion,
  });

  factory XcodeProject.parse(String path, String source) {
    final root = parseOpenStepPlist(path, source);
    if (root is! PbxDict) {
      throw DocumentParseException(
          path, 'The project root is not a dictionary.');
    }
    final objects = root.dict('objects');
    if (objects == null) {
      throw DocumentParseException(path, 'The project has no "objects".');
    }

    PbxDict? object(String id) => objects.dict(id);

    List<XcodeBuildConfiguration> configurationsOf(String? listId) {
      if (listId == null) return const [];
      final list = object(listId);
      if (list == null) return const [];
      return [
        for (final id in list.stringList('buildConfigurations'))
          if (object(id) case final config?)
            XcodeBuildConfiguration(
                id, config.string('name') ?? id, config.dict('buildSettings')),
      ];
    }

    final targets = <XcodeTarget>[];
    List<XcodeBuildConfiguration> projectConfigurations = const [];
    final packageReferences = <XcodeSwiftPackageReference>[];
    final productNames = <String>[];

    for (final entry in objects.entries) {
      final value = entry.value;
      if (value is! PbxDict) continue;
      switch (value.string('isa')) {
        case 'PBXNativeTarget':
          targets.add(XcodeTarget(
            entry.key.value,
            value.string('name') ?? entry.key.value,
            value.string('productType'),
            configurationsOf(value.string('buildConfigurationList')),
          ));
        case 'PBXProject':
          projectConfigurations =
              configurationsOf(value.string('buildConfigurationList'));
        case 'XCLocalSwiftPackageReference':
          packageReferences.add(XcodeSwiftPackageReference(
              isLocal: true, location: value.string('relativePath') ?? ''));
        case 'XCRemoteSwiftPackageReference':
          packageReferences.add(XcodeSwiftPackageReference(
              isLocal: false, location: value.string('repositoryURL') ?? ''));
        case 'XCSwiftPackageProductDependency':
          final name = value.string('productName');
          if (name != null) productNames.add(name);
      }
    }

    return XcodeProject(
      path: path,
      projectConfigurations: projectConfigurations,
      targets: targets,
      swiftPackageReferences: packageReferences,
      swiftPackageProductNames: productNames,
      objectVersion: root.string('objectVersion'),
    );
  }

  final String path;

  /// Project-level build configurations (inherited by every target).
  final List<XcodeBuildConfiguration> projectConfigurations;

  final List<XcodeTarget> targets;
  final List<XcodeSwiftPackageReference> swiftPackageReferences;
  final List<String> swiftPackageProductNames;
  final String? objectVersion;

  XcodeTarget? target(String name) =>
      targets.where((t) => t.name == name).firstOrNull;

  /// Whether Flutter's Swift Package Manager integration is wired into the
  /// project (`FlutterGeneratedPluginSwiftPackage`).
  bool get usesFlutterSwiftPackage =>
      swiftPackageProductNames.contains('FlutterGeneratedPluginSwiftPackage');
}
