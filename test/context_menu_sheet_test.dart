import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A menu with no pointer to open at is a sheet: a short one its title and
/// the sheet's own buttons, a long one rows.
void main() {
  Future<BuildContext> pump(WidgetTester tester) async {
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

  Future<void> step(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('a short menu is buttons at the end of the sheet', (tester) async {
    final ctx = await pump(tester);
    var deleted = false;
    showContextMenu(ctx, [
      ContextMenuAction(text: 'rename', icon: Icons.edit, onTap: () {}),
      ContextMenuAction(
        text: 'delete',
        icon: Icons.delete_outline,
        destructive: true,
        onTap: () => deleted = true,
      ),
    ], title: 'chat');
    await step(tester);

    expect(find.byType(SheetScaffold), findsOneWidget);
    expect(find.byType(ContextMenuRow), findsNothing);
    final sheet = tester.getRect(find.byType(SheetScaffold));
    final title = tester.getRect(find.text('chat'));
    final button = tester.getRect(find.widgetWithText(TextButton, 'delete'));
    expect(button.top, greaterThan(title.bottom));
    expect(button.center.dx, greaterThan(sheet.center.dx));

    await tester.tap(find.text('delete'));
    // Run once the sheet is gone.
    expect(deleted, isFalse);
    await step(tester);
    expect(deleted, isTrue);
  });

  testWidgets('a long menu is rows', (tester) async {
    final ctx = await pump(tester);
    showContextMenu(ctx, [
      for (var i = 0; i < 4; i++) ContextMenuAction(text: 'entry $i', onTap: () {}),
    ], title: 'file');
    await step(tester);
    expect(find.byType(ContextMenuRow), findsNWidgets(4));
  });

  testWidgets('a long menu\'s title is the sheet\'s, not a row', (tester) async {
    final ctx = await pump(tester);
    showContextMenu(ctx, [
      for (var i = 0; i < 4; i++) ContextMenuAction(text: 'entry $i', onTap: () {}),
    ], title: 'file');
    await step(tester);
    final sheet = tester.getRect(find.byType(SheetScaffold));
    final title = tester.getRect(find.text('file'));
    expect(title.left, sheet.left + SheetScaffold.defaultTitlePadding.left);
    expect(title.bottom, lessThanOrEqualTo(tester.getRect(find.byType(ContextMenuRow).first).top));
    expect(
      find.descendant(of: find.byType(SingleChildScrollView), matching: find.text('file')),
      findsNothing,
    );
  });
}
