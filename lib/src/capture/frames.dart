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
///
/// Frames are captured only while the app is on screen, like the native
/// engines' own capture, which pauses when the app goes to the background and
/// restarts when it returns. A Dart timer keeps firing in the background (iOS
/// runs it until the app is suspended, Android until the process is frozen),
/// so without this every tick there rendered and encoded a frame of a screen
/// nobody sees: wasted CPU and battery, and on iOS frames that only stretch
/// the replay.
class ReplayFrameCapture with WidgetsBindingObserver {
  ReplayFrameCapture._() : _onTick = null;

  /// A capturer whose ticks call [onTick] instead of imaging the app, so the
  /// loop's scheduling can be tested without a rendered tree.
  @visibleForTesting
  ReplayFrameCapture.forTesting({required Future<void> Function() onTick})
      : _onTick = onTick;

  static final ReplayFrameCapture instance = ReplayFrameCapture._();

  /// ~2 fps keeps `toImage` cost low while matching the native engine's frame
  /// cadence closely enough for replay.
  static const Duration interval = Duration(milliseconds: 500);

  /// Spans dialogs/modals via the [wrap] overlay so the whole app is captured.
  final GlobalKey rootBoundaryKey =
      GlobalKey(debugLabel: 'replayfy_root_boundary');

  final Future<void> Function()? _onTick;

  Timer? _timer;
  bool _busy = false;

  // install() was called and stop() wasn't: capture whenever the app is on
  // screen.
  bool _installed = false;

  // Whether the app is on screen, from the last lifecycle state Flutter
  // reported.
  bool _visible = true;

  // A frame with the app in it has been laid out, so the root boundary has
  // something to image.
  bool _rendered = false;

  // A post-frame callback is pending, so a repeated install() or resume
  // doesn't queue another.
  bool _awaitingFrame = false;

  /// Whether the periodic capture loop is running.
  @visibleForTesting
  bool get isCapturing => _timer != null;

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

  /// Capture a frame every [interval] while the app is on screen, once a
  /// frame with the app in it has been laid out. Safe to call again: there is
  /// only ever one loop.
  void install() {
    final WidgetsBinding binding = WidgetsBinding.instance;
    if (!_installed) {
      _installed = true;
      binding.addObserver(this);
    }
    // Both engines report detached until the host sends its first lifecycle
    // event, so a start() in main() sees detached and the loop starts on the
    // inactive (iOS, as the view appears) or resumed that follows. Flutter
    // schedules no frames while detached either (only runApp's first one is
    // drawn), so an add-to-app host that turns off the engine's lifecycle
    // dispatch has to send these events itself for the app to update at all.
    // Null only when the platform reported no state, as in tests.
    final AppLifecycleState? state = binding.lifecycleState;
    _visible = state == null || _isVisible(state);
    _startWhenRendered();
  }

  /// Stop capturing, and stay stopped when the app comes back to the
  /// foreground.
  void stop() {
    if (_installed) {
      _installed = false;
      WidgetsBinding.instance.removeObserver(this);
    }
    _cancel();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _visible = _isVisible(state);
    if (_visible) {
      _startWhenRendered();
    } else {
      _cancel();
    }
  }

  /// On screen: resumed, or inactive (visible without input focus: a system
  /// dialog over the app, the app switcher, the notification shade, an
  /// unfocused split-screen window). Flutter itself renders frames only in
  /// these two states. iOS and Android go hidden then paused on the way to
  /// the background and detached when the view goes away; each stops the
  /// loop. Written as a check for the on-screen states because `hidden` only
  /// exists from Flutter 3.13 and this package supports 3.10.
  static bool _isVisible(AppLifecycleState state) =>
      state == AppLifecycleState.resumed ||
      state == AppLifecycleState.inactive;

  void _startWhenRendered() {
    if (!_installed || !_visible || _timer != null) return;
    final WidgetsBinding binding = WidgetsBinding.instance;
    // start() usually runs before runApp, when the root boundary has nothing
    // laid out to image: start after the first frame that has the app in it.
    // Once the app has been on screen (start() called later, e.g. after a
    // consent prompt) there is no frame to wait for: a static screen might
    // not draw another for a long time.
    if (!_rendered && !binding.firstFrameRasterized) {
      if (_awaitingFrame) return;
      _awaitingFrame = true;
      binding.addPostFrameCallback((_) {
        _awaitingFrame = false;
        // A frame drawn before runApp has no app in it; wait for the next.
        _rendered = binding.rootElement != null;
        _startWhenRendered(); // re-checks: the app may have left meanwhile
      });
      return;
    }
    _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void _cancel() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() => (_onTick ?? _capture)();

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
