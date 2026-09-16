Pod::Spec.new do |s|
  s.name             = 'modern_share_plugin'
  s.version          = '2.1.0'
  s.summary          = 'A share plugin in the style of current Flutter plugins (fixture).'
  s.homepage         = 'https://example.com/modern_share_plugin'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Example' => 'dev@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'

  s.platform = :osx, '10.15'
  s.swift_version = '5.0'
end
