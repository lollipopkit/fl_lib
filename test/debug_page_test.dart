import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the Logs back button pops its nested route', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: NestedNavigator(
          rootBuilder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => DebugPage.route.go(
                  context,
                  args: const DebugPageArgs(title: 'Logs'),
                ),
                child: const Text('open Logs'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open Logs'));
    await tester.pumpAndSettle();
    expect(find.byType(DebugPage), findsOneWidget);

    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();

    expect(find.byType(DebugPage), findsNothing);
    expect(find.text('open Logs'), findsOneWidget);
  });
}
