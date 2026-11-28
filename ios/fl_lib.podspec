Pod::Spec.new do |s|
  s.name             = 'fl_lib'
  s.version          = '0.0.1'
  s.summary          = 'Shared Flutter utilities and iOS system bar layout regions.'
  s.homepage         = 'https://github.com/lollipopkit/fl_lib'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'lollipopkit' => 'https://github.com/lollipopkit' }
  s.source           = { :path => '.' }
  s.source_files     = 'fl_lib/Sources/fl_lib/**/*.swift'
  s.dependency 'Flutter'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
