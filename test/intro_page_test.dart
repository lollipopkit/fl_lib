import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
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
}
