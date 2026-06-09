import 'package:flutter/widgets.dart';

import '../replayfy_flutter.dart';

/// Tags Replayfy screens from the Flutter [Navigator].
///
/// Native auto-screen detection swizzles `UIViewController` / `Activity`
/// transitions — but a Flutter app is a single host controller, so route
/// changes never surface there. Drop this observer into your app to tag
/// screens automatically from named routes:
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [ReplayNavigatorObserver()],
/// );
/// ```
///
/// Routes without a `settings.name` are skipped (use a [RouteSettings] name,
/// or call [Replay.tagScreenName] manually for those screens).
class ReplayNavigatorObserver extends NavigatorObserver {
  ReplayNavigatorObserver({this.nameOf});

  /// Optional custom resolver, e.g. to derive a name from arguments. Return
  /// null to skip tagging for that route.
  final String? Function(Route<dynamic> route)? nameOf;

  void _tag(Route<dynamic>? route) {
    if (route == null) return;
    final String? name = nameOf?.call(route) ?? route.settings.name;
    if (name == null || name.isEmpty) return;
    Replay.tagScreenName(name);
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _tag(route);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    // Returning to the screen underneath — re-tag it.
    _tag(previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    _tag(newRoute);
  }
}
