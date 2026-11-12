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
    final picked = ctx.showPickSingleSheet<String>(
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
    final picked = ctx.showPickSheet<String>(
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
    final picked = ctx.showPickSheet<String>(items: const ['a', 'b']);
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(await picked, isNull);
  });

  testWidgets('a wide window gets the sheet, as wide as every other', (
    tester,
  ) async {
    final ctx = await pump(tester, const Size(1600, 900));
    ctx.showPickSheet<String>(items: const ['a', 'b']);
    await tester.pumpAndSettle();
    expect(find.byType(PickSheet<String>), findsOneWidget);
    expect(tester.getSize(find.byType(ResizableSheet)).width, 640);
  });

  testWidgets('loading, then rows: both under its title, its actions at the end', (
    tester,
  ) async {
    final ctx = await pump(tester, const Size(400, 800));
    final loading = true.vn;
    addTearDown(loading.dispose);
    ctx.showPickSheet<String>(items: const ['a', 'b'], showLoading: loading);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    void check(Finder body) {
      final sheet = tester.getRect(find.byType(SheetScaffold));
      final title = tester.getRect(find.text(libL10n.select));
      final ok = tester.getRect(find.widgetWithText(TextButton, libL10n.ok));
      final rect = tester.getRect(body);
      expect(title.bottom, lessThanOrEqualTo(rect.top));
      expect(title.left, lessThan(sheet.center.dx));
      expect(ok.top, greaterThanOrEqualTo(rect.bottom));
      expect(ok.left, greaterThan(sheet.center.dx));
    }

    expect(find.byType(SheetChoiceTile), findsNothing);
    check(find.byType(SizedLoading));

    loading.value = false;
    await tester.pump();
    expect(find.byType(SizedLoading), findsNothing);
    check(find.byType(SheetChoiceTile).last);
    // A row keeps its own text style, not the body's of a prompt.
    final scheme = Theme.of(tester.element(find.byType(SheetChoiceTile).first)).colorScheme;
    expect(
      DefaultTextStyle.of(tester.element(find.byType(SheetChoiceTile).first)).style.color,
      isNot(scheme.onSurfaceVariant),
    );
  });
}
