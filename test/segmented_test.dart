import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const marker = ValueKey('segmented-marker');

  Future<void> pumpTabs(
    WidgetTester tester, {
    required ValueNotifier<String> selected,
    bool expand = false,
    double width = 400,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: ValueListenableBuilder<String>(
                valueListenable: selected,
                builder: (_, value, _) => SegmentedTabs<String>(
                  expand: expand,
                  segments: const [
                    SegmentedTab(value: 'a', label: 'Alpha'),
                    SegmentedTab(value: 'b', label: 'Beta'),
                    SegmentedTab(value: 'c', label: 'Gamma'),
                  ],
                  selected: value,
                  onSelected: (next) => selected.value = next,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // A segment's box is only known once it has been laid out, so the marker
  // cannot be placed on the frame that first builds the control.
  testWidgets('the marker arrives on the frame after the first', (
    tester,
  ) async {
    final selected = ValueNotifier('a');
    addTearDown(selected.dispose);

    await pumpTabs(tester, selected: selected);
    expect(find.byKey(marker), findsNothing);

    await tester.pump();
    expect(find.byKey(marker), findsOneWidget);
    expect(
      tester.getCenter(find.byKey(marker)).dx,
      closeTo(tester.getCenter(find.text('Alpha')).dx, 1),
    );
  });

  testWidgets('choosing another segment slides the marker to it', (
    tester,
  ) async {
    final selected = ValueNotifier('a');
    addTearDown(selected.dispose);

    await pumpTabs(tester, selected: selected);
    await tester.pump();
    final from = tester.getCenter(find.byKey(marker)).dx;
    final to = tester.getCenter(find.text('Gamma')).dx;

    await tester.tap(find.text('Gamma'));
    // One frame to rebuild with the new selection, a second for the post-frame
    // measurement to reach the marker — only then does it have a target to
    // animate towards.
    await tester.pump();
    await tester.pump();
    await tester.pump(SegmentedTabs.duration ~/ 2);

    // Half way through it is between the two, which a cross-fade would never
    // be: that is what distinguishes a marker that moves from two that swap.
    final midway = tester.getCenter(find.byKey(marker)).dx;
    expect(midway, greaterThan(from));
    expect(midway, lessThan(to));

    await tester.pumpAndSettle();
    expect(tester.getCenter(find.byKey(marker)).dx, closeTo(to, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the marker follows a segment that is not the same width', (
    tester,
  ) async {
    final selected = ValueNotifier('a');
    addTearDown(selected.dispose);

    // Sized to their labels, so 'Alpha' and 'Beta' are different widths and a
    // marker that only moved would be the wrong size on one of them.
    await pumpTabs(tester, selected: selected);
    await tester.pump();
    final alpha = tester.getSize(find.byKey(marker)).width;

    await tester.tap(find.text('Beta'));
    await tester.pumpAndSettle();
    final beta = tester.getSize(find.byKey(marker)).width;

    expect(beta, lessThan(alpha));
    expect(
      tester.getCenter(find.byKey(marker)).dx,
      closeTo(tester.getCenter(find.text('Beta')).dx, 1),
    );
  });

  testWidgets('expand gives every segment the same width', (tester) async {
    final selected = ValueNotifier('a');
    addTearDown(selected.dispose);

    await pumpTabs(tester, selected: selected, expand: true, width: 400);
    await tester.pump();

    final widths = ['Alpha', 'Beta', 'Gamma']
        .map((label) => tester.getSize(find.text(label)).width)
        .toList();
    final centers = ['Alpha', 'Beta', 'Gamma']
        .map((label) => tester.getCenter(find.text(label)).dx)
        .toList();
    expect(widths.every((w) => w > 0), true);
    // Equal shares put the gaps between centres equal too.
    expect(centers[2] - centers[1], closeTo(centers[1] - centers[0], 1));
    expect(tester.takeException(), isNull);
  });
}
