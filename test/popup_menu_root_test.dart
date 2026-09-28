import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A [PopupMenu] with an initial value scrolls that item into view as it
/// opens, to the middle of every scrollable above it. On a page's own navigator inside a page view — a home screen's
/// tabs — that moved the page view too, and left it on another page.
void main() {
  testWidgets('opening it leaves the pages it sits in where they were', (
    tester,
  ) async {
    final pages = PageController();
    addTearDown(pages.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: PageView(
          controller: pages,
          physics: const NeverScrollableScrollPhysics(),
          children: [
            // Each page its own navigator, as a tab's is.
            Navigator(
              onGenerateRoute: (_) => MaterialPageRoute(
                builder: (_) => Scaffold(
                  // Off the middle, as a row's trailing menu is: the item is
                  // scrolled to the middle of every scrollable above it.
                  body: Align(
                    alignment: Alignment.centerRight,
                    child: PopupMenu<int>(
                      initialValue: 2,
                      items: const [
                        PopupMenuItem(value: 1, child: Text('one')),
                        PopupMenuItem(value: 2, child: Text('two')),
                      ],
                      onSelected: (_) {},
                      child: const Text('open'),
                    ),
                  ),
                ),
              ),
            ),
            const Center(child: Text('second page')),
          ],
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('two'), findsWidgets);
    expect(pages.page, 0);

    await tester.tap(find.text('two').last);
    await tester.pumpAndSettle();
    expect(pages.page, 0);
    expect(find.text('open'), findsOneWidget);
  });
}
