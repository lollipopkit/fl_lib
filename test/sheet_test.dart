import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// `showSheet` and the sheets built on it.
void main() {
  Future<BuildContext> pump(
    WidgetTester tester, {
    Size size = const Size(400, 800),
  }) async {
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

  testWidgets('a sheet, closed by popSheet with its result', (tester) async {
    final ctx = await pump(tester);
    final closed = ctx.showSheet<int>(
      title: 'title',
      child: const Text('body'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(PromptSheet), findsOneWidget);
    expect(SheetX.topSheet, isA<SheetRoute>());

    ctx.popSheet(7);
    await tester.pumpAndSettle();
    expect(find.byType(PromptSheet), findsNothing);
    expect(await closed, 7);
    expect(SheetX.topSheet, isNull);
  });

  testWidgets('Btnx.cancelOk answers true, and null on cancel', (
    tester,
  ) async {
    final ctx = await pump(tester);
    for (final (label, answer) in [(libL10n.ok, true), (libL10n.cancel, null)]) {
      final closed = ctx.showSheet<bool>(
        child: const Text('body'),
        actions: Btnx.cancelOk,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(await closed, answer);
      expect(find.byType(PromptSheet), findsNothing);
    }
  });

  testWidgets('dismissible false holds against the barrier and a drag', (
    tester,
  ) async {
    final ctx = await pump(tester);
    var closed = false;
    ctx
        .showSheet<void>(
          child: const Text('body'),
          dismissible: false,
        )
        .then((_) => closed = true);
    await tester.pumpAndSettle();

    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(SheetGrip), const Offset(0, 400));
    await tester.pumpAndSettle();
    await tester.fling(find.text('body'), const Offset(0, 400), 2000);
    await tester.pumpAndSettle();
    expect(find.byType(PromptSheet), findsOneWidget);
    expect(closed, isFalse);

    ctx.popSheet();
    await tester.pumpAndSettle();
    expect(closed, isTrue);
  });

  testWidgets('a dismissible one goes with the barrier or a drag', (
    tester,
  ) async {
    final ctx = await pump(tester);
    ctx.showSheet<void>(child: const Text('body'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(200, 20));
    await tester.pumpAndSettle();
    expect(find.byType(PromptSheet), findsNothing);

    ctx.showSheet<void>(child: const Text('body'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(SheetGrip), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(find.byType(PromptSheet), findsNothing);
  });

  testWidgets('an autofocused field sits above the keyboard', (tester) async {
    final ctx = await pump(tester);
    final closed = ctx.showPwdSheet(title: 'title');
    // Not settled: a focused field keeps a caret blinking.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final field = find.byType(TextField);
    expect(tester.testTextInput.isVisible, isTrue);
    final before = tester.getRect(field);

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final rect = tester.getRect(field);
    expect(rect.bottom, lessThanOrEqualTo(800 - 300));
    // Moved up by the keyboard and nothing else: the same size, no jump.
    expect(rect.size, before.size);
    expect(rect.top, before.top - 300);
    expect(
      tester.getRect(find.text(libL10n.pwd)).top,
      greaterThanOrEqualTo(0),
    );

    await tester.enterText(field, 'secret');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(await closed, 'secret');
  });

  testWidgets('a wide window gets a sheet as wide as every other', (
    tester,
  ) async {
    final ctx = await pump(tester, size: const Size(1600, 1000));
    ctx.showSheet<void>(child: const Text('body'));
    await tester.pumpAndSettle();
    final round = tester.getRect(find.byType(PromptSheet));
    Navigator.of(ctx, rootNavigator: true).pop();
    await tester.pumpAndSettle();

    showRowsSheet<void>(ctx, rows: (_) => const [Text('row')]);
    await tester.pumpAndSettle();
    final rows = tester.getRect(find.byType(ResizableSheet));
    expect(round.width, rows.width);
    expect(rows.width, 640);
    expect(round.center.dx, 800);
  });

  testWidgets('a form taller than 60% is not cut off', (tester) async {
    final ctx = await pump(tester);
    ctx.showSheet<void>(
      title: 'title',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [for (var i = 0; i < 9; i++) const SizedBox(height: 60)],
      ),
      actions: Btnx.oks,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text(libL10n.ok).hitTestable(), findsOneWidget);
  });

  testWidgets('the loading sheet holds until the work is done', (
    tester,
  ) async {
    final ctx = await pump(tester);
    final done = ctx.showLoadingSheet(
      fn: () => Future.delayed(const Duration(seconds: 1), () => 1),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SizedLoading), findsOneWidget);
    await tester.tapAt(const Offset(200, 20));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SizedLoading), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
    expect((await done).$1, 1);
    expect(find.byType(PromptSheet), findsNothing);
  });

  testWidgets('the input sheet answers what was typed, by OK', (
    tester,
  ) async {
    final ctx = await pump(tester);
    final typed = ctx.showInputSheet(title: 'title', initial: 'a');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.tap(find.text(libL10n.ok));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(await typed, 'abc');
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('a red confirmation is a sheet too, and answers', (
    tester,
  ) async {
    final ctx = await pump(tester);
    final closed = ctx.showSheet<bool>(
      child: const Text('body'),
      actions: Btnx.cancelRedOk,
    );
    await tester.pumpAndSettle();
    expect(find.byType(PromptSheet), findsOneWidget);
    await tester.tap(find.text(libL10n.ok));
    await tester.pumpAndSettle();
    expect(await closed, isTrue);
  });

  testWidgets('a sheet answers once it is off the screen', (tester) async {
    // Its exit still builds what it holds: an answer at the start of it had a
    // caller dispose the field's controller under the field.
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return const SizedBox();
          },
        ),
      ),
    );
    final ctrl = TextEditingController(text: 'typed');
    var answered = false;
    unawaited(() async {
      await page.showSheet<void>(child: TextField(controller: ctrl));
      answered = true;
      ctrl.dispose();
    }());
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('typed'), findsOneWidget);
    expect(answered, isFalse);

    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('typed'), findsNothing);
    expect(answered, isTrue);
    expect(tester.takeException(), isNull);
  });
}
