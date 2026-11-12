import 'dart:async';

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
    for (final e in find.byType(SheetScaffold, skipOffstage: false).evaluate()) {
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

  testWidgets('a list of rows over a sheet is its next page too', (tester) async {
    final ctx = await pump(tester);
    outer(ctx);
    await step(tester);
    final sheet = ModalRoute.of(tester.element(find.byType(SheetScaffold)))!;

    final picked = showRowsSheet<String>(
      ctx,
      rows: (rowsCtx) => [
        ListTile(title: const Text('row'), onTap: () => Navigator.of(rowsCtx).pop('row')),
      ],
    );
    await step(tester);
    expect(ModalRoute.of(tester.element(find.text('row'))), same(sheet));
    expect(SheetX.frontSheet!.depth, 2);

    await tester.tap(find.text('row'));
    await step(tester);
    expect(await picked, 'row');
    expect(SheetX.frontSheet!.depth, 1);
    expect(find.byKey(const Key('field')), findsOneWidget);
  });

  testWidgets('a sheet with a body of its own is a page too, unless standalone', (
    tester,
  ) async {
    final ctx = await pump(tester);
    outer(ctx);
    await step(tester);
    final sheet = ModalRoute.of(tester.element(find.byType(SheetScaffold)))!;

    showResizableSheet<void>(ctx, builder: (_) => const Text('panel'));
    await step(tester);
    expect(ModalRoute.of(tester.element(find.text('panel'))), same(sheet));
    expect(SheetX.frontSheet!.depth, 2);

    showResizableSheet<void>(ctx, standalone: true, builder: (_) => const Text('apart'));
    await step(tester);
    expect(ModalRoute.of(tester.element(find.text('apart'))), isNot(same(sheet)));
    expect(SheetX.frontSheet!.depth, 1);
  });

  testWidgets('back to a taller page: it stands still while the sheet grows', (
    tester,
  ) async {
    final ctx = await pump(tester);
    ctx.showSheet<void>(child: const SizedBox(key: Key('tall'), height: 300));
    await step(tester);
    ctx.showSheet<void>(child: const SizedBox(key: Key('short'), height: 40));
    await step(tester);

    ctx.popSheet();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final moving = tester.getRect(find.byKey(const Key('tall'))).bottom;
    await step(tester);
    expect(tester.getRect(find.byKey(const Key('tall'))).bottom, moving);
  });

  testWidgets('an answer that raises the next page: the sheet does not open on the page between', (
    tester,
  ) async {
    final ctx = await pump(tester);
    ctx.showSheet<void>(child: const SizedBox(key: Key('tall'), height: 300));
    await step(tester);
    // A menu over it, whose answer asks a second question.
    unawaited(() async {
      final go = await ctx.showSheet<bool>(
        child: const SizedBox(height: 40),
        actions: Btnx.oks,
      );
      if (go == true) {
        await ctx.showSheet<void>(child: const SizedBox(key: Key('ask'), height: 60));
      }
    }());
    await step(tester);
    double height() => tester.getSize(find.byType(AnimatedSize).last).height;
    final short = height();

    await tester.tap(find.text(libL10n.ok));
    var highest = 0.0;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      if (height() > highest) highest = height();
    }
    expect(find.byKey(const Key('ask')), findsOneWidget);
    // Between the two short pages, never the tall one's height.
    expect(highest, lessThan(short + 25));
  });

  testWidgets('back to a page that fills its room: never taller than it ends', (
    tester,
  ) async {
    final ctx = await pump(tester);
    // A list: as tall as it is let be, under a cap lower than a prompt's.
    showResizableSheet<void>(
      ctx,
      restLimit: 0.5,
      builder: (_) => ListView(key: const Key('list'), children: const [SizedBox(height: 2000)]),
    );
    await step(tester);
    final rest = tester.getSize(find.byKey(const Key('list'))).height;
    ctx.showSheet<void>(child: const SizedBox(height: 40));
    await step(tester);

    ctx.popSheet();
    var highest = 0.0;
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 16));
      final h = tester.getSize(find.byType(AnimatedSize).last).height;
      if (h > highest) highest = h;
    }
    expect(tester.getSize(find.byKey(const Key('list'))).height, rest);
    expect(highest, lessThanOrEqualTo(rest + 1));
  });

  for (final (platform, floats) in [(TargetPlatform.macOS, true), (TargetPlatform.android, false)]) {
    testWidgets('on ${platform.name} the sheet ${floats ? 'stands clear of' : 'is against'} the bottom', (
      tester,
    ) async {
      Future<Rect> surface(Size size) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        late BuildContext ctx;
        await tester.pumpWidget(
          MaterialApp(
            key: ValueKey(size),
            theme: ThemeData(platform: platform),
            home: Builder(
              builder: (context) {
                ctx = context;
                return const Scaffold();
              },
            ),
          ),
        );
        ctx.showSheet<void>(title: 'title', child: const SizedBox(height: 40));
        await step(tester);
        return tester.getRect(
          find.ancestor(of: find.byType(ResizableSheet), matching: find.byType(Material)).first,
        );
      }

      final gap = floats ? SheetRoute.margin : 0.0;
      final narrow = await surface(const Size(400, 800));
      expect(narrow.bottom, 800 - gap);
      expect(narrow.left, gap);
      expect(narrow.right, 400 - gap);

      final wide = await surface(const Size(1600, 1000));
      expect(wide.bottom, 1000 - gap);
      expect(wide.width, SheetRoute.width);
      expect(wide.center.dx, 800);
    });
  }

  testWidgets('pages switch with animations off', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final ctx = await pump(tester);
    ctx.showSheet<void>(child: const SizedBox(key: Key('tall'), height: 300));
    await step(tester);
    ctx.showSheet<void>(child: const SizedBox(height: 40));
    await step(tester);
    ctx.popSheet();
    await step(tester);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('tall')), findsOneWidget);
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
    expect(find.byType(SheetScaffold, skipOffstage: false), findsNothing);
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
    expect(find.byType(SheetScaffold, skipOffstage: false), findsNothing);
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
      ModalRoute.of(tester.element(find.byType(SheetScaffold))),
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
      final sheet = tester.getRect(find.byType(SheetScaffold));
      final inset = SheetScaffold.defaultTitlePadding.left;
      expect(tester.getRect(find.text('title')).left, sheet.left + inset);
      expect(
        tester.getRect(find.text('body')).left,
        sheet.left + SheetScaffold.defaultContentPadding.left,
      );
      ctx.popSheet();
      await step(tester);

      ctx.showPickSheet<String>(title: 'pick', items: const ['a']);
      await step(tester);
      final pick = tester.getRect(find.byType(SheetScaffold));
      expect(tester.getRect(find.text('pick')).left, pick.left + inset);
    });
  }


  testWidgets('a loading sheet does not time out under a prompt', (
    tester,
  ) async {
    // The time is the work's: timed out while a prompt raised from inside it
    // was up, the failure was said and answering the prompt still did the
    // work.
    final ctx = await pump(tester);
    (String?, Object?)? ended;
    ctx
        .showLoadingSheet<String?>(
          timeout: const Duration(seconds: 1),
          showErr: false,
          fn: () => ctx.showSheet<String>(
            title: 'prompt',
            actions: [
              TextButton(
                onPressed: () => ctx.popSheet('answer'),
                child: const Text('answer'),
              ),
            ],
          ),
        )
        .then((r) => ended = r);
    await step(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(ended, isNull);
    expect(find.text('prompt'), findsOneWidget);

    await tester.tap(find.text('answer'));
    await step(tester);
    await step(tester);
    expect(ended, ('answer', null));
  });

  testWidgets('a loading sheet with nothing over it times out', (tester) async {
    final ctx = await pump(tester);
    (void, Object?)? ended;
    ctx
        .showLoadingSheet<void>(
          timeout: const Duration(seconds: 1),
          showErr: false,
          fn: () => Completer<void>().future,
        )
        .then((r) => ended = r);
    await step(tester);
    await tester.pump(const Duration(seconds: 1));
    await step(tester);
    expect(ended?.$2, isA<TimeoutException>());
    expect(find.byType(SheetScaffold), findsNothing);
  });

  testWidgets('work that throws before it starts ends the loading sheet', (
    tester,
  ) async {
    final ctx = await pump(tester);
    (void, Object?)? ended;
    ctx
        .showLoadingSheet<void>(
          timeout: const Duration(seconds: 1),
          showErr: false,
          fn: () => throw StateError('at once'),
        )
        .then((r) => ended = r);
    await step(tester);
    await step(tester);
    expect(ended?.$2, isA<StateError>());
    expect(find.byType(SheetScaffold), findsNothing);
    // Nothing left to fire: a timer still armed would time out into nobody.
    await tester.pump(const Duration(seconds: 2));
    expect(tester.takeException(), isNull);
  });
}
