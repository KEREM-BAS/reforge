import 'dart:io';

/// Writes human-readable output: consistent symbols, indentation and optional
/// color. Color is used for emphasis only; meaning never depends on it.
final class Terminal {
  Terminal(this._sink, {required this.color, required this.unicode});

  /// A terminal for [stdout] honoring `NO_COLOR` and TTY detection.
  factory Terminal.stdout({bool? color}) {
    final noColor = Platform.environment.containsKey('NO_COLOR');
    final supportsAnsi = stdout.hasTerminal && stdout.supportsAnsiEscapes;
    return Terminal(
      stdout,
      color: color ?? (supportsAnsi && !noColor),
      unicode: !Platform.isWindows || supportsAnsi,
    );
  }

  final StringSink _sink;
  final bool color;
  final bool unicode;

  String get ok => unicode ? '✓' : '+';
  String get fail => unicode ? '✗' : 'x';
  String get warn => '!';
  String get info => unicode ? '•' : '-';
  String get arrow => unicode ? '→' : '->';
  String get dot => unicode ? '·' : '-';

  String _wrap(String code, String text) =>
      color ? '\x1B[${code}m$text\x1B[0m' : text;

  String bold(String text) => _wrap('1', text);
  String dim(String text) => _wrap('2', text);
  String red(String text) => _wrap('31', text);
  String green(String text) => _wrap('32', text);
  String yellow(String text) => _wrap('33', text);
  String cyan(String text) => _wrap('36', text);

  void line([String text = '']) => _sink.writeln(text);

  void write(String text) => _sink.write(text);

  /// Writes `label` padded to [width] followed by [value], indented.
  void field(String label, String value, {int indent = 4, int width = 12}) {
    line('${' ' * indent}${label.padRight(width)} $value');
  }

  void heading(String text) {
    line();
    line(bold(text));
  }

  /// Writes [text] wrapped to [width] columns with a hanging [indent].
  void paragraph(String text, {int indent = 4, int width = 80}) {
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty);
    final prefix = ' ' * indent;
    var current = StringBuffer(prefix);
    var length = indent;
    for (final word in words) {
      if (length > indent && length + 1 + word.length > width) {
        line(current.toString());
        current = StringBuffer(prefix);
        length = indent;
      }
      if (length > indent) {
        current.write(' ');
        length++;
      }
      current.write(word);
      length += word.length;
    }
    if (length > indent) line(current.toString());
  }
}
