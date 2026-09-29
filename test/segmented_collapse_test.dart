import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [SegmentedTabs] that rests as its selected segment alone.
///
/// What it is set to is worth a place in a bar all the time; what else it
/// could be set to is worth one while somebody is choosing.
void main() {
  Future<ValueNotifier<String>> pumpTabs(
    WidgetTester tester, {
    String selected = 'b',
    bool collapse = true,
  }) async {
    final value = ValueNotifier(selected);
    addTearDown(value.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // In a row with something after it, which is where one of these
          // lives: sized by what is in it, with its right edge held.
          body: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              ValueListenableBuilder<String>(
                valueListenable: value,
                builder: (_, selected, _) => SegmentedTabs<String>(
                  collapse: collapse,
                  segments: const [
                    SegmentedTab(value: 'a', label: 'Alpha'),
                    SegmentedTab(value: 'b', label: 'Beta'),
                    SegmentedTab(value: 'c', label: 'Gamma'),
                  ],
                  selected: selected,
                  onSelected: (next) => value.value = next,
                ),
              ),
              const SizedBox(width: 40, key: ValueKey('after')),
            ],
          ),
        ),
      ),
    );
    return value;
  }

  /// [pumpTabs], and the frame after it: the control as it rests.
  Future<ValueNotifier<String>> pumpSettled(
    WidgetTester tester, {
    String selected = 'b',
  }) async {
    final value = await pumpTabs(tester, selected: selected);
    await tester.pump();
    return value;
  }

  Rect control(WidgetTester tester) =>
      tester.getRect(find.byType(SegmentedTabs<String>));

  /// Whether [label] is wholly inside the control, which is what it is to be
  /// on show: the row behind the window is always all there.
  bool shown(WidgetTester tester, String label) {
    final box = control(tester);
    final text = tester.getRect(find.text(label));
    return text.left >= box.left - 0.01 && text.right <= box.right + 0.01;
  }

  Future<TestGesture> pointer(WidgetTester tester) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    return mouse;
  }

  testWidgets('rests as the selected segment, and is never drawn open first', (
    tester,
  ) async {
    await pumpTabs(tester, collapse: false);
    final open = control(tester).width;
    await tester.pumpWidget(const SizedBox.shrink());

    // Where the selected segment is, is measured after the first build, so
    // that frame cannot be the closed control. It is nothing rather than the
    // open one: the control arriving a frame late — with its marker, which
    // was always a frame late — is not a flash, and all three segments for
    // one frame is.
    await pumpTabs(tester);
    final first = tester.renderObject(
      find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_SegmentWindow',
      ),
    );
    expect(first, paintsNothing);
    expect(find.text('Gamma').hitTestable(), findsNothing);

    await tester.pump();
    expect(control(tester).width, lessThan(open / 2));
    expect(shown(tester, 'Beta'), isTrue);
    expect(shown(tester, 'Alpha'), isFalse);
    expect(shown(tester, 'Gamma'), isFalse);
    // And what is not on show cannot be pressed.
    expect(find.text('Gamma').hitTestable(), findsNothing);
  });

  testWidgets('opens under a pointer, and closes when it leaves', (
    tester,
  ) async {
    final value = await pumpSettled(tester);
    final closed = control(tester);
    final mouse = await pointer(tester);

    await mouse.moveTo(closed.center);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final open = control(tester);
    expect(open.width, greaterThan(closed.width * 2));
    // Its right edge is where what follows it begins, so that has not moved.
    expect(open.right, closed.right);
    for (final label in ['Alpha', 'Beta', 'Gamma']) {
      expect(shown(tester, label), isTrue, reason: label);
    }

    await tester.tap(find.text('Gamma'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(value.value, 'c');
    // Still under the pointer, so still open.
    expect(control(tester).width, open.width);

    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(control(tester).width, lessThan(open.width / 2));
    expect(shown(tester, 'Gamma'), isTrue);
    expect(shown(tester, 'Beta'), isFalse);
  });

  testWidgets('the selected segment is on show the whole way', (tester) async {
    // The point of closing with a window rather than by narrowing the other
    // segments: nothing in the row moves against anything else in it, so the
    // marker — placed from a measurement a frame old — never trails the label
    // it is under.
    await pumpSettled(tester);
    final mouse = await pointer(tester);
    const marker = ValueKey('segmented-marker');
    await tester.pump(const Duration(milliseconds: 50));

    void expectTogether(String when) {
      expect(shown(tester, 'Beta'), isTrue, reason: when);
      final fill = tester.getRect(find.byKey(marker));
      final label = tester.getRect(find.text('Beta'));
      expect(fill.contains(label.center), isTrue, reason: when);
    }

    await mouse.moveTo(control(tester).center);
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expectTogether('opening, frame $i');
    }
    await mouse.moveTo(Offset.zero);
    for (var i = 0; i < 16; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      expectTogether('closing, frame $i');
    }
  });

  testWidgets('a click on it does not hold it open', (tester) async {
    // A pointer has opened it already by being over it. A click that also
    // held it open would leave it open once the pointer had gone.
    await pumpSettled(tester);
    final closed = control(tester).width;
    final mouse = await pointer(tester);

    await mouse.moveTo(control(tester).center);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Beta'), kind: PointerDeviceKind.mouse);
    await mouse.moveTo(Offset.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(control(tester).width, closed);
  });

  testWidgets('a touch opens it, and choosing closes it', (tester) async {
    final value = await pumpSettled(tester);
    final closed = control(tester).width;

    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(control(tester).width, greaterThan(closed * 2));

    await tester.tap(find.text('Alpha'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(value.value, 'a');
    expect(shown(tester, 'Alpha'), isTrue);
    expect(shown(tester, 'Beta'), isFalse);
  });

  testWidgets('and so does a touch anywhere else', (tester) async {
    await pumpSettled(tester);
    final closed = control(tester).width;

    await tester.tap(find.text('Beta'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(control(tester).width, greaterThan(closed * 2));

    await tester.tapAt(const Offset(10, 300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(control(tester).width, closed);
  });

  testWidgets('one that does not close is as it was', (tester) async {
    await pumpTabs(tester, collapse: false);
    for (final label in ['Alpha', 'Beta', 'Gamma']) {
      expect(shown(tester, label), isTrue, reason: label);
    }
    expect(find.byType(MouseRegion), isNot(findsNothing));
  });
}
