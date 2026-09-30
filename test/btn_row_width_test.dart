import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// [Btn.row]'s label shrinks to an ellipsis where its width is bounded, and
/// is laid out whole where it is not — beside an [Expanded], in a dialog —
/// instead of failing the flex assertion there.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(home: Scaffold(body: Center(child: child))),
  );

  Widget button() => Btn.row(
    text: 'A label long enough to need the whole row and more',
    icon: const Icon(Icons.add),
    onTap: () {},
  );

  testWidgets('beside an Expanded, where its width is unbounded', (
    tester,
  ) async {
    await pump(
      tester,
      Row(children: [const Expanded(child: Text('What this is')), button()]),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('in an intrinsic width, as a dialog lays it out', (
    tester,
  ) async {
    await pump(tester, IntrinsicWidth(child: button()));
    expect(tester.takeException(), isNull);
  });

  testWidgets('in a narrow box, ends in an ellipsis', (tester) async {
    await pump(tester, SizedBox(width: 120, child: button()));
    expect(tester.takeException(), isNull);
    final label = tester.widget<Text>(
      find.text('A label long enough to need the whole row and more'),
    );
    expect(label.overflow, TextOverflow.ellipsis);
    expect(
      tester.getSize(find.byType(Btn)).width,
      lessThanOrEqualTo(120),
    );
  });
}
