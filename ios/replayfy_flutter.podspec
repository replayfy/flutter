Pod::Spec.new do |s|
  s.name             = 'replayfy_flutter'
  s.version          = '0.0.1'
  s.summary          = 'Replayfy session replay & analytics for Flutter (iOS).'
  s.description      = 'Thin Flutter plugin over the native Replayfy iOS SDK.'
  s.homepage         = 'https://replayfy.io'
  s.license          = { :type => 'Commercial' }
  s.authors          = { 'Nasirudeen Olohundare' => 'iamnasirudeen@gmail.com' }
  s.source           = { :path => '.' }

  # Sources live under the Swift Package layout so the podspec and Package.swift
  # build the same files.
  s.source_files     = 'replayfy_flutter/Sources/replayfy_flutter/**/*.swift'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'

  # The Flutter engine (platform channels) + the native iOS SDK that does the
  # real recording. For local development the example app points `Replay` at
  # the sibling SDK checkout via a :path pod entry in its Podfile.
  s.dependency 'Flutter'
  s.dependency 'Replay'

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
