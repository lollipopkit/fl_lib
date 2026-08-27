import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('system back respects the nested root PopScope', (tester) async {
    var rejectedPops = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: NestedNavigator(
          rootBuilder: (_) => PopScope<void>(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) rejectedPops++;
            },
            child: const Scaffold(body: Text('nested root')),
          ),
        ),
      ),
    );
    // NavigatorPopHandler updates from the nested navigator's notification on
    // the frame after the route is installed.
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('nested root'), findsOneWidget);
    expect(rejectedPops, 1);
  });
}
