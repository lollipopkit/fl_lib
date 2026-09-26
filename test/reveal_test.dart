import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// [open] is driven from a parent, as a form's would be: what is under test
  /// is how the rows arrive when it flips, not who flipped it.
  Future<void> pump(
    WidgetTester tester, {
    required ValueNotifier<bool> open,
    bool reducedMotion = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(disableAnimations: reducedMotion),
          child: child!,
        ),
        home: Scaffold(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('header'),
              ValueListenableBuilder(
                valueListenable: open,
                builder: (_, open, _) => Reveal(
                  open: open,
                  children: const [Text('source'), Text('capacity')],
                ),
              ),
              const Text('below'),
            ],
          ),
        ),
      ),
    );
  }

  testWidgets('the rows are not built at all while closed', (tester) async {
    final open = ValueNotifier(false);
    addTearDown(open.dispose);
    await pump(tester, open: open);

    expect(find.text('source'), findsNothing);
    expect(find.text('capacity'), findsNothing);
  });

  testWidgets('opening unfolds them, and the rows below move down', (
    tester,
  ) async {
    final open = ValueNotifier(false);
    addTearDown(open.dispose);
    await pump(tester, open: open);
    final wasAt = tester.getTopLeft(find.text('below')).dy;

    open.value = true;
    await tester.pump();
    // Built the moment it opens — the fold is the space they take, not how
    // much of each row is drawn.
    expect(find.text('source'), findsOneWidget);
    expect(find.text('capacity'), findsOneWidget);

    // Part way: the rows are under the header and the group below has started
    // moving, but has not arrived.
    await tester.pump(const Duration(milliseconds: 60));
    final middle = tester.getTopLeft(find.text('below')).dy;
    expect(middle, greaterThan(wasAt));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('below')).dy, greaterThan(middle));
  });

  testWidgets('closing keeps them until they have folded away', (tester) async {
    final open = ValueNotifier(true);
    addTearDown(open.dispose);
    await pump(tester, open: open);
    await tester.pumpAndSettle();
    final wasAt = tester.getTopLeft(find.text('below')).dy;

    open.value = false;
    await tester.pump();
    // Still there, on their way out: dropping them here is what would leave an
    // empty gap closing where they were.
    expect(find.text('source'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.text('source'), findsOneWidget);
    expect(tester.getTopLeft(find.text('below')).dy, lessThan(wasAt));

    await tester.pumpAndSettle();
    expect(find.text('source'), findsNothing);
    expect(find.text('below'), findsOneWidget);
  });

  testWidgets('closing and opening again comes back to the same place', (
    tester,
  ) async {
    final open = ValueNotifier(true);
    addTearDown(open.dispose);
    await pump(tester, open: open);
    await tester.pumpAndSettle();
    final wasAt = tester.getTopLeft(find.text('below')).dy;

    open.value = false;
    await tester.pumpAndSettle();
    open.value = true;
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(find.text('below')).dy, wasAt);
    expect(find.text('capacity'), findsOneWidget);
  });

  testWidgets('a closed Reveal takes no room', (tester) async {
    final open = ValueNotifier(false);
    addTearDown(open.dispose);
    await pump(tester, open: open);

    expect(tester.getSize(find.byType(Reveal)).height, 0);
  });

  testWidgets('with reduced motion it opens and closes at once', (
    tester,
  ) async {
    final open = ValueNotifier(false);
    addTearDown(open.dispose);
    await pump(tester, open: open, reducedMotion: true);
    final closedAt = tester.getTopLeft(find.text('below')).dy;

    open.value = true;
    await tester.pump();
    await tester.pump();
    final openAt = tester.getTopLeft(find.text('below')).dy;
    expect(openAt, greaterThan(closedAt));
    expect(tester.hasRunningAnimations, isFalse);

    open.value = false;
    await tester.pump();
    await tester.pump();
    expect(find.text('source'), findsNothing);
    expect(tester.getTopLeft(find.text('below')).dy, closedAt);
  });
}
