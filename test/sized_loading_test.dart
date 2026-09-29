import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('takes its size, the indicator its size less the padding', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Center(child: SizedLoading(25, padding: 3, builder: SizedLoading.circularBuilder)),
      ),
    );
    expect(tester.getSize(find.byType(SizedLoading)), const Size.square(25));
    expect(tester.getSize(find.byType(CircularProgressIndicator)), const Size.square(19));
  });

  testWidgets('the presets are as documented', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Center(child: SizedLoading.small)));
    expect(tester.getSize(find.byType(SizedLoading)), const Size.square(25));
  });
}
