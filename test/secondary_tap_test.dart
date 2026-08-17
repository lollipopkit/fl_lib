import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Right-click, and what it must not cost the gestures already there.
///
/// Every call site goes through this one extension — a server card, a side bar
/// entry, a `Btn`, a file row — so its contract is checked here rather than
/// once per page. What each caller does with the callback is that caller's
/// test; that it arrives, on release, without eating anything else, is this.
void main() {
  /// The widget under test: a tappable, long-pressable box with [onSecondary]
  /// wrapped around it, recording what fires.
  Widget harness({
    required List<String> log,
    void Function(Offset at)? onSecondary,
    ScrollController? scroll,
  }) {
    final tile = SizedBox(
      height: 100,
      width: 400,
      child: GestureDetector(
        onTap: () => log.add('tap'),
        onLongPress: () => log.add('longPress'),
        child: const ColoredBox(
          key: Key('tile'),
          color: Color(0xFF000000),
        ),
      ),
    ).onSecondary(onSecondary);

    return MaterialApp(
      home: Scaffold(
        body: ListView(
          controller: scroll,
          children: [tile, const SizedBox(height: 2000)],
        ),
      ),
    );
  }

  testWidgets('a secondary tap reports where the pointer was', (tester) async {
    final log = <String>[];
    Offset? at;
    await tester.pumpWidget(
      harness(
        log: log,
        onSecondary: (where) {
          log.add('secondary');
          at = where;
        },
      ),
    );

    const pointer = Offset(120, 40);
    final gesture = await tester.startGesture(pointer, buttons: kSecondaryButton);
    await gesture.up();
    await tester.pumpAndSettle();

    expect(log, ['secondary']);
    // A global position, which is what a menu opening at the cursor needs.
    expect(at, pointer);
  });

  testWidgets('it fires on release, not on press', (tester) async {
    // Windows opens its context menu when the button comes up, and releasing
    // is also what lets someone change their mind by dragging off first.
    final log = <String>[];
    await tester.pumpWidget(
      harness(log: log, onSecondary: (_) => log.add('secondary')),
    );

    final gesture = await tester.startGesture(
      const Offset(120, 40),
      buttons: kSecondaryButton,
    );
    await tester.pumpAndSettle();
    expect(log, isEmpty, reason: 'fired while the button was still down');

    await gesture.up();
    await tester.pumpAndSettle();
    expect(log, ['secondary']);
  });

  testWidgets('dragging off before release calls nothing', (tester) async {
    final log = <String>[];
    await tester.pumpWidget(
      harness(log: log, onSecondary: (_) => log.add('secondary')),
    );

    final gesture = await tester.startGesture(
      const Offset(120, 40),
      buttons: kSecondaryButton,
    );
    await gesture.moveTo(const Offset(120, 900));
    await gesture.up();
    await tester.pumpAndSettle();

    expect(log, isEmpty);
  });

  testWidgets('the primary button still taps and long-presses', (tester) async {
    // `HitTestBehavior.translucent` is what buys this: the wrapper claims the
    // secondary button and lets everything else through to the child. Opaque
    // would swallow the tap that opens the thing.
    final log = <String>[];
    await tester.pumpWidget(
      harness(log: log, onSecondary: (_) => log.add('secondary')),
    );

    await tester.tap(find.byKey(const Key('tile')));
    await tester.pumpAndSettle();
    expect(log, ['tap']);

    await tester.longPress(find.byKey(const Key('tile')));
    await tester.pumpAndSettle();
    expect(log, ['tap', 'longPress']);
  });

  testWidgets('a scroll drag still scrolls, and is not a long press', (
    tester,
  ) async {
    final log = <String>[];
    final scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      harness(log: log, onSecondary: (_) => log.add('secondary'), scroll: scroll),
    );

    await tester.drag(find.byKey(const Key('tile')), const Offset(0, -300));
    await tester.pumpAndSettle();

    expect(scroll.offset, greaterThan(0), reason: 'the list did not move');
    expect(log, isEmpty, reason: 'a drag fired a tap or a long press');
  });

  testWidgets('null leaves the widget alone', (tester) async {
    // Rather than wrapping it in a detector that answers nothing — one fewer
    // node, and no hit-test participant that could shadow something later.
    final log = <String>[];
    await tester.pumpWidget(harness(log: log));

    expect(
      find.descendant(
        of: find.byType(ListView),
        matching: find.byType(GestureDetector),
      ),
      findsOneWidget,
      reason: 'the child GestureDetector, and no wrapper beside it',
    );

    final gesture = await tester.startGesture(
      const Offset(120, 40),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
    expect(log, isEmpty);
  });

  group('asSecondary', () {
    test('turns a long-press callback into a positional one', () {
      var fired = 0;
      final handler = asSecondary(() => fired++);

      handler!(const Offset(1, 2));

      expect(fired, 1);
    });

    test('stays null for a null callback', () {
      // So `onSecondary` gets the null that leaves the widget untouched,
      // rather than a function that ignores a tap.
      expect(asSecondary(null), isNull);
    });
  });
}
