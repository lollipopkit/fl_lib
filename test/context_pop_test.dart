import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pop on a context whose widget is gone does nothing', (
    tester,
  ) async {
    // A pop is often the last line after an `await`, and the widget that
    // asked can be gone by then. `Navigator.of` on that context failed a null
    // check inside the framework.
    late BuildContext stale;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            stale = context;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());

    expect(stale.mounted, isFalse);
    expect(stale.canPop, isFalse);
    expect(() => stale.pop(), returnsNormally);
  });

  testWidgets('popSheet closes a sheet whose page is gone', (tester) async {
    // The sheet is on the root navigator, so it outlives a page that a
    // layout switch remounts, and its buttons hold that page's context.
    final wide = ValueNotifier(false);
    addTearDown(wide.dispose);
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: wide,
          builder: (_, wide, _) => Builder(
            key: ValueKey(wide),
            builder: (context) {
              if (!wide) page = context;
              return const SizedBox();
            },
          ),
        ),
      ),
    );

    final closed = page.showSheet<bool>(
      actions: [
        TextButton(
          onPressed: () => page.popSheet(true),
          child: const Text('close'),
        ),
      ],
    );
    await tester.pumpAndSettle();
    wide.value = true;
    await tester.pumpAndSettle();
    expect(page.mounted, isFalse);

    await tester.tap(find.text('close'));
    await tester.pumpAndSettle();

    expect(find.text('close'), findsNothing);
    expect(await closed, isTrue);
    expect(SheetX.topSheet, isNull);
  });
}
