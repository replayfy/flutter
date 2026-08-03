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
flutter pub add replayfy
```

Or add it to your `pubspec.yaml`:

```yaml
dependencies:
  replayfy: ^0.0.1
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
    projectKey: 'rpl_pk_xxx',
    ingestUrl: 'https://us.replayfy.app',
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
| `projectKey` | `String` | — (required) | Your project API key from the dashboard. |
| `ingestUrl` | `String` | — (required) | Your Replayfy ingest host, e.g. `https://us.replayfy.app`. |
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

### Runtime configuration

```dart
await Replay.setAutomaticScreenNameTagging(true);
await Replay.setMultiSessionRecord(true);
await Replay.allowShortBreakForAnotherApp(true);
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

- Docs: https://replayfy.app
- Dashboard: https://replayfy.app
