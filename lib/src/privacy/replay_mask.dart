import 'package:flutter/widgets.dart';

import 'occlusion_models.dart';
import 'occlusion_registry.dart';
import 'replay_mask_render_box.dart';

/// Masks everything rendered inside it during playback.
///
/// ```dart
/// ReplayMask(
///   maskStyle: ReplayMaskStyle.overlay,
///   child: Text('•••• •••• •••• 4242'),
/// )
/// ```
///
/// One widget, like the React Native SDK's `<ReplayMask>`. Wrap any sensitive
/// subtree; nest freely. The masked region tracks the live widget (scroll,
/// layout, transitions) and the native engine renders it per [maskStyle] —
/// a solid `overlay`, `blur` or `pixelate` — the same render the native
/// iOS/Android engines produce. Without a [maskStyle] the region uses the
/// style set with `Replay.setMaskStyle`, a solid overlay unless changed.
///
/// Unlike those SDKs there is no native view to register: Flutter paints into
/// a single surface, so the bounds are computed in Dart and sent with each
/// captured frame. Taps inside the region are recorded without a label.
///
/// Text fields, `obscureText` password fields included, are not masked
/// automatically: wrap every sensitive field in a [ReplayMask].
class ReplayMask extends SingleChildRenderObjectWidget {
  const ReplayMask({
    super.key,
    this.maskStyle,
    required Widget super.child,
  });

  /// How this region is rendered in the recording. Null (the default) uses
  /// the style set with `Replay.setMaskStyle`: [ReplayMaskStyle.overlay]
  /// unless changed.
  final ReplayMaskStyle? maskStyle;

  @override
  ReplayMaskRenderBox createRenderObject(BuildContext context) {
    // Touch the registry so its native pull handler is installed before the
    // engine's first capture, even if start() didn't run yet.
    OcclusionRegistry.ensureInitialized();
    return ReplayMaskRenderBox(
      registry: OcclusionRegistry.instance,
      maskStyle: maskStyle,
    )..attachContext(context);
  }

  @override
  void updateRenderObject(
      BuildContext context, ReplayMaskRenderBox renderObject) {
    renderObject
      ..attachContext(context)
      ..maskStyle = maskStyle;
  }
}
