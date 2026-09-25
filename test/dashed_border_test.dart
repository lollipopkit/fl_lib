import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('draws dashes around its child, sized by it', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(
          child: DashedBorder(
            child: SizedBox(width: 120, height: 40),
          ),
        ),
      ),
    );
    final paint = find.descendant(
      of: find.byType(DashedBorder),
      matching: find.byType(CustomPaint),
    );
    expect(tester.getSize(paint), const Size(120, 40));
    // Dashes, not one closed outline: a stroke per dash.
    expect(paint, paints..path()..path()..path());
  });
}
