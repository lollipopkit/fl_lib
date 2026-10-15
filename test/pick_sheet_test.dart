import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<BuildContext> pump(WidgetTester tester, Size size) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return ctx;
  }

  testWidgets('a phone picks one from rows in a sheet', (tester) async {
    final ctx = await pump(tester, const Size(400, 800));
    final picked = ctx.showPickSingleDialog<String>(
      items: const ['a', 'b', 'c'],
      initial: 'a',
    );
    await tester.pumpAndSettle();
    expect(find.byType(PickSheet<String>), findsOneWidget);
    expect(find.byType(SheetChoiceTile), findsNWidgets(3));

    await tester.tap(find.text('b'));
    await tester.pumpAndSettle();
    expect(await picked, 'b');
    expect(find.byType(PickSheet<String>), findsNothing);
  });

  testWidgets('a phone picks several, and OK ends it', (tester) async {
    final ctx = await pump(tester, const Size(400, 800));
    final picked = ctx.showPickDialog<String>(
      items: const ['a', 'b', 'c'],
      initial: const ['a'],
    );
    await tester.pumpAndSettle();
    // Not clearable: the last one stays.
    await tester.tap(find.text('a'));
    await tester.pump();
    await tester.tap(find.text('c'));
    await tester.pump();
    await tester.tap(find.text('a'));
    await tester.pump();
    await tester.tap(find.byType(TextButton).last);
    await tester.pumpAndSettle();
    expect(await picked, ['c']);
  });

  testWidgets('dismissing the sheet answers null', (tester) async {
    final ctx = await pump(tester, const Size(400, 800));
    final picked = ctx.showPickDialog<String>(items: const ['a', 'b']);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(await picked, isNull);
  });

  testWidgets('a wide window keeps the dialog', (tester) async {
    final ctx = await pump(tester, const Size(1200, 800));
    ctx.showPickDialog<String>(items: const ['a', 'b']);
    await tester.pumpAndSettle();
    expect(find.byType(PickSheet<String>), findsNothing);
    expect(find.byType(ChoiceWidget<String>), findsOneWidget);
  });
}
