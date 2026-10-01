import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Across, the box is the track: a trailing switch ends where the rest of a
/// row's content does, not 4 (scaled) short of it.
void main() {
  testWidgets('M3: as wide as its track', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(),
        home: Scaffold(
          body: Center(child: SwitchX(value: false, onChanged: (_) {})),
        ),
      ),
    );
    final size = tester.getSize(find.byType(SwitchX));
    expect(size.height, 25);
    expect(size.width, closeTo(25 * 52 / 40, 0.01));
  });
}
