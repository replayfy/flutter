import 'dart:io';

import 'package:flutter/material.dart';
import 'package:replayfy_flutter/replayfy_flutter.dart';

void main() {
  // runZoned lets Replayfy capture print/debugPrint ($console) and uncaught
  // async errors ($exception) — the Flutter analogue of patching console.*.
  Replay.runZoned(() async {
    WidgetsFlutterBinding.ensureInitialized();

    // Android emulator reaches the host at 10.0.2.2; iOS simulator shares
    // the host network, so localhost works.
    final String ingestUrl = Platform.isAndroid
        ? 'http://10.0.2.2:4000'
        : 'http://localhost:4000';

    // Boot the SDK. The native engine takes over screenshots, taps,
    // performance, and crashes; the Dart layer adds masking + network +
    // console + error capture. recordNetwork/Console/Errors default on.
    await Replay.start(ReplayConfig(
      projectKey: 'rpl_pk_ef7e2fc8c7f952bcd0a69466e1a42a0625f9',
      ingestUrl: ingestUrl,
      maskAllInputs: false,
    ));

    // Headless crash-test hook. Run with
    //   flutter run --dart-define=REPLAY_AUTOCRASH=dart_fatal
    // to fire a crash a few seconds after start (enough for the session to
    // register) without needing a UI tap. Values: dart_fatal | dart_handled.
    const String autoCrash = String.fromEnvironment('REPLAY_AUTOCRASH');
    if (autoCrash.isNotEmpty) {
      Future<void>.delayed(const Duration(seconds: 6), () {
        debugPrint('[replayfy] auto-crash: $autoCrash');
        switch (autoCrash) {
          case 'dart_handled':
            // → FlutterError.onError → $exception (fatal:false)
            throw StateError('autocrash: handled dart error');
          case 'dart_fatal':
          default:
            // → PlatformDispatcher.onError → $exception (fatal:true)
            throw StateError('autocrash: fatal dart error');
        }
      });
    }

    runApp(const ExampleApp());
  });
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Replayfy Flutter',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      // REQUIRED for screen capture: native PixelCopy can't read Flutter's
      // SurfaceView, so frames are captured Dart-side via a root
      // RepaintBoundary that this builder injects. Without it the SDK records
      // events but zero frames.
      builder: Replay.appBuilder,
      // Auto-tag screens from named routes (native swizzling can't see
      // Flutter's Navigator).
      navigatorObservers: <NavigatorObserver>[ReplayNavigatorObserver()],
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String? _sessionId;

  @override
  void initState() {
    super.initState();
    Replay.tagScreenName('Home');
    _refreshSession();
  }

  Future<void> _refreshSession() async {
    final String? id = await Replay.currentSessionId();
    if (mounted) setState(() => _sessionId = id);
  }

  // Demonstrates Dart HTTP capture: this request goes through dart:io's
  // HttpClient (invisible to the native interceptors), so the Dart-side proxy
  // records it. The ingest host is excluded, so we hit a different endpoint.
  Future<void> _makeRequest() async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req =
          await client.getUrl(Uri.parse('https://api.github.com/zen'));
      final HttpClientResponse resp = await req.close();
      await resp.drain<void>();
    } catch (_) {
      // Network errors are fine for a demo button.
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Replayfy Flutter Example')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Text('Session: ${_sessionId ?? "—"}'),
            const SizedBox(height: 24),

            // Anything inside <ReplayMask> is masked in playback per its
            // style — blur (default), overlay (solid box), or pixelate
            // (mosaic). Bounds are tracked in Dart and pulled by the engine.
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Column(
                  children: <Widget>[
                    ReplayMask(
                      child: Text('blur  4242 4242 4242 4242',
                          style: TextStyle(fontSize: 18, letterSpacing: 1)),
                    ),
                    SizedBox(height: 8),
                    ReplayMask(
                      maskStyle: ReplayMaskStyle.overlay,
                      child: Text('overlay  012-34-5678',
                          style: TextStyle(fontSize: 18, letterSpacing: 1)),
                    ),
                    SizedBox(height: 8),
                    ReplayMask(
                      maskStyle: ReplayMaskStyle.pixelate,
                      child: Text('pixelate  hunter2',
                          style: TextStyle(fontSize: 18, letterSpacing: 1)),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),

            FilledButton(
              onPressed: () => Replay.track('cta_tapped',
                  properties: <String, dynamic>{'screen': 'Home'}),
              child: const Text('Track event'),
            ),
            OutlinedButton(
              onPressed: _makeRequest,
              child: const Text('Make network request'),
            ),
            OutlinedButton(
              // Captured as a $console event via runZoned's print hook.
              onPressed: () => debugPrint('Replayfy demo log line'),
              child: const Text('Log a message'),
            ),
            OutlinedButton(
              // A throw in a callback is reported via FlutterError.onError,
              // which ReplayErrorCapture forwards as a $exception (fatal:false).
              onPressed: () => throw StateError('demo: handled error'),
              child: const Text('Trigger handled error'),
            ),
            OutlinedButton(
              // An uncaught async error escapes to PlatformDispatcher.onError,
              // forwarded as a $exception (fatal:true) — the Dart analogue of
              // an unhandled crash. The app keeps running (the engine catches
              // native signals separately).
              onPressed: () => Future<void>.delayed(
                Duration.zero,
                () => throw StateError('demo: fatal async error'),
              ),
              child: const Text('Trigger fatal async error'),
            ),
            TextButton(
              onPressed: () async {
                await Replay.startNewSession();
                await _refreshSession();
              },
              child: const Text('Start new session'),
            ),
          ],
        ),
      ),
    );
  }
}
