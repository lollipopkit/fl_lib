import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A pane layout has more than one navigator, so "push this page" stops being
/// an unambiguous instruction. These lock the three answers, and in particular
/// that the default one keeps working for a call site that knows nothing about
/// panes — which is the whole reason the app's existing routes did not have to
/// change.
void main() {
  final route = AppRouteNoArg<void>(
    page: ({Key? key}) => const Scaffold(
      appBar: CustomAppBar(title: Text('pushed title')),
      body: Text('pushed'),
    ),
    path: '/pushed',
  );

  /// A root navigator, a pane beside it, and a button in each.
  ///
  /// The "sibling" button stands for a list next to a detail area: it is
  /// outside the pane, so `nearest` would push over the whole layout.
  Widget harness({required NavTarget targetFromSibling}) {
    final paneKey = GlobalKey<NavigatorState>();
    return MaterialApp(
      home: PaneScope(
        navigatorKey: paneKey,
        split: true,
        child: Builder(
          builder: (rootCtx) => Scaffold(
            body: Row(
              children: [
                Expanded(
                  child: TextButton(
                    onPressed: () =>
                        route.go(rootCtx, target: targetFromSibling),
                    child: const Text('sibling'),
                  ),
                ),
                Expanded(
                  child: Navigator(
                    key: paneKey,
                    onGenerateRoute: (settings) => MaterialPageRoute<void>(
                      settings: settings,
                      builder: (paneCtx) => Scaffold(
                        appBar: const CustomAppBar(title: Text('pane root')),
                        body: TextButton(
                          onPressed: () => route.go(paneCtx),
                          child: const Text('inside'),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('nearest stays inside the pane it was called from', (
    tester,
  ) async {
    await tester.pumpWidget(harness(targetFromSibling: NavTarget.nearest));
    await tester.tap(find.text('inside'));
    await tester.pumpAndSettle();

    // The sibling is still there, so the push landed in the pane rather than
    // over the whole layout
    expect(find.text('pushed'), findsOneWidget);
    expect(find.text('sibling'), findsOneWidget);
  });

  testWidgets('root covers the whole layout even from beside a pane', (
    tester,
  ) async {
    await tester.pumpWidget(harness(targetFromSibling: NavTarget.root));
    await tester.tap(find.text('sibling'));
    await tester.pumpAndSettle();

    expect(find.text('pushed'), findsOneWidget);
    expect(find.text('sibling'), findsNothing);
  });

  testWidgets('pane opens in the pane rather than over the caller', (
    tester,
  ) async {
    await tester.pumpWidget(harness(targetFromSibling: NavTarget.pane));
    await tester.tap(find.text('sibling'));
    await tester.pumpAndSettle();

    expect(find.text('pushed'), findsOneWidget);
    expect(
      find.text('sibling'),
      findsOneWidget,
      reason: 'a list must keep standing while it opens something beside it',
    );
  });

  testWidgets('pane falls back to nearest when there is no pane', (
    tester,
  ) async {
    // The single-page layout: asking for "the detail area" when there is none
    // has to open the page, not fail
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (ctx) => Scaffold(
            body: TextButton(
              onPressed: () => route.go(ctx, target: NavTarget.pane),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('pushed'), findsOneWidget);
  });

  testWidgets('a pane knows it is one, and the outside does not', (
    tester,
  ) async {
    bool? insidePane;
    bool? outsidePane;
    final paneKey = GlobalKey<NavigatorState>();

    await tester.pumpWidget(
      MaterialApp(
        home: PaneScope(
          navigatorKey: paneKey,
          split: true,
          child: Row(
            children: [
              Builder(
                builder: (ctx) {
                  outsidePane = PaneScope.isInPane(ctx);
                  return const SizedBox();
                },
              ),
              Navigator(
                key: paneKey,
                onGenerateRoute: (settings) => MaterialPageRoute<void>(
                  settings: settings,
                  builder: (ctx) {
                    insidePane = PaneScope.isInPane(ctx);
                    return const SizedBox();
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      insidePane,
      isTrue,
      reason: 'the pane\'s own navigator is the nearest one here',
    );
    expect(
      outsidePane,
      isFalse,
      reason: 'a sibling is under the same scope but not in the pane',
    );
  });

  testWidgets('a page in a pane gets no window frame', (tester) async {
    // The frame draws a caption bar. At the top of a window that is a title;
    // in the middle of one it is a stripe across the layout.
    await tester.pumpWidget(harness(targetFromSibling: NavTarget.nearest));
    await tester.tap(find.text('inside'));
    await tester.pumpAndSettle();

    final framed = find.ancestor(
      of: find.text('pushed'),
      matching: find.byType(VirtualWindowFrame),
    );
    expect(framed, findsNothing);
  });

  testWidgets('the pane root has no back button, a page pushed into it does', (
    tester,
  ) async {
    await tester.pumpWidget(harness(targetFromSibling: NavTarget.nearest));

    // Nothing to go back to: the pane's first route is where the pane starts
    expect(find.byType(BackButton), findsNothing);

    await tester.tap(find.text('inside'));
    await tester.pumpAndSettle();
    expect(
      find.byType(BackButton),
      findsOneWidget,
      reason: 'the pane has a stack now, and back is what leaves the page',
    );
  });
}
