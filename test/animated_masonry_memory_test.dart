import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// A grid mounted with a card already expanded.
///
/// An expanded card takes no column space, so its column is told it still
/// costs what it did — and the grid takes that from the first layout the card
/// is expanded in. A caller that drops the grid while a card is open and
/// mounts it again for the way back gives it no layout of that card at rest,
/// so what it measured was the card at its expanded height: every card after
/// it in the column was placed that much too low until the card had landed,
/// and travelled home afterwards.
void main() {
  const rest = 40.0;
  const expanded = 400.0;

  Widget grid({
    required bool open,
    MasonryMemory? memory,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: AnimatedMasonry(
          // One column, which is the case where every card is in the expanded
          // one's column.
          columnWidth: double.infinity,
          padding: EdgeInsets.zero,
          spacing: 0,
          expandedKey: open ? const ValueKey('b') : null,
          expansion: open ? 1 : 0,
          memory: memory,
          children: [
            const SizedBox(key: ValueKey('a'), height: rest),
            SizedBox(key: const ValueKey('b'), height: open ? expanded : rest),
            const SizedBox(key: ValueKey('c'), height: rest),
          ],
        ),
      ),
    );
  }

  double topOfC(WidgetTester tester) =>
      tester.getTopLeft(find.byKey(const ValueKey('c'))).dy;

  testWidgets('remembers what a card cost its column across a remount', (
    tester,
  ) async {
    final memory = MasonryMemory();

    await tester.pumpWidget(grid(open: false, memory: memory));
    final atRest = topOfC(tester);
    expect(atRest, rest * 2);

    // Gone, and back with the card already at full size.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(grid(open: true, memory: memory));

    expect(topOfC(tester), atRest);
  });

  testWidgets('without one, the first expanded layout is all it has', (
    tester,
  ) async {
    await tester.pumpWidget(grid(open: false));
    final atRest = topOfC(tester);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(grid(open: true));

    // The fallback, and the reason for the memory: the slot is the expanded
    // card's height.
    expect(topOfC(tester), atRest + expanded - rest);
  });

  testWidgets('a grid that was on screen needs none', (tester) async {
    await tester.pumpWidget(grid(open: false));
    final atRest = topOfC(tester);

    // Expanded in place: the first expanded layout is still the card at rest
    // only if the card has not changed size by then, which is the caller's to
    // arrange. Here it has, and the memory is what holds the slot anyway.
    final memory = MasonryMemory();
    await tester.pumpWidget(grid(open: false, memory: memory));
    await tester.pumpWidget(grid(open: true, memory: memory));

    expect(topOfC(tester), atRest);
  });

  testWidgets('an expanded card grows into what the inset leaves', (
    tester,
  ) async {
    // What a column beside the page takes from the grid's left: the card
    // lands where the page is, not under the column.
    Widget at(double expansion) => MaterialApp(
      home: Scaffold(
        body: AnimatedMasonry(
          columnWidth: 200,
          padding: EdgeInsets.zero,
          spacing: 0,
          expandedKey: const ValueKey('b'),
          expansion: expansion,
          expandedInset: const EdgeInsets.only(left: 100),
          children: const [
            SizedBox(key: ValueKey('a'), height: rest),
            SizedBox(key: ValueKey('b'), height: rest),
          ],
        ),
      ),
    );

    await tester.pumpWidget(at(0));
    await tester.pumpWidget(at(1));
    final rect = tester.getRect(find.byKey(const ValueKey('b')));
    expect(rect.left, 100);
    expect(rect.width, 800 - 100);
  });
}
