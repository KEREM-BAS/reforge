import 'package:reforge_core/src/version/tool_version.dart';
import 'package:test/test.dart';

void main() {
  ToolVersion v(String text) => ToolVersion.parse(text);

  test('parses common toolchain version formats', () {
    expect(v('8.3').components, [8, 3]);
    expect(v('7.6.3').components, [7, 6, 3]);
    expect(v('2.1.0-RC2').qualifier, 'RC2');
    expect(v('9.1.0-rc-1').qualifier, 'rc-1');
    expect(v('17').major, 17);
    expect(v('8.0.0-beta01').isPreRelease, isTrue);
    expect(ToolVersion.tryParse(r'$kotlin_version'), isNull);
    expect(ToolVersion.tryParse(''), isNull);
    expect(ToolVersion.tryParse('latest.release'), isNull);
  });

  test('compares numerically, not lexically', () {
    expect(v('8.10') > v('8.9'), isTrue);
    expect(v('8.10.2') > v('8.10'), isTrue);
    expect(v('1.8.22') < v('1.10.0'), isTrue);
  });

  test('treats missing components as zero', () {
    expect(v('8.0'), v('8.0.0'));
    expect(v('8'), v('8.0.0'));
    expect(v('8.0').hashCode, v('8.0.0').hashCode);
  });

  test('pre-releases sort before releases', () {
    expect(v('9.0.0-rc-1') < v('9.0.0'), isTrue);
    expect(v('9.0.0-alpha01') < v('9.0.0-beta01'), isTrue);
    expect(v('9.0.0-rc-2') > v('9.0.0-rc-1'), isTrue);
    expect(v('2.0.0-RC10') > v('2.0.0-RC9'), isTrue);
    expect(v('9.0.0-rc-1') > v('8.13.0'), isTrue);
  });

  test('qualifier equality ignores case and separators', () {
    expect(v('1.0-rc1'), v('1.0-RC-01'));
    expect(v('1.0-rc1').hashCode, v('1.0-RC-01').hashCode);
  });

  test('preserves the original text', () {
    expect(v('8.3').toString(), '8.3');
    expect(v(' 2.1.0-RC2 ').toString(), '2.1.0-RC2');
    expect(ToolVersion(8, 11, 1).toString(), '8.11.1');
  });
}
