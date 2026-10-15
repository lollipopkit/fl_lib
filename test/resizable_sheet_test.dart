import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<void> open(WidgetTester tester, {int rows = 40}) async {
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

  /// A frame between moves, as a finger gives one.
  Future<void> drag(WidgetTester tester, double dy) async {
    final g = await tester.startGesture(
      tester.getCenter(find.byType(SheetGrip)),
    );
    const steps = 10;
    for (var i = 0; i < steps; i++) {
      await g.moveBy(Offset(0, dy / steps));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await g.up();
  }

  double sheetHeight(WidgetTester tester) =>
      tester.getSize(find.byType(ResizableSheet)).height;

  const rest = 800 * ResizableSheet.restFactor;

  testWidgets('opens at its content height, up to 60%', (tester) async {
    await open(tester, rows: 2);
    expect(sheetHeight(tester), lessThan(rest));

    Navigator.of(tester.element(find.byKey(const Key('content')))).pop();
    await tester.pumpAndSettle();
    await open(tester);
    expect(sheetHeight(tester), rest);
  });

  testWidgets('one drag past halfway up takes the window', (tester) async {
    await open(tester);
    await drag(tester, -200);
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), 800);
  });

  testWidgets('a short drag snaps back to its own height', (tester) async {
    await open(tester);
    await drag(tester, -100);
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), rest);
    await drag(tester, 100);
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), rest);
  });

  testWidgets('a fling goes one step: up to the window, down to its own', (
    tester,
  ) async {
    await open(tester);
    await tester.fling(find.byType(SheetGrip), const Offset(0, -80), 1500);
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), 800);
    await tester.fling(find.byType(SheetGrip), const Offset(0, 80), 1500);
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), rest);
  });

  testWidgets('from the window, down past halfway to closed lands at its own', (
    tester,
  ) async {
    await open(tester);
    await drag(tester, -400);
    await tester.pumpAndSettle();
    await drag(tester, 400);
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), rest);
  });

  testWidgets('down past half its own height closes, without growing back', (
    tester,
  ) async {
    await open(tester);
    await drag(tester, 300);
    await tester.pump(const Duration(milliseconds: 50));
    expect(sheetHeight(tester), rest - 300);
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
    await drag(tester, -300);
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), 800);
  });

  testWidgets('outside a sheet the grip is nothing', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Center(child: SheetGrip())),
    );
    expect(tester.getSize(find.byType(SheetGrip)), Size.zero);
  });

  testWidgets('it sits on the keyboard, its heights out of what is left', (
    tester,
  ) async {
    await open(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    final content = tester.getRect(find.byKey(const Key('content')));
    // Above the keyboard, and 60% of the 500 it leaves.
    expect(content.bottom, lessThanOrEqualTo(500));
    expect(sheetHeight(tester), 500 * ResizableSheet.restFactor + 300);

    await drag(tester, -300);
    await tester.pumpAndSettle();
    expect(sheetHeight(tester), 800);
    expect(tester.getRect(find.byKey(const Key('content'))).bottom, 500);
  });
}
