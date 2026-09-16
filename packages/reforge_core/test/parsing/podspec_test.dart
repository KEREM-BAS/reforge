import 'package:reforge_core/src/parsing/ruby/podspec.dart';
import 'package:test/test.dart';

Map<String, String?> platforms(String body) => {
      for (final platform
          in Podspec.parse('a.podspec', 'Pod::Spec.new do |spec|\n$body\nend\n')
              .platforms
              .values)
        platform.name: platform.version,
    };

void main() {
  test('platform declarations', () {
    expect(platforms("  spec.platform = :ios, '12.0'"), {'ios': '12.0'});
    expect(platforms('  spec.platform = :ios'), {'ios': null});
    expect(
        platforms("  spec.ios.deployment_target = '13.0'\n"
            "  spec.osx.deployment_target = '10.14'"),
        {'ios': '13.0', 'osx': '10.14'});
    expect(platforms("  spec.platforms = { :ios => '11.0', :osx => '10.11' }"),
        {'ios': '11.0', 'osx': '10.11'});
    expect(platforms("  spec.platforms = { ios: '14.0' }"), {'ios': '14.0'});
  });

  test('computed values are not evaluated', () {
    expect(platforms('  spec.ios.deployment_target = MINIMUM'), isEmpty);
    final broken = Podspec.parse('a.podspec', 'Pod::Spec.new do |s|\n');
    expect(broken.isReliable, isFalse);
  });
}
