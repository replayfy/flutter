import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'occlusion_models.dart';
import 'occlusion_registry.dart';

/// A timestamped bounds sample, kept in the sliding window.
class _BoundsSample {
  const _BoundsSample(this.atMs, this.bounds);
  final int atMs;
  final Rect bounds;
}

/// Render object behind [ReplayMask]. Tracks the global bounds of its subtree
/// every frame and reports them to the [OcclusionRegistry], which the native
/// engine pulls at capture rate.
///
/// Flutter paints everything into one surface, so there is no native view to
/// hand to the engine the way the iOS/Android/React Native SDKs do — bounds
/// must be computed here and pulled across. The hard part is correctness
/// under motion: scrolling lists, `IndexedStack` tab switches, page
/// transitions that detach layers, and clips. The mitigations below mirror
/// the field-proven tolerances of mature Flutter occlusion implementations:
///
///  * a short **sliding-window union** (100 ms) so a one-frame layout blip
///    never unmasks sensitive pixels,
///  * a **layer-detach grace** (500 ms) so a snapshotted page transition
///    keeps masking while its layer is briefly detached,
///  * **snap-to-device-pixels** so the rect lands on integer device pixels
///    and never leaves a 1px sliver of unmasked content,
///  * **visibility gating** so an off-screen list row or hidden tab does not
///    report stale bounds.
class ReplayMaskRenderBox extends RenderProxyBox
    implements OcclusionBoundsReporter {
  ReplayMaskRenderBox({required OcclusionRegistry registry})
      : _registry = registry;

  final OcclusionRegistry _registry;

  static const int _windowMs = 100;
  static const int _layerDetachGraceMs = 500;

  final List<_BoundsSample> _window = <_BoundsSample>[];
  Rect? _lastBounds;
  int? _layerDetachedSinceMs;
  int? _stableId;
  bool _registered = false;
  BuildContext? _context;

  static int _counter = 0;

  // A repaint boundary gives this subtree its own layer, which lets us read
  // ancestor opacity layers to detect "painted but fully transparent".
  @override
  bool get isRepaintBoundary => true;

  void attachContext(BuildContext context) => _context = context;

  // ── Pipeline lifecycle ───────────────────────────────────────────────────

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _ensureStableId();
    if (!_registered) {
      _registered = true;
      _registry.register(this);
    }
  }

  @override
  void detach() {
    if (_registered) {
      _registered = false;
      // Hand the last-known bounds to the registry so a recycled/transitioning
      // entry keeps masking through the detach grace, not flickering open.
      _registry.markDetached(this);
    }
    super.detach();
  }

  @override
  void dispose() {
    _registry.remove(this);
    _registered = false;
    super.dispose();
  }

  // ── Identity ─────────────────────────────────────────────────────────────

  void _ensureStableId() => _stableId ??= _deriveStableId();

  int _deriveStableId() {
    // Prefer the widget key — survives list recycling and tab switches.
    final BuildContext? ctx = _context;
    if (ctx is Element) {
      final Key? key = ctx.widget.key;
      if (key != null) return Object.hash('key', key);
    }
    // Else a lazy-list slot is identified by its sliver index + view.
    final Object? pd = parentData;
    if (pd is SliverMultiBoxAdaptorParentData && pd.index != null) {
      return Object.hash('sliver', pd.index, _viewId());
    }
    // Otherwise a process-unique counter (stable for this box's lifetime).
    return Object.hash('gen', ++_counter);
  }

  @override
  int get stableId {
    _ensureStableId();
    return _stableId!;
  }

  // ── Visibility gating ────────────────────────────────────────────────────

  /// True if some ancestor isn't actually painting this subtree (hidden
  /// `IndexedStack` branch, scrolled-away `Offstage`/viewport sliver) or a
  /// fully-transparent opacity layer sits above it.
  bool _isInvisible() {
    RenderObject? child = this;
    RenderObject? ancestor = parent;
    while (ancestor != null) {
      if (!ancestor.paintsChild(child!)) return true;
      if (ancestor is RenderViewport && _isSliverHidden(ancestor, child)) {
        return true;
      }
      child = ancestor;
      ancestor = ancestor.parent;
    }
    return _isUnderZeroOpacity();
  }

  bool _isSliverHidden(RenderViewport viewport, RenderObject from) {
    RenderObject? current = from;
    while (current != null && current != viewport) {
      if (current is RenderSliver) {
        final SliverGeometry? g = current.geometry;
        if (g == null) return false;
        return !g.visible || g.paintExtent <= 0;
      }
      current = current.parent;
    }
    return false;
  }

  bool _isUnderZeroOpacity() {
    final ContainerLayer? root = layer;
    if (root == null || !root.attached) return false;
    Layer? l = root.parent;
    while (l != null) {
      if (l is OpacityLayer && (l.alpha ?? 255) == 0) return true;
      l = l.parent;
    }
    return false;
  }

  // ── Bounds computation ───────────────────────────────────────────────────

  Rect? _computeGlobalBounds() {
    if (!attached || !hasSize) return null;

    final Matrix4 transform = getTransformTo(null);
    Rect bounds = MatrixUtils.transformRect(transform, Offset.zero & size);

    // Intersect with every ancestor clip so a widget scrolled half under a
    // clip reports only its visible portion (we must not mask outside it).
    final Rect? clip = _accumulatedClip();
    if (clip != null) bounds = bounds.intersect(clip);

    if (bounds.width <= 0 || bounds.height <= 0) return null;
    return _snapToDevicePixels(bounds, devicePixelRatio);
  }

  Rect? _accumulatedClip() {
    Rect? acc;
    RenderObject? child = this;
    RenderObject? ancestor = parent;
    while (ancestor != null) {
      if (ancestor is RenderBox) {
        final Rect? clip = ancestor.describeApproximatePaintClip(child!);
        if (clip != null) {
          final Rect global =
              MatrixUtils.transformRect(ancestor.getTransformTo(null), clip);
          acc = acc?.intersect(global) ?? global;
        }
      }
      child = ancestor;
      ancestor = ancestor.parent;
    }
    return acc;
  }

  Rect _snapToDevicePixels(Rect r, double dpr) => Rect.fromLTRB(
        (r.left * dpr).floorToDouble() / dpr,
        (r.top * dpr).floorToDouble() / dpr,
        (r.right * dpr).ceilToDouble() / dpr,
        (r.bottom * dpr).ceilToDouble() / dpr,
      );

  double _viewDpr() {
    final BuildContext? ctx = _context;
    if (ctx != null) {
      final v = View.maybeOf(ctx);
      if (v != null) return v.devicePixelRatio;
    }
    return WidgetsBinding
        .instance.platformDispatcher.views.first.devicePixelRatio;
  }

  int _viewId() {
    final BuildContext? ctx = _context;
    if (ctx != null) {
      final v = View.maybeOf(ctx);
      if (v != null) return v.viewId;
    }
    return 0;
  }

  // ── Sliding window ───────────────────────────────────────────────────────

  void _prune(int nowMs) =>
      _window.removeWhere((s) => s.atMs < nowMs - _windowMs);

  void _push(Rect bounds, int nowMs) {
    _window.add(_BoundsSample(nowMs, bounds));
    _prune(nowMs);
  }

  bool _layerDetached(int nowMs) {
    final ContainerLayer? root = layer;
    if (root == null || !root.attached) {
      _layerDetachedSinceMs ??= nowMs;
      return true;
    }
    _layerDetachedSinceMs = null;
    return false;
  }

  // ── OcclusionBoundsReporter ──────────────────────────────────────────────

  @override
  Rect? get currentBounds => _lastBounds;

  @override
  double get devicePixelRatio => _viewDpr();

  @override
  Rect? unionOfRecentBounds() {
    _prune(DateTime.now().millisecondsSinceEpoch);
    Rect? u;
    for (final _BoundsSample s in _window) {
      if (s.bounds.width > 0 && s.bounds.height > 0) {
        u = u == null ? s.bounds : u.expandToInclude(s.bounds);
      }
    }
    return u;
  }

  @override
  void refreshBounds() {
    if (!attached || !hasSize) return;
    final BuildContext? ctx = _context;
    if (ctx is Element && !ctx.mounted) return;

    final int nowMs = DateTime.now().millisecondsSinceEpoch;

    // During a snapshotted page transition the layer briefly detaches. Keep
    // masking with the last bounds for the grace window rather than flicker.
    if (_layerDetached(nowMs)) {
      final int detachedMs = nowMs - (_layerDetachedSinceMs ?? nowMs);
      if (detachedMs > _layerDetachGraceMs) {
        _window.clear();
        _lastBounds = null;
      } else if (_lastBounds != null) {
        _push(_lastBounds!, nowMs);
      }
      return;
    }

    _prune(nowMs);

    if (_isInvisible()) {
      _window.clear();
      _lastBounds = null;
      return;
    }

    final Rect? bounds = _computeGlobalBounds();
    if (bounds != null) {
      _lastBounds = bounds;
      _push(bounds, nowMs);
    } else if (_lastBounds != null) {
      // Transient null (mid-layout) — hold the last bounds one more sample.
      _push(_lastBounds!, nowMs);
    }
  }
}
