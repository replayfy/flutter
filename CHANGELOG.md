# Changelog

## 0.0.8

- iOS: requires the native SDK `Replayfy` 0.0.5 or later (CocoaPods and Swift
  Package Manager). It fixes, for Flutter apps on iOS:
  - frames and events lost when the app goes to the background (uploads now
    finish under a background task, and leftovers are sent on return);
  - native, unmasked screenshots taken after the first background or after
    leaving an excluded screen (a Flutter app's frames come only from the
    Dart capturer, with its `ReplayMask` occlusion);
  - excluded screens and `pauseRecording` not holding across foregrounding or
    a session rotation, and not applying to Flutter's own frames.
- iOS (CocoaPods): the plugin pod is now a static framework, like the
  `Replayfy` pod it depends on. `pod install` failed with "transitive
  dependencies that include statically linked binaries" in any app whose
  Podfile uses `use_frameworks!`, which is Flutter's default.
- The example app wraps `MaterialApp` with `builder: Replay.appBuilder`, as the
  README says; without it no frames are captured.

To update an existing app, run `flutter pub upgrade replayfy_flutter`, then
`cd ios && pod update Replayfy --repo-update` (CocoaPods; a plain
`pod install` keeps the version in `Podfile.lock`), or let Xcode resolve the
new package version (Swift Package Manager), then ship a new build.

## 0.0.7

- Wire the mobile engine stubs + screen exclusion through the plugin:
  `excludeScreen` / `unexcludeScreen` / `setExcludedScreens` and
  `enableAdvancedGestureRecognizer`, plus the short-break window
  (`breakWindowMs`) on `allowShortBreakForAnotherApp`. Bundles native
  Android SDK 0.0.4.

## 0.0.6

- Android: the bundled native SDK now resolves from Maven Central
  (`app.replayfy:android-sdk:0.0.3`) as the primary source, with JitPack kept as
  a fallback. Fixes Gradle `No route to host` failures on networks that can't
  reach jitpack.io, and removes the need to add the JitPack repository to your
  app's `android/settings.gradle`.

## 0.0.5

- **Breaking:** renamed `ReplayConfig.projectKey` -> `apiKey` and `ingestUrl` ->
  `apiHost` to match the other Replayfy SDKs. Update your `ReplayConfig(apiKey:,
  apiHost:)`.

## 0.0.4

- Relicensed under BSD-3-Clause (was MIT).

## 0.0.2

- Fix native SDK resolution for published builds. The iOS plugin now depends on
  the `Replayfy` CocoaPods pod, and the Android plugin on
  `com.github.replayfy:android-sdk` via JitPack — previously both were wired to a
  local development name/path (`Replay` pod / `com.replayfy:android-sdk` from
  `mavenLocal`) that could not resolve for consumers.

## 0.0.1

- Initial release of Replayfy for Flutter.
- Session replay for iOS and Android with automatic capture of screens, taps,
  network requests, console output, performance vitals, and device info.
- Product analytics: `identify`, `track`, screen tagging, and user/session properties.
- Error and crash monitoring, including manual `captureException`.
- Privacy masking: `ReplayMask` widget (blur / overlay / pixelate), bulk and
  whole-screen occlusion, mask-all-inputs, and a persistent GDPR opt-out.
