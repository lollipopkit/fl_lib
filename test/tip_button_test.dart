import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n_en.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Future<void> pump(WidgetTester tester, String tip) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: Center(child: TipButton(tip)))),
    );
  }

  testWidgets('it is named for a screen reader', (tester) async {
    await pump(tester, 'tip');
    expect(find.byTooltip(LibLocalizationsEn().note), findsOneWidget);
  });

  testWidgets('a plain tip longer than the dialog scrolls', (tester) async {
    await pump(tester, List.filled(200, 'A long line of help.').join('\n'));
    await tester.tap(find.byType(TipButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      find.ancestor(
        of: find.textContaining('A long line'),
        matching: find.byType(SingleChildScrollView),
      ),
      findsOneWidget,
    );
  });
}
