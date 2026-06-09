import '../replay_channel.dart';

/// Mirrors console output to the engine as `$console` events — matching the
/// React Native SDK's `console.*` capture, so logs land in the same dashboard
/// panel for both stacks.
///
/// Flutter has no global `console` object to patch; instead the capture rides
/// a guarded [Zone]'s `print` hook (installed by `Replay.runZoned`), which
/// sees both `print` and `debugPrint`. We deliberately turn the native
/// console capture off for Flutter sessions (Dart owns this), so a line is
/// never recorded twice.
class ReplayConsoleCapture {
  ReplayConsoleCapture._();

  /// Gated by `ReplayConfig.recordConsole`, flipped on in `Replay.start`.
  static bool enabled = false;

  /// Forward one console line. Fire-and-forget; never throws into logging.
  static void emit(String line) {
    if (!enabled || line.isEmpty) return;
    ReplayChannel.instance.invoke('track', <String, dynamic>{
      'name': r'$console',
      'properties': <String, dynamic>{'level': 'log', 'message': line},
    });
  }
}
