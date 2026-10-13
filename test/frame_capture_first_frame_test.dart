import 'dart:ui' show FrameTiming;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replayfy_flutter/src/capture/frames.dart';

// When the Dart frame loop may start relative to the app's first frame. These
// run on the binding an app runs on, in a file (an isolate) of their own:
// testWidgets puts a widget tree in place before every test body, and the
// test binding draws frames its own way, never reporting one as rasterized.
// Frames are drawn by hand and each test is synchronous, so no capture tick
// runs and no loop outlives its test.
void main() {
  final WidgetsBinding binding = WidgetsFlutterBinding.ensureInitialized();

  void drawFrame() {
    binding.handleBeginFrame(null);
    binding.handleDrawFrame();
  }

  ReplayFrameCapture capturer() {
    final ReplayFrameCapture c =
        ReplayFrameCapture.forTesting(onTick: () async {});
    addTearDown(c.stop);
    return c;
  }

  test('a frame drawn before runApp does not start capture', () {
    // Replay.start() before runApp, and a frame before the app is attached:
    // the root boundary has nothing in it to image yet.
    expect(binding.rootElement, isNull);
    expect(binding.firstFrameRasterized, isFalse);
    final ReplayFrameCapture c = capturer();

    c.install();
    drawFrame();
    expect(c.isCapturing, isFalse);

    // runApp: the first frame with the app in it starts the loop.
    binding.attachRootWidget(binding.wrapWithDefaultView(const SizedBox()));
    drawFrame();
    expect(c.isCapturing, isTrue);
  });

  test('installed after the first frame was shown, starts without another',
      () {
    // Replay.start() late (after a consent prompt, say) on a screen that may
    // not repaint for a long time: the app is already on screen, so there is
    // no frame to wait for. The engine reports a frame's timings once it is
    // rasterized, which marks the first one shown; report them here.
    drawFrame();
    binding.platformDispatcher.onReportTimings?.call(const <FrameTiming>[]);
    expect(binding.firstFrameRasterized, isTrue);
    final ReplayFrameCapture c = capturer();

    c.install();
    expect(c.isCapturing, isTrue);
  });
}
