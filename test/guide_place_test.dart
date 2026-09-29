import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// Where [GuideView] puts its card.
///
/// It picked the widest margin around the spot without asking whether the
/// card fit in it. A spot covering nearly the whole window — a remote
/// desktop's canvas, with a toolbar above and a navigation bar below — left
/// every margin thinner than the card, and it overflowed out of the strip
/// under the navigation bar with its text cut off.
void main() {
  const size = Size(800, 1200);
  const body = 'One finger moves the pointer like a touchpad.';

  Future<void> pump(WidgetTester tester, Rect spot) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [LibLocalizations.delegate],
        supportedLocales: LibLocalizations.supportedLocales,
        home: GuideView(
          steps: [GuideStep(title: 'Touchpad', body: body, spot: spot)],
          step: 0,
          onStep: (_) {},
          onDone: () {},
        ),
      ),
    );
  }

  Rect card(WidgetTester tester) => tester.getRect(
    find.ancestor(of: find.text(body), matching: find.byType(Material)).first,
  );

  testWidgets('a spot with no room around it gets the card over it', (
    tester,
  ) async {
    await pump(tester, const Rect.fromLTWH(0, 60, 800, 1060));

    expect(tester.takeException(), isNull);
    final rect = card(tester);
    expect((Offset.zero & size).contains(rect.topLeft), isTrue);
    expect(rect.bottom, lessThanOrEqualTo(size.height));
    // At the bottom, where a spot-less guide puts it.
    expect(rect.bottom, greaterThan(size.height / 2));
  });

  testWidgets('a small spot keeps the card beside it', (tester) async {
    const spot = Rect.fromLTWH(700, 20, 40, 40);
    await pump(tester, spot);

    expect(tester.takeException(), isNull);
    final rect = card(tester);
    expect(rect.overlaps(spot.inflate(6)), isFalse);
    expect(rect.top, greaterThanOrEqualTo(spot.bottom));
  });
}
