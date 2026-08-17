import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A grabbed divider says so, on every kind of pointer.
///
/// It used to say so only on hover, which a touchscreen does not have: on a
/// tablet the line could be held and dragged with nothing on screen confirming
/// it had been grabbed at all.
void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              height: 400,
              child: PaneDivider(onDrag: (_) {}),
            ),
          ),
        ),
      ),
    );
  }

  /// The colour of the hairline itself, not of the grab area around it.
  Color? lineColor(WidgetTester tester) {
    return tester
        .widget<Container>(
          find.descendant(
            of: find.byType(PaneDivider),
            matching: find.byType(Container),
          ),
        )
        .color;
  }

  testWidgets('a finger on the line lights it up, and lifting it does not', (
    tester,
  ) async {
    await pump(tester);
    final resting = lineColor(tester);

    final touch = await tester.startGesture(
      tester.getCenter(find.byType(PaneDivider)),
    );
    await tester.pump();

    // Before any movement: a horizontal drag is not recognised until the
    // finger has travelled, and by then the feedback is too late to be of use.
    expect(lineColor(tester), isNot(resting));

    await touch.up();
    await tester.pump();

    expect(lineColor(tester), resting);
  });

  testWidgets('what a press shows is what a hover shows', (tester) async {
    await pump(tester);
    final center = tester.getCenter(find.byType(PaneDivider));

    final touch = await tester.startGesture(center);
    await tester.pump();
    final pressed = lineColor(tester);
    await touch.up();
    await tester.pump();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(center);
    await tester.pump();

    expect(lineColor(tester), pressed);
  });

  testWidgets('a mouse that drags off the line keeps its hover', (
    tester,
  ) async {
    await pump(tester);
    final center = tester.getCenter(find.byType(PaneDivider));

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(center);
    await tester.pump();
    final hovered = lineColor(tester);

    await mouse.down(center);
    await tester.pump();
    await mouse.up();
    await tester.pump();

    // Releasing the button is not leaving the line: the cursor is still on it,
    // so the two states have to be tracked apart rather than as one flag.
    expect(lineColor(tester), hovered);
  });

  testWidgets('a cancelled pointer puts the line back', (tester) async {
    await pump(tester);
    final resting = lineColor(tester);

    final touch = await tester.startGesture(
      tester.getCenter(find.byType(PaneDivider)),
    );
    await tester.pump();
    expect(lineColor(tester), isNot(resting));

    await touch.cancel();
    await tester.pump();

    expect(lineColor(tester), resting);
  });
}
