import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// An empty label is no label: given to the field as one, it kept the room a
/// label floats into, and a focused password field had its cursor below the
/// middle under nothing.
void main() {
  testWidgets('an empty label leaves the text in the middle', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: Input(label: '', obscureText: true, autoFocus: true),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    final field = tester.getRect(find.byType(TextField));
    final text = tester.getRect(find.byType(EditableText));
    expect((text.center.dy - field.center.dy).abs(), lessThan(1));
  });
}
