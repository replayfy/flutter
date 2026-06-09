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

## Public API

`Replay.start / stop`, `identify`, `track`, `tagScreenName`,
`setUserProperty`, `setSessionProperty`, `pauseRecording`,
`resumeRecording`, `optIn` / `optOut`, `startNewSession`, `isRecording`,
`currentSessionId`, and the bulk-privacy helpers. See
`lib/replayfy_flutter.dart`.

## Building

Requires the Flutter SDK. From the package root:

```sh
flutter pub get
flutter analyze
cd example && flutter run
```
