import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replayfy_flutter/replayfy_flutter.dart';
import 'package:replayfy_flutter/src/capture/frames.dart';

// The Dart frame loop's scheduling: when it runs, and that it never runs
// twice. Ticks are counted through ReplayFrameCapture.forTesting in
// testWidgets' fake time, so 2 s of pumping is exactly 4 ticks of one loop.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const Duration twoSeconds = Duration(seconds: 2);
  const int ticksPerTwoSeconds = 4; // one loop at ReplayFrameCapture.interval

  void setLifecycle(WidgetTester tester, AppLifecycleState state) =>
      tester.binding.handleAppLifecycleStateChanged(state);

  // Lay out a frame; capture waits for one before it starts.
  Future<void> drawFrame(WidgetTester tester) async {
    tester.binding.scheduleFrame();
    await tester.pump();
  }

  // A capturer for one test. Every test stops it before it ends (testWidgets
  // fails on a timer left running); the teardown also puts the app back in
  // the foreground for the next test.
  ReplayFrameCapture capturer(WidgetTester tester, void Function() onTick) {
    final ReplayFrameCapture c =
        ReplayFrameCapture.forTesting(onTick: () async => onTick());
    addTearDown(() {
      c.stop();
      setLifecycle(tester, AppLifecycleState.resumed);
    });
    return c;
  }

  testWidgets('waits for a laid-out frame before capturing',
      (WidgetTester tester) async {
    // The test binding never reports a rasterized frame, so this exercises
    // the wait start() does when it runs before runApp.
    expect(tester.binding.firstFrameRasterized, isFalse);
    int ticks = 0;
    final ReplayFrameCapture c = capturer(tester, () => ticks++);

    c.install();
    await tester.pump(twoSeconds); // time passes, nothing is drawn
    expect(c.isCapturing, isFalse);
    expect(ticks, 0);

    await drawFrame(tester);
    expect(c.isCapturing, isTrue);
    await tester.pump(twoSeconds);
    expect(ticks, ticksPerTwoSeconds);
    c.stop();
  });

  testWidgets('stops in the background and restarts on resumed',
      (WidgetTester tester) async {
    int ticks = 0;
    final ReplayFrameCapture c = capturer(tester, () => ticks++);
    c.install();
    await drawFrame(tester);
    expect(c.isCapturing, isTrue);

    // Leaving the app: still on screen while inactive (app switcher, a
    // system dialog), gone once hidden then paused.
    setLifecycle(tester, AppLifecycleState.inactive);
    expect(c.isCapturing, isTrue);
    setLifecycle(tester, AppLifecycleState.hidden);
    expect(c.isCapturing, isFalse);
    setLifecycle(tester, AppLifecycleState.paused);
    expect(c.isCapturing, isFalse);

    ticks = 0;
    await tester.pump(twoSeconds);
    expect(ticks, 0, reason: 'no frames while the app is in the background');

    // Coming back: hidden, inactive (on screen again), resumed. No new frame
    // is needed: the app was laid out before it left.
    setLifecycle(tester, AppLifecycleState.hidden);
    expect(c.isCapturing, isFalse);
    setLifecycle(tester, AppLifecycleState.inactive);
    setLifecycle(tester, AppLifecycleState.resumed);
    expect(c.isCapturing, isTrue);
    await tester.pump(twoSeconds);
    expect(ticks, ticksPerTwoSeconds);
    c.stop();
  });

  testWidgets('paused stops capture and resumed restarts it',
      (WidgetTester tester) async {
    int ticks = 0;
    final ReplayFrameCapture c = capturer(tester, () => ticks++);
    c.install();
    await drawFrame(tester);

    setLifecycle(tester, AppLifecycleState.paused);
    expect(c.isCapturing, isFalse);
    await tester.pump(twoSeconds);
    expect(ticks, 0);

    setLifecycle(tester, AppLifecycleState.resumed);
    expect(c.isCapturing, isTrue);
    await tester.pump(twoSeconds);
    expect(ticks, ticksPerTwoSeconds);
    c.stop();
  });

  testWidgets('detached stops capture', (WidgetTester tester) async {
    final ReplayFrameCapture c = capturer(tester, () {});
    c.install();
    await drawFrame(tester);

    setLifecycle(tester, AppLifecycleState.detached);
    expect(c.isCapturing, isFalse);
    c.stop();
  });

  testWidgets('never runs two loops', (WidgetTester tester) async {
    int ticks = 0;
    final ReplayFrameCapture c = capturer(tester, () => ticks++);

    // A second Replay.start(), and resumes, before and after the first frame.
    c.install();
    c.install();
    setLifecycle(tester, AppLifecycleState.inactive);
    setLifecycle(tester, AppLifecycleState.resumed);
    await drawFrame(tester);
    c.install();
    setLifecycle(tester, AppLifecycleState.inactive);
    setLifecycle(tester, AppLifecycleState.resumed);
    setLifecycle(tester, AppLifecycleState.paused);
    setLifecycle(tester, AppLifecycleState.resumed);
    c.install();
    await drawFrame(tester);

    ticks = 0;
    await tester.pump(twoSeconds);
    expect(ticks, ticksPerTwoSeconds);
    c.stop();
  });

  testWidgets('installed in the background, starts once the app is resumed',
      (WidgetTester tester) async {
    int ticks = 0;
    final ReplayFrameCapture c = capturer(tester, () => ticks++);
    setLifecycle(tester, AppLifecycleState.paused);

    c.install();
    await tester.pump(twoSeconds);
    expect(c.isCapturing, isFalse);
    expect(ticks, 0);

    // Resuming schedules a frame; capture starts once it is laid out.
    setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(c.isCapturing, isTrue);
    c.stop();
  });

  testWidgets(
      'cold start: installed at detached, starts once the app is on screen',
      (WidgetTester tester) async {
    int ticks = 0;
    final ReplayFrameCapture c = capturer(tester, () => ticks++);
    // Both engines report detached until the host's first lifecycle event, so
    // this is what Replay.start() in main() sees.
    setLifecycle(tester, AppLifecycleState.detached);

    c.install();
    // runApp's first frame, which Flutter draws whatever the lifecycle state
    // (scheduleFrame does nothing while detached).
    tester.binding.scheduleForcedFrame();
    await tester.pump();
    await tester.pump(twoSeconds);
    expect(c.isCapturing, isFalse);
    expect(ticks, 0);

    // iOS reports inactive as the view appears (Android goes straight to
    // resumed); the app is on screen from then on.
    setLifecycle(tester, AppLifecycleState.inactive);
    await tester.pump();
    expect(c.isCapturing, isTrue);
    setLifecycle(tester, AppLifecycleState.resumed);
    await tester.pump(twoSeconds);
    expect(ticks, ticksPerTwoSeconds);
    c.stop();
  });

  testWidgets('stop() keeps capture off when the app comes back',
      (WidgetTester tester) async {
    int ticks = 0;
    final ReplayFrameCapture c = capturer(tester, () => ticks++);
    c.install();
    await drawFrame(tester);

    c.stop();
    expect(c.isCapturing, isFalse);
    setLifecycle(tester, AppLifecycleState.paused);
    setLifecycle(tester, AppLifecycleState.resumed);
    await drawFrame(tester);
    await tester.pump(twoSeconds);
    expect(c.isCapturing, isFalse);
    expect(ticks, 0);
  });

  group('Replay facade', () {
    const MethodChannel command = MethodChannel('replayfy_flutter');

    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(command, (MethodCall call) async => null);
    });

    tearDown(() {
      ReplayFrameCapture.instance.stop();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(command, null);
    });

    // Replay.stop() never stopped the Dart loop, and still doesn't: a session
    // the native engine opens later without Replay.start() (startNewSession,
    // Android's rotation after a long break) gets its frames only from Dart.
    testWidgets('Replay.stop() leaves foreground capture running',
        (WidgetTester tester) async {
      addTearDown(() => setLifecycle(tester, AppLifecycleState.resumed));
      await Replay.start(const ReplayConfig(
        apiKey: 'k',
        apiHost: 'u',
        recordErrors: false,
        recordNetwork: false,
        recordConsole: false,
      ));
      await drawFrame(tester);
      expect(ReplayFrameCapture.instance.isCapturing, isTrue);

      await Replay.stop();
      expect(ReplayFrameCapture.instance.isCapturing, isTrue);

      setLifecycle(tester, AppLifecycleState.paused);
      expect(ReplayFrameCapture.instance.isCapturing, isFalse);
      setLifecycle(tester, AppLifecycleState.resumed);
      expect(ReplayFrameCapture.instance.isCapturing, isTrue);
      ReplayFrameCapture.instance.stop(); // no timer may outlive the test
    });

    testWidgets('recordScreen: false never captures',
        (WidgetTester tester) async {
      await Replay.start(const ReplayConfig(
        apiKey: 'k',
        apiHost: 'u',
        recordScreen: false,
        recordErrors: false,
        recordNetwork: false,
        recordConsole: false,
      ));
      await drawFrame(tester);
      setLifecycle(tester, AppLifecycleState.paused);
      setLifecycle(tester, AppLifecycleState.resumed);
      expect(ReplayFrameCapture.instance.isCapturing, isFalse);
    });
  });
}
