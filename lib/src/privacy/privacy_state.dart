import 'package:flutter/foundation.dart';

import 'occlusion_models.dart';

/// Process-wide masking switches, read when a frame is captured.
///
/// Set from the `Replay` facade (`occludeSensitiveScreen`, `setMaskStyle`,
/// `start`) before the matching native call goes out, so a frame captured
/// while that call is in flight is already masked the new way.
class ReplayPrivacyState {
  ReplayPrivacyState._();

  /// The whole frame is covered with a solid box (`occludeSensitiveScreen`).
  /// Stays on across sessions until it is turned off.
  static bool sensitiveScreen = false;

  /// Touches are not recorded while [sensitiveScreen] is on.
  static bool hideGesturesOnSensitiveScreen = true;

  /// Style of a `ReplayMask` that sets no `maskStyle`. A solid overlay by
  /// default: no pixel of the masked region survives.
  static ReplayMaskStyle globalMaskStyle = ReplayMaskStyle.overlay;

  /// Platform views (WebView, maps, camera and video textures) are covered
  /// with a solid placeholder. From `ReplayConfig.maskPlatformViews`.
  static bool maskPlatformViews = true;

  @visibleForTesting
  static void reset() {
    sensitiveScreen = false;
    hideGesturesOnSensitiveScreen = true;
    globalMaskStyle = ReplayMaskStyle.overlay;
    maskPlatformViews = true;
  }
}
