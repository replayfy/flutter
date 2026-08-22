# Replayfy for Flutter

> Session replay, product analytics & error monitoring for your Flutter apps — iOS and Android.

Replayfy records what your users actually experience — every screen, tap, and
error — so you can see how your product is really used, understand drop-off,
and fix bugs from a real reproduction instead of a guess.

## Features

- **Session replay** — pixel-accurate playback of real user sessions on iOS and Android.
- **Product analytics** — funnels, custom events, and user journeys from `identify` and `track`.
- **Error & crash monitoring** — automatic capture of unhandled errors and crashes, plus manual `captureException`.
- **Automatic capture** — screens, taps, network requests, console output, performance vitals, and device info, out of the box.
- **Privacy-first masking** — blur, cover, or pixelate any sensitive widget; mask all inputs with one flag; nothing sensitive leaves the device.
- **Remote configuration** — tune capture from the dashboard without shipping a new build.
- **GDPR-ready** — a persistent per-user opt-out kill switch.

## Install

```sh
flutter pub add replayfy_flutter
```

Or add it to your `pubspec.yaml`:

```yaml
dependencies:
  replayfy_flutter: ^0.0.7
```

### Android (JitPack)

The native Android recording engine is distributed through JitPack. Add its
repository to your app's `android/settings.gradle` so Gradle can resolve the
transitive native SDK:

```gradle
dependencyResolutionManagement {
  repositories {
    google()
    mavenCentral()
    maven { url 'https://jitpack.io' }
  }
}
```

## Quick start

Start Replayfy as early as possible — ideally inside `Replay.runZoned` so
console output and uncaught async errors are captured too:

```dart
import 'package:flutter/widgets.dart';
import 'package:replayfy_flutter/replayfy_flutter.dart';

void main() => Replay.runZoned(() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Replay.start(const ReplayConfig(
    apiKey: 'rpl_pk_xxx',
    apiHost: 'https://us.replayfy.app',
  ));

  runApp(const MyApp());
});
```

To enable session replay, use the provided app builder so Replayfy can capture
each frame:

```dart
MaterialApp(
  builder: Replay.appBuilder,
  navigatorObservers: [ReplayNavigatorObserver()], // auto-tags screens
  home: const HomePage(),
);
```

## Configuration

Every option on `ReplayConfig`:

| Option | Type | Default | Description |
|---|---|---|---|
| `apiKey` | `String` | — (required) | Your project API key from the dashboard. |
| `apiHost` | `String` | — (required) | Your Replayfy ingest host, e.g. `https://us.replayfy.app`. |
| `distinctId` | `String?` | `null` | Known user id at start; otherwise an install-stable anonymous id is used. |
| `recordScreen` | `bool` | `true` | Capture screen frames for replay. |
| `recordNetwork` | `bool` | `true` | Capture network requests and responses. |
| `recordConsole` | `bool` | `true` | Capture console output (`print` / `debugPrint`). Requires `Replay.runZoned`. |
| `recordErrors` | `bool` | `true` | Capture unhandled errors and crashes. |
| `recordPerformance` | `bool` | `true` | Capture performance vitals (cold start, frame drops, memory, thermal, battery). |
| `maskAllInputs` | `bool` | `false` | Automatically mask every text input. |
| `autoScreenName` | `bool` | `true` | Automatically tag screens from the navigator. |
| `useRemoteConfig` | `bool` | `true` | Let the dashboard override capture settings remotely. |
| `debug` | `bool` | `false` | Verbose SDK logging. |

## API

All methods are static on `Replay`. Most return `Future<void>`.

### Lifecycle

```dart
await Replay.start(config);       // boot the SDK and start recording
await Replay.stop();              // stop and finalize the session
await Replay.pauseRecording();    // pause capture without ending the session
await Replay.resumeRecording();   // resume after a pause
await Replay.startNewSession();   // end the current session, begin a fresh one
await Replay.cancelSession();     // discard the in-flight session without uploading

final recording = await Replay.isRecording();       // bool
final sessionId = await Replay.currentSessionId();   // String?
```

**`Replay.flush()` equivalent** — force-upload everything immediately (e.g. right before a forced logout):

```dart
await Replay.stopApplicationAndUploadData();
```

### Identify a user

```dart
await Replay.identify('user_123', properties: {
  'email': 'ada@example.com',
  'plan': 'pro',
});
```

### Track an event

```dart
await Replay.track('checkout_completed', properties: {
  'value': 49.0,
  'currency': 'USD',
});
```

### Capture an exception

```dart
try {
  await risky();
} catch (e, stack) {
  await Replay.captureException(e, stackTrace: stack); // handled: true by default
}
```

### Track a text input

Flutter manages its own text widgets, so record a field's value from its
callback. Pass `masked: true` for sensitive fields — the value is dropped to
`"***"` and never leaves the device:

```dart
TextField(onSubmitted: (v) => Replay.trackInput('Email', v));
TextField(
  obscureText: true,
  onSubmitted: (v) => Replay.trackInput('Password', v, masked: true),
);
```

### Screens, tags & properties

```dart
await Replay.tagScreenName('Checkout');
await Replay.addTagWithProperties('promo_shown', properties: {'variant': 'B'});
await Replay.setUserProperty('plan', 'pro');       // sticks to the user
await Replay.setSessionProperty('experiment', 'A'); // this session only
await Replay.setMetadata('build_channel', 'beta');
await Replay.markSessionAsFavorite();
await Replay.reportBugEvent('Broken layout', description: 'Overflow on the cart row');
await Replay.log('order placed', level: 'info');    // into the console timeline
```

### Exclude a screen

Stop capturing **frames** for a screen by name. While an excluded screen is in
the foreground the periodic screenshot capture pauses — taps, network, console,
and performance events keep flowing — and it resumes on the next non-excluded
screen. Names are matched case-insensitively against the tagged (or auto-tagged)
screen name.

```dart
await Replay.excludeScreen('Checkout');                  // stop capturing frames of this screen
await Replay.unexcludeScreen('Checkout');                // resume capturing it
await Replay.setExcludedScreens(['Checkout', 'Card']);   // replace the whole exclusion list
```

This is distinct from `occludeSensitiveScreen` (below), which keeps recording
the screen but blanks the frame — exclusion captures no frames of that screen at
all.

### Runtime configuration

```dart
await Replay.setAutomaticScreenNameTagging(true);
await Replay.enableAdvancedGestureRecognizer(true); // also capture pinch + rotate (default off)
await Replay.setMultiSessionRecord(true);           // many sessions per launch (default); false = one, then no more this launch
await Replay.allowShortBreakForAnotherApp(true, breakWindowMs: 30000); // a switch away shorter than the window keeps the session; longer starts a fresh one
await Replay.setAppVersion('1.4.0', build: '204');
await Replay.setPushNotificationToken(token, platform: 'fcm');
```

### Deep links

```dart
final sessionUrl = await Replay.urlForCurrentSession(); // String?
final userUrl = await Replay.urlForCurrentUser();       // String?
```

## Privacy & masking

Replayfy is built to keep sensitive data off the wire.

**Mask a widget** — wrap anything sensitive; it is blurred (default), covered,
or pixelated in the recording:

```dart
ReplayMask(
  maskStyle: ReplayMaskStyle.blur, // .blur | .overlay | .pixelate
  child: Text('•••• •••• •••• 4242'),
);
```

**Set the global mask style** for bulk-occluded and whole-screen regions:

```dart
await Replay.setMaskStyle(ReplayMaskStyle.pixelate);
```

**Bulk & whole-screen masking:**

```dart
await Replay.occludeAllTextFields(true);      // all text fields
await Replay.occludeAllTextView(true);        // all multi-line text views
await Replay.occludeSensitiveScreen(true);    // the entire screen
```

Or mask every input from the start with `maskAllInputs: true` in `ReplayConfig`.

**GDPR opt-out** — a persistent kill switch that survives relaunches:

```dart
await Replay.optOut(true);                 // stop all recording
await Replay.optIn();                       // resume (same as optOut(false))
final out = await Replay.isOptedOut();      // bool
```

## Links

- Docs: https://docs.replayfy.app/platforms/flutter
- Dashboard: https://app.replayfy.app

## Native SDK distribution & build troubleshooting

`replayfy_flutter` is a thin plugin over the native Replayfy SDKs, pulled at
build time:

- **Android** → `app.replayfy:android-sdk` from **Maven Central** (primary;
  JitPack `com.github.replayfy:android-sdk` is a fallback).
- **iOS** → the **`Replayfy`** pod from **CocoaPods trunk** (the Flutter default).

### iOS: use CocoaPods, not Swift Package Manager

Flutter's iOS integration uses **CocoaPods by default**, which pulls a published
pod — reliable. Do **not** enable Flutter's SwiftPM integration for this plugin:
Xcode's SwiftPM resolves the iOS SDK by doing a live `git ls-remote --tags`,
which frequently fails in Xcode with `Couldn't get the list of tags` (Xcode uses
its own git/cache/credentials, and GitHub rate-limits unauthenticated tag
listing) even when the repo is reachable from your shell. If it's already on:

```bash
flutter config --no-enable-swift-package-manager
flutter clean && cd ios && pod install --repo-update
```

### Fixing the two common build failures

**Android — `No route to host` fetching from `jitpack.io`:** your build host
can't reach JitPack (corporate/CI firewall, proxy, or IPv6). Maven Central
(now the primary channel) avoids this. If a build still hits JitPack:
- confirm reachability on the *build host*: `curl -I https://jitpack.io`
- behind a proxy → set `systemProp.https.proxyHost/proxyPort` in `gradle.properties`
- IPv6 issue → `org.gradle.jvmargs=-Djava.net.preferIPv4Stack=true`

**iOS — `Couldn't get the list of tags` resolving a Swift package:** you're on
the SwiftPM path — switch to CocoaPods (above). If you must stay on SwiftPM,
prime the cache with the shell git that works, or clear the SPM cache:

```bash
cd ios && xcodebuild -resolvePackageDependencies
# or
rm -rf ~/Library/Caches/org.swift.swiftpm ~/Library/Developer/Xcode/DerivedData
```
