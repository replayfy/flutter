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

  // Integration diagnostic. recordScreen is on, so we run the capture loop —
  // but frames only flow if the app wired `MaterialApp(builder:
  // Replay.appBuilder)` to mount our root RepaintBoundary. Track whether we
  // ever found it (and ever shipped a frame) so we can warn ONCE if the builder
  // is missing; without this a mis-integrated app records events but zero frames
  // and the omission is silent.
  Timer? _diagnosticTimer;
  bool _boundaryEverFound = false;
  int _framesShipped = 0;
  bool _warned = false;

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
    // One-shot integration check ~8s in (≈16 capture attempts) — enough time for
    // the app to build and the appBuilder to mount the boundary. If nothing has
    // been captured by then, the builder is almost certainly missing.
    _diagnosticTimer?.cancel();
    if (!_warned) {
      _diagnosticTimer =
          Timer(const Duration(seconds: 8), _checkInstallDiagnostic);
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _diagnosticTimer?.cancel();
    _diagnosticTimer = null;
  }

  /// Fires once, ~8s after [install]. If our root RepaintBoundary was never
  /// found, the host app never installed the capture builder, so no frames can
  /// be captured — warn loudly and actionably. If the boundary WAS found but
  /// nothing shipped, capture is failing for a different reason (secure surface,
  /// backgrounded app) — a softer note.
  void _checkInstallDiagnostic() {
    if (_warned) return;
    if (!_boundaryEverFound) {
      _warned = true;
      debugPrint(
        '[replayfy] ⚠️  Screen recording is ON but NO frames are being captured.\n'
        '[replayfy]     Native capture cannot read the Flutter surface on Android,\n'
        '[replayfy]     so frames come from a Dart-side RepaintBoundary that you\n'
        '[replayfy]     must install through the app builder:\n'
        '[replayfy]\n'
        '[replayfy]         MaterialApp(\n'
        '[replayfy]           builder: Replay.appBuilder,   // <-- add this line\n'
        '[replayfy]           ...\n'
        '[replayfy]         )\n'
        '[replayfy]\n'
        '[replayfy]     Until then Replayfy records events but the player shows no\n'
        '[replayfy]     video. Pass recordScreen: false to ReplayConfig to silence this.',
      );
    } else if (_framesShipped == 0) {
      _warned = true;
      debugPrint(
        '[replayfy] ⚠️  Screen recording is ON and the capture boundary is '
        'mounted, but no frames have been produced yet. If the player stays '
        'blank, check for secure/DRM surfaces or a long-backgrounded app.',
      );
    }
  }

  Future<void> _capture() async {
    if (_busy) return;
    _busy = true;
    try {
      final BuildContext? ctx = rootBoundaryKey.currentContext;
      final RenderObject? ro = ctx?.findRenderObject();
      if (ro is! RenderRepaintBoundary) return;
      // The boundary is in the tree, so the app builder is wired correctly —
      // this alone clears the "missing builder" diagnostic.
      _boundaryEverFound = true;
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
      _framesShipped++;
    } catch (_) {
      /* skip frame */
    } finally {
      _busy = false;
    }
  }
}
