import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:multi_split_view/multi_split_view.dart';

/// The seam between the two panes, on a touchscreen.
///
/// [PaneDivider] — the line drawn by hand where there is no split view — was
/// fixed to answer a finger as well as a cursor. This is the other line, the
/// one `multi_split_view` lays out between the panes, and it is a different
/// widget reached by a different path: whether the same thing is true of it
/// was never measured, only assumed either way.
void main() {
  Future<void> pump(WidgetTester tester) async {
    // Wide enough to earn two panes. Sized on the view rather than the
    // surface: `MediaQuery` reports the view, and `AdaptivePanes` asks the
    // constraints it is given — so a test that set the surface alone would be
    // laying out a tablet inside a phone's window.
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptivePanes(
            primaryBuilder: (_, _) => const Text('list'),
            detailBuilder: (_) => const Text('detail'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Whether the package considers the divider grabbed.
  ///
  /// This flag is the whole input to what is drawn: it is handed to the
  /// painter, and it is what starts the 250ms fade from the resting hairline
  /// to `Hairline.activeColor`. Nothing sits between it and the pixels.
  bool highlighted(WidgetTester tester) =>
      tester.widget<DividerWidget>(find.byType(DividerWidget)).highlighted;

  /// Lets go, and drains what the package schedules on drag end — a
  /// zero-duration `Future.delayed`, which a bare `pump` does not reach and
  /// which then fails the test as a pending timer.
  Future<void> release(WidgetTester tester, TestGesture touch) async {
    await touch.up();
    await tester.pump(const Duration(milliseconds: 1));
  }

  testWidgets('a finger on it lights it up before the drag is recognised', (
    tester,
  ) async {
    await pump(tester);
    expect(highlighted(tester), isFalse);

    final touch = await tester.startGesture(
      tester.getCenter(find.byType(DividerWidget)),
    );
    await tester.pump();

    // Not after moving: a horizontal drag is not recognised until the finger
    // has travelled past the slop, and by then the user is already dragging
    // and no longer needs telling which line they got.
    expect(
      highlighted(tester),
      isTrue,
      reason: 'a touchscreen has no hover, so this press is the only chance '
          'the line has to say it was grabbed',
    );

    await release(tester, touch);

    expect(highlighted(tester), isFalse);
  });

  testWidgets('and lets go when the pointer is cancelled', (tester) async {
    await pump(tester);

    final touch = await tester.startGesture(
      tester.getCenter(find.byType(DividerWidget)),
    );
    await tester.pump();
    expect(highlighted(tester), isTrue);

    // A scroll elsewhere taking over the gesture leaves the line lit
    // otherwise, and nothing later would put it back.
    await touch.cancel();
    await tester.pump(const Duration(milliseconds: 1));

    expect(highlighted(tester), isFalse);
  });
}
