import 'package:yaml/yaml.dart';

import '../../common/source.dart';

/// A [SourceRef] for a YAML node in the document at [path].
SourceRef refForNode(String path, YamlNode node) => SourceRef(
      path,
      line: node.span.start.line + 1,
      column: node.span.start.column + 1,
      range: TextRange.fromBounds(node.span.start.offset, node.span.end.offset),
    );
