import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../replay_channel.dart';

/// Dart-side gesture capture that reports the **actual widget tapped**.
///
/// Why this exists: a Flutter app paints its entire UI into a single native
/// view (`FlutterView`). The native engine's view-tree hit-test therefore
/// labels every touch "FlutterView". Here we intercept pointer events globally
/// via [GestureBinding.pointerRouter], hit-test the Flutter render tree at the
/// touch point, find the nearest interactive widget, and extract a human label
/// (button text, field hint, icon, list-tile title, …) — then forward
/// `{kind, label, x, y}` over the command channel. The native engine's own
/// touch capture is turned OFF for Flutter sessions (`captureTouch: false`,
/// mirroring how Dart owns console + network), so a touch is never recorded
/// twice.
///
/// Mechanism mirrors the established Flutter session-replay approach: a global
/// pointer route + a render-tree hit-test + an element-tree label walk.
class ReplayGestureCapture {
  ReplayGestureCapture._();

  static bool _installed = false;

  // A tap fires on pointer-up if it stayed put; a drag past [_swipeMin] is a
  // swipe; a press held past [_longPressMs] is a long-press. The label is
  // always extracted on pointer-DOWN (the widget is guaranteed mounted then,
  // before any tap-triggered navigation tears it down).
  static const double _swipeMin = 24.0;
  static const int _longPressMs = 500;

  static int? _pointer;
  static Offset? _downPos;
  static String _downLabel = '';
  static Timer? _longPressTimer;
  static bool _consumed = false; // long-press already emitted for this pointer

  static void install() {
    if (_installed) return;
    _installed = true;
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
  }

  static void uninstall() {
    if (!_installed) return;
    _installed = false;
    _longPressTimer?.cancel();
    try {
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    } catch (_) {/* binding gone */}
  }

  static void _onPointer(PointerEvent e) {
    if (e is PointerDownEvent) {
      _onDown(e);
    } else if (e is PointerUpEvent) {
      _onUp(e);
    } else if (e is PointerCancelEvent) {
      _reset();
    }
  }

  static void _onDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.trackpad) return;
    _pointer = e.pointer;
    _downPos = e.position;
    _consumed = false;
    _downLabel = _labelAt(e.position, e.viewId) ?? '';

    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: _longPressMs), () {
      if (_pointer == e.pointer) {
        _consumed = true;
        _emit('long_press', e.position, _downLabel);
      }
    });
  }

  static void _onUp(PointerUpEvent e) {
    if (e.pointer != _pointer) return;
    _longPressTimer?.cancel();
    final down = _downPos;
    final label = _downLabel;
    final consumed = _consumed;
    _reset();
    if (down == null || consumed) return;

    final delta = e.position - down;
    if (delta.distance >= _swipeMin) {
      final dir = delta.dx.abs() > delta.dy.abs()
          ? (delta.dx > 0 ? 'right' : 'left')
          : (delta.dy > 0 ? 'down' : 'up');
      _emit('swipe', down, label, direction: dir);
    } else {
      _emit('tap', down, label);
    }
  }

  static void _reset() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
    _pointer = null;
    _downPos = null;
    _downLabel = '';
    _consumed = false;
  }

  static void _emit(String kind, Offset pos, String label, {String? direction}) {
    // Fire-and-forget; never let a gesture report throw into the app (e.g. a
    // platform without the `reportTap` handler yet → MissingPluginException).
    ReplayChannel.instance.invoke('reportTap', <String, dynamic>{
      'kind': kind,
      'label': label,
      'x': pos.dx.round(),
      'y': pos.dy.round(),
      if (direction != null) 'direction': direction,
    }).catchError((Object _) {});
  }

  // ── Label extraction ──────────────────────────────────────────────

  /// Hit-test at [pos] and return the best human label for what was tapped,
  /// or null. Walks the render-tree hit path, maps the hit `RenderObject`s
  /// back to `Element`s, and picks the most meaningful label deepest-first.
  static String? _labelAt(Offset pos, int viewId) {
    final hits = _hitTest(pos, viewId);
    if (hits.isEmpty) return null;

    final root = WidgetsBinding.instance.rootElement;
    if (root == null) return null;

    // Elements whose RenderObject is in the hit path, in tree order
    // (ancestor → descendant).
    final matched = <Element>[];
    void walk(Element el) {
      final ro = el.renderObject;
      if (ro != null && hits.contains(ro)) matched.add(el);
      el.visitChildren(walk);
    }

    root.visitChildren(walk);
    if (matched.isEmpty) return null;

    // Deepest (most specific) first.
    for (final el in matched.reversed) {
      final label = _labelForElement(el);
      if (label != null && label.isNotEmpty) return label;
    }
    return null;
  }

  static Set<RenderObject> _hitTest(Offset pos, int viewId) {
    final result = HitTestResult();
    try {
      RendererBinding.instance.hitTestInView(result, pos, viewId);
    } catch (_) {
      try {
        final views = WidgetsBinding.instance.renderViews;
        if (views.isNotEmpty) views.first.hitTest(result, position: pos);
      } catch (_) {/* no view */}
    }
    final set = <RenderObject>{};
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderObject) set.add(target);
    }
    return set;
  }

  /// A label for a single element: text content, field hint, icon name, or —
  /// for an interactive widget tapped on its padding — the first text/icon
  /// found in its subtree. Returns null for non-meaningful nodes so the
  /// caller keeps walking up the hit path.
  static String? _labelForElement(Element el) {
    final w = el.widget;

    // Direct text.
    if (w is Text) return w.data;
    if (w is SelectableText) return w.data;
    if (w is RichText) return _spanText(w.text);

    // Input fields → the hint/label, never the typed value (privacy).
    if (w is TextField) {
      return w.decoration?.hintText ?? w.decoration?.labelText ?? 'TextField';
    }
    if (w is CupertinoTextField) return w.placeholder ?? 'TextField';

    // Icons → semantic label or a stable icon id.
    if (w is Icon) {
      if (w.semanticLabel != null && w.semanticLabel!.isNotEmpty) {
        return w.semanticLabel;
      }
      final i = w.icon;
      if (i != null) return 'Icon(${i.fontFamily ?? ''}-${i.codePoint.toRadixString(16)})';
    }

    // Interactive containers → text/icon found inside (handles taps that land
    // on the control's padding rather than directly on its label).
    if (_isInteractive(w)) {
      final inner = _firstLabelInSubtree(el);
      return inner ?? w.runtimeType.toString();
    }
    return null;
  }

  static const Set<Type> _interactiveTypes = <Type>{
    ElevatedButton, TextButton, OutlinedButton, FilledButton, IconButton,
    FloatingActionButton, InkWell, InkResponse, ListTile, PopupMenuItem,
    BackButton, CloseButton, MenuItemButton, SegmentedButton,
    ActionChip, FilterChip, InputChip, ChoiceChip, RawChip,
    CupertinoButton, GestureDetector, Switch, Checkbox, Radio, Slider,
  };

  static bool _isInteractive(Widget w) =>
      _interactiveTypes.contains(w.runtimeType) ||
      w.runtimeType.toString().startsWith('Radio<') ||
      w.runtimeType.toString().startsWith('SegmentedButton<');

  static String? _firstLabelInSubtree(Element root) {
    String? found;
    void visit(Element el) {
      if (found != null) return;
      final w = el.widget;
      if (w is Text && (w.data?.isNotEmpty ?? false)) {
        found = w.data;
        return;
      }
      if (w is RichText) {
        final t = _spanText(w.text);
        if (t.isNotEmpty) {
          found = t;
          return;
        }
      }
      if (w is Icon && w.semanticLabel != null && w.semanticLabel!.isNotEmpty) {
        found = w.semanticLabel;
        return;
      }
      el.visitChildren(visit);
    }

    root.visitChildren(visit);
    return found;
  }

  static String _spanText(InlineSpan span) {
    final buf = StringBuffer();
    span.visitChildren((s) {
      if (s is TextSpan && s.text != null) buf.write(s.text);
      return true;
    });
    return buf.toString();
  }
}
