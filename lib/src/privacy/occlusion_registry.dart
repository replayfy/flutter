import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'occlusion_models.dart';
import 'privacy_state.dart';

/// One cached occlusion entry. Holds either a live reporter or, once
/// detached, its last-known bounds for a short grace period.
class _Entry {
  _Entry(this.id);
  final int id;
  OcclusionBoundsReporter? reporter;
  Rect? lastBounds;
  double dpr = 1.0;
  int lastUpdatedMs = 0;
  bool attached = false;
  // Frozen alongside the bounds so a detached entry keeps the SAME render
  // style through its grace window (the reporter is gone by then). Null: the
  // global style, resolved when a frame is captured.
  ReplayMaskStyle? style;
}

/// Holds the live set of [ReplayMask] regions in a warm cache, refreshed each
/// frame with cheap matrix math and no IPC.
///
/// The Dart frame capturer reads the cache ([currentRects], no layout work)
/// in the same turn as it images a frame, and sends the rects with that
/// frame. The Android plugin also still pulls it through [_handleCall] for
/// the engine's own screenshotter, which Flutter apps run with off.
class OcclusionRegistry with WidgetsBindingObserver {
  OcclusionRegistry._() {
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler(_handleCall);
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
    // Built by the first ReplayMask's build (no Replay.start before it), the
    // registry is created mid-frame, and a persistent callback added then
    // only runs from the next frame: until it does, the mask has no bounds
    // and masks nothing. A post-frame callback added now runs at the end of
    // this frame, after paint, so the bounds are there before a capture can
    // read them.
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  static final OcclusionRegistry instance = OcclusionRegistry._();

  /// Call once at SDK start so the native pull handler is live even before
  /// the first [ReplayMask] mounts (avoids a MissingPluginException on the
  /// engine's first capture).
  static void ensureInitialized() => instance;

  /// Detached entries keep masking for this long before being dropped — long
  /// enough to bridge a list-recycle or a page transition.
  static const int _detachedTtlMs = 1500;

  static const MethodChannel _channel =
      MethodChannel('replayfy_flutter/occlusion');

  final Map<int, _Entry> _entries = <int, _Entry>{};

  // ── Registration (called from the render box) ────────────────────────────

  void register(OcclusionBoundsReporter box) {
    final _Entry e = _entries[box.stableId] ?? _Entry(box.stableId);
    e
      ..reporter = box
      ..attached = true;
    _refresh(e, box);
    _entries[box.stableId] = e;
  }

  void markDetached(OcclusionBoundsReporter box) {
    final _Entry? e = _entries[box.stableId];
    if (e == null) return;
    e
      ..attached = false
      ..reporter = null
      ..lastBounds = box.unionOfRecentBounds() ?? box.currentBounds
      ..dpr = box.devicePixelRatio
      ..style = box.maskStyle
      ..lastUpdatedMs = DateTime.now().millisecondsSinceEpoch;
  }

  void remove(OcclusionBoundsReporter box) => _entries.remove(box.stableId);

  // ── Frame pump (keeps the cache warm) ────────────────────────────────────

  void _onFrame(Duration _) {
    if (_entries.isEmpty) return;
    for (final _Entry e in _entries.values.toList()) {
      final OcclusionBoundsReporter? r = e.reporter;
      if (e.attached && r != null && r.attached && r.hasSize) {
        r.refreshBounds();
        _refresh(e, r);
      }
    }
  }

  void _refresh(_Entry e, OcclusionBoundsReporter box) {
    e
      ..lastBounds = box.unionOfRecentBounds() ?? box.currentBounds
      ..dpr = box.devicePixelRatio
      ..style = box.maskStyle
      ..lastUpdatedMs = DateTime.now().millisecondsSinceEpoch;
  }

  // ── Native pull ──────────────────────────────────────────────────────────

  Future<Object?> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'requestOcclusionRects':
        // Native maps a missing style to blur, so resolve the global style
        // here: a rect never crosses the channel without one.
        final int fallback = ReplayPrivacyState.globalMaskStyle.index;
        return currentRects()
            .map((Map<String, dynamic> r) => <String, dynamic>{
                  ...r,
                  'style': (r['style'] as int?) ?? fallback,
                })
            .toList();
      default:
        throw PlatformException(
          code: 'unsupported',
          message: 'Method ${call.method} is not supported',
        );
    }
  }

  /// The current occlusion rectangles in **logical pixels** of the root view,
  /// each carrying its view's `dpr`. Reads the warm cache only — no layout
  /// work on this path. `style` is null for a mask that sets none; the frame
  /// capturer resolves it to the global style.
  List<Map<String, dynamic>> currentRects() {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    _expireDetached(nowMs);

    final List<Map<String, dynamic>> out = <Map<String, dynamic>>[];
    for (final _Entry e in _entries.values.toList()) {
      Rect? bounds;
      if (e.attached) {
        final OcclusionBoundsReporter? r = e.reporter;
        bounds = r?.unionOfRecentBounds() ?? r?.currentBounds ?? e.lastBounds;
      } else {
        // Within the grace window — keep masking with the frozen bounds.
        if (nowMs - e.lastUpdatedMs > _detachedTtlMs) continue;
        bounds = e.lastBounds;
      }
      if (bounds == null || bounds.width <= 0 || bounds.height <= 0) continue;
      out.add(<String, dynamic>{
        'id': e.id,
        'left': bounds.left,
        'top': bounds.top,
        'right': bounds.right,
        'bottom': bounds.bottom,
        'dpr': e.dpr,
        // Native rebuilds the enum from this index (blur = 0, overlay = 1,
        // pixelate = 2).
        'style': e.style?.index,
      });
    }
    return out;
  }

  void _expireDetached(int nowMs) => _entries.removeWhere(
        (_, e) => !e.attached && (nowMs - e.lastUpdatedMs) > _detachedTtlMs,
      );
}
