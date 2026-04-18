import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const initialPage = Center(
    key: ValueKey('initial-page'),
    child: Text('Initial Page'),
  );
  const pageOne = Center(
    key: ValueKey('page-one'),
    child: Text('Page One'),
  );
  const pageTwo = Center(
    key: ValueKey('page-two'),
    child: Text('Page Two'),
  );

  testWidgets('push replace and pop keep split view content consistent', (
    tester,
  ) async {
    final controller = SplitViewController(
      initialRight: initialPage,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SplitView(
            controller: controller,
            leftBuilder: (context, area) =>
                const ColoredBox(color: Colors.blue),
            initialRight: initialPage,
          ),
        ),
      ),
    );

    expect(find.text('Initial Page'), findsOneWidget);

    controller.push<void>(pageOne);
    await tester.pump();
    await tester.pump(Durations.medium3 + const Duration(milliseconds: 50));
    await tester.pump();

    expect(find.text('Page One'), findsOneWidget);
    expect(find.text('Initial Page'), findsNothing);

    controller.replace<void>(pageTwo);
    await tester.pump();
    await tester.pump(Durations.medium3 + const Duration(milliseconds: 50));
    await tester.pump();

    expect(find.text('Page Two'), findsOneWidget);
    expect(find.text('Page One'), findsNothing);

    controller.pop<void>();
    await tester.pump();
    await tester.pump(Durations.medium3 + const Duration(milliseconds: 50));
    await tester.pump();

    expect(find.text('Initial Page'), findsOneWidget);
    expect(find.text('Page Two'), findsNothing);
  });
}
