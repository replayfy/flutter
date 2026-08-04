/// Replayfy session replay & product analytics for Flutter.
///
/// ```dart
/// import 'package:replayfy_flutter/replayfy_flutter.dart';
///
/// await Replay.start(const ReplayConfig(
///   projectKey: 'rpl_pk_xxx',
///   ingestUrl: 'https://ingest.replayfy.io',
/// ));
/// ```
///
/// `start()` boots the native engine, which auto-captures screenshots,
/// taps, performance, and crashes. Wrap sensitive widgets in [ReplayMask].
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'src/capture/console.dart';
import 'src/capture/errors.dart';
import 'src/capture/frames.dart';
import 'src/capture/gestures.dart';
import 'src/capture/network.dart';
import 'src/privacy/occlusion_models.dart';
import 'src/privacy/occlusion_registry.dart';
import 'src/replay_channel.dart';
import 'src/replay_config.dart';

export 'src/replay_config.dart' show ReplayConfig;
export 'src/privacy/occlusion_models.dart' show ReplayMaskStyle;
export 'src/privacy/replay_mask.dart' show ReplayMask;
export 'src/replay_navigator_observer.dart' show ReplayNavigatorObserver;

/// Public API. Mirrors the Replayfy iOS / Android / React Native SDKs so the
/// surface is identical across stacks. Every call is a thin forward onto the
/// native engine via the platform channel.
class Replay {
  Replay._();

  static final ReplayChannel _ch = ReplayChannel.instance;

  // ── Lifecycle ──────────────────────────────────────────────────────────

  /// Boot the SDK and start recording. The native engine takes over
  /// screenshots, taps, performance, and crash capture from here.
  static Future<void> start(ReplayConfig config) {
    // Install the occlusion pull handler now so the engine's first capture
    // never races a not-yet-mounted <ReplayMask>.
    OcclusionRegistry.ensureInitialized();
    // Forward uncaught Dart errors to the engine as `$exception` events — the
    // native crash handler can't see them (they never leave the Dart layer).
    if (config.recordErrors) ReplayErrorCapture.install();
    // Capture Dart HTTP (invisible to the native interceptors). Skip our own
    // uploads to the ingest host.
    if (config.recordNetwork) {
      ReplayNetworkCapture.install(
        ignoreHosts: <String>{Uri.parse(config.ingestUrl).host},
      );
    }
    // Console capture rides Replay.runZoned's print hook; this just arms it.
    ReplayConsoleCapture.enabled = config.recordConsole;
    // Dart-side gesture capture: reports the ACTUAL tapped widget's label
    // (the native engine only sees the single FlutterView). The native touch
    // capture is disabled for Flutter sessions in the iOS/Android plugins, so
    // a touch is never recorded twice.
    ReplayGestureCapture.install();
    // Neither native screenshotter can read Flutter's surface (Android's
    // SurfaceView → black frames; iOS would need a separate rect pull that
    // trailed scroll), so capture frames Dart-side via the root
    // RepaintBoundary on BOTH platforms and ship each frame with its occlusion
    // rects in the same payload — no poll, no mask lag. Requires the app to use
    // `MaterialApp(builder: Replay.appBuilder)`.
    if (config.recordScreen) {
      ReplayFrameCapture.instance.install();
    }
    return _ch.invoke('start', <String, dynamic>{
      'projectKey': config.projectKey,
      'ingestUrl': config.ingestUrl,
      'config': config.toJson(),
    });
  }

  /// App builder that injects the capture `RepaintBoundary` used for Dart-side
  /// frame capture (required on both iOS + Android). Use as
  /// `MaterialApp(builder: Replay.appBuilder, ...)`.
  static Widget appBuilder(BuildContext context, Widget? child) =>
      ReplayFrameCapture.instance.wrap(context, child);

  /// Run your app inside a guarded zone so Replayfy can capture **console
  /// output** (`print` / `debugPrint` → `$console` events) and **uncaught
  /// async errors** (→ `$exception` events). This is the Flutter analogue of
  /// the React Native SDK patching `console.*` — Flutter has no global console
  /// to patch, so the capture rides the zone's `print` hook.
  ///
  /// ```dart
  /// void main() => Replay.runZoned(() async {
  ///   WidgetsFlutterBinding.ensureInitialized();
  ///   await Replay.start(const ReplayConfig(...));
  ///   runApp(const MyApp());
  /// });
  /// ```
  ///
  /// Widget-tree errors are captured even without this wrapper (via
  /// `FlutterError.onError` in [start]); only `print` capture and uncaught
  /// *async* errors require the zone.
  static R? runZoned<R>(R Function() body) {
    return runZonedGuarded<R>(
      body,
      (Object error, StackTrace stack) {
        ReplayErrorCapture.reportException(error.toString(), stack,
            fatal: true);
      },
      zoneSpecification: ZoneSpecification(
        print: (Zone self, ZoneDelegate parent, Zone zone, String line) {
          ReplayConsoleCapture.emit(line);
          parent.print(zone, line); // keep stdout / devtools output
        },
      ),
    );
  }

  /// Stop recording and finalize the session.
  static Future<void> stop() => _ch.invoke('stop');

  /// True while a session is actively recording.
  static Future<bool> isRecording() async =>
      (await _ch.get<bool>('isRecording')) ?? false;

  /// The current session's public id, or null if not recording.
  static Future<String?> currentSessionId() =>
      _ch.get<String>('currentSessionId');

  /// End the current session and start a fresh one immediately.
  static Future<void> startNewSession() => _ch.invoke('startNewSession');

  /// Pause screenshot/event capture without ending the session.
  static Future<void> pauseRecording() => _ch.invoke('pauseRecording');

  /// Resume capture after [pauseRecording].
  static Future<void> resumeRecording() => _ch.invoke('resumeRecording');

  /// Discard the in-flight session without uploading it.
  static Future<void> cancelSession() => _ch.invoke('cancelSession');

  /// Flush everything and upload immediately (e.g. before a forced logout).
  static Future<void> stopApplicationAndUploadData() =>
      _ch.invoke('stopApplicationAndUploadData');

  // ── Identity & events ──────────────────────────────────────────────────

  /// Associate the session with a known user id, optionally with traits.
  static Future<void> identify(String distinctId,
      {Map<String, dynamic>? properties}) {
    return _ch.invoke('identify', <String, dynamic>{
      'distinctId': distinctId,
      'properties': properties,
    });
  }

  /// Record a custom analytics event.
  static Future<void> track(String name, {Map<String, dynamic>? properties}) {
    return _ch.invoke('track', <String, dynamic>{
      'name': name,
      'properties': properties,
    });
  }

  /// Report a developer-caught exception on the session timeline. Emits the same
  /// `$exception` event the automatic error handlers emit, so a handled error is
  /// first-class in the dashboard's issues. [handled] defaults to true
  /// (non-fatal); it maps to the wire's `fatal` discriminator (`fatal = !handled`).
  static Future<void> captureException(Object error,
      {StackTrace? stackTrace,
      bool handled = true,
      Map<String, dynamic>? properties}) {
    ReplayErrorCapture.reportException(
      error.toString(),
      stackTrace,
      fatal: !handled,
      properties: properties,
    );
    return Future<void>.value();
  }

  /// Record a text input's value on the session timeline. Flutter manages its
  /// own text widgets (there's no native field for the engine to observe), so
  /// call this from your field's `onSubmitted`/`onEditingComplete`. Pass
  /// [masked] true for sensitive fields — the value is dropped (recorded as
  /// "***") and never leaves the device.
  static Future<void> trackInput(String label, String value, {bool masked = false}) {
    return _ch.invoke('trackInput', <String, dynamic>{
      'label': label,
      'value': value,
      'masked': masked,
    });
  }

  /// Tag the current screen by name (also done automatically when
  /// [ReplayConfig.autoScreenName] is on).
  static Future<void> tagScreenName(String name) =>
      _ch.invoke('tagScreenName', <String, dynamic>{'name': name});

  /// Tag the session with a named, optionally-propertied marker.
  static Future<void> addTagWithProperties(String name,
      {Map<String, dynamic>? properties}) {
    return _ch.invoke('addTagWithProperties', <String, dynamic>{
      'name': name,
      'properties': properties,
    });
  }

  /// Set a persistent user-level property.
  static Future<void> setUserProperty(String key, Object? value) =>
      _ch.invoke('setUserProperty', <String, dynamic>{'key': key, 'value': value});

  /// Set a property scoped to this session only.
  static Future<void> setSessionProperty(String key, Object? value) =>
      _ch.invoke('setSessionProperty',
          <String, dynamic>{'key': key, 'value': value});

  /// Attach a free-form metadata string to the session.
  static Future<void> setMetadata(String key, String value) =>
      _ch.invoke('setMetadata', <String, dynamic>{'key': key, 'value': value});

  /// Mark the current session as a favorite in the dashboard.
  static Future<void> markSessionAsFavorite() =>
      _ch.invoke('markSessionAsFavorite');

  /// Report a manual bug event with an optional description.
  static Future<void> reportBugEvent(String name, {String? description}) {
    return _ch.invoke('reportBugEvent', <String, dynamic>{
      'name': name,
      'description': description,
    });
  }

  // ── Privacy / GDPR ─────────────────────────────────────────────────────

  /// Opt the user out of all recording (kill switch). Persists across
  /// launches; pass false to opt back in.
  static Future<void> optOut(bool optOut) =>
      _ch.invoke('optOut', <String, dynamic>{'optOut': optOut});

  /// Convenience for `optOut(false)`.
  static Future<void> optIn() => optOut(false);

  /// True if the user is currently opted out of all recording.
  static Future<bool> isOptedOut() async =>
      (await _ch.get<bool>('isOptedOut')) ?? false;

  /// Auto-occlude every text field for the rest of the session.
  static Future<void> occludeAllTextFields(bool occlude) =>
      _ch.invoke('occludeAllTextFields', <String, dynamic>{'occlude': occlude});

  /// Occlude the entire screen (e.g. a sensitive flow).
  static Future<void> occludeSensitiveScreen(bool occlude) =>
      _ch.invoke('occludeSensitiveScreen', <String, dynamic>{'occlude': occlude});

  /// Occlude all multi-line text views in screenshots (parity with the
  /// native SDKs' `occludeAllTextView`; complements [occludeAllTextFields]).
  static Future<void> occludeAllTextView(bool occlude) =>
      _ch.invoke('occludeAllTextView', <String, dynamic>{'occlude': occlude});

  /// Record multiple sessions per app launch instead of a single one.
  static Future<void> setMultiSessionRecord(bool enabled) =>
      _ch.invoke('setMultiSessionRecord', <String, dynamic>{'enabled': enabled});

  /// Allow a brief switch to another app without ending the session.
  static Future<void> allowShortBreakForAnotherApp(bool allow) =>
      _ch.invoke('allowShortBreak', <String, dynamic>{'allow': allow});

  /// Bridge a customer log line into the `$console` event stream. (Flutter's
  /// native console capture is off — Dart owns it — so this routes through the
  /// Dart `track` path rather than the native `log`.)
  static Future<void> log(String message, {String level = 'log'}) =>
      _ch.invoke('track', <String, dynamic>{
        'name': r'$console',
        'properties': <String, dynamic>{'level': level, 'message': message},
      });

  /// Set the global mask render style — [ReplayMaskStyle.blur] (default),
  /// [ReplayMaskStyle.overlay] (a solid box), or [ReplayMaskStyle.pixelate]
  /// (coarse mosaic blocks). Applies to bulk-occluded text, whole-screen
  /// occlusion, and any [ReplayMask] that doesn't set its own `maskStyle`.
  /// Per-region styles (passed on the [ReplayMask] widget) ride the occlusion
  /// pull channel and override this for that region.
  static Future<void> setMaskStyle(ReplayMaskStyle style) =>
      _ch.invoke('setMaskStyle', <String, dynamic>{'style': style.index});

  // ── Configuration ──────────────────────────────────────────────────────

  /// Toggle automatic screen-name tagging at runtime.
  static Future<void> setAutomaticScreenNameTagging(bool enabled) =>
      _ch.invoke('setAutomaticScreenNameTagging',
          <String, dynamic>{'enabled': enabled});

  /// Register a push token so dashboards can correlate notifications.
  static Future<void> setPushNotificationToken(String token,
          {String platform = 'fcm'}) =>
      _ch.invoke('setPushNotificationToken',
          <String, dynamic>{'token': token, 'platform': platform});

  /// Override the reported app version/build (else read from the bundle).
  static Future<void> setAppVersion(String? version, {String? build}) =>
      _ch.invoke('setAppVersion',
          <String, dynamic>{'version': version, 'build': build});

  // ── Deep links ─────────────────────────────────────────────────────────

  /// Dashboard URL for the current session, or null if not recording.
  static Future<String?> urlForCurrentSession() =>
      _ch.get<String>('urlForCurrentSession');

  /// Dashboard URL for the current user, or null if unidentified.
  static Future<String?> urlForCurrentUser() =>
      _ch.get<String>('urlForCurrentUser');
}
