import 'package:xml/xml_events.dart';

import '../../common/source.dart';
import '../parse_diagnostic.dart';

/// An attribute of an XML start tag with exact source ranges.
final class LocatedXmlAttribute {
  const LocatedXmlAttribute({
    required this.name,
    required this.value,
    required this.range,
    required this.leadingWhitespaceStart,
  });

  /// Qualified name, e.g. `package` or `android:name`.
  final String name;

  /// Decoded value.
  final String value;

  /// Range of `name="value"`.
  final TextRange range;

  /// Offset where the whitespace preceding the attribute begins. Deleting
  /// `[leadingWhitespaceStart, range.end)` removes the attribute cleanly.
  final int leadingWhitespaceStart;
}

/// The facts Reforge needs from an `AndroidManifest.xml`.
final class AndroidManifest {
  const AndroidManifest({
    required this.path,
    required this.manifestTagRange,
    required this.attributes,
    required this.applicationName,
  });

  /// Parses [source], throwing [DocumentParseException] for malformed XML.
  factory AndroidManifest.parse(String path, String source) {
    final Iterable<XmlEvent> events;
    try {
      events = parseEvents(source, withLocation: true, validateNesting: true)
          .toList();
    } on Exception catch (e) {
      throw DocumentParseException(path, 'Malformed XML: $e');
    }

    XmlStartElementEvent? manifest;
    String? applicationName;
    for (final event in events) {
      if (event is XmlStartElementEvent) {
        if (manifest == null) {
          if (event.name != 'manifest') {
            throw DocumentParseException(
                path, 'The root element is <${event.name}>, not <manifest>.');
          }
          manifest = event;
        } else if (event.name == 'application') {
          applicationName = event.attributes
              .where((a) => a.name == 'android:name')
              .map((a) => a.value)
              .firstOrNull;
        }
      }
    }
    if (manifest == null) {
      throw DocumentParseException(path, 'No <manifest> element found.');
    }
    final tagRange = TextRange.fromBounds(manifest.start!, manifest.stop!);
    return AndroidManifest(
      path: path,
      manifestTagRange: tagRange,
      attributes: _locateAttributes(source, tagRange),
      applicationName: applicationName,
    );
  }

  final String path;

  /// Range of the `<manifest ...>` start tag.
  final TextRange manifestTagRange;

  /// Attributes of the `<manifest>` element with their source ranges.
  final List<LocatedXmlAttribute> attributes;

  /// `android:name` of `<application>`, if any.
  final String? applicationName;

  LocatedXmlAttribute? attribute(String name) =>
      attributes.where((a) => a.name == name).firstOrNull;

  /// The legacy `package` attribute (the application namespace before AGP 8).
  String? get packageAttribute => attribute('package')?.value;
}

/// Scans the attributes of a start tag whose exact range is known from the XML
/// parser. Restricting the scan to the tag produced by a real XML parser keeps
/// this safe: quotes and entities are handled, and nothing outside the tag is
/// considered.
List<LocatedXmlAttribute> _locateAttributes(String source, TextRange tag) {
  final attributes = <LocatedXmlAttribute>[];
  var i = tag.offset + 1; // skip '<'
  bool isNameChar(int c) =>
      (c >= 0x41 && c <= 0x5A) ||
      (c >= 0x61 && c <= 0x7A) ||
      (c >= 0x30 && c <= 0x39) ||
      c == 0x3A ||
      c == 0x5F ||
      c == 0x2D ||
      c == 0x2E;
  bool isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

  // Element name.
  while (i < tag.end && isNameChar(source.codeUnitAt(i))) {
    i++;
  }
  while (i < tag.end) {
    final whitespaceStart = i;
    while (i < tag.end && isSpace(source.codeUnitAt(i))) {
      i++;
    }
    if (i >= tag.end) break;
    final c = source.codeUnitAt(i);
    if (c == 0x3E /* > */ || c == 0x2F /* / */) break;
    final nameStart = i;
    while (i < tag.end && isNameChar(source.codeUnitAt(i))) {
      i++;
    }
    final name = source.substring(nameStart, i);
    while (i < tag.end && isSpace(source.codeUnitAt(i))) {
      i++;
    }
    if (i >= tag.end || source.codeUnitAt(i) != 0x3D /* = */) break;
    i++;
    while (i < tag.end && isSpace(source.codeUnitAt(i))) {
      i++;
    }
    if (i >= tag.end) break;
    final quote = source.codeUnitAt(i);
    if (quote != 0x22 && quote != 0x27) break;
    final valueStart = i + 1;
    final valueEnd = source.indexOf(String.fromCharCode(quote), valueStart);
    if (valueEnd == -1 || valueEnd >= tag.end) break;
    i = valueEnd + 1;
    attributes.add(LocatedXmlAttribute(
      name: name,
      value: _decodeEntities(source.substring(valueStart, valueEnd)),
      range: TextRange.fromBounds(nameStart, i),
      leadingWhitespaceStart: whitespaceStart,
    ));
  }
  return attributes;
}

String _decodeEntities(String value) => value
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&amp;', '&');
