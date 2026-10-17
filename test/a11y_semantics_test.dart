import 'dart:ui' show SemanticsAction;

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// What a screen reader finds in a form field, an empty place and an area
/// that only answers the secondary button.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(home: Scaffold(body: Center(child: child))),
  );

  testWidgets('a field is named by its label, with its value beside it', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      Input(
        label: 'Host',
        controller: TextEditingController(text: '10.0.2.2'),
      ),
    );

    final data = tester.getSemantics(find.byType(TextField)).getSemanticsData();
    expect(data.flagsCollection.isTextField, isTrue);
    expect(data.label, 'Host');
    expect(data.value, '10.0.2.2');
    handle.dispose();
  });

  testWidgets('a right-click area is not a nameless button', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      const SizedBox(width: 200, height: 200, child: Text('area'))
          .onSecondary((_) {}),
    );

    final data = tester.getSemantics(find.text('area')).getSemanticsData();
    expect(data.hasAction(SemanticsAction.tap), isFalse);
    handle.dispose();
  });

  testWidgets('an empty place with no words is read as empty', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester, const EmptyMark(icon: Icons.folder_open));
    expect(find.bySemanticsLabel(libL10n.empty), findsOneWidget);

    await pump(tester, const EmptyMark(icon: Icons.search_off, label: 'q'));
    expect(find.bySemanticsLabel(libL10n.empty), findsNothing);
    expect(find.bySemanticsLabel('q'), findsOneWidget);
    handle.dispose();
  });
}
