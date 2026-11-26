import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Two pages at a given window size, in a given language.
  ///
  /// [maxWidth] is the content column the bar aligns itself to; the bar puts
  /// labelled buttons in it, so a language with long words is the case
  /// that decides whether the column is wide enough.
  Widget harness(Locale locale, {double maxWidth = UIs.pageColumnWidth}) {
    return MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        LibLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: LibLocalizations.supportedLocales,
      // Deliberately no `ResponsivePoints.builder`: this page is used by apps
      // that never installed one, and asking for it was what made it throw
      // there. Leaving it out is what keeps that from coming back.
      home: IntroPage(
        args: IntroPageArgs(
          maxWidth: maxWidth,
          pages: const [Center(child: Text('one')), Center(child: Text('two'))],
          onDone: (_) {},
        ),
      ),
    );
  }

  /// Overflow is reported as an exception rather than a failed frame, so it has
  /// to be drained explicitly — and drained on both pages, because `previous`
  /// shows on the second.
  List<Object> takeErrors() {
    final errs = <Object>[];
    var e = TestWidgetsFlutterBinding.instance.takeException();
    while (e != null) {
      errs.add(e);
      e = TestWidgetsFlutterBinding.instance.takeException();
    }
    return errs;
  }

  const sizes = [
    Size(1400, 900), // desktop
    Size(700, 800),
    Size(390, 844), // phone
  ];

  for (final size in sizes) {
    for (final locale in LibLocalizations.supportedLocales) {
      testWidgets('bar fits ${size.width.toInt()}w in $locale', (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(harness(locale));
        await tester.pumpAndSettle();
        expect(takeErrors(), isEmpty, reason: 'page 1');

        await tester.tap(find.byType(FilledButton));
        await tester.pumpAndSettle();
        expect(takeErrors(), isEmpty, reason: 'page 2');
      });
    }
  }

  for (final width in [1400.0, 390.0]) {
    testWidgets('counter centred between the buttons at ${width.toInt()}w', (tester) async {
      tester.view.physicalSize = Size(width, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(harness(const Locale('en')));
      await tester.pumpAndSettle();

      final counter = tester.getCenter(find.text('1/2', findRichText: true));
      expect(counter.dx, closeTo(width / 2, 1));
      final next = tester.getTopRight(find.byType(FilledButton));
      // Bounded by the content column rather than the window.
      expect(next.dx, lessThanOrEqualTo(width / 2 + UIs.pageColumnWidth / 2));
    });
  }

  testWidgets('previous is hidden on the first page only', (tester) async {
    await tester.pumpWidget(harness(const Locale('en')));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Previous'), findsNothing);

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Previous'));
    await tester.pumpAndSettle();
    expect(find.text('one'), findsOneWidget);
  });

  for (final (label, size) in [
    ('wide', const Size(1400, 900)),
    ('compact', const Size(390, 844)),
  ]) {
    testWidgets('a single page shows no counter ($label)', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [LibLocalizations.delegate],
          home: IntroPage(
            args: IntroPageArgs(
              pages: const [Center(child: Text('only'))],
              onDone: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('/'), findsNothing);
      // Asserted alongside, because "no counter" is also what a bar that
      // failed to render at all would look like.
      expect(find.text('only'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
    });
  }

  testWidgets('canProceed gates Next button and IntroPage.nextOf skips', (tester) async {
    final gate = false.vn;
    addTearDown(gate.dispose);
    var doneCalled = false;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [LibLocalizations.delegate],
        home: IntroPage(
          args: IntroPageArgs(
            pages: [
              Builder(
                builder: (ctx) => Center(
                  child: TextButton(
                    onPressed: () => IntroPage.nextOf(ctx),
                    child: const Text('skip'),
                  ),
                ),
              ),
              const Center(child: Text('page2')),
            ],
            canProceed: (page) => page == 0 ? gate : null,
            onDone: (_) => doneCalled = true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Next is disabled while gate is false.
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);

    // Explicit skip advances to page 2 even while gate is false.
    await tester.tap(find.text('skip'));
    await tester.pumpAndSettle();
    expect(find.text('page2'), findsOneWidget);

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(doneCalled, isTrue);
  });

  testWidgets('a locked page swipes back, not forward', (tester) async {
    final gate = false.vn;
    addTearDown(gate.dispose);
    Future<void> swipe(double dx) async {
      await tester.drag(find.byType(PageView), Offset(dx, 0));
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [LibLocalizations.delegate],
        home: IntroPage(
          args: IntroPageArgs(
            pages: const [
              Center(child: Text('page-0')),
              Center(child: Text('page-1')),
              Center(child: Text('page-2')),
            ],
            canProceed: (page) => page == 1 ? gate : null,
            onBeforeNext: (page) => page == 2 ? () async => true : null,
            onDone: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await swipe(-600);
    expect(find.text('page-1'), findsOneWidget);
    await swipe(-600);
    expect(find.text('page-1'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-200, 0), 3000);
    await tester.pumpAndSettle();
    expect(find.text('page-1'), findsOneWidget);
    await swipe(600);
    expect(find.text('page-0'), findsOneWidget);

    // A page with a commit hook swipes back too.
    gate.value = true;
    await swipe(-600);
    await swipe(-600);
    expect(find.text('page-2'), findsOneWidget);
    await swipe(-600);
    expect(find.text('page-2'), findsOneWidget);
    await tester.fling(find.byType(PageView), const Offset(-200, 0), 3000);
    await tester.pumpAndSettle();
    expect(find.text('page-2'), findsOneWidget);
    await swipe(600);
    expect(find.text('page-1'), findsOneWidget);
  });

  testWidgets('onBeforeNext locks swiping, gates advance, and blocks concurrent nav', (tester) async {
    final gate = true.vn;
    addTearDown(gate.dispose);
    const allowCommit = false;
    Completer<bool>? pendingCommit;
    var commitCalls = 0;
    var doneCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [LibLocalizations.delegate],
        home: IntroPage(
          args: IntroPageArgs(
            pages: [
              Builder(
                builder: (ctx) => Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text('commit-page'),
                      TextButton(
                        onPressed: () => IntroPage.nextOf(ctx),
                        child: const Text('skip'),
                      ),
                    ],
                  ),
                ),
              ),
              const Center(child: Text('page2')),
            ],
            canProceed: (page) => page == 0 ? gate : null,
            onBeforeNext: (page) => page == 0
                ? () async {
                    commitCalls++;
                    final pending = pendingCommit;
                    if (pending != null) return pending.future;
                    return allowCommit;
                  }
                : null,
            onDone: (_) => doneCalls++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Even with canProceed == true, swiping cannot bypass onBeforeNext.
    await tester.drag(find.byType(PageView), const Offset(-400, 0));
    await tester.pumpAndSettle();
    expect(find.text('commit-page'), findsOneWidget);
    expect(commitCalls, 0);

    // Returning false stays on the page.
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('commit-page'), findsOneWidget);
    expect(commitCalls, 1);

    // While an async onBeforeNext is in flight, repeated Next or Skip taps are ignored.
    pendingCommit = Completer<bool>();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.tap(find.byType(FilledButton));
    await tester.tap(find.text('skip'));
    await tester.pump();
    expect(commitCalls, 2);
    expect(find.text('commit-page'), findsOneWidget);

    pendingCommit.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('page2'), findsOneWidget);

    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(doneCalls, 1);
  });

  testWidgets('IntroPage.finishOf finishes immediately', (tester) async {
    var doneCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [LibLocalizations.delegate],
        home: IntroPage(
          args: IntroPageArgs(
            pages: [
              Builder(
                builder: (ctx) => Center(
                  child: TextButton(
                    onPressed: () => IntroPage.finishOf(ctx),
                    child: const Text('finish-now'),
                  ),
                ),
              ),
              const Center(child: Text('page2')),
            ],
            onDone: (_) => doneCalls++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('finish-now'));
    await tester.pump();
    expect(doneCalls, 1);
  });

  testWidgets('double-tapping Next mid-animation runs onBeforeNext only once', (tester) async {
    var commitCalls = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [LibLocalizations.delegate],
        home: IntroPage(
          args: IntroPageArgs(
            pages: const [
              Center(child: Text('page-0')),
              Center(child: Text('page-1')),
              Center(child: Text('page-2')),
            ],
            onBeforeNext: (page) => page == 0
                ? () async {
                    commitCalls++;
                    return true;
                  }
                : null,
            onDone: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap Next, pump a short frame before the page animation finishes and page
    // index changes, then tap Next a second time.
    await tester.tap(find.byType(FilledButton));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();

    expect(commitCalls, 1);
    expect(find.text('page-1'), findsOneWidget);
  });

  testWidgets('Previous holds advance lock for its full animation', (tester) async {
    late BuildContext page1Ctx;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [LibLocalizations.delegate],
        home: IntroPage(
          args: IntroPageArgs(
            pages: [
              const Center(child: Text('page-0')),
              Builder(
                builder: (ctx) {
                  page1Ctx = ctx;
                  return const Center(child: Text('page-1'));
                },
              ),
              const Center(child: Text('page-2')),
            ],
            onDone: (_) {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Go to page 1.
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('page-1'), findsOneWidget);

    // Tap Previous, then immediately tap Next and call bypass IntroPage.nextOf
    // mid-animation; Previous must complete cleanly to page 0 without
    // overlapping forward navigation.
    await tester.tap(find.text('Previous'));
    await tester.pump(const Duration(milliseconds: 20));
    await tester.tap(find.byType(FilledButton));
    IntroPage.nextOf(page1Ctx);
    await tester.pumpAndSettle();

    expect(find.text('page-0'), findsOneWidget);
  });

  testWidgets('horizontal pointer-scroll respects canProceed gate and runs onBeforeNext hook', (tester) async {
    final gate = false.vn;
    addTearDown(gate.dispose);
    var allowHook = false;
    var hookCalls = 0;
    var doneCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [LibLocalizations.delegate],
        home: IntroPage(
          args: IntroPageArgs(
            pages: const [
              Center(child: Text('page-0')),
              Center(child: Text('page-1')),
              Center(child: Text('page-2')),
            ],
            canProceed: (page) => page == 1 ? gate : null,
            onBeforeNext: (page) => page == 2
                ? () async {
                    hookCalls++;
                    return allowHook;
                  }
                : null,
            onDone: (_) => doneCalls++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Future<void> scrollHorizontal(double dx) async {
      final center = tester.getCenter(find.byType(PageView));
      final pointer = TestPointer(1, PointerDeviceKind.mouse);
      await tester.sendEventToBinding(pointer.hover(center));
      await tester.sendEventToBinding(pointer.scroll(Offset(dx, 0)));
      await tester.pumpAndSettle();
    }

    // Move to gated page-1 via Next.
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('page-1'), findsOneWidget);

    // Forward horizontal pointer-scroll (> half viewport) on locked page-1 must not advance.
    await scrollHorizontal(500);
    expect(find.text('page-1'), findsOneWidget);

    // Backward horizontal pointer-scroll still navigates back.
    await scrollHorizontal(-500);
    expect(find.text('page-0'), findsOneWidget);

    // Unlock page-1 and advance to hook-guarded final page-2.
    gate.value = true;
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('page-2'), findsOneWidget);

    // Forward horizontal pointer-scroll runs onBeforeNext; returning false stays.
    await scrollHorizontal(500);
    expect(hookCalls, 1);
    expect(doneCalls, 0);
    expect(find.text('page-2'), findsOneWidget);

    // When onBeforeNext succeeds on the last page, matches Done behavior.
    allowHook = true;
    await scrollHorizontal(500);
    expect(hookCalls, 2);
    expect(doneCalls, 1);
  });

  testWidgets('onBeforeNext completion is discarded if user scrolled back while awaiting', (tester) async {
    final pending = Completer<bool>();
    var doneCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [LibLocalizations.delegate],
        home: IntroPage(
          args: IntroPageArgs(
            pages: const [
              Center(child: Text('page-0')),
              Center(child: Text('page-1')),
              Center(child: Text('page-2')),
            ],
            onBeforeNext: (page) => page == 1 ? () => pending.future : null,
            onDone: (_) => doneCalls++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Go to page-1 and start async onBeforeNext via Next.
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    expect(find.text('page-1'), findsOneWidget);

    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    // Swipe back to page-0 while page-1's hook is still pending.
    await tester.drag(find.byType(PageView), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(find.text('page-0'), findsOneWidget);

    // Hook resolves true: stale completion must be discarded, staying on page-0.
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('page-0'), findsOneWidget);
    expect(doneCalls, 0);
  });

  testWidgets('onBeforeNext completion is discarded after ABA page navigation (1 -> 0 -> 1)', (tester) async {
    final pending = Completer<bool>();
    var doneCalls = 0;

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [LibLocalizations.delegate],
        home: IntroPage(
          args: IntroPageArgs(
            pages: const [
              Center(child: Text('page-0')),
              Center(child: Text('page-1')),
              Center(child: Text('page-2')),
            ],
            onBeforeNext: (page) => page == 1 ? () => pending.future : null,
            onDone: (_) => doneCalls++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Go to page-1 and start async onBeforeNext.
    await tester.tap(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();

    // Navigate 1 -> 0 -> 1 while the original hook is still pending.
    await tester.drag(find.byType(PageView), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(find.text('page-0'), findsOneWidget);

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('page-1'), findsOneWidget);

    // Original hook resolves true: ABA navigation must still discard it.
    pending.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('page-1'), findsOneWidget);
    expect(doneCalls, 0);
  });
}
