import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'occlusion_models.dart';

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
}

/// Holds the live set of [ReplayMask] regions and serves them to the native
/// engine on demand — the **pull** model.
///
/// Why pull, not push: Flutter rebuilds at display rate (60–120 fps) but the
/// engine only screenshots at ~3 fps. Pushing rects every frame would cross
/// the platform channel 20–40× more often than the data is ever read. Instead
/// we keep a warm cache here (refreshed each frame with cheap matrix math, no
/// IPC) and let native call [_handleCall] right before each capture. IPC then
/// happens at capture rate, and the response does no layout work — it just
/// reads the cache. This is the mechanism mature Flutter session-replay SDKs
/// converged on, and it maps cleanly onto our engines' existing
/// `privacyRectsProvider` hook.
class OcclusionRegistry with WidgetsBindingObserver {
  OcclusionRegistry._() {
    WidgetsBinding.instance.addObserver(this);
    _channel.setMethodCallHandler(_handleCall);
    SchedulerBinding.instance.addPersistentFrameCallback(_onFrame);
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
      ..lastUpdatedMs = DateTime.now().millisecondsSinceEpoch;
  }

  // ── Native pull ──────────────────────────────────────────────────────────

  Future<Object?> _handleCall(MethodCall call) async {
    switch (call.method) {
      case 'requestOcclusionRects':
        return currentRects();
      default:
        throw PlatformException(
          code: 'unsupported',
          message: 'Method ${call.method} is not supported',
        );
    }
  }

  /// The current occlusion rectangles in **logical pixels**, each carrying
  /// its view's `dpr` so the native bridge can convert per platform. Reads
  /// the warm cache only — no layout work on this path.
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
      });
    }
    return out;
  }

  void _expireDetached(int nowMs) => _entries.removeWhere(
        (_, e) => !e.attached && (nowMs - e.lastUpdatedMs) > _detachedTtlMs,
      );
}
