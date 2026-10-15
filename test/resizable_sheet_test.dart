import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<void> open(
    WidgetTester tester, {
    double? heightFactor,
    int rows = 40,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showResizableSheet<void>(
                context,
                heightFactor: heightFactor,
                builder: (_) => ListView(
                  key: const Key('content'),
                  shrinkWrap: true,
                  children: [
                    for (var i = 0; i < rows; i++)
                      ListTile(title: Text('Row $i')),
                  ],
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  double sheetHeight(WidgetTester tester) =>
      tester.getSize(find.byType(ResizableSheet)).height;

  testWidgets('opens at its content height, capped at 9/16', (tester) async {
    await open(tester, rows: 2);
    final short = sheetHeight(tester);
    expect(short, lessThan(800 * ResizableSheet.defaultContentMaxFactor));

    Navigator.of(tester.element(find.byKey(const Key('content')))).pop();
    await tester.pumpAndSettle();
    await open(tester);
    expect(sheetHeight(tester), 800 * ResizableSheet.defaultContentMaxFactor);
  });

  testWidgets('dragging the grip up takes the window, down restores', (
    tester,
  ) async {
    await open(tester, heightFactor: 0.5);
    expect(sheetHeight(tester), 400);

    await tester.drag(find.byType(SheetGrip), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), 800);

    await tester.drag(find.byType(SheetGrip), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), 500);

    // Below where it opened, but not by half: back to where it opened.
    await tester.drag(find.byType(SheetGrip), const Offset(0, 200));
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), 400);
  });

  testWidgets('dragging the grip well below where it opened closes it', (
    tester,
  ) async {
    await open(tester, heightFactor: 0.5);
    await tester.drag(find.byType(SheetGrip), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(find.byType(ResizableSheet), findsNothing);
  });

  testWidgets('a rows sheet is resizable too', (tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showRowsSheet<void>(
                context,
                rows: (_) => [
                  for (var i = 0; i < 40; i++)
                    ListTile(title: Text('Row $i')),
                ],
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.byType(SheetGrip), findsOneWidget);
    await tester.drag(find.byType(SheetGrip), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), 800);
  });

  testWidgets('outside a sheet the grip is nothing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: SheetGrip())),
    );
    expect(tester.getSize(find.byType(SheetGrip)), Size.zero);
  });
}
