import 'dart:convert';

import 'package:xml/xml_events.dart';
import 'package:yaml/yaml.dart';

import '../parsing/gradle/gradle_script.dart';
import '../parsing/parse_diagnostic.dart';
import '../parsing/ruby/podfile.dart';
import '../parsing/xcode/pbxproj.dart';

/// Checks that an edited file is still well-formed.
///
/// Returns `null` when the content is valid, otherwise a description of the
/// problem. Reforge never plans or applies an edit that produces a file it
/// cannot parse.
String? validateEditedFile(String path, String content) {
  final name = path.split('/').last;
  try {
    if (name.endsWith('.gradle') || name.endsWith('.gradle.kts')) {
      final script = GradleScript.parse(path, content);
      return script.isReliable
          ? null
          : 'Gradle script no longer parses: ${script.diagnostics.first.message}';
    }
    if (name == 'Podfile') {
      final podfile = Podfile.parse(path, content);
      return podfile.isReliable
          ? null
          : 'Podfile no longer parses: ${podfile.diagnostics.first.message}';
    }
    if (name.endsWith('.pbxproj')) {
      parseOpenStepPlist(path, content);
      return null;
    }
    if (name.endsWith('.yaml') || name.endsWith('.yml')) {
      loadYaml(content);
      return null;
    }
    if (name.endsWith('.xml') || name.endsWith('.plist')) {
      parseEvents(content, validateNesting: true, validateDocument: true)
          .toList();
      return null;
    }
    if (name.endsWith('.json') || name == '.fvmrc') {
      jsonDecode(content);
      return null;
    }
    return null;
  } on DocumentParseException catch (e) {
    return e.message;
  } on YamlException catch (e) {
    return 'YAML no longer parses: ${e.message}';
  } on FormatException catch (e) {
    return 'Content no longer parses: ${e.message}';
  } on Exception catch (e) {
    return 'Content no longer parses: $e';
  }
}
