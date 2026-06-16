# replayfy_flutter

Replayfy session replay & product analytics for Flutter apps (iOS + Android).

This is a thin plugin over the native Replayfy SDKs — the native engines do
the real recording (periodic screenshots, taps, performance vitals, crashes).
The Dart layer contributes the public API, `ReplayConfig`, and the masking
widget.

## Install

```yaml
dependencies:
  replayfy_flutter: ^0.0.1
```

For local development against the SDKs in this monorepo, the example app
points the native dependency at the sibling SDK checkouts (see
`example/ios/Podfile` and `example/android/settings.gradle`).

## Quick start

```dart
import 'package:replayfy_flutter/replayfy_flutter.dart';

await Replay.start(const ReplayConfig(
  projectKey: 'rpl_pk_xxx',
  ingestUrl: 'https://ingest.replayfy.io',
));
```

`start()` boots the native engine, which auto-captures screenshots, taps,
performance, and crashes. No per-screen wiring is required.

## Masking sensitive content

Wrap anything sensitive in a single widget:

```dart
ReplayMask(
  child: Text('•••• •••• •••• 4242'),
)
```

Flutter renders everything into one surface, so there are no per-widget
native views to register (the way the iOS/Android/React Native SDKs do).
Instead the masked region's bounds are tracked on the Dart side and the
native engine **pulls** them at capture rate (~3 fps) right before each
screenshot — the masked region is blurred with a diagonal-stripe overlay,
matching the other SDKs. IPC happens at capture rate, not per frame.

## Text input tracking

Flutter manages its own text widgets, so there's no native field to
auto-observe — call `trackInput` from a field's `onSubmitted` /
`onEditingComplete`. Pass `masked: true` for sensitive fields (the value
is dropped to `"***"` and never leaves the device):

```dart
TextField(
  onSubmitted: (v) => Replay.trackInput('Email', v),
)
TextField(
  obscureText: true,
  onSubmitted: (v) => Replay.trackInput('Password', v, masked: true),
)
```

## Public API

All methods are static on `Replay` and return `Future<void>` unless noted.

| Method | Purpose |
|---|---|
| `start(config)` / `stop()` | Boot + start / stop recording |
| `identify(distinctId, {properties})` | Attach a known user |
| `track(name, {properties})` | Custom timeline / funnel event |
| `trackInput(label, value, {masked})` | Record a text input's value (masked → `"***"`) |
| `tagScreenName(name)` | Set the current screen (call from a route observer or screen `initState`) |
| `addTagWithProperties(name, {properties})` | Tag the session |
| `setMetadata` / `setUserProperty` / `setSessionProperty` | Sticky key/values |
| `setMaskStyle(style)` | Global mask style (blur / overlay / pixelate) |
| `log(message, {level})` | Bridge a custom logger into the console tab |
| `pauseRecording` / `resumeRecording` / `startNewSession` / `cancelSession` | Lifecycle |
| `optOut(bool)` / `optIn()` / `isOptedOut()` | GDPR opt-out |
| `isRecording()` / `currentSessionId()` | Session state |
| `occludeAllTextFields` / `occludeAllTextView` / `occludeSensitiveScreen` | Bulk masking |
| `setMultiSessionRecord` / `allowShortBreakForAnotherApp` / `setAppVersion` / `setPushNotificationToken` / `markSessionAsFavorite` / `reportBugEvent` | Session extras |
| `urlForCurrentSession()` / `urlForCurrentUser()` | Deep links |
| `ReplayMask(child:)` | Mask sensitive content (widget) |

Screenshots, taps, performance, device info (incl. network type), and
crashes are captured automatically.

## Building

Requires the Flutter SDK. From the package root:

```sh
flutter pub get
flutter analyze
cd example && flutter run
```
