import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../privacy/occlusion_registry.dart';
import '../replay_channel.dart';

/// Dart-side frame capture for Flutter.
///
/// The native engine's screenshotter can't read Flutter's hardware
/// `SurfaceView` on Android — `PixelCopy(Window)` returns the (black) window
/// background, not the Flutter content. So we capture the rendered app via a
/// root `RepaintBoundary` (`toImage` → PNG), exactly like the reference Flutter
/// SDK, and ship frames to the native engine over the `reportFrame` channel;
/// the native side packs them into the same frames archive. Native
/// screenshotting is disabled for Flutter on Android (`captureSnapshotPixels =
/// false` in the Android plugin) so frames are never captured twice.
///
/// Occlusion already renders Dart-side via `ReplayMask` (a `RepaintBoundary`
/// that paints the obscured content), so the captured image is pre-masked.
class ReplayFrameCapture {
  ReplayFrameCapture._();

  static final ReplayFrameCapture instance = ReplayFrameCapture._();

  /// Spans dialogs/modals via the [wrap] overlay so the whole app is captured.
  final GlobalKey rootBoundaryKey =
      GlobalKey(debugLabel: 'replayfy_root_boundary');

  Timer? _timer;
  bool _busy = false;

  /// Wrap [child] in an `Overlay` + `RepaintBoundary`. Use as
  /// `MaterialApp(builder: Replay.appBuilder)`.
  Widget wrap(BuildContext context, Widget? child) {
    return Overlay(
      initialEntries: <OverlayEntry>[
        OverlayEntry(
          maintainState: true,
          opaque: false,
          builder: (BuildContext ctx) => RepaintBoundary(
            key: rootBoundaryKey,
            child: child ?? const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }

  /// Start the periodic capture loop. ~2 fps keeps `toImage` cost low while
  /// matching the native engine's frame cadence closely enough for replay.
  void install() {
    _timer?.cancel();
    _timer = Timer.periodic(
        const Duration(milliseconds: 500), (_) => unawaited(_capture()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _capture() async {
    if (_busy) return;
    _busy = true;
    try {
      final BuildContext? ctx = rootBoundaryKey.currentContext;
      final RenderObject? ro = ctx?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return;
      // Wait for the in-flight frame to settle so we image a stable tree.
      try {
        await WidgetsBinding.instance.endOfFrame
            .timeout(const Duration(milliseconds: 50));
      } catch (_) {/* proceed with whatever is current */}
      // Cap the pixel ratio so large/high-DPI screens don't produce huge PNGs;
      // the native side downscales again before JPEG.
      final double dpr =
          ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
      final double pr = dpr > 2.0 ? 2.0 : dpr;
      final ui.Image image = await ro.toImage(pixelRatio: pr);
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return;
      // Occlusion rects (developer `ReplayMask` bounds) are in logical coords;
      // scale to the captured PNG's pixels so the native encoder masks the
      // right regions. Without this the Android frame applies no masking.
      final List<Map<String, dynamic>> rects = OcclusionRegistry.instance
          .currentRects()
          .map((Map<String, dynamic> r) => <String, dynamic>{
                'left': (r['left'] as num) * pr,
                'top': (r['top'] as num) * pr,
                'right': (r['right'] as num) * pr,
                'bottom': (r['bottom'] as num) * pr,
                'style': r['style'],
              })
          .toList();
      // Fire-and-forget; never let frame capture throw into the app.
      await ReplayChannel.instance.invoke('reportFrame', <String, dynamic>{
        'bytes': bytes.buffer.asUint8List(),
        'ts': DateTime.now().millisecondsSinceEpoch,
        'rects': rects,
      });
    } catch (_) {
      /* skip frame */
    } finally {
      _busy = false;
    }
  }
}
