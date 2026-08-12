import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const from = Rect.fromLTWH(0, 0, 200, 100);
  const to = Rect.fromLTWH(400, 300, 100, 50);

  /// An overlay and something to hang a ticker on.
  late OverlayState overlay;

  Future<void> pumpHost(WidgetTester tester) async {
    final key = GlobalKey<OverlayState>();
    await tester.pumpWidget(
      MaterialApp(
        home: Overlay(
          key: key,
          initialEntries: [
            OverlayEntry(builder: (_) => const SizedBox.expand()),
          ],
        ),
      ),
    );
    overlay = key.currentState!;
  }

  /// Where the copy is right now, in the overlay's coordinates.
  Rect rectOf(WidgetTester tester) {
    return tester.getRect(find.byKey(const ValueKey('flyer')));
  }

  const flyer = SizedBox.expand(key: ValueKey('flyer'));

  testWidgets('the copy starts where the widget was and lands where it went', (
    tester,
  ) async {
    await pumpHost(tester);
    var ended = false;

    OverlayFlight.launch(
      overlay: overlay,
      vsync: tester,
      from: from,
      to: to,
      child: flyer,
      duration: const Duration(milliseconds: 300),
      onEnd: () => ended = true,
    );

    await tester.pump();
    expect(rectOf(tester), from);

    await tester.pump(const Duration(milliseconds: 150));
    final middle = rectOf(tester);
    expect(middle, isNot(from));
    expect(middle, isNot(to));
    expect(
      middle.left,
      greaterThan(0),
      reason: 'the copy is on its way, not at either end',
    );
    expect(ended, isFalse);

    // Settling rather than pumping the remaining 150ms: the ticker reports
    // arrival on the frame after the one that reaches the far end.
    await tester.pumpAndSettle();
    expect(ended, isTrue, reason: 'the caller unhides the real widget here');
    expect(
      find.byKey(const ValueKey('flyer')),
      findsNothing,
      reason: 'the copy is scenery and must not outlive the flight',
    );
  });

  testWidgets('cancelling takes the copy away and still reports the end', (
    tester,
  ) async {
    await pumpHost(tester);
    var ended = false;

    final flight = OverlayFlight.launch(
      overlay: overlay,
      vsync: tester,
      from: from,
      to: to,
      child: flyer,
      duration: const Duration(milliseconds: 300),
      onEnd: () => ended = true,
    );

    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(flight.isFlying, isTrue);

    flight.cancel();
    await tester.pump();

    expect(find.byKey(const ValueKey('flyer')), findsNothing);
    expect(flight.isFlying, isFalse);
    expect(
      ended,
      isTrue,
      reason: 'a row hidden for a flight that was cut short stays hidden '
          'otherwise',
    );

    // Nothing is left running: an undisposed controller fails the test here.
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('cancelling twice is not an error', (tester) async {
    await pumpHost(tester);
    final flight = OverlayFlight.launch(
      overlay: overlay,
      vsync: tester,
      from: from,
      to: to,
      child: flyer,
    );

    await tester.pump();
    flight.cancel();
    await tester.pump();
    flight.cancel();
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('rectInOverlay measures a widget that is not painted', (
    tester,
  ) async {
    // What the landing row is during a flight: laid out so it can be measured,
    // hidden so the same card is not on screen twice.
    final key = GlobalKey<OverlayState>();
    final target = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Overlay(
          key: key,
          initialEntries: [
            OverlayEntry(
              builder: (_) => Align(
                alignment: Alignment.topLeft,
                child: Visibility(
                  key: target,
                  visible: false,
                  maintainSize: true,
                  maintainAnimation: true,
                  maintainState: true,
                  child: const SizedBox(width: 120, height: 40),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    final rect = rectInOverlay(target.currentContext, key.currentState!);
    expect(rect, const Rect.fromLTWH(0, 0, 120, 40));
  });

  testWidgets('an unmounted or unlaid-out target measures as nothing', (
    tester,
  ) async {
    await pumpHost(tester);
    expect(rectInOverlay(null, overlay), isNull);
  });
}
