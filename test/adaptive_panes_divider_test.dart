import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The seam between the two panes, on a touchscreen.
///
/// A touchscreen has no hover, and a horizontal drag is not recognised until
/// the finger has already travelled past the slop — so waiting for the drag
/// means the line lights up only once it has started moving, which is the
/// moment the user no longer needs telling which line they got. [PaneDivider]
/// answers the pointer instead, through a `Listener` that sees it before the
/// gesture arena resolves.
///
/// This used to measure `multi_split_view`'s `DividerWidget` and read its
/// `highlighted` flag. That package is gone and so is the flag; what replaced
/// both draws the state directly, so this reads the colour on screen — which is
/// what the old test said it wanted and had to approximate.
void main() {
  Future<void> pump(WidgetTester tester) async {
    // Wide enough to earn two panes, and therefore a seam between them. Sized
    // on the view rather than the surface: `MediaQuery` reports the view, and
    // `AdaptivePanes` asks the constraints it is given — so a test that set the
    // surface alone would be laying out a tablet inside a phone's window.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptivePanes.detail(
            listBuilder: (_, _) => const Text('list'),
            detailBuilder: (_) => const Text('detail'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  final line = find.descendant(
    of: find.byType(PaneDivider),
    matching: find.byType(Container),
  );

  /// Whether the line is drawn as grabbed.
  ///
  /// The painted colour, not a flag: it is the whole of what this behaviour is
  /// for, and reading it leaves nothing between the assertion and the pixels.
  bool active(WidgetTester tester) {
    final context = tester.element(find.byType(PaneDivider));
    return tester.widget<Container>(line).color ==
        Hairline.activeColor(context);
  }

  testWidgets('a finger on it lights it up before the drag is recognised', (
    tester,
  ) async {
    await pump(tester);
    expect(active(tester), isFalse);

    final touch = await tester.startGesture(
      tester.getCenter(find.byType(PaneDivider)),
    );
    await tester.pump();

    // Not after moving. By the time a horizontal drag is recognised the user
    // is already dragging, and this is the only chance the line has to say it
    // was the one they got.
    expect(active(tester), isTrue);

    await touch.up();
    await tester.pump();

    expect(active(tester), isFalse);
  });

  testWidgets('and lets go when the pointer is cancelled', (tester) async {
    await pump(tester);

    final touch = await tester.startGesture(
      tester.getCenter(find.byType(PaneDivider)),
    );
    await tester.pump();
    expect(active(tester), isTrue);

    // A scroll elsewhere taking over the gesture leaves the line lit
    // otherwise, and nothing later would put it back.
    await touch.cancel();
    await tester.pump();

    expect(active(tester), isFalse);
  });

  testWidgets('a mouse leaving after a drag does not leave it lit', (
    tester,
  ) async {
    // Both ways of holding the line are true at once for a mouse drag, and
    // letting go of one must not undo the other — `_active` is the or of them.
    await pump(tester);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(find.byType(PaneDivider)));
    addTearDown(mouse.removePointer);
    await tester.pump();
    expect(active(tester), isTrue, reason: 'hovering counts');

    await mouse.down(tester.getCenter(find.byType(PaneDivider)));
    await tester.pump();
    await mouse.up();
    await tester.pump();
    expect(active(tester), isTrue, reason: 'still hovering after the release');

    await mouse.moveTo(const Offset(5, 5));
    await tester.pump();
    expect(active(tester), isFalse);
  });
}
