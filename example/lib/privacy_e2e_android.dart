// Privacy fixture for the masking end-to-end run on an Android emulator.
//
// Build with `-t lib/privacy_e2e_android.dart` and pass the ingest key and
// host as --dart-define=REPLAY_API_KEY=... / REPLAY_API_HOST=... (the
// emulator reaches the host's localhost at 10.0.2.2). What must be hidden is
// magenta, what must stay visible is cyan or yellow, so a recorded frame can
// be checked pixel by pixel. MainActivity registers the two native platform
// views used here and relays commands sent with
//   adb shell am broadcast -a com.example.replayfy_flutter_example.E2E \
//     -p com.example.replayfy_flutter_example --es cmd "occlude 1"
// Every element's rect (logical px of the root view) is written to logcat
// (tag ReplayE2E) whenever the screen changes.
import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:replayfy_flutter/replayfy_flutter.dart';

void main() {
  Replay.runZoned(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Replay.start(const ReplayConfig(
      apiKey: String.fromEnvironment('REPLAY_API_KEY'),
      apiHost: String.fromEnvironment('REPLAY_API_HOST',
          defaultValue: 'http://10.0.2.2:4000'),
    ));
    runApp(const PrivacyE2EApp());
  });
}

class PrivacyE2EApp extends StatelessWidget {
  const PrivacyE2EApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Privacy E2E',
      debugShowCheckedModeBanner: false,
      builder: Replay.appBuilder,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: const PrivacyE2EScreen(),
    );
  }
}

class PrivacyE2EScreen extends StatefulWidget {
  const PrivacyE2EScreen({super.key});

  static const Color magenta = Color(0xFFFF00FF);
  static const Color cyan = Color(0xFF00FFFF);
  static const Color yellow = Color(0xFFFFFF00);
  static const Color orange = Color(0xFFFF8000);
  static const Color blue = Color(0xFF0000FF);

  @override
  State<PrivacyE2EScreen> createState() => _PrivacyE2EScreenState();
}

class _PrivacyE2EScreenState extends State<PrivacyE2EScreen> {
  static const MethodChannel _e2e = MethodChannel('replayfy_example/e2e');

  final ScrollController _scroll = ScrollController();
  final FocusNode _pwMaskedFocus = FocusNode();
  final FocusNode _pwPlainFocus = FocusNode();
  final Map<String, GlobalKey> _keys = <String, GlobalKey>{
    for (final String k in <String>[
      'yellowL', 'maskDefault', 'yellowR', 'cyanTop', 'cyanBottom',
      'maskBlur', 'native', 'webview', 'texture', 'pwMasked', 'pwPlain',
      'tapBtn', 'toggle', 'maskLow', 'cyanLow',
    ])
      k: GlobalKey(debugLabel: k),
  };

  Timer? _poll;
  int _logSeq = 0;
  String _lastCmd = 'boot';
  String _lastLogged = '';
  bool _sensitive = false;
  bool _covered = false;
  int _taps = 0;

  @override
  void initState() {
    super.initState();
    _e2e.setMethodCallHandler((MethodCall call) async {
      if (call.method == 'cmd') _run((call.arguments as String?) ?? '');
    });
    unawaited(_e2e.invokeMethod<void>('listen'));
    _poll = Timer.periodic(
        const Duration(milliseconds: 100), (_) => _logState(force: false));
  }

  @override
  void dispose() {
    _poll?.cancel();
    _e2e.setMethodCallHandler(null);
    super.dispose();
  }

  void _setSensitive(bool on, {bool keepGestures = false}) {
    setState(() => _sensitive = on);
    unawaited(Replay.occludeSensitiveScreen(on, hideGestures: !keepGestures));
  }

  void _run(String line) {
    final List<String> parts = line.trim().split(RegExp(r'\s+'));
    if (parts.isEmpty || parts.first.isEmpty) return;
    final String cmd = parts.first;
    final List<String> args = parts.sublist(1);
    switch (cmd) {
      case 'occlude':
        _setSensitive(args.isNotEmpty && args[0] == '1',
            keepGestures: args.length > 1 && args[1] == 'keep');
      case 'scroll':
        final double to = double.tryParse(args.isEmpty ? '0' : args[0]) ?? 0;
        final int ms = args.length > 1 ? int.tryParse(args[1]) ?? 0 : 0;
        if (ms == 0) {
          _scroll.jumpTo(to);
        } else {
          unawaited(_scroll.animateTo(to,
              duration: Duration(milliseconds: ms), curve: Curves.linear));
        }
      case 'focus':
        (args.isNotEmpty && args[0] == 'plain' ? _pwPlainFocus : _pwMaskedFocus)
            .requestFocus();
      case 'unfocus':
        FocusManager.instance.primaryFocus?.unfocus();
      case 'style':
        final int i = int.tryParse(args.isEmpty ? '0' : args[0]) ?? 0;
        unawaited(Replay.setMaskStyle(ReplayMaskStyle.values[i]));
      case 'push':
        // An opaque route over the screen: the platform views below it are
        // not painted, so they must get no placeholder.
        setState(() => _covered = true);
        unawaited(Navigator.of(context)
            .push(MaterialPageRoute<void>(
                builder: (BuildContext _) => const _CoverScreen()))
            .then((_) {
          if (mounted) setState(() => _covered = false);
        }));
      case 'pop':
        Navigator.of(context).maybePop();
      case 'stop':
        unawaited(Replay.stopApplicationAndUploadData());
      case 'mark':
      default:
        break;
    }
    _lastCmd = parts.join(' ');
    _logState(force: true);
  }

  // Rects in logical px of the root view (the root boundary fills it).
  Map<String, List<double>> _rects() {
    final Map<String, List<double>> out = <String, List<double>>{};
    _keys.forEach((String k, GlobalKey key) {
      final RenderObject? ro = key.currentContext?.findRenderObject();
      if (ro is RenderBox && ro.attached && ro.hasSize) {
        final Offset o = ro.localToGlobal(Offset.zero);
        out[k] = <double>[o.dx, o.dy, ro.size.width, ro.size.height]
            .map((double v) => (v * 100).roundToDouble() / 100)
            .toList();
      }
    });
    return out;
  }

  void _logState({required bool force}) {
    if (!mounted) return;
    final ui.FlutterView view = View.of(context);
    final Size win = view.physicalSize / view.devicePixelRatio;
    final Map<String, dynamic> body = <String, dynamic>{
      'cmd': _lastCmd,
      'sensitive': _sensitive,
      'covered': _covered,
      'scroll': _scroll.hasClients ? _scroll.offset : 0.0,
      'window': <double>[win.width, win.height],
      'dpr': view.devicePixelRatio,
      'focus': _pwMaskedFocus.hasFocus
          ? 'masked'
          : (_pwPlainFocus.hasFocus ? 'plain' : ''),
      'taps': _taps,
      'release': kReleaseMode,
      'rects': _rects(),
    };
    final String enc = jsonEncode(body);
    if (!force && enc == _lastLogged) return;
    _lastLogged = enc;
    body['t'] = DateTime.now().millisecondsSinceEpoch;
    body['seq'] = ++_logSeq;
    unawaited(_e2e.invokeMethod<void>('log', jsonEncode(body)));
  }

  Widget _box(String key, Color color, double w, double h) =>
      Container(key: _keys[key], width: w, height: h, color: color);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          children: <Widget>[
            Text(_sensitive ? 'SENSITIVE ON' : 'Privacy E2E',
                style: const TextStyle(fontSize: 18, color: Colors.black)),
            const SizedBox(height: 8),
            // A default-style mask hugged by visible boxes on all four sides.
            Center(child: _box('cyanTop', PrivacyE2EScreen.cyan, 300, 20)),
            Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  _box('yellowL', PrivacyE2EScreen.yellow, 16, 48),
                  ReplayMask(
                    key: _keys['maskDefault'],
                    child: Container(
                      width: 268,
                      height: 48,
                      color: PrivacyE2EScreen.magenta,
                      alignment: Alignment.center,
                      child: const Text('4111 1111 1111 1111',
                          style: TextStyle(color: Colors.white, fontSize: 18)),
                    ),
                  ),
                  _box('yellowR', PrivacyE2EScreen.yellow, 16, 48),
                ],
              ),
            ),
            Center(child: _box('cyanBottom', PrivacyE2EScreen.cyan, 300, 20)),
            const SizedBox(height: 12),
            // An explicit style still applies: blue/white stripes, blurred.
            Center(
              child: ReplayMask(
                key: _keys['maskBlur'],
                maskStyle: ReplayMaskStyle.blur,
                child: SizedBox(
                  width: 300,
                  height: 40,
                  child: Row(
                    children: List<Widget>.generate(
                        75,
                        (int i) => Container(
                            width: 4,
                            color: i.isEven
                                ? PrivacyE2EScreen.blue
                                : Colors.white)),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            // Platform views Flutter can't image, each of which must get a
            // solid placeholder: a native magenta view (AndroidView, texture
            // layer composition), a WebView (hybrid composition) and a
            // texture.
            Center(
              child: SizedBox(
                key: _keys['native'],
                width: 300,
                height: 70,
                child: defaultTargetPlatform == TargetPlatform.android
                    ? const AndroidView(viewType: 'e2e-native-box')
                    : const ColoredBox(color: PrivacyE2EScreen.magenta),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: SizedBox(
                key: _keys['webview'],
                width: 300,
                height: 80,
                child: defaultTargetPlatform == TargetPlatform.android
                    ? const _HybridWebView()
                    : const ColoredBox(color: PrivacyE2EScreen.magenta),
              ),
            ),
            const SizedBox(height: 8),
            Center(
              child: SizedBox(
                key: _keys['texture'],
                width: 120,
                height: 36,
                child: const Texture(textureId: 4242),
              ),
            ),
            const SizedBox(height: 12),
            // Wrapped: never a character in the replay.
            ReplayMask(
              key: _keys['pwMasked'],
              child: TextField(
                focusNode: _pwMaskedFocus,
                obscureText: true,
                cursorColor: PrivacyE2EScreen.magenta,
                style: const TextStyle(
                    color: PrivacyE2EScreen.magenta, fontSize: 28),
                decoration:
                    const InputDecoration(labelText: 'Password (masked)'),
              ),
            ),
            const SizedBox(height: 8),
            // Not wrapped: the documented leak (each typed character shows
            // for a moment), and a debug-build console warning.
            TextField(
              key: _keys['pwPlain'],
              focusNode: _pwPlainFocus,
              obscureText: true,
              // Black, so the orange ink is only the dots and the shown
              // character.
              cursorColor: Colors.black,
              style:
                  const TextStyle(color: PrivacyE2EScreen.orange, fontSize: 28),
              decoration:
                  const InputDecoration(labelText: 'Password (NOT masked)'),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: _keys['toggle'],
              title: const Text('Sensitive screen'),
              value: _sensitive,
              onChanged: (bool on) => _setSensitive(on),
            ),
            Center(
              child: SizedBox(
                key: _keys['tapBtn'],
                width: 200,
                height: 48,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                      backgroundColor: PrivacyE2EScreen.cyan,
                      foregroundColor: Colors.black),
                  onPressed: () => setState(() => _taps++),
                  child: Text('TapTarget $_taps'),
                ),
              ),
            ),
            const SizedBox(height: 400),
            // Further down: scrolled into view by the host.
            Center(child: _box('cyanLow', PrivacyE2EScreen.cyan, 300, 20)),
            Center(
              child: ReplayMask(
                key: _keys['maskLow'],
                child: Container(
                  width: 300,
                  height: 60,
                  color: PrivacyE2EScreen.magenta,
                  alignment: Alignment.center,
                  child: const Text('SSN 012-34-5678',
                      style: TextStyle(color: Colors.white, fontSize: 18)),
                ),
              ),
            ),
            const SizedBox(height: 600),
          ],
        ),
      ),
    );
  }
}

/// A native WebView shown through hybrid composition, so its render object is
/// a PlatformViewRenderBox rather than the RenderAndroidView of AndroidView.
class _HybridWebView extends StatelessWidget {
  const _HybridWebView();

  static const String viewType = 'e2e-webview';

  @override
  Widget build(BuildContext context) {
    return PlatformViewLink(
      viewType: viewType,
      surfaceFactory: (BuildContext context, PlatformViewController controller) =>
          PlatformViewSurface(
        controller: controller,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
      ),
      onCreatePlatformView: (PlatformViewCreationParams params) {
        final AndroidViewController controller =
            PlatformViewsService.initExpensiveAndroidView(
          id: params.id,
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParamsCodec: const StandardMessageCodec(),
        );
        controller
          ..addOnPlatformViewCreatedListener(params.onPlatformViewCreated)
          ..create();
        return controller;
      },
    );
  }
}

/// The opaque route the 'push' command covers the screen with.
class _CoverScreen extends StatelessWidget {
  const _CoverScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: PrivacyE2EScreen.cyan,
      body: Center(
        child: Text('Covered', style: TextStyle(fontSize: 24)),
      ),
    );
  }
}
