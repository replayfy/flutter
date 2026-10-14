Pod::Spec.new do |s|
  s.name             = 'replayfy_flutter'
  s.version          = '0.0.9'
  s.summary          = 'Replayfy session replay & analytics for Flutter (iOS).'
  s.description      = 'Thin Flutter plugin over the native Replayfy iOS SDK.'
  s.homepage         = 'https://replayfy.app'
  s.license          = { :type => 'MIT' }
  s.authors          = { 'Nasirudeen Olohundare' => 'iamnasirudeen@gmail.com' }
  s.source           = { :path => '.' }

  # Sources live under the Swift Package layout so the podspec and Package.swift
  # build the same files.
  s.source_files     = 'replayfy_flutter/Sources/replayfy_flutter/**/*.swift'
  s.platform         = :ios, '15.0'
  s.swift_version    = '5.0'

  # The Flutter engine (platform channels) + the native iOS SDK that does the
  # real recording, published to CocoaPods trunk as "Replayfy". For local
  # development the example app overrides it with a :path pod entry in its Podfile.
  s.dependency 'Flutter'
  # Bare Replayfy (Core). Live presence is derived server-side from ingest-batch
  # recency now, so there is no Socket.IO subspec to opt into. 0.0.5 is the
  # first release that keeps frames across background/resume and never takes
  # native (unmasked) screenshots for a Flutter host; 0.0.6 drops the frames a
  # Flutter host reports while the app is in the background.
  s.dependency 'Replayfy', '>= 0.0.6'

  # Replayfy is a static framework (it links PLCrashReporter's static
  # xcframework), and a pod that depends on one must be static too, or a
  # Podfile with `use_frameworks!` (Flutter's default) fails to install.
  s.static_framework = true

  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
