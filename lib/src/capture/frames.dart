import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../privacy/occlusion_models.dart';
import '../privacy/occlusion_registry.dart';
import '../privacy/privacy_state.dart';
import '../privacy/replay_mask_render_box.dart';
import '../replay_channel.dart';

/// Dart-side frame capture for Flutter.
///
/// Our native screenshotters do not image Flutter's surface, so the app is
/// imaged through the root RepaintBoundary installed by Replay.appBuilder
/// (toImage -> PNG). Each frame goes over the reportFrame channel together
/// with its mask rects; the native engine paints those rects, encodes the
/// JPEG and packs the frames archive. Native screenshotting is off for
/// Flutter on both platforms (captureSnapshotPixels = false in each plugin),
/// so a frame is never captured twice.
///
/// The PNG is NOT pre-masked: ReplayMask paints nothing, it only reports its
/// bounds. Rects are built in the same synchronous turn as the toImage call
/// and in the boundary's own coordinate space, so they line up with the
/// pixels while scrolling. A frame carries ReplayMask regions and
/// platform-view placeholders; while occludeSensitiveScreen is on it carries
/// one full-frame box instead. Unmasked pixels never leave the process.
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

  /// Stands in for `RenderRepaintBoundary.toImage`, so a test can check what
  /// had already run when the frame was imaged.
  @visibleForTesting
  Future<ui.Image> Function(RenderRepaintBoundary boundary, double pixelRatio)?
      debugToImage;

  /// Called each time a frame's mask rects have been built.
  @visibleForTesting
  void Function()? debugOnFrameRects;

  /// Captures and reports one frame now, as a loop tick does.
  @visibleForTesting
  Future<void> debugCaptureOnce() => _capture();

  /// The mask rects a frame of [boundary] imaged at [pixelRatio] would carry.
  @visibleForTesting
  List<Map<String, dynamic>> debugFrameRects(
          RenderRepaintBoundary boundary, double pixelRatio) =>
      _frameRects(boundary, pixelRatio);

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
      if (!ro.attached || !ro.hasSize || ro.size.isEmpty) return;
      // Cap the pixel ratio so large/high-DPI screens don't produce huge PNGs;
      // the native side downscales again before JPEG.
      final double dpr =
          ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
      final double pr = dpr > 2.0 ? 2.0 : dpr;
      final Size size = ro.size;
      // The rects and the image come from the same frame: toImage builds its
      // scene from the current layer tree when it is called, and there is no
      // await between these two lines for a scroll or a rebuild to slip into.
      // If building the rects throws, no frame is sent.
      List<Map<String, dynamic>> rects = _frameRects(ro, pr);
      final ui.Image image =
          await (debugToImage?.call(ro, pr) ?? ro.toImage(pixelRatio: pr));
      final ByteData? bytes =
          await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (bytes == null) return;
      // The screen turned sensitive while this frame was being encoded: cover
      // it too.
      if (ReplayPrivacyState.sensitiveScreen) {
        rects = <Map<String, dynamic>>[fullFrame(size, pr)];
      }
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

  // ── Mask rects ─────────────────────────────────────────────────────────

  // Access pattern: one registry read (an in-memory cache, refreshed by the
  // existing per-frame callback) plus one render-subtree walk per capture,
  // about 2 per second. The reference tracker does the same walk on each
  // capture.
  List<Map<String, dynamic>> _frameRects(RenderRepaintBoundary b, double pr) {
    try {
      if (ReplayPrivacyState.sensitiveScreen) {
        return <Map<String, dynamic>>[fullFrame(b.size, pr)];
      }
      final Matrix4 toRoot;
      final List<Rect> platformViews;
      try {
        toRoot = b.getTransformTo(null);
        platformViews = _platformViewRects(b,
            collect: ReplayPrivacyState.maskPlatformViews);
      } catch (_) {
        // Can't place the masks: cover the whole frame instead.
        return <Map<String, dynamic>>[fullFrame(b.size, pr)];
      }
      return rectsForFrame(
        boundaryToRoot: toRoot,
        size: b.size,
        pixelRatio: pr,
        masks: OcclusionRegistry.instance.currentRects(),
        platformViews: platformViews,
        defaultStyle: ReplayPrivacyState.globalMaskStyle.index,
      );
    } finally {
      debugOnFrameRects?.call();
    }
  }

  /// The rects a frame carries, in the PNG's pixels: each mask in [masks]
  /// (logical pixels of the root view, as the registry reports them) moved
  /// into the boundary's own space through [boundaryToRoot], and each
  /// platform view in [platformViews] (logical pixels of the boundary), each
  /// clipped to the frame and rounded outwards to whole pixels. A mask with no
  /// style takes [defaultStyle]; a platform view is always a solid overlay.
  /// Every rect carries a style: the native parsers read a missing one as
  /// blur.
  ///
  /// Fails closed: masks that can't be placed (a singular transform, a
  /// non-finite rect) give one rect covering the whole frame.
  @visibleForTesting
  static List<Map<String, dynamic>> rectsForFrame({
    required Matrix4 boundaryToRoot,
    required Size size,
    required double pixelRatio,
    required List<Map<String, dynamic>> masks,
    required List<Rect> platformViews,
    required int defaultStyle,
  }) {
    final Rect frame = Offset.zero & size;
    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    final Matrix4? inv = Matrix4.tryInvert(boundaryToRoot);
    if (masks.isNotEmpty && inv == null) {
      return <Map<String, dynamic>>[fullFrame(size, pixelRatio)];
    }
    for (final Map<String, dynamic> m in masks) {
      final Rect root = Rect.fromLTRB(
        (m['left'] as num).toDouble(),
        (m['top'] as num).toDouble(),
        (m['right'] as num).toDouble(),
        (m['bottom'] as num).toDouble(),
      );
      final Rect local = MatrixUtils.transformRect(inv!, root).intersect(frame);
      if (!local.isFinite) {
        return <Map<String, dynamic>>[fullFrame(size, pixelRatio)];
      }
      if (local.isEmpty) continue; // outside the frame
      out.add(_pixelRect(
          local, pixelRatio, (m['style'] as int?) ?? defaultStyle));
    }
    for (final Rect r in platformViews) {
      final Rect local = r.intersect(frame);
      if (!local.isFinite) {
        return <Map<String, dynamic>>[fullFrame(size, pixelRatio)];
      }
      if (local.isEmpty) continue;
      out.add(_pixelRect(local, pixelRatio, ReplayMaskStyle.overlay.index));
    }
    return out;
  }

  /// One solid box over the whole frame: the PNG `toImage` makes of a
  /// boundary of [size] at [pr] is `ceil(w * pr)` x `ceil(h * pr)`.
  @visibleForTesting
  static Map<String, dynamic> fullFrame(Size size, double pr) =>
      <String, dynamic>{
        'left': 0.0,
        'top': 0.0,
        'right': (size.width * pr).ceilToDouble(),
        'bottom': (size.height * pr).ceilToDouble(),
        'style': ReplayMaskStyle.overlay.index,
      };

  // Logical rect → PNG pixels, rounded outwards so no edge pixel is left
  // uncovered.
  static Map<String, dynamic> _pixelRect(Rect r, double pr, int style) =>
      <String, dynamic>{
        'left': (r.left * pr).floorToDouble(),
        'top': (r.top * pr).floorToDouble(),
        'right': (r.right * pr).ceilToDouble(),
        'bottom': (r.bottom * pr).ceilToDouble(),
        'style': style,
      };

  // ── Platform views ─────────────────────────────────────────────────────

  /// The painted platform views under [boundary], in its logical pixels,
  /// when [collect] is on. Flutter can't image them, so each one is covered
  /// whole, as far as its ancestors' clips let it show. Debug builds also
  /// warn here about unmasked password fields.
  List<Rect> _platformViewRects(RenderRepaintBoundary boundary,
      {required bool collect}) {
    final List<Rect> out = <Rect>[];
    if (collect || kDebugMode) {
      _visitPainted(boundary, boundary, out,
          collect: collect, insideMask: false, clip: null);
    }
    return out;
  }

  // [clip] is the part of the boundary [node] may paint into (null: all of
  // it), tracked only when [collect] is on. [filtered] is the area an
  // ancestor image filter draws [node] into, if one does.
  void _visitPainted(
    RenderObject node,
    RenderRepaintBoundary boundary,
    List<Rect> out, {
    required bool collect,
    required bool insideMask,
    required Rect? clip,
    Rect? filtered,
  }) {
    node.visitChildren((RenderObject child) {
      if (!_isPainted(node, child)) return;
      final Rect? childClip =
          collect ? _childClip(node, child, boundary, clip) : null;
      // The outermost filter wins: it covers the inner ones.
      final Rect? childFiltered = filtered ??
          (collect ? _filteredArea(child, boundary, childClip) : null);
      // Type checks only: they survive --obfuscate.
      final bool isPlatformView = child is PlatformViewRenderBox ||
          child is RenderAndroidView ||
          child is RenderUiKitView ||
          child is TextureBox;
      if (isPlatformView) {
        if (collect && child is RenderBox && child.hasSize) {
          final Rect bounds = MatrixUtils.transformRect(
              child.getTransformTo(boundary), Offset.zero & child.size);
          // Scrolled partly out of a list, say: only the part that shows,
          // so the box doesn't cover the app bar above it. Under an image
          // filter, all that the filter draws: it moves the view's pixels
          // where the render tree can't follow them.
          out.add(childFiltered ??
              (childClip == null ? bounds : bounds.intersect(childClip)));
        }
        return; // never descend into a platform view
      }
      if (kDebugMode &&
          !insideMask &&
          child is RenderEditable &&
          child.obscureText) {
        _debugWarnUnmaskedPassword(child);
      }
      _visitPainted(child, boundary, out,
          collect: collect,
          insideMask: insideMask || child is ReplayMaskRenderBox,
          clip: childClip,
          filtered: childFiltered);
    });
  }

  /// The part of [boundary] that [node] draws its subtree into through an
  /// image filter this frame, as far as [clip] lets it show, or null when it
  /// draws none. Flutter's stretch overscroll on Android (Impeller) is such a
  /// filter: a shader that shifts a list's pixels along the list while the
  /// user pulls past its end.
  static Rect? _filteredArea(
      RenderObject node, RenderRepaintBoundary boundary, Rect? clip) {
    // `layer` is protected only to keep it out of paint code; reading it here
    // changes nothing. A filter that is off paints no layer.
    // ignore: invalid_use_of_protected_member
    final ContainerLayer? filter = node.layer;
    if (filter is! ImageFilterLayer ||
        !filter.attached ||
        node is! RenderBox ||
        !node.hasSize) {
      return null;
    }
    final Rect area = MatrixUtils.transformRect(
        node.getTransformTo(boundary), Offset.zero & node.size);
    return clip == null ? area : area.intersect(clip);
  }

  /// [clip] narrowed by the clip [parent] paints [child] with, in
  /// [boundary]'s logical pixels. describeApproximatePaintClip gives a
  /// rounded or path clip's bounding box, so a placeholder can only be
  /// larger than what shows, never smaller.
  static Rect? _childClip(RenderObject parent, RenderObject child,
      RenderRepaintBoundary boundary, Rect? clip) {
    final Rect? local = parent.describeApproximatePaintClip(child);
    if (local == null) return clip;
    final Rect inBoundary =
        MatrixUtils.transformRect(parent.getTransformTo(boundary), local);
    return clip == null ? inBoundary : clip.intersect(inBoundary);
  }

  /// Whether [parent] paints [child] into the current frame. paintsChild
  /// covers Offstage, zero opacity and the like, but reports an offstage
  /// route (an Overlay entry under an opaque one) and a hidden IndexedStack
  /// child as painted. Their repaint boundaries are not painted, though, so
  /// their layers are not in the layer tree toImage renders. Every platform
  /// view is a repaint boundary itself, so this check covers each one.
  static bool _isPainted(RenderObject parent, RenderObject child) =>
      parent.paintsChild(child) &&
      (!child.isRepaintBoundary ||
          // `layer` is protected only to keep it out of paint code; reading
          // it here changes nothing, and nothing public says whether a
          // boundary is in the current layer tree.
          // ignore: invalid_use_of_protected_member
          (child.layer?.attached ?? false));

  // One console line per field, not one per frame.
  static final Expando<bool> _debugWarned = Expando<bool>();

  static void _debugWarnUnmaskedPassword(RenderEditable field) {
    if (_debugWarned[field] ?? false) return;
    _debugWarned[field] = true;
    debugPrint('replayfy_flutter: an obscureText text field is recorded '
        'outside any ReplayMask. Flutter briefly shows each typed password '
        'character on Android and iOS, so the replay can show it. Wrap the '
        'field in ReplayMask. Field: ${field.debugCreator ?? field}');
  }
}
