import 'package:flutter/services.dart';

/// Thin [MethodChannel] forwarder onto the native Replayfy SDK.
///
/// One channel for the command API (`replayfy_flutter`). The masking pull
/// runs on its own channel (`replayfy_flutter/occlusion`) owned by the
/// occlusion registry, so capture-time rect requests never queue behind a
/// slow command.
class ReplayChannel {
  ReplayChannel._();

  static final ReplayChannel instance = ReplayChannel._();

  static const MethodChannel _channel = MethodChannel('replayfy_flutter');

  Future<void> invoke(String method, [Map<String, dynamic>? args]) async {
    await _channel.invokeMethod<void>(method, args);
  }

  Future<T?> get<T>(String method, [Map<String, dynamic>? args]) {
    return _channel.invokeMethod<T>(method, args);
  }
}
