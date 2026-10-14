# Changelog

## 0.0.9

- Frames are captured only while the app is on screen. The Dart capturer's
  timer kept running in the background, rendering and encoding a frame of a
  screen nobody could see every 500 ms until the system suspended or froze
  the app. It now stops when the app goes to the background (Flutter's
  `hidden`, `paused` or `detached`), restarts when the app comes back, and
  doesn't start before a frame with the app in it has been laid out.
  `Replay.stop()` leaves it running while the app is on screen, as before.
  Capture follows the lifecycle events the host sends, as Flutter's own
  rendering does: an add-to-app host that turns off the engine's lifecycle
  dispatch must send them itself.
- Android: the future `stopApplicationAndUploadData` returns now completes
  once the session's data has been sent, or after 5 s, so awaiting it before
  the process exits (a forced logout, say) keeps that data. It used to
  complete at once, with the uploads still under way. The wait doesn't hold
  the main thread, but code that awaits it waits too: up to 5 s when the
  device is offline. On iOS it still completes at once.
- Android: requires the native SDK `app.replayfy:android-sdk` 0.0.6. It
  fixes, for Flutter apps on Android:
  - playback that flashed between two kinds of frame: the native SDK
    restarted its own screenshots after a background, so the recording mixed
    the Dart capturer's frames with native screenshots of the Flutter surface
    (often black);
  - a crash (`Detected multithreaded access to SnapshotStateObserver`) in
    apps that show a Jetpack Compose screen, from the native screenshot
    fallback drawing views off the main thread;
  - frames and events lost when the app goes to the background (everything
    buffered, Flutter's frames included, is uploaded then, and an upload that
    fails stays queued and goes out on return);
  - a permission dialog or another Activity in front treated as the app
    going to the background;
  - native screenshots taken after the first background, `resumeRecording`
    or leaving an excluded screen, alongside the Dart capturer's frames and
    without their `ReplayMask` occlusion;
  - frames reported while the app is in the background being recorded;
  - excluded screens and `pauseRecording` not applying to Flutter's frames,
    and not holding across the background, a session rotation or a screen
    rotation;
  - `stop`, `pauseRecording` and `resumeRecording` not sending everything
    captured before them, a session end that never reached the server being
    lost (it is now kept on disk and sent on the next launch), and a message
    larger than the batch cap holding up the queue;
  - each session's upload, screenshot and frame-decode threads outliving it:
    every new session (after a long background, or `startNewSession`) left
    about three idle threads behind for the life of the process;
  - sessions reporting the native SDK as version 2.0.0, whatever its real
    version.
- iOS: requires the native SDK `Replayfy` 0.0.6 or later (CocoaPods and Swift
  Package Manager). It drops the frames a Flutter app reports while it is in
  the background, where the SDK's background task keeps it running: they
  recorded a screen nobody could see and delayed the session's last upload,
  and its end.
- iOS (CocoaPods): the plugin pod declares the MIT license, matching
  `LICENSE` (it declared BSD-3-Clause).

To update an existing app, run `flutter pub upgrade replayfy_flutter`. On
Android, the next Gradle build resolves the new native SDK from Maven
Central. On iOS, run `cd ios && pod update Replayfy --repo-update`
(CocoaPods; a plain `pod install` keeps the version in `Podfile.lock`), or
let Xcode resolve the new package version (Swift Package Manager). Then ship
a new build.

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
