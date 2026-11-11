import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A sheet raised while one of these is in front is that sheet's next page.
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

  /// Not settled: a focused field keeps a caret blinking.
  Future<void> step(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  int sheetRoutes(WidgetTester tester) {
    final routes = <Route<dynamic>>{};
    for (final e in find.byType(PromptSheet, skipOffstage: false).evaluate()) {
      routes.add(ModalRoute.of(e)!);
    }
    return routes.length;
  }

  Future<String?> outer(BuildContext ctx) => ctx.showSheet<String>(
    title: 'outer',
    child: const TextField(key: Key('field')),
    actions: Btnx.cancelOk,
  );

  testWidgets('a sheet over a sheet is its next page, and pops back to it', (
    tester,
  ) async {
    final ctx = await pump(tester);
    outer(ctx);
    await step(tester);
    await tester.enterText(find.byKey(const Key('field')), 'typed');
    await step(tester);

    final inner = ctx.showSheet<int>(title: 'inner', child: const Text('two'));
    await step(tester);
    expect(find.text('two'), findsOneWidget);
    expect(find.text('outer'), findsNothing);
    expect(sheetRoutes(tester), 1);
    expect(find.byTooltip(MaterialLocalizations.of(ctx).backButtonTooltip),
        findsOneWidget);

    ctx.popSheet(5);
    await step(tester);
    expect(await inner, 5);
    expect(find.text('outer'), findsOneWidget);
    expect(find.text('typed'), findsOneWidget);
    expect(find.byTooltip(MaterialLocalizations.of(ctx).backButtonTooltip),
        findsNothing);
  });

  testWidgets('Btnx.cancelOk on the inner page answers its own caller', (
    tester,
  ) async {
    final ctx = await pump(tester);
    var outerDone = false;
    outer(ctx).then((_) => outerDone = true);
    await step(tester);
    for (final (label, answer) in [(libL10n.ok, true), (libL10n.cancel, null)]) {
      final inner = ctx.showSheet<bool>(
        title: 'inner',
        child: const Text('two'),
        actions: Btnx.cancelOk,
      );
      await step(tester);
      await tester.tap(find.text(label));
      await step(tester);
      expect(await inner, answer);
      expect(find.text('outer'), findsOneWidget);
      expect(outerDone, isFalse);
    }
  });

  testWidgets('the back button and system back pop one page', (tester) async {
    final ctx = await pump(tester);
    outer(ctx);
    await step(tester);
    final inner = ctx.showSheet<int>(title: 'inner', child: const Text('two'));
    await step(tester);
    await tester.tap(
      find.byTooltip(MaterialLocalizations.of(ctx).backButtonTooltip),
    );
    await step(tester);
    expect(await inner, isNull);
    expect(find.text('outer'), findsOneWidget);

    final again = ctx.showSheet<int>(title: 'inner', child: const Text('two'));
    await step(tester);
    await tester.binding.handlePopRoute();
    await step(tester);
    expect(await again, isNull);
    expect(find.text('outer'), findsOneWidget);
  });

  testWidgets('the barrier pops one page; the grip closes every page', (
    tester,
  ) async {
    final ctx = await pump(tester);
    final order = <String>[];
    outer(ctx).then((v) => order.add('outer $v'));
    await step(tester);
    ctx
        .showSheet<int>(title: 'inner', child: const Text('two'))
        .then((v) => order.add('inner $v'));
    await step(tester);
    await tester.tapAt(const Offset(200, 20));
    await step(tester);
    expect(order, ['inner null']);
    expect(find.text('outer'), findsOneWidget);

    ctx
        .showSheet<int>(title: 'inner', child: const Text('two'))
        .then((v) => order.add('again $v'));
    await step(tester);
    await tester.drag(find.byType(SheetGrip), const Offset(0, 700));
    await step(tester);
    await tester.pump(const Duration(milliseconds: 400));
    expect(order, ['inner null', 'again null', 'outer null']);
    expect(find.byType(PromptSheet, skipOffstage: false), findsNothing);
  });

  testWidgets('the grip springs back over a page under it that holds', (
    tester,
  ) async {
    final ctx = await pump(tester);
    ctx.showSheet<void>(title: 'holds', dismissible: false);
    await step(tester);
    final inner = ctx.showSheet<int>(title: 'inner', child: const Text('two'));
    await step(tester);
    await tester.drag(find.byType(SheetGrip), const Offset(0, 700));
    await step(tester);
    expect(find.text('two'), findsOneWidget);

    // The barrier is the top page's: it goes, the one that holds stays.
    await tester.tapAt(const Offset(200, 20));
    await step(tester);
    expect(await inner, isNull);
    expect(find.text('holds'), findsOneWidget);
    await tester.tapAt(const Offset(200, 20));
    await step(tester);
    expect(find.text('holds'), findsOneWidget);
    ctx.popSheet();
    await step(tester);
  });

  testWidgets('a loading sheet closes itself, not a page raised over it', (
    tester,
  ) async {
    // What is raised while the loading is up is raised by someone else — an
    // update, an error from elsewhere — and outlives it with what was typed.
    final ctx = await pump(tester);
    outer(ctx);
    await step(tester);
    Future<int?>? over;
    final done = ctx.showLoadingSheet(
      fn: () async {
        over = ctx.showSheet<int>(
          title: 'over',
          child: const TextField(key: Key('over field')),
        );
        await Future<void>.delayed(const Duration(seconds: 1));
        return 1;
      },
    );
    await step(tester);
    await tester.enterText(find.byKey(const Key('over field')), 'kept');
    await tester.pump(const Duration(seconds: 1));
    await step(tester);
    expect((await done).$1, 1);
    expect(find.byType(SizedLoading, skipOffstage: false), findsNothing);
    expect(find.text('over'), findsOneWidget);
    expect(find.text('kept'), findsOneWidget);
    expect(sheetRoutes(tester), 1);

    // Under it, the outer page; and the loading is not on the way back.
    ctx.popSheet(2);
    await step(tester);
    expect(await over, 2);
    expect(find.text('outer'), findsOneWidget);
  });

  testWidgets('the first page closing leaves the pages over it up', (
    tester,
  ) async {
    final ctx = await pump(tester);
    VoidCallback? close;
    var firstDone = false;
    ctx
        .showSheet<void>(title: 'first', onShown: (c) => close = c)
        .then((_) => firstDone = true);
    await step(tester);
    final over = ctx.showSheet<int>(title: 'over');
    await step(tester);
    close!();
    await step(tester);
    expect(firstDone, isTrue);
    expect(find.text('over'), findsOneWidget);
    expect(sheetRoutes(tester), 1);
    expect(find.byTooltip(MaterialLocalizations.of(ctx).backButtonTooltip),
        findsNothing);

    ctx.popSheet(3);
    await step(tester);
    expect(await over, 3);
    expect(find.byType(PromptSheet, skipOffstage: false), findsNothing);
  });

  testWidgets('a sheet raised while another leaves takes taps once up', (
    tester,
  ) async {
    final ctx = await pump(tester);
    final first = ctx.showSheet<bool>(title: 'first', actions: Btnx.cancelOk);
    await step(tester);
    await tester.tap(find.text(libL10n.ok));
    await tester.pump();
    // Raised in the exit window, by code rather than by a tap.
    final second = ctx.showSheet<bool>(title: 'second', actions: Btnx.cancelOk);
    await step(tester);
    expect(await first, isTrue);
    await tester.tap(find.text(libL10n.ok));
    await step(tester);
    expect(await second, isTrue);
  });

  testWidgets('a body of its own takes a sheet raised from it as a page', (
    tester,
  ) async {
    // The tag editor: its own surface and grip, then Rename from inside it.
    final ctx = await pump(tester);
    var closed = false;
    showResizableSheet<void>(
      ctx,
      showGrip: false,
      backgroundColor: Colors.transparent,
      builder: (_) => const Material(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [SheetGrip(), TextField(key: Key('own'))],
        ),
      ),
    ).then((_) => closed = true);
    await step(tester);
    await tester.enterText(find.byKey(const Key('own')), 'typed');
    final rename = ctx.showSheet<String>(title: 'rename');
    await step(tester);
    expect(
      ModalRoute.of(tester.element(find.byType(PromptSheet))),
      ModalRoute.of(
        tester.element(find.byKey(const Key('own'), skipOffstage: false)),
      ),
    );
    expect(find.byTooltip(MaterialLocalizations.of(ctx).backButtonTooltip),
        findsOneWidget);

    ctx.popSheet('new');
    await step(tester);
    expect(await rename, 'new');
    expect(find.text('typed'), findsOneWidget);
    expect(closed, isFalse);
  });

  testWidgets('nothing under a leaving sheet takes a tap before it answers', (
    tester,
  ) async {
    await pump(tester);
    var raised = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  raised++;
                  await context.showSheet<bool>(
                    title: 'confirm',
                    actions: Btnx.cancelOk,
                  );
                },
                child: const Text('delete'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('delete'));
    await step(tester);
    await tester.tap(find.text(libL10n.ok));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('delete'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump();
    expect(raised, 1);
    expect(find.text('confirm'), findsNothing);
  });

  testWidgets('a page that holds holds against the barrier and back', (
    tester,
  ) async {
    final ctx = await pump(tester);
    outer(ctx);
    await step(tester);
    final inner = ctx.showSheet<int>(
      title: 'inner',
      child: const Text('two'),
      dismissible: false,
    );
    await step(tester);
    expect(find.byTooltip(MaterialLocalizations.of(ctx).backButtonTooltip),
        findsNothing);
    await tester.tapAt(const Offset(200, 20));
    await step(tester);
    await tester.binding.handlePopRoute();
    await step(tester);
    await tester.drag(find.byType(SheetGrip), const Offset(0, 500));
    await step(tester);
    expect(find.text('two'), findsOneWidget);

    ctx.popSheet(1);
    await step(tester);
    expect(await inner, 1);
    expect(find.text('outer'), findsOneWidget);
  });

  testWidgets('loading inside a sheet is a page, then the page is back', (
    tester,
  ) async {
    final ctx = await pump(tester);
    outer(ctx);
    await step(tester);
    final done = ctx.showLoadingSheet(
      fn: () => Future.delayed(const Duration(seconds: 1), () => 1),
    );
    await step(tester);
    expect(find.byType(SizedLoading), findsOneWidget);
    expect(sheetRoutes(tester), 1);
    await tester.pump(const Duration(seconds: 1));
    await step(tester);
    expect((await done).$1, 1);
    expect(find.byType(SizedLoading), findsNothing);
    expect(find.text('outer'), findsOneWidget);
  });

  testWidgets('three deep, and back down one at a time', (tester) async {
    final ctx = await pump(tester);
    outer(ctx);
    await step(tester);
    final two = ctx.showSheet<int>(title: 'two');
    await step(tester);
    final three = ctx.showSheet<int>(title: 'three');
    await step(tester);
    expect(find.text('three'), findsOneWidget);
    expect(sheetRoutes(tester), 1);

    ctx.popSheet(3);
    await step(tester);
    expect(await three, 3);
    expect(find.text('two'), findsOneWidget);
    ctx.popSheet(2);
    await step(tester);
    expect(await two, 2);
    expect(find.text('outer'), findsOneWidget);
  });

  testWidgets('popSheet from a page gone since pops the inner page', (
    tester,
  ) async {
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
    page.showSheet<void>(title: 'outer');
    await step(tester);
    final inner = page.showSheet<int>(title: 'inner');
    await step(tester);
    wide.value = true;
    await step(tester);
    expect(page.mounted, isFalse);

    page.popSheet(4);
    await step(tester);
    expect(await inner, 4);
    expect(find.text('outer'), findsOneWidget);
    expect(SheetX.topSheet, isNotNull);
  });

  testWidgets('a raw Navigator.pop inside takes one page', (tester) async {
    final ctx = await pump(tester);
    outer(ctx);
    await step(tester);
    final inner = ctx.showSheet<int>(
      title: 'inner',
      childBuilder: (sheet) => TextButton(
        onPressed: () => Navigator.of(sheet).pop(9),
        child: const Text('raw'),
      ),
    );
    await step(tester);
    await tester.tap(find.text('raw'));
    await step(tester);
    expect(await inner, 9);
    expect(find.text('outer'), findsOneWidget);
  });

  for (final size in [const Size(400, 800), const Size(1600, 1000)]) {
    testWidgets('the title starts at the content inset, ${size.width} wide', (
      tester,
    ) async {
      final ctx = await pump(tester, size: size);
      ctx.showSheet<void>(title: 'title', child: const Text('body'));
      await step(tester);
      final sheet = tester.getRect(find.byType(PromptSheet));
      final inset = PromptSheet.defaultTitlePadding.left;
      expect(tester.getRect(find.text('title')).left, sheet.left + inset);
      expect(
        tester.getRect(find.text('body')).left,
        sheet.left + PromptSheet.defaultContentPadding.left,
      );
      ctx.popSheet();
      await step(tester);

      ctx.showPickSheet<String>(title: 'pick', items: const ['a']);
      await step(tester);
      final pick = tester.getRect(find.byType(PromptSheet));
      expect(tester.getRect(find.text('pick')).left, pick.left + inset);
    });
  }

}
