import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('arrows stay at the trailing edge for different titles', (
    tester,
  ) async {
    for (final width in [280.0, 620.0]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: width,
              child: Column(
                children: [
                  for (final title in ['PVE', 'Appearance and location'])
                    ExpandableTile(
                      key: ValueKey((width, title)),
                      title: Text(title),
                      summary: const Text('Options'),
                      children: const [Text('Fields')],
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      final arrows = find.byIcon(Icons.expand_more);
      final first = tester.getRect(arrows.first);
      final second = tester.getRect(arrows.last);
      expect(first.right, closeTo(second.right, 0.1));
      expect(width - first.right, lessThan(30));
      await tester.tap(find.text('PVE'));
      await tester.pumpAndSettle();
      expect(tester.getRect(arrows.first).right, closeTo(first.right, 0.1));
      expect(find.text('Fields'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('a summary that is not text keeps its own width', (tester) async {
    // `summary` is typed `Widget?`, and the slot sits in an `Expanded` so the
    // arrow lands at the trailing edge whatever the title is. A child that
    // does not size itself — a pill, a badge — took the whole of that
    // `Expanded` and was drawn as a bar across the row.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: ExpandableTile(
              title: Text('BMC (Redfish)'),
              summary: BetaTag(key: ValueKey('beta')),
              children: [Text('Fields')],
            ),
          ),
        ),
      ),
    );

    final tag = tester.getRect(find.byKey(const ValueKey('beta')));
    expect(tag.width, lessThan(60));
    expect(tag.height, BetaTag.title);
    // Still against the arrow, which is what the `Expanded` is there for.
    final arrow = tester.getRect(find.byIcon(Icons.expand_more));
    expect(arrow.left - tag.right, lessThan(30));
  });
}
