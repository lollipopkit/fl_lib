import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('pop on a context whose widget is gone does nothing', (
    tester,
  ) async {
    // A pop is often the last line after an `await`, and the widget that
    // asked can be gone by then. `Navigator.of` on that context failed a null
    // check inside the framework.
    late BuildContext stale;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            stale = context;
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpWidget(const SizedBox());

    expect(stale.mounted, isFalse);
    expect(stale.canPop, isFalse);
    expect(() => stale.pop(), returnsNormally);
  });
}
