# Changelog

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
