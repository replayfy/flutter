import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:replayfy_flutter/replayfy_flutter.dart';
import 'package:replayfy_flutter/src/privacy/occlusion_registry.dart';

// Without Replay.start, the first ReplayMask's build creates the registry, in
// the middle of a frame. In a file (an isolate) of its own: the registry is
// made once per process, so nothing may create it before this test does.
void main() {
  testWidgets('a mask built before the registry exists has bounds after its '
      'first frame', (WidgetTester tester) async {
    tester.view
      ..devicePixelRatio = 1.0
      ..physicalSize = const Size(400, 800);
    addTearDown(tester.view.reset);

    // One frame: it builds the mask (creating the registry), lays it out and
    // paints it. A capture right after must see the mask.
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(
          padding: EdgeInsets.all(10),
          child: ReplayMask(child: SizedBox(width: 50, height: 20)),
        ),
      ),
    ));

    final List<Map<String, dynamic>> rects =
        OcclusionRegistry.instance.currentRects();
    expect(rects, hasLength(1));
    expect(
      <Object?>[
        rects.single['left'],
        rects.single['top'],
        rects.single['right'],
        rects.single['bottom'],
      ],
      <double>[10, 10, 60, 30],
    );
  });
}
