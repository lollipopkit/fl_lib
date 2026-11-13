import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('blurs behind its shape and carries ink', (t) async {
    var taps = 0;
    await t.pumpWidget(
      MaterialApp(
        home: Center(
          child: Frosted(
            shape: const CircleBorder(),
            child: InkWell(
              onTap: () => taps++,
              child: const SizedBox.square(dimension: 48),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsOneWidget);
    await t.tap(find.byType(InkWell));
    expect(taps, 1);
  });
}
