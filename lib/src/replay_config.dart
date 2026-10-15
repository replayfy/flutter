import 'dart:convert';

/// Top-level configuration passed to [Replayfy.start].
///
/// Field names mirror the other Replayfy SDKs (`apiKey`, `apiHost`,
/// `recordScreen`) so a team shipping on multiple stacks sees one
/// vocabulary. The native engine owns the
/// authoritative knobs (`captureSnapshotPixels`, `captureConsole`, …); this
/// config is serialised to JSON and handed to the native bridge at boot,
/// which maps it onto the native `ReplayConfig`.
class ReplayConfig {
  const ReplayConfig({
    required this.apiKey,
    required this.apiHost,
    this.distinctId,
    this.recordScreen = true,
    this.recordNetwork = true,
    this.recordConsole = true,
    this.recordErrors = true,
    this.recordPerformance = true,
    @Deprecated('Has no effect on Flutter widgets: Flutter text fields are not '
        'native text views. Wrap sensitive fields in ReplayMask.')
    this.maskAllInputs = false,
    this.maskPlatformViews = true,
    this.autoScreenName = true,
    this.useRemoteConfig = true,
    this.debug = false,
  });

  /// Project API key from the dashboard (publishable, e.g. `rpl_pk_…`).
  final String apiKey;

  /// Ingest base URL, e.g. `https://us.replayfy.app`.
  final String apiHost;

  /// Known user id at start (else an install-stable anonymous id).
  final String? distinctId;

  /// Capture screenshots/frames. Maps to native `captureSnapshotPixels`.
  /// Default true.
  final bool recordScreen;

  /// Capture network traffic. Default true (matching the React Native SDK).
  /// Implemented Dart-side via an `HttpClient` proxy — Dart's HTTP does not
  /// route through the native OkHttp/URLSession interceptors, so the native
  /// `captureNetwork` is left off and the Dart layer owns this.
  final bool recordNetwork;

  /// Capture console output (`print` / `debugPrint` → `$console` events) when
  /// the app is wrapped in `Replay.runZoned`. Default true. The Dart layer
  /// owns console capture, so native `captureConsole` is left off (no
  /// double-recording).
  final bool recordConsole;

  /// Capture unhandled errors. Maps to native `captureErrors`. Default true.
  final bool recordErrors;

  /// Capture native performance vitals (cold start, frame drops, memory,
  /// thermal, battery). Default true. (Native always collects these when a
  /// session is recording; the flag is forwarded for parity/forward-compat.)
  final bool recordPerformance;

  /// Auto-mask the host's native text inputs. Maps to native bulk text-field
  /// occlusion. Default false. Flutter text fields are drawn by Flutter, not
  /// as native text views, so this masks none of them: wrap sensitive fields
  /// in `ReplayMask`.
  @Deprecated('Has no effect on Flutter widgets: Flutter text fields are not '
      'native text views. Wrap sensitive fields in ReplayMask.')
  final bool maskAllInputs;

  /// Cover platform views (WebView, maps, camera and video textures) with a
  /// solid placeholder. Flutter cannot image their content, and what it can't
  /// see it can't mask, so they are covered whole. Default true.
  final bool maskPlatformViews;

  /// Auto-tag screens from the navigator. Maps to native `autoScreenName`.
  /// Default true.
  final bool autoScreenName;

  /// Let the dashboard override these knobs via remote config. Maps to
  /// native `useRemoteConfig`. Default true.
  final bool useRemoteConfig;

  /// Verbose SDK logging. Default false.
  final bool debug;

  /// The native bridge boots with `(projectKey, ingestUrl, configJson)`;
  /// this is the `configJson` blob the native side parses.
  Map<String, dynamic> toMap() => <String, dynamic>{
        'distinctId': distinctId,
        'recordScreen': recordScreen,
        'recordNetwork': recordNetwork,
        'recordConsole': recordConsole,
        'recordErrors': recordErrors,
        'recordPerformance': recordPerformance,
        'maskAllInputs': maskAllInputs,
        'maskPlatformViews': maskPlatformViews,
        'autoScreenName': autoScreenName,
        'useRemoteConfig': useRemoteConfig,
        'debug': debug,
      };

  String toJson() => jsonEncode(toMap());
}
