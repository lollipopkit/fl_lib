import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// [Btn.row] with nothing to do looks it, whatever colour its caller gave
/// the icon and the text: a red delete that cannot be pressed read as one
/// that could.
void main() {
  Future<void> pump(WidgetTester tester, VoidCallback? onTap) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: Btn.row(
                text: 'Delete',
                icon: const Icon(Icons.delete, color: Colors.red),
                textStyle: const TextStyle(color: Colors.red),
                onTap: onTap,
              ),
            ),
          ),
        ),
      );

  double? opacity(WidgetTester tester) {
    final faded = find.ancestor(
      of: find.text('Delete'),
      matching: find.byType(Opacity),
    );
    if (faded.evaluate().isEmpty) return null;
    return tester.widget<Opacity>(faded.first).opacity;
  }

  testWidgets('disabled: faded', (tester) async {
    await pump(tester, null);
    expect(opacity(tester), 0.38);
  });

  testWidgets('enabled: as drawn', (tester) async {
    await pump(tester, () {});
    expect(opacity(tester), isNull);
  });
}
