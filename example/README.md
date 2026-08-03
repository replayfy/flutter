# Replayfy Flutter example

Minimal app exercising `Replay.start`, `tagScreenName`, `track`,
`currentSessionId`, `startNewSession`, and the `<ReplayMask>` widget.

## Generate the platform runners

The `android/` and `ios/` runner projects are toolchain-generated and not
checked in. From this `example/` directory:

```sh
flutter create .
flutter pub get
```

`flutter create .` fills in the runners without touching `lib/main.dart`,
`pubspec.yaml`, or this README.

## Wire the local native SDKs (development)

The plugin depends on the native SDKs (`Replayfy` pod / `com.github.replayfy:android-sdk`).
For local development against the sibling checkouts in this monorepo:

**iOS** — in `example/ios/Podfile`, point the `Replayfy` pod at the local SDK:

```ruby
pod 'Replayfy', :path => '../../../replay-ios-sdk'
```

then `cd ios && pod install`.

**Android** — publish the native SDK to your local Maven cache once:

```sh
cd ../../replay-android-sdk && ./gradlew :sdk:publishToMavenLocal
```

`mavenLocal()` is already in the plugin's repositories, so Gradle resolves
`com.github.replayfy:android-sdk:0.0.1` from there.

## Run

```sh
flutter run        # with an emulator/simulator or device attached
```

The example points `ingestUrl` at `http://10.0.2.2:4000` (the Android
emulator's alias for the host's `localhost:4000`). On iOS simulator use
`http://localhost:4000`; on a physical device use the host's LAN IP.
