import 'package:flutter/services.dart';

/// Thin [MethodChannel] forwarder onto the native Replayfy SDK.
///
/// One channel for the command API (`replayfy_flutter`). The masking pull
/// runs on its own channel (`replayfy_flutter/occlusion`) owned by the
/// occlusion registry, so capture-time rect requests never queue behind a
/// slow command.
///
/// Every call swallows its own errors. Recording must NEVER surface an
/// exception into the host app — not when the plugin is missing
/// (`MissingPluginException`), nor when the native side or the ingest backend
/// it talks to is unreachable. A failed call is simply a dropped data point.
/// This matters most for [invoke]: the console/error/network capture paths are
/// fire-and-forget (some run *from* the host's own error handler), so an
/// unguarded `await` there would become an unhandled async error in the host.
class ReplayChannel {
  ReplayChannel._();

  static final ReplayChannel instance = ReplayChannel._();

  static const MethodChannel _channel = MethodChannel('replayfy_flutter');

  Future<void> invoke(String method, [Map<String, dynamic>? args]) async {
    try {
      await _channel.invokeMethod<void>(method, args);
    } catch (_) {
      // Dropped event/frame — never propagate into the host app.
    }
  }

  Future<T?> get<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } catch (_) {
      // Treat an unreachable/unlinked native side as "no value".
      return null;
    }
  }
}
