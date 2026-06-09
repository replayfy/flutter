import 'package:flutter/foundation.dart';

import '../replay_channel.dart';

/// Forwards uncaught Dart errors to the engine as `$exception` events —
/// matching the React Native SDK, so the dashboard renders Flutter and RN
/// crashes through the same path.
///
/// The native crash handlers catch native signals (SIGSEGV/SIGABRT) and ANRs;
/// a Dart exception never reaches them — it's surfaced by the Flutter
/// framework (`FlutterError.onError`), the engine's uncaught-async hook
/// (`PlatformDispatcher.onError`), or a guarded zone's error callback. All
/// three funnel into [reportException] here.
///
/// The framework/platform hooks **chain** whatever was installed before us, so
/// the red error screen, `flutter run` output, and any other reporter
/// (Crashlytics, Sentry) keep working untouched.
class ReplayErrorCapture {
  ReplayErrorCapture._();

  static bool _installed = false;

  static void install() {
    if (_installed) return;
    _installed = true;

    final previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (FlutterErrorDetails details) {
      // Framework-reported errors are usually recoverable → not fatal.
      reportException(details.exceptionAsString(), details.stack, fatal: false);
      previousFlutterHandler?.call(details);
    };

    final previousPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
      reportException(error.toString(), stack, fatal: true);
      return previousPlatformHandler?.call(error, stack) ?? false;
    };
  }

  /// Forward one exception to the engine as a `$exception` event. Shared by
  /// the framework hook, the platform hook, and `Replay.runZoned`'s
  /// uncaught-error callback. Fire-and-forget; never throws.
  static void reportException(String message, StackTrace? stack,
      {required bool fatal}) {
    ReplayChannel.instance.invoke('track', <String, dynamic>{
      'name': r'$exception',
      'properties': <String, dynamic>{
        'message': message,
        'stack': stack?.toString(),
        'fatal': fatal,
      },
    });
  }

  /// Test-only: allow re-installing against a controlled base handler.
  @visibleForTesting
  static void debugReset() => _installed = false;
}
