import 'package:meta/meta.dart';

/// A version of a build tool such as Gradle, the Android Gradle Plugin,
/// Kotlin, a JDK or an Xcode deployment target.
///
/// These tools do not follow semantic versioning strictly: `8.3`, `7.6.3`,
/// `1.8.22`, `2.1.0-RC2`, `9.1.0-rc-1` and `17` are all valid. Numeric
/// components are compared numerically, missing components count as zero, and
/// a pre-release qualifier sorts before the corresponding release.
@immutable
final class ToolVersion implements Comparable<ToolVersion> {
  ToolVersion._(this.components, this.qualifier, this._text);

  /// Creates a release version from numeric components.
  factory ToolVersion(int major, [int? minor, int? patch]) {
    final components = List<int>.unmodifiable(
        [major, if (minor != null) minor, if (patch != null) patch]);
    return ToolVersion._(components, null, components.join('.'));
  }

  final List<int> components;
  final String _text;

  /// Pre-release qualifier without the separator, for example `rc-1`.
  final String? qualifier;

  static final RegExp _pattern =
      RegExp(r'^(\d+(?:\.\d+)*)(?:[-.]?([A-Za-z][0-9A-Za-z.\-]*))?$');

  /// Parses [input], returning `null` when it is not a recognizable version.
  static ToolVersion? tryParse(String input) {
    final match = _pattern.firstMatch(input.trim());
    if (match == null) return null;
    final numbers = match.group(1)!.split('.').map(int.parse).toList();
    return ToolVersion._(
        List.unmodifiable(numbers), match.group(2), input.trim());
  }

  static ToolVersion parse(String input) {
    final version = tryParse(input);
    if (version == null) {
      throw FormatException('Not a version: "$input"');
    }
    return version;
  }

  int get major => components[0];
  int get minor => components.length > 1 ? components[1] : 0;
  int get patch => components.length > 2 ? components[2] : 0;

  bool get isPreRelease => qualifier != null;

  @override
  int compareTo(ToolVersion other) {
    final length = components.length > other.components.length
        ? components.length
        : other.components.length;
    for (var i = 0; i < length; i++) {
      final a = i < components.length ? components[i] : 0;
      final b = i < other.components.length ? other.components[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    final q1 = qualifier;
    final q2 = other.qualifier;
    if (q1 == null && q2 == null) return 0;
    if (q1 == null) return 1;
    if (q2 == null) return -1;
    return _compareQualifiers(q1, q2);
  }

  static final RegExp _qualifierToken = RegExp(r'\d+|[A-Za-z]+');

  /// Splits a qualifier into lowercase alphabetic and normalized numeric
  /// tokens, so `RC-01` and `rc1` compare (and hash) equally.
  static List<String> _qualifierTokens(String qualifier) =>
      _qualifierToken.allMatches(qualifier.toLowerCase()).map((m) {
        final token = m.group(0)!;
        final number = int.tryParse(token);
        return number == null ? token : number.toString();
      }).toList();

  static int _compareQualifiers(String a, String b) {
    final listA = _qualifierTokens(a);
    final listB = _qualifierTokens(b);
    for (var i = 0; i < listA.length && i < listB.length; i++) {
      final x = listA[i];
      final y = listB[i];
      final nx = int.tryParse(x);
      final ny = int.tryParse(y);
      final int result;
      if (nx != null && ny != null) {
        result = nx.compareTo(ny);
      } else {
        result = x.compareTo(y);
      }
      if (result != 0) return result;
    }
    return listA.length.compareTo(listB.length);
  }

  bool operator <(ToolVersion other) => compareTo(other) < 0;
  bool operator <=(ToolVersion other) => compareTo(other) <= 0;
  bool operator >(ToolVersion other) => compareTo(other) > 0;
  bool operator >=(ToolVersion other) => compareTo(other) >= 0;

  /// Whether this version has the same major and minor components as [other].
  bool sameMinorLine(ToolVersion other) =>
      major == other.major && minor == other.minor;

  @override
  bool operator ==(Object other) =>
      other is ToolVersion && compareTo(other) == 0;

  @override
  int get hashCode {
    // Trailing zero components do not change equality ("8.0" == "8.0.0").
    var significant = components.length;
    while (significant > 1 && components[significant - 1] == 0) {
      significant--;
    }
    final q = qualifier;
    return Object.hash(
      Object.hashAll(components.take(significant)),
      q == null ? null : Object.hashAll(_qualifierTokens(q)),
    );
  }

  /// The version as written in its source.
  @override
  String toString() => _text;
}
