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

  Future<void> swipeBack(WidgetTester tester) async {
    final g = await tester.startGesture(const Offset(5, 300));
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(40, 0));
      await tester.pump(const Duration(milliseconds: 50));
    }
    await g.up();
    await tester.pumpAndSettle();
  }

  /// A nested navigator with a page pushed in it, the way a tab or a settings
  /// view holds one; [tabs] of them side by side, the first one shown.
  Widget nested({int tabs = 1}) {
    final theme = ThemeData(
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: SwipeBackPageTransitionsBuilder(),
          TargetPlatform.android: SwipeBackPageTransitionsBuilder(),
        },
      ),
    );
    Widget tab(int i) => NestedNavigator(
      rootBuilder: (context) => Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () => AppRouteNoArg<void>(
              page: ({key}) => Scaffold(
                body: Center(
                  child: TextButton(
                    onPressed: () => AppRouteNoArg<void>(
                      page: ({key}) => const Scaffold(body: Center(child: Text('over everything'))),
                      path: '/over',
                    ).go(context, target: NavTarget.root),
                    child: Text('level $i'),
                  ),
                ),
              ),
              path: '/level',
            ).go(context),
            child: Text('tab $i'),
          ),
        ),
      ),
    );
    return MaterialApp(
      theme: theme,
      home: Row(
        children: [
          for (var i = 0; i < tabs; i++)
            Expanded(child: BackScope(enabled: i == 0, child: tab(i))),
        ],
      ),
    );
  }

  // A page pushed over the whole window from inside a nested navigator: the
  // swipe used to pop it and the nested page under it too, both being current
  // in their own navigators.
  testWidgets('a swipe pops the page on screen, not the nested one under it', (tester) async {
    await tester.pumpWidget(nested());
    await tester.tap(find.text('tab 0'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('level 0'));
    await tester.pumpAndSettle();
    expect(find.text('over everything'), findsOneWidget);

    await swipeBack(tester);
    expect(find.text('over everything'), findsNothing);
    expect(find.text('level 0'), findsOneWidget);

    await swipeBack(tester);
    expect(find.text('level 0'), findsNothing);
    expect(find.text('tab 0'), findsOneWidget);
  });

  // Two navigators, both uncovered: a tab kept alive while another is shown, a
  // pane beside the focused one. Their pages are current in their own
  // navigators, and only a `BackScope` says which one back is for.
  testWidgets('a swipe leaves a region back is not for alone', (tester) async {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(nested(tabs: 2));
    await tester.tap(find.text('tab 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('tab 0'));
    await tester.pumpAndSettle();
    expect(find.text('level 0'), findsOneWidget);
    expect(find.text('level 1'), findsOneWidget);

    await swipeBack(tester);
    expect(find.text('level 0'), findsNothing);
    expect(find.text('level 1'), findsOneWidget);
  });

  // Every `NavigatorPopHandler` on a route hears a back, so the plain back
  // popped every region too.
  testWidgets('a back pops only the region it is for', (tester) async {
    tester.view.physicalSize = const Size(1600, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(nested(tabs: 2));
    await tester.tap(find.text('tab 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('tab 0'));
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('level 0'), findsNothing);
    expect(find.text('level 1'), findsOneWidget);
  });

  // A dialog does not cover what is under it the way a page does — the page
  // keeps its tickers and its focus — but it is on top of the route holding
  // the navigator, and back is the dialog's.
  testWidgets('a page under a dialog is not on screen', (tester) async {
    await tester.pumpWidget(nested());
    await tester.tap(find.text('tab 0'));
    await tester.pumpAndSettle();
    final level = ModalRoute.of(tester.element(find.text('level 0')))!;
    expect(isRouteOnScreen(level), isTrue);

    showDialog<void>(
      context: tester.element(find.text('level 0')),
      useRootNavigator: true,
      builder: (_) => const AlertDialog(content: Text('dialog')),
    );
    await tester.pumpAndSettle();
    expect(isRouteOnScreen(level), isFalse);
    expect(level.popGestureEnabled, isFalse);
  });

  test('a pushed route takes the gesture only while on screen', () {
    expect(AppPageRoute<void>(builder: (_) => const SizedBox()), isA<OnScreenPopGestureRoute<void>>());
  });
}
