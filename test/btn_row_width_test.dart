import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/rendering.dart';
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

  testWidgets('its dry baseline is the one it lays out with, unbounded', (
    tester,
  ) async {
    await pump(
      tester,
      Row(children: [const Expanded(child: Text('What this is')), button()]),
    );
    final row = tester.renderObject<RenderFlex>(
      find
          .descendant(
            of: find.byType(Btn),
            matching: find.byWidgetPredicate((w) => w is Flex),
          )
          .first,
    );
    expect(row.constraints.hasBoundedWidth, isFalse);
    // Read outside a layout, which only an intrinsics check may.
    RenderObject.debugCheckingIntrinsics = true;
    final double? laidOut;
    try {
      laidOut = row.getDistanceToBaseline(TextBaseline.alphabetic);
    } finally {
      RenderObject.debugCheckingIntrinsics = false;
    }
    expect(laidOut, isNotNull);
    expect(row.getDryBaseline(row.constraints, TextBaseline.alphabetic), laidOut);
    expect(row.getDryLayout(row.constraints), row.size);
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
