import 'dart:ui';

/// Contract a render object implements so the [OcclusionRegistry] can read
/// its live bounds without knowing the concrete render-box type.
///
/// All bounds are reported in **logical pixels** (Flutter's coordinate
/// space). The native bridge converts per platform — iOS consumes logical
/// points directly; Android multiplies by [devicePixelRatio] to reach
/// decor-view device pixels, which is what its screenshotter masks in.
abstract class OcclusionBoundsReporter {
  /// Stable identity across frames (key-derived, sliver-index-derived, or
  /// generated) so the registry can dedupe and track an entry through
  /// detach/reattach (e.g. list recycling, snapshot transitions).
  int get stableId;

  /// The most recently computed global bounds, or null if not visible.
  Rect? get currentBounds;

  /// Logical-to-device pixel ratio for the view hosting this box.
  double get devicePixelRatio;

  /// Whether the render object is currently attached to the pipeline.
  bool get attached;

  /// Whether the render object has been laid out.
  bool get hasSize;

  /// Union of bounds observed within the recent sliding window. Smooths
  /// single-frame jitter and bridges brief layer detaches.
  Rect? unionOfRecentBounds();

  /// Recompute bounds from the current transform. Cheap — pure matrix math,
  /// no IPC. Called once per frame for attached entries.
  void refreshBounds();
}
