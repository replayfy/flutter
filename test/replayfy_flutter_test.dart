import 'dart:convert';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replayfy_flutter/replayfy_flutter.dart';
import 'package:replayfy_flutter/src/capture/console.dart';
import 'package:replayfy_flutter/src/capture/errors.dart';
import 'package:replayfy_flutter/src/capture/network.dart';
import 'package:replayfy_flutter/src/privacy/occlusion_registry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const command = MethodChannel('replayfy_flutter');
  const occlusion = MethodChannel('replayfy_flutter/occlusion');

  group('ReplayConfig', () {
    test('toMap carries the documented knobs with correct defaults', () {
      const c = ReplayConfig(
        apiKey: 'k',
        apiHost: 'u',
        maskAllInputs: true,
        recordNetwork: true,
      );
      final Map<String, dynamic> m = c.toMap();
      expect(m['recordScreen'], true); // default on
      expect(m['recordConsole'], true); // default on
      expect(m['recordNetwork'], true); // overridden
      expect(m['maskAllInputs'], true); // overridden
      expect(m['autoScreenName'], true);

      final Map<String, dynamic> decoded =
          jsonDecode(c.toJson()) as Map<String, dynamic>;
      expect(decoded['useRemoteConfig'], true);
    });
  });

  group('Replay facade forwards over the command channel', () {
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(command, (MethodCall call) async {
        calls.add(call);
        switch (call.method) {
          case 'isRecording':
            return true;
          case 'currentSessionId':
            return 'ses_abc';
          case 'isOptedOut':
            return false;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(command, null);
    });

    test('start sends projectKey/ingestUrl/config', () async {
      // Disable the auto-installed captures so this test doesn't mutate global
      // state (error hooks, HttpOverrides, console flag).
      await Replay.start(const ReplayConfig(
        apiKey: 'k',
        apiHost: 'u',
        recordErrors: false,
        recordNetwork: false,
        recordConsole: false,
      ));
      final MethodCall c = calls.firstWhere((MethodCall x) => x.method == 'start');
      final Map<dynamic, dynamic> a = c.arguments as Map<dynamic, dynamic>;
      expect(a['projectKey'], 'k');
      expect(a['ingestUrl'], 'u');
      expect(a['config'], isA<String>()); // JSON blob
      expect(jsonDecode(a['config'] as String)['recordScreen'], true);
    });

    test('typed getters round-trip', () async {
      expect(await Replay.isRecording(), true);
      expect(await Replay.currentSessionId(), 'ses_abc');
      expect(await Replay.isOptedOut(), false);
    });

    test('tagScreenName / track / optIn forward with the right args', () async {
      await Replay.tagScreenName('Home');
      await Replay.track('cta', properties: <String, dynamic>{'k': 1});
      await Replay.optIn();

      final MethodCall screen = calls.firstWhere((MethodCall x) => x.method == 'tagScreenName');
      expect((screen.arguments as Map)['name'], 'Home');

      final MethodCall track = calls.firstWhere((MethodCall x) => x.method == 'track');
      expect((track.arguments as Map)['name'], 'cta');
      expect(((track.arguments as Map)['properties'] as Map)['k'], 1);

      final MethodCall opt = calls.firstWhere((MethodCall x) => x.method == 'optOut');
      expect((opt.arguments as Map)['optOut'], false); // optIn == optOut(false)
    });
  });

  group('Pull-based masking', () {
    Future<void> pumpMask(WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: ReplayMask(
                child: SizedBox(
                  width: 100,
                  height: 40,
                  child: ColoredBox(color: Color(0xFF112233)),
                ),
              ),
            ),
          ),
        ),
      );
      // One frame registers the box; the next lets the persistent frame
      // callback compute + cache its bounds.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
    }

    testWidgets('a mounted ReplayMask populates the warm cache', (WidgetTester tester) async {
      await pumpMask(tester);

      final List<Map<String, dynamic>> rects =
          OcclusionRegistry.instance.currentRects();
      expect(rects, isNotEmpty);

      final Map<String, dynamic> r = rects.first;
      final double w = (r['right'] as double) - (r['left'] as double);
      final double h = (r['bottom'] as double) - (r['top'] as double);
      expect(w, closeTo(100, 2)); // device-pixel snap may add <1px/side
      expect(h, closeTo(40, 2));
      expect(r['dpr'], greaterThan(0));
      expect(r['id'], isA<int>());
      // Default style is blur (index 0).
      expect(r['style'], ReplayMaskStyle.blur.index);
    });

    testWidgets('per-region maskStyle propagates to the pulled rect',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: ReplayMask(
                maskStyle: ReplayMaskStyle.overlay,
                child: SizedBox(
                  width: 80,
                  height: 30,
                  child: ColoredBox(color: Color(0xFF445566)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));

      final List<Map<String, dynamic>> rects =
          OcclusionRegistry.instance.currentRects();
      expect(rects, isNotEmpty);
      // overlay == index 1; native rebuilds the enum from this.
      expect(rects.first['style'], ReplayMaskStyle.overlay.index);
    });

    testWidgets('native pull over the occlusion channel returns the cache',
        (WidgetTester tester) async {
      await pumpMask(tester);

      // Simulate native → Dart: invoke requestOcclusionRects on the channel
      // the plugin pulls each capture.
      final ByteData? reply = await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        occlusion.name,
        occlusion.codec
            .encodeMethodCall(const MethodCall('requestOcclusionRects')),
        (ByteData? _) {},
      );
      final Object? decoded = occlusion.codec.decodeEnvelope(reply!);
      expect(decoded, isA<List<dynamic>>());
      expect((decoded as List<dynamic>), isNotEmpty);
    });

    testWidgets('removing the mask drains the cache after the detach grace',
        (WidgetTester tester) async {
      await pumpMask(tester);
      expect(OcclusionRegistry.instance.currentRects(), isNotEmpty);

      // Replace the masked subtree with a plain box.
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      // Past the 1.5s detached TTL.
      await tester.pump(const Duration(milliseconds: 1600));

      expect(OcclusionRegistry.instance.currentRects(), isEmpty);
    });
  });

  group('Error capture', () {
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(command, (MethodCall call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(command, null);
    });

    test('a FlutterError is forwarded as a \$exception and the prior handler still runs',
        () {
      final original = FlutterError.onError;
      bool chained = false;
      // Replace the test reporter with a benign base so our synthetic error
      // doesn't fail the test, and prove install() chains it.
      FlutterError.onError = (_) => chained = true;

      ReplayErrorCapture.debugReset();
      ReplayErrorCapture.install();
      final installed = FlutterError.onError!;
      installed(FlutterErrorDetails(exception: StateError('boom')));

      FlutterError.onError = original; // restore before asserting

      expect(chained, isTrue, reason: 'previous onError must still be called');
      final MethodCall ev =
          calls.firstWhere((MethodCall c) => c.method == 'track');
      final Map<dynamic, dynamic> a = ev.arguments as Map<dynamic, dynamic>;
      expect(a['name'], r'$exception');
      final Map<dynamic, dynamic> props =
          a['properties'] as Map<dynamic, dynamic>;
      expect(props['message'], contains('boom'));
      expect(props['fatal'], false);
    });

    test('an uncaught async error is forwarded as a fatal \$exception and chains',
        () {
      final original = PlatformDispatcher.instance.onError;
      bool chained = false;
      PlatformDispatcher.instance.onError = (Object _, StackTrace __) {
        chained = true;
        return true;
      };

      ReplayErrorCapture.debugReset();
      ReplayErrorCapture.install();
      final handler = PlatformDispatcher.instance.onError!;
      handler(StateError('async-boom'), StackTrace.current);

      PlatformDispatcher.instance.onError = original; // restore before asserting

      expect(chained, isTrue, reason: 'previous onError must still be called');
      final MethodCall ev =
          calls.firstWhere((MethodCall c) => c.method == 'track');
      final Map<dynamic, dynamic> a = ev.arguments as Map<dynamic, dynamic>;
      expect(a['name'], r'$exception');
      final Map<dynamic, dynamic> props =
          a['properties'] as Map<dynamic, dynamic>;
      expect(props['message'], contains('async-boom'));
      expect(props['fatal'], true);
      expect(props['stack'], isNotNull);
    });
  });

  group('Console capture', () {
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(command, (MethodCall call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      ReplayConsoleCapture.enabled = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(command, null);
    });

    test('runZoned print forwards a \$console event when enabled', () async {
      ReplayConsoleCapture.enabled = true;
      Replay.runZoned(() {
        // ignore: avoid_print
        print('hello-from-zone');
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final MethodCall ev = calls.firstWhere((MethodCall c) =>
          c.method == 'track' &&
          (c.arguments as Map<dynamic, dynamic>)['name'] == r'$console');
      final Map<dynamic, dynamic> props =
          (ev.arguments as Map<dynamic, dynamic>)['properties']
              as Map<dynamic, dynamic>;
      expect(props['message'], 'hello-from-zone');
      expect(props['level'], 'log');
    });

    test('disabled console capture forwards nothing', () async {
      ReplayConsoleCapture.enabled = false;
      Replay.runZoned(() {
        // ignore: avoid_print
        print('should-not-record');
      });
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(calls.where((MethodCall c) => c.method == 'track'), isEmpty);
    });
  });

  group('Network capture', () {
    final List<MethodCall> calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(command, (MethodCall call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(command, null);
    });

    // Plain test(): real socket I/O needs real async, not testWidgets' FakeAsync.
    test('records a request and leaves the response body intact', () async {
      final HttpServer server =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        req.response
          ..statusCode = 201
          ..write('world');
        await req.response.close();
      });
      final int port = server.port;

      String body = '';
      await HttpOverrides.runWithHttpOverrides(() async {
        final HttpClient client = HttpClient();
        final HttpClientRequest req =
            await client.getUrl(Uri.parse('http://127.0.0.1:$port/hello?x=1'));
        final HttpClientResponse resp = await req.close();
        body = await resp.transform(const Utf8Decoder()).join();
        client.close();
      }, ReplayNetworkCapture.debugOverrides(const <String>{}));

      await server.close(force: true);
      await Future<void>.delayed(
          const Duration(milliseconds: 50)); // flush fire-and-forget

      // The proxy must not consume/truncate the body the host reads.
      expect(body, 'world');

      final MethodCall rec =
          calls.firstWhere((MethodCall c) => c.method == 'recordNetwork');
      final Map<dynamic, dynamic> a = rec.arguments as Map<dynamic, dynamic>;
      expect(a['method'], 'GET');
      expect(a['status'], 201);
      expect(a['url'] as String, contains('/hello'));
      expect(a['durationMs'], isA<int>());
    });

    test('skips the ignored ingest host', () async {
      final HttpServer server =
          await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((HttpRequest req) async {
        req.response
          ..statusCode = 200
          ..write('ok');
        await req.response.close();
      });
      final int port = server.port;

      await HttpOverrides.runWithHttpOverrides(() async {
        final HttpClient client = HttpClient();
        final HttpClientRequest req =
            await client.getUrl(Uri.parse('http://127.0.0.1:$port/up'));
        final HttpClientResponse resp = await req.close();
        await resp.drain<void>();
        client.close();
      }, ReplayNetworkCapture.debugOverrides(<String>{'127.0.0.1'}));

      await server.close(force: true);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        calls.where((MethodCall c) => c.method == 'recordNetwork'),
        isEmpty,
      );
    });
  });
}
