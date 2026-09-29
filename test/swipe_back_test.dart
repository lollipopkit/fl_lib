import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  Widget app() => MaterialApp(
    theme: ThemeData(
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: SwipeBackPageTransitionsBuilder(),
          TargetPlatform.android: SwipeBackPageTransitionsBuilder(),
        },
      ),
    ),
    home: Builder(
      builder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Center(child: Text('second')))),
            ),
            child: const Text('first'),
          ),
        ),
      ),
    ),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(app());
    await tester.tap(find.text('first'));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
  }

  testWidgets('a swipe from the left edge goes back', (tester) async {
    await open(tester);
    final g = await tester.startGesture(const Offset(5, 300));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Mid-gesture, the page below shows through.
    expect(find.text('first'), findsOneWidget);
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('second'), findsNothing);
    expect(find.text('first'), findsOneWidget);
  });

  testWidgets('a short, slow swipe returns to the page', (tester) async {
    await open(tester);
    final g = await tester.startGesture(const Offset(5, 300));
    for (var i = 0; i < 5; i++) {
      await g.moveBy(const Offset(10, 0));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await g.up();
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
  });

  testWidgets('a swipe away from the edge is not a back', (tester) async {
    await open(tester);
    await tester.dragFrom(const Offset(200, 300), const Offset(500, 0));
    await tester.pumpAndSettle();
    expect(find.text('second'), findsOneWidget);
  });
}
