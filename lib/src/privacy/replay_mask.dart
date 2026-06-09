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
/// `blur` (default) or a solid `overlay` — the same render the native
/// iOS/Android engines produce.
///
/// Unlike those SDKs there is no native view to register: Flutter paints into
/// a single surface, so the bounds are computed in Dart and the engine pulls
/// them (with the style) at capture rate. See [OcclusionRegistry] for why pull
/// beats push here.
class ReplayMask extends SingleChildRenderObjectWidget {
  const ReplayMask({
    super.key,
    this.maskStyle = ReplayMaskStyle.blur,
    required Widget super.child,
  });

  /// How this region is rendered in the recording. Default [ReplayMaskStyle.blur].
  final ReplayMaskStyle maskStyle;

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
