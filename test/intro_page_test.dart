import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// Two pages at a given window size, in a given language.
  ///
  /// [maxWidth] is the content column the bar aligns itself to; the wide bar
  /// puts labelled buttons in it, so a language with long words is the case
  /// that decides whether the column is wide enough.
  Widget harness(Locale locale, {double maxWidth = UIs.pageColumnWidth}) {
    return MaterialApp(
      locale: locale,
      localizationsDelegates: const [
        LibLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
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
  /// to be drained explicitly — and drained on both pages, because the bar is
  /// at its widest on the second, where `previous` sits beside `next`.
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
    Size(700, 800), // the narrowest window that still gets the wide bar
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

        final advance = size.width < 600 ? find.byType(IconButton) : find.byType(FilledButton);
        await tester.tap(advance);
        await tester.pumpAndSettle();
        expect(takeErrors(), isEmpty, reason: 'page 2');
      });
    }
  }

  testWidgets('wide bar puts the progress before the buttons', (tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(const Locale('en')));
    await tester.pumpAndSettle();

    final progress = tester.getTopLeft(find.text('1'));
    final next = tester.getTopLeft(find.byType(FilledButton));
    expect(progress.dx, lessThan(next.dx));

    // Bounded by the content column rather than the window.
    expect(next.dx, lessThan(1400 / 2 + UIs.pageColumnWidth / 2));
  });

  testWidgets('compact bar keeps the progress centred', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness(const Locale('en')));
    await tester.pumpAndSettle();

    expect(find.byType(FilledButton), findsNothing);

    // The counter is two `Text`s so the current page can fade in on its own.
    final left = tester.getTopLeft(find.text('1')).dx;
    final right = tester.getBottomRight(find.text(' / 2')).dx;
    expect((left + right) / 2, closeTo(390 / 2, 12));
  });

  /// Both bars, because `_pageCount <= 1` is answered in `_buildProgress`,
  /// which each of them calls — and this test used to run only at the default
  /// 800x600 view, i.e. only ever the wide one.
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
      expect(find.byType(BottomAppBar), findsOneWidget);
    });
  }
}
