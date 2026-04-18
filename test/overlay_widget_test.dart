import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<void> pumpOverlayWidget(
    WidgetTester tester, {
    required bool blurBg,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: OverlayWidget(
              blurBg: blurBg,
              popup: const Material(
                child: Text('Overlay Popup'),
              ),
              child: const SizedBox(
                key: ValueKey('overlay-trigger'),
                width: 80,
                height: 40,
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('shows and dismisses popup with blurred background', (
    tester,
  ) async {
    final overlayTrigger = find.byType(InkWell);
    await pumpOverlayWidget(tester, blurBg: true);

    await tester.longPress(overlayTrigger, warnIfMissed: false);
    await tester.pump();
    await tester.pump(Durations.medium1);

    expect(find.text('Overlay Popup'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);

    await tester.tap(find.byType(GestureDetector).last);
    await tester.pumpAndSettle();

    expect(find.text('Overlay Popup'), findsNothing);
  });

  testWidgets('renders popup without blur when blurBg is false', (
    tester,
  ) async {
    final overlayTrigger = find.byType(InkWell);
    await pumpOverlayWidget(tester, blurBg: false);

    await tester.longPress(overlayTrigger, warnIfMissed: false);
    await tester.pump();
    await tester.pump(Durations.medium1);

    expect(find.text('Overlay Popup'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);
  });
}
