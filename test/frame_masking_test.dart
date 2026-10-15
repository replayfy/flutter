import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replayfy_flutter/replayfy_flutter.dart';
import 'package:replayfy_flutter/src/capture/frames.dart';
import 'package:replayfy_flutter/src/capture/gestures.dart';
import 'package:replayfy_flutter/src/privacy/privacy_state.dart';

// What each Dart frame carries for masking: ReplayMask regions in the
// boundary's own PNG pixels, platform-view placeholders, and one full-frame
// box while the screen is sensitive. Also the touches and tap labels that
// masking hides.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel command = MethodChannel('replayfy_flutter');
  const MethodChannel occlusion = MethodChannel('replayfy_flutter/occlusion');
  final ReplayFrameCapture capture = ReplayFrameCapture.instance;
  final List<MethodCall> calls = <MethodCall>[];

  final int overlay = ReplayMaskStyle.overlay.index;
  final int blur = ReplayMaskStyle.blur.index;
  final int pixelate = ReplayMaskStyle.pixelate.index;

  setUp(() {
    ReplayPrivacyState.reset();
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(command, (MethodCall call) async {
      calls.add(call);
      return null;
    });
  });

  tearDown(() {
    ReplayPrivacyState.reset();
    capture
      ..debugToImage = null
      ..debugOnFrameRects = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(command, null);
  });

  Map<String, dynamic> px(
          double left, double top, double right, double bottom, int style) =>
      <String, dynamic>{
        'left': left,
        'top': top,
        'right': right,
        'bottom': bottom,
        'style': style,
      };

  RenderRepaintBoundary boundary() => capture.rootBoundaryKey.currentContext!
      .findRenderObject()! as RenderRepaintBoundary;

  // A 400 x 800 view at a device pixel ratio of 1, so the registry's snap to
  // device pixels leaves whole logical values.
  void setView(WidgetTester tester) {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);
  }

  // One frame registers each mask; the next caches its bounds.
  Future<void> settleMasks(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
  }

  // Lays [child] out under the capture boundary, the way Replay.appBuilder
  // does, inset by [padding] so the boundary is not at the view's origin.
  Future<RenderRepaintBoundary> pumpCaptured(WidgetTester tester, Widget child,
      {EdgeInsets padding = EdgeInsets.zero}) async {
    setView(tester);
    await tester.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: Padding(
        padding: padding,
        child: Builder(
            builder: (BuildContext ctx) => capture.wrap(ctx, child)),
      ),
    ));
    await settleMasks(tester);
    return boundary();
  }

  Widget at(double left, double top, double width, double height,
          Widget child) =>
      Positioned(
          left: left, top: top, width: width, height: height, child: child);

  Iterable<MethodCall> named(String method) =>
      calls.where((MethodCall c) => c.method == method);

  group('Mask rects', () {
    testWidgets('are relative to the boundary, in PNG pixels',
        (WidgetTester tester) async {
      final RenderRepaintBoundary b = await pumpCaptured(
        tester,
        Stack(children: <Widget>[
          at(10, 20, 100, 30, const ReplayMask(child: SizedBox.expand())),
        ]),
        padding: const EdgeInsets.only(left: 40, top: 60),
      );

      expect(capture.debugFrameRects(b, 2.0), <Map<String, dynamic>>[
        px(20, 40, 220, 100, overlay), // unstyled: the default overlay
      ]);
    });

    test('round outwards to whole pixels', () {
      final List<Map<String, dynamic>> rects =
          ReplayFrameCapture.rectsForFrame(
        boundaryToRoot: Matrix4.identity(),
        size: const Size(400, 800),
        pixelRatio: 2.0,
        masks: <Map<String, dynamic>>[
          <String, dynamic>{
            'left': 10.3,
            'top': 20.7,
            'right': 60.5,
            'bottom': 40.2,
            'style': 1,
          },
        ],
        platformViews: const <Rect>[],
        defaultStyle: 0,
      );
      // floor on left/top, ceil on right/bottom.
      expect(rects, <Map<String, dynamic>>[px(20, 41, 121, 81, 1)]);
    });

    test('clip to the frame and drop what falls outside it', () {
      final List<Map<String, dynamic>> rects =
          ReplayFrameCapture.rectsForFrame(
        boundaryToRoot: Matrix4.translationValues(0, 100, 0),
        size: const Size(400, 800),
        pixelRatio: 1.0,
        masks: <Map<String, dynamic>>[
          <String, dynamic>{
            'left': 0.0,
            'top': 50.0,
            'right': 100.0,
            'bottom': 150.0,
            'style': null,
          },
          <String, dynamic>{
            'left': 0.0,
            'top': 0.0,
            'right': 100.0,
            'bottom': 90.0,
            'style': 2,
          },
        ],
        platformViews: const <Rect>[Rect.fromLTRB(390, 790, 420, 820)],
        defaultStyle: 1,
      );
      expect(rects, <Map<String, dynamic>>[
        px(0, 0, 100, 50, 1),
        px(390, 790, 400, 800, overlay),
      ]);
    });

    test('fail closed when the boundary transform cannot be inverted', () {
      final Map<String, dynamic> mask = <String, dynamic>{
        'left': 0.0,
        'top': 0.0,
        'right': 10.0,
        'bottom': 10.0,
        'style': 0,
      };
      List<Map<String, dynamic>> rects(List<Map<String, dynamic>> masks) =>
          ReplayFrameCapture.rectsForFrame(
            boundaryToRoot: Matrix4.zero(),
            size: const Size(400, 800),
            pixelRatio: 2.0,
            masks: masks,
            platformViews: const <Rect>[],
            defaultStyle: 0,
          );

      expect(rects(<Map<String, dynamic>>[mask]), <Map<String, dynamic>>[
        ReplayFrameCapture.fullFrame(const Size(400, 800), 2.0),
      ]);
      expect(rects(const <Map<String, dynamic>>[]), isEmpty);
    });

    test('fail closed on a rect that is not finite', () {
      expect(
        ReplayFrameCapture.rectsForFrame(
          boundaryToRoot: Matrix4.identity(),
          size: const Size(400, 800),
          pixelRatio: 2.0,
          masks: <Map<String, dynamic>>[
            <String, dynamic>{
              'left': double.nan,
              'top': 0.0,
              'right': 10.0,
              'bottom': 10.0,
              'style': 0,
            },
          ],
          platformViews: const <Rect>[],
          defaultStyle: 0,
        ),
        <Map<String, dynamic>>[
          ReplayFrameCapture.fullFrame(const Size(400, 800), 2.0),
        ],
      );
    });

    test('the full-frame box matches the PNG toImage makes', () {
      expect(ReplayFrameCapture.fullFrame(const Size(393, 851.5), 1.5),
          px(0, 0, 590, 1278, overlay));
    });
  });

  group('Sensitive screen', () {
    testWidgets('covers the whole frame until turned off',
        (WidgetTester tester) async {
      final RenderRepaintBoundary b = await pumpCaptured(
        tester,
        Stack(children: <Widget>[
          at(10, 20, 100, 30, const ReplayMask(child: SizedBox.expand())),
          at(30, 200, 50, 50, const Texture(textureId: 7)),
        ]),
      );
      final List<Map<String, dynamic>> normal = capture.debugFrameRects(b, 2.0);
      expect(normal, hasLength(2));

      await Replay.occludeSensitiveScreen(true);
      expect(capture.debugFrameRects(b, 2.0), <Map<String, dynamic>>[
        px(0, 0, 800, 1600, overlay),
      ]);
      final MethodCall call = named('occludeSensitiveScreen').single;
      expect(call.arguments,
          <String, dynamic>{'occlude': true, 'hideGestures': true});

      // Not ended by the session ending, a new session or a discarded one.
      await Replay.stop();
      await Replay.startNewSession();
      await Replay.cancelSession();
      expect(ReplayPrivacyState.sensitiveScreen, isTrue);
      expect(capture.debugFrameRects(b, 2.0), <Map<String, dynamic>>[
        px(0, 0, 800, 1600, overlay),
      ]);

      await Replay.occludeSensitiveScreen(false);
      expect(capture.debugFrameRects(b, 2.0), normal);
    });

    testWidgets('covers the frame with no mask on screen',
        (WidgetTester tester) async {
      final RenderRepaintBoundary b =
          await pumpCaptured(tester, const SizedBox.expand());
      expect(capture.debugFrameRects(b, 1.0), isEmpty);

      await Replay.occludeSensitiveScreen(true);
      expect(capture.debugFrameRects(b, 1.0), <Map<String, dynamic>>[
        px(0, 0, 400, 800, overlay),
      ]);
    });
  });

  group('Platform views', () {
    testWidgets('get a solid placeholder', (WidgetTester tester) async {
      final RenderRepaintBoundary b = await pumpCaptured(
        tester,
        Stack(children: <Widget>[
          at(30, 30, 50, 50, const Texture(textureId: 7)),
        ]),
      );
      expect(capture.debugFrameRects(b, 2.0), <Map<String, dynamic>>[
        px(60, 60, 160, 160, overlay),
      ]);

      ReplayPrivacyState.maskPlatformViews = false;
      expect(capture.debugFrameRects(b, 2.0), isEmpty);
    });

    testWidgets('cover only the part their ancestors\' clips show',
        (WidgetTester tester) async {
      // A 300 px texture in a list, scrolled 200 px up under the list's top
      // edge, which sits 100 px down the screen (below an app bar, say).
      final ScrollController scroll = ScrollController();
      addTearDown(scroll.dispose);
      final RenderRepaintBoundary b = await pumpCaptured(
        tester,
        Stack(children: <Widget>[
          at(
            0,
            100,
            400,
            400,
            ListView(controller: scroll, children: const <Widget>[
              SizedBox(height: 300, child: Texture(textureId: 7)),
              SizedBox(height: 1000),
            ]),
          ),
        ]),
      );
      scroll.jumpTo(200);
      await tester.pump();

      expect(capture.debugFrameRects(b, 1.0), <Map<String, dynamic>>[
        px(0, 100, 400, 200, overlay), // not 0..-100 over the app bar
      ]);

      // Scrolled out of the list entirely: nothing to cover.
      scroll.jumpTo(350);
      await tester.pump();
      expect(capture.debugFrameRects(b, 1.0), isEmpty);
    });

    testWidgets('get none in a hidden IndexedStack child',
        (WidgetTester tester) async {
      final RenderRepaintBoundary b = await pumpCaptured(
        tester,
        const IndexedStack(children: <Widget>[
          SizedBox.expand(),
          Texture(textureId: 7),
        ]),
      );
      expect(capture.debugFrameRects(b, 1.0), isEmpty);
    });

    testWidgets('get none on a route covered by an opaque one',
        (WidgetTester tester) async {
      // Routes without transitions, so nothing but the Overlay keeps the
      // covered route out of the frame (a fade would hide it on its own).
      PageRouteBuilder<void> page(Widget child) => PageRouteBuilder<void>(
            transitionDuration: Duration.zero,
            reverseTransitionDuration: Duration.zero,
            pageBuilder: (_, __, ___) => child,
          );
      final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
      await pumpCaptured(
        tester,
        Navigator(
          key: navigator,
          onGenerateRoute: (_) => page(Stack(children: <Widget>[
            at(30, 30, 50, 50, const Texture(textureId: 7)),
          ])),
        ),
      );
      expect(capture.debugFrameRects(boundary(), 1.0), <Map<String, dynamic>>[
        px(30, 30, 80, 80, overlay),
      ]);

      navigator.currentState!
          .push(page(const ColoredBox(color: Color(0xFFFFFFFF))));
      await tester.pumpAndSettle();
      expect(capture.debugFrameRects(boundary(), 1.0), isEmpty);

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(capture.debugFrameRects(boundary(), 1.0), hasLength(1));
    });

    test('ReplayConfig.maskPlatformViews defaults on and is sent natively',
        () {
      expect(
          const ReplayConfig(apiKey: 'k', apiHost: 'u')
              .toMap()['maskPlatformViews'],
          true);
      expect(
          const ReplayConfig(apiKey: 'k', apiHost: 'u', maskPlatformViews: false)
              .toMap()['maskPlatformViews'],
          false);
    });

    testWidgets('Replay.start applies maskPlatformViews',
        (WidgetTester tester) async {
      addTearDown(ReplayGestureCapture.uninstall);
      await Replay.start(const ReplayConfig(
        apiKey: 'k',
        apiHost: 'u',
        recordScreen: false,
        recordErrors: false,
        recordNetwork: false,
        recordConsole: false,
        maskPlatformViews: false,
      ));
      expect(ReplayPrivacyState.maskPlatformViews, isFalse);
    });
  });

  group('Snapshotted page transitions', () {
    // The zoom transition draws both pages as snapshot images, scaled by a
    // painter the render tree doesn't report: a mask's layer is detached
    // meanwhile and its bounds can't follow the pixels.
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    const Widget masked = Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: EdgeInsets.all(20),
        child: ReplayMask(child: SizedBox(width: 100, height: 40)),
      ),
    );

    Future<void> pumpApp(WidgetTester tester, Widget home,
        {PageTransitionsBuilder transition =
            const ZoomPageTransitionsBuilder()}) async {
      setView(tester);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        builder: Replay.appBuilder,
        theme: ThemeData(
          pageTransitionsTheme: PageTransitionsTheme(
            builders: <TargetPlatform, PageTransitionsBuilder>{
              for (final TargetPlatform p in TargetPlatform.values)
                p: transition,
            },
          ),
        ),
        home: home,
      ));
      await settleMasks(tester);
    }

    void push(Widget page) => navigator.currentState!
        .push(MaterialPageRoute<void>(builder: (_) => page));

    // A mask's sliding window and detach grace run on the wall clock, which
    // pump doesn't move: let real time pass, then draw a frame (masks update
    // once per frame).
    Future<void> wait(WidgetTester tester, int ms) async {
      await tester.runAsync(
          () => Future<void>.delayed(Duration(milliseconds: ms)));
      tester.binding.scheduleFrame();
      await tester.pump();
    }

    testWidgets('cover the frame while a masked page zooms in',
        (WidgetTester tester) async {
      await pumpApp(tester, const ColoredBox(color: Color(0xFFFFFFFF)));
      push(masked);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      // Its mask had no bounds before; it has none it can trust now.
      expect(capture.debugFrameRects(boundary(), 1.0), <Map<String, dynamic>>[
        px(0, 0, 400, 800, overlay),
      ]);

      // Drawn as itself again: the mask follows it, and the cover ends.
      await tester.pumpAndSettle();
      await wait(tester, 150); // past the sliding window
      expect(capture.debugFrameRects(boundary(), 1.0), <Map<String, dynamic>>[
        px(20, 20, 120, 60, overlay),
      ]);
    });

    testWidgets('cover the frame while a masked page zooms out',
        (WidgetTester tester) async {
      await pumpApp(tester, masked);
      expect(capture.debugFrameRects(boundary(), 1.0), <Map<String, dynamic>>[
        px(20, 20, 120, 60, overlay),
      ]);
      push(const ColoredBox(color: Color(0xFFFFFFFF)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      expect(capture.debugFrameRects(boundary(), 1.0), <Map<String, dynamic>>[
        px(0, 0, 400, 800, overlay),
      ]);

      // Covered by the new page, it isn't drawn at all: the cover ends, and
      // the mask lets go once its detach grace is over.
      await tester.pumpAndSettle();
      await wait(tester, 150); // past the sliding window
      expect(capture.debugFrameRects(boundary(), 1.0),
          isNot(contains(px(0, 0, 400, 800, overlay))));
      await wait(tester, 500); // past the grace
      expect(capture.debugFrameRects(boundary(), 1.0), isEmpty);
    });

    testWidgets('cover a snapshot only while it is drawn',
        (WidgetTester tester) async {
      // A snapshot left switched on, on a page that then gets covered.
      final SnapshotController snapshot =
          SnapshotController(allowSnapshotting: true);
      addTearDown(snapshot.dispose);
      await pumpApp(
          tester, SnapshotWidget(controller: snapshot, child: masked));
      expect(capture.debugFrameRects(boundary(), 1.0), <Map<String, dynamic>>[
        px(0, 0, 400, 800, overlay),
      ]);

      navigator.currentState!.push(PageRouteBuilder<void>(
        transitionDuration: Duration.zero,
        pageBuilder: (_, __, ___) =>
            const ColoredBox(color: Color(0xFFFFFFFF)),
      ));
      await tester.pumpAndSettle();
      await wait(tester, 150); // past the sliding window
      expect(capture.debugFrameRects(boundary(), 1.0), isEmpty);
    });

    testWidgets('follow the page when the transition is not a snapshot',
        (WidgetTester tester) async {
      await pumpApp(tester, const ColoredBox(color: Color(0xFFFFFFFF)),
          transition: const FadeForwardsPageTransitionsBuilder());
      push(masked);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 150));
      final List<Map<String, dynamic>> rects =
          capture.debugFrameRects(boundary(), 1.0);
      expect(rects, hasLength(1));
      expect(rects.single, isNot(px(0, 0, 400, 800, overlay)));
    });
  });

  group('Image filters', () {
    // Flutter's stretch overscroll on Android (Impeller) draws a list through
    // an ImageFiltered shader that shifts its pixels along the list, by
    // nothing the render tree reports. Test runs have no shader filters, so a
    // matrix filter that moves the pixels 40 px down stands in for it.
    final ui.ImageFilter shift =
        ui.ImageFilter.matrix(Matrix4.translationValues(0, 40, 0).storage);

    // The sliding window runs on the wall clock, which pump doesn't move.
    Future<void> wait(WidgetTester tester, int ms) async {
      await tester.runAsync(
          () => Future<void>.delayed(Duration(milliseconds: ms)));
      tester.binding.scheduleFrame();
      await tester.pump();
    }

    Future<RenderRepaintBoundary> pumpFiltered(
        WidgetTester tester, ValueNotifier<bool> on, Widget content) {
      return pumpCaptured(
        tester,
        Stack(children: <Widget>[
          at(
            0,
            100,
            400,
            300,
            ValueListenableBuilder<bool>(
              valueListenable: on,
              builder: (_, bool enabled, Widget? child) => ImageFiltered(
                  enabled: enabled, imageFilter: shift, child: child),
              child: Stack(children: <Widget>[content]),
            ),
          ),
        ]),
      );
    }

    testWidgets('a mask covers all that a filter over it draws',
        (WidgetTester tester) async {
      final ValueNotifier<bool> on = ValueNotifier<bool>(true);
      addTearDown(on.dispose);
      final RenderRepaintBoundary b = await pumpFiltered(tester, on,
          at(10, 20, 100, 30, const ReplayMask(child: SizedBox.expand())));

      expect(capture.debugFrameRects(b, 1.0), <Map<String, dynamic>>[
        px(0, 100, 400, 400, overlay), // the whole filtered area
      ]);

      // A filter that is off moves nothing: the mask's own box again, once
      // the filtered samples have left the sliding window.
      on.value = false;
      await tester.pump();
      await wait(tester, 150);
      expect(capture.debugFrameRects(b, 1.0), <Map<String, dynamic>>[
        px(10, 120, 110, 150, overlay),
      ]);
    });

    testWidgets('a platform view is covered with all that a filter over it '
        'draws', (WidgetTester tester) async {
      final ValueNotifier<bool> on = ValueNotifier<bool>(true);
      addTearDown(on.dispose);
      final RenderRepaintBoundary b = await pumpFiltered(
          tester, on, at(30, 30, 50, 50, const Texture(textureId: 7)));

      expect(capture.debugFrameRects(b, 1.0), <Map<String, dynamic>>[
        px(0, 100, 400, 400, overlay),
      ]);

      on.value = false;
      await tester.pump();
      expect(capture.debugFrameRects(b, 1.0), <Map<String, dynamic>>[
        px(30, 130, 80, 180, overlay),
      ]);
    });
  });

  group('Mask style', () {
    Widget masks() => Stack(children: <Widget>[
          at(0, 0, 10, 10, const ReplayMask(child: SizedBox.expand())),
          at(0, 20, 10, 10,
              const ReplayMask(
                  maskStyle: ReplayMaskStyle.pixelate,
                  child: SizedBox.expand())),
        ]);

    List<Object?> styles(RenderRepaintBoundary b) => capture
        .debugFrameRects(b, 1.0)
        .map((Map<String, dynamic> r) => r['style'])
        .toList();

    testWidgets('an unstyled ReplayMask follows setMaskStyle',
        (WidgetTester tester) async {
      final RenderRepaintBoundary b = await pumpCaptured(tester, masks());
      expect(styles(b), unorderedEquals(<int>[overlay, pixelate]));

      await Replay.setMaskStyle(ReplayMaskStyle.blur);
      expect(styles(b), unorderedEquals(<int>[blur, pixelate]));
      expect(named('setMaskStyle').single.arguments,
          <String, dynamic>{'style': blur});
    });

    testWidgets('the native pull never sends a rect without a style',
        (WidgetTester tester) async {
      await pumpCaptured(tester, masks());
      final ByteData? reply = await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        occlusion.name,
        occlusion.codec
            .encodeMethodCall(const MethodCall('requestOcclusionRects')),
        (ByteData? _) {},
      );
      final List<Object?> rects =
          occlusion.codec.decodeEnvelope(reply!) as List<Object?>;
      expect(
        rects.map((Object? r) => (r! as Map<Object?, Object?>)['style']),
        unorderedEquals(<int>[overlay, pixelate]),
      );
    });
  });

  group('Frame capture', () {
    testWidgets('builds the rects in the same turn as it images the frame',
        (WidgetTester tester) async {
      final RenderRepaintBoundary b = await pumpCaptured(
        tester,
        Stack(children: <Widget>[
          at(10, 20, 100, 30, const ReplayMask(child: SizedBox.expand())),
        ]),
      );
      final ui.Image image = (await tester.runAsync(
          () => createTestImage(width: 4, height: 4, cache: false)))!;

      int built = 0;
      bool microtaskRan = false;
      int? builtWhenImaged;
      bool? microtaskRanWhenImaged;
      capture
        ..debugOnFrameRects = () {
          built++;
          scheduleMicrotask(() => microtaskRan = true);
        }
        ..debugToImage = (RenderRepaintBoundary _, double __) {
          builtWhenImaged = built;
          microtaskRanWhenImaged = microtaskRan;
          return Future<ui.Image>.value(image);
        };

      await tester.runAsync(capture.debugCaptureOnce);

      expect(builtWhenImaged, 1);
      // A microtask queued as the rects were built had not run yet: nothing
      // awaited in between.
      expect(microtaskRanWhenImaged, isFalse);
      expect(microtaskRan, isTrue);

      // The frame carries those rects. Frames are imaged at the platform
      // view's pixel ratio, capped at 2.
      capture.debugOnFrameRects = null;
      final double dpr =
          ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
      final double pr = dpr > 2.0 ? 2.0 : dpr;
      final Map<Object?, Object?> frame =
          named('reportFrame').single.arguments as Map<Object?, Object?>;
      expect(frame['bytes'], isA<Uint8List>());
      expect(frame['rects'], capture.debugFrameRects(b, pr));
      expect(frame['rects'], <Map<String, dynamic>>[
        px(10 * pr, 20 * pr, 110 * pr, 50 * pr, overlay),
      ]);
    });

    testWidgets('covers a frame whose screen turned sensitive while encoding',
        (WidgetTester tester) async {
      final RenderRepaintBoundary b = await pumpCaptured(
        tester,
        Stack(children: <Widget>[
          at(10, 20, 100, 30, const ReplayMask(child: SizedBox.expand())),
        ]),
      );
      final ui.Image image = (await tester.runAsync(
          () => createTestImage(width: 4, height: 4, cache: false)))!;
      capture.debugToImage = (RenderRepaintBoundary _, double __) {
        // After this frame's rects were built, before it is sent.
        ReplayPrivacyState.sensitiveScreen = true;
        return Future<ui.Image>.value(image);
      };

      await tester.runAsync(capture.debugCaptureOnce);

      final double dpr =
          ui.PlatformDispatcher.instance.views.first.devicePixelRatio;
      final double pr = dpr > 2.0 ? 2.0 : dpr;
      final Map<Object?, Object?> frame =
          named('reportFrame').single.arguments as Map<Object?, Object?>;
      expect(frame['rects'], <Map<String, dynamic>>[
        ReplayFrameCapture.fullFrame(b.size, pr),
      ]);
    });

    testWidgets('sends no frame when the rects cannot be built',
        (WidgetTester tester) async {
      await pumpCaptured(tester, const SizedBox.expand());
      bool imaged = false;
      capture
        ..debugOnFrameRects = () {
          throw StateError('rects');
        }
        ..debugToImage = (RenderRepaintBoundary _, double __) {
          imaged = true;
          return Future<ui.Image>.error(StateError('imaged'));
        };

      await tester.runAsync(capture.debugCaptureOnce);
      expect(imaged, isFalse);
      expect(named('reportFrame'), isEmpty);
    });
  });

  group('Gestures', () {
    setUp(ReplayGestureCapture.install);
    tearDown(ReplayGestureCapture.uninstall);

    List<Map<Object?, Object?>> taps() => named('reportTap')
        .map((MethodCall c) => c.arguments as Map<Object?, Object?>)
        .toList();

    Future<void> pumpPlain(WidgetTester tester) async {
      setView(tester);
      await tester.pumpWidget(const Directionality(
          textDirection: TextDirection.ltr, child: SizedBox.expand()));
    }

    testWidgets('a sensitive screen records no touches',
        (WidgetTester tester) async {
      await pumpPlain(tester);
      await Replay.occludeSensitiveScreen(true);

      await tester.tapAt(const Offset(50, 50));
      await tester.longPressAt(const Offset(50, 50));
      expect(taps(), isEmpty);
    });

    testWidgets('hideGestures: false keeps them, without their text',
        (WidgetTester tester) async {
      setView(tester);
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: Text('4111 1111 1111 1111')),
      ));
      await Replay.occludeSensitiveScreen(true, hideGestures: false);
      // The native engines are told too: iOS drops the touches the app
      // reports unless told to keep them.
      expect(named('occludeSensitiveScreen').single.arguments,
          <String, dynamic>{'occlude': true, 'hideGestures': false});

      await tester.tap(find.text('4111 1111 1111 1111'));
      await tester.longPress(find.text('4111 1111 1111 1111'));
      expect(taps().map((Map<Object?, Object?> t) => t['kind']),
          <String>['tap', 'long_press']);
      for (final Map<Object?, Object?> t in taps()) {
        expect(t['label'], '***');
        expect(t['x'], isA<int>());
        expect(t['y'], isA<int>());
      }
    });

    testWidgets('a touch that went down before the screen turned sensitive '
        'loses its text', (WidgetTester tester) async {
      setView(tester);
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: Text('4111 1111 1111 1111')),
      ));
      final TestGesture press = await tester
          .startGesture(tester.getCenter(find.text('4111 1111 1111 1111')));
      await Replay.occludeSensitiveScreen(true, hideGestures: false);
      await press.up();

      expect(taps().single['label'], '***');
    });

    testWidgets('a long press armed before the screen turned sensitive is '
        'dropped', (WidgetTester tester) async {
      await pumpPlain(tester);
      final TestGesture press = await tester.startGesture(const Offset(50, 50));
      await Replay.occludeSensitiveScreen(true);
      await tester.pump(const Duration(milliseconds: 600));
      await press.up();
      expect(taps(), isEmpty);
    });

    testWidgets('a tap inside a ReplayMask keeps its position, not its text',
        (WidgetTester tester) async {
      setView(tester);
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: ReplayMask(child: Text('4111 1111'))),
      ));
      await tester.tap(find.text('4111 1111'));

      final Map<Object?, Object?> tap = taps().single;
      expect(tap['label'], '');
      expect(tap['x'], isA<int>());
      expect(tap['y'], isA<int>());
    });

    testWidgets('a control tapped beside masked text does not take it',
        (WidgetTester tester) async {
      setView(tester);
      await tester.pumpWidget(MaterialApp(
        home: Center(
          child: ElevatedButton(
            onPressed: () {},
            child: const ReplayMask(child: Text('4111 1111')),
          ),
        ),
      ));
      // On the button's padding, outside the masked label.
      final Rect button = tester.getRect(find.byType(ElevatedButton));
      await tester.tapAt(Offset(button.left + 4, button.center.dy));

      final Map<Object?, Object?> tap = taps().single;
      expect(tap['label'], isNot(contains('4111')));
    });

    testWidgets('an unmasked tap keeps its label', (WidgetTester tester) async {
      setView(tester);
      await tester.pumpWidget(const Directionality(
        textDirection: TextDirection.ltr,
        child: Center(child: Text('Pay now')),
      ));
      await tester.tap(find.text('Pay now'));
      expect(taps().single['label'], 'Pay now');
    });
  });

  group('Unmasked password fields', () {
    final List<String?> logs = <String?>[];
    late DebugPrintCallback original;

    setUp(() {
      logs.clear();
      original = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) => logs.add(message);
    });

    testWidgets('get one debug warning each; masked ones get none',
        (WidgetTester tester) async {
      setView(tester);
      await tester.pumpWidget(const MaterialApp(
        builder: Replay.appBuilder,
        home: Scaffold(
          body: Column(children: <Widget>[
            ReplayMask(child: TextField(obscureText: true)),
            TextField(obscureText: true, key: ValueKey<String>('bare')),
            TextField(),
          ]),
        ),
      ));
      await settleMasks(tester);

      final List<Map<String, dynamic>> rects;
      try {
        capture.debugFrameRects(boundary(), 1.0);
        rects = capture.debugFrameRects(boundary(), 1.0);
      } finally {
        debugPrint = original; // before the binding checks it was restored
      }
      final List<String?> warnings = logs
          .where((String? l) => l != null && l.contains('obscureText'))
          .toList();
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('ReplayMask'));

      // Masking behaviour does not change: only the wrapped field is covered.
      expect(rects, hasLength(1));
    });
  });

  group('Deprecated text-field APIs', () {
    test('still forward without throwing', () async {
      // ignore: deprecated_member_use_from_same_package
      await Replay.occludeAllTextFields(true);
      // ignore: deprecated_member_use_from_same_package
      await Replay.occludeAllTextView(true);
      expect(named('occludeAllTextFields').single.arguments,
          <String, dynamic>{'occlude': true});
      expect(named('occludeAllTextView').single.arguments,
          <String, dynamic>{'occlude': true});

      const ReplayConfig config = ReplayConfig(
        apiKey: 'k',
        apiHost: 'u',
        // ignore: deprecated_member_use_from_same_package
        maskAllInputs: true,
      );
      expect(config.toMap()['maskAllInputs'], true);
    });
  });
}
