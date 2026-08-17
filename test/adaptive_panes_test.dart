import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  /// A list of two items beside a detail area, at a given width.
  ///
  /// [selected] stands for the app's selection state: null before anything is
  /// opened, which is the case that must not reserve a column for nothing.
  Widget harness({
    required double width,
    String? selected,
    double minWidthForDetail = 800,
    VoidCallback? onClose,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            height: 600,
            child: AdaptivePanes(
              minWidthForDetail: minWidthForDetail,
              detailId: selected,
              onCloseDetail: onClose,
              primaryBuilder: (_, split) => Text(split ? 'list compact' : 'list'),
              detailBuilder: selected == null
                  ? null
                  : (context) => Scaffold(
                      appBar: CustomAppBar(title: Text('detail $selected')),
                      body: TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const Scaffold(
                              appBar: CustomAppBar(title: Text('deeper')),
                              body: Text('deeper body'),
                            ),
                          ),
                        ),
                        child: const Text('go deeper'),
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a primary width given later replaces the one it opened with', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Widget at(double width) => MaterialApp(
      home: Scaffold(
        body: AdaptivePanes(
          primaryWidth: width,
          detailId: 'a',
          primaryBuilder: (_, _) =>
              const ColoredBox(key: ValueKey('primary'), color: Colors.grey),
          detailBuilder: (_) => const Scaffold(body: Text('detail')),
        ),
      ),
    );

    await tester.pumpWidget(at(300));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byKey(const ValueKey('primary'))).width, 300);

    // What several of these sharing one stored width look like: another page
    // wrote it, and this one — kept alive behind it — is rebuilt with the new
    // number. Ignoring it made one setting behave as one per page.
    await tester.pumpWidget(at(420));
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byKey(const ValueKey('primary'))).width, 420);
  });

  testWidgets('a narrow window shows the list alone', (tester) async {
    await tester.pumpWidget(harness(width: 700, selected: 'a'));
    await tester.pumpAndSettle();

    expect(find.text('list'), findsOneWidget);
    expect(
      find.text('detail a'),
      findsNothing,
      reason: 'below the breakpoint the detail is pushed, not placed beside',
    );
  });

  testWidgets('a wide window shows both', (tester) async {
    await tester.pumpWidget(harness(width: 1000, selected: 'a'));
    await tester.pumpAndSettle();

    expect(find.text('list compact'), findsOneWidget);
    expect(find.text('detail a'), findsOneWidget);
  });

  testWidgets('nothing selected leaves the list the whole width', (
    tester,
  ) async {
    await tester.pumpWidget(harness(width: 1000));
    await tester.pumpAndSettle();

    expect(find.text('list'), findsOneWidget);
    expect(
      find.byType(VerticalDivider),
      findsNothing,
      reason: 'an empty column is worse than no column',
    );
  });

  testWidgets('selecting another item replaces the detail', (tester) async {
    await tester.pumpWidget(harness(width: 1000, selected: 'a'));
    await tester.pumpAndSettle();
    expect(find.text('detail a'), findsOneWidget);

    await tester.pumpWidget(harness(width: 1000, selected: 'b'));
    await tester.pumpAndSettle();

    expect(find.text('detail b'), findsOneWidget);
    expect(find.text('detail a'), findsNothing);
  });

  testWidgets('the page being replaced is not rebuilt into the new one', (
    tester,
  ) async {
    // Rebuilding a navigator rebuilds every route's page, so the route on its
    // way out ran the caller's builder again and rendered the item just
    // picked. The new page was then on screen twice — once underneath at
    // once, once more as the incoming route animated in over it — which read
    // as the pane flashing twice for one tap.
    await tester.pumpWidget(harness(width: 1000, selected: 'a'));
    await tester.pumpAndSettle();

    await tester.pumpWidget(harness(width: 1000, selected: 'b'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('detail b'), findsOneWidget);
    expect(
      find.text('detail a'),
      findsOneWidget,
      reason: 'the outgoing page shows what it always showed until it goes',
    );

    await tester.pumpAndSettle();
    expect(find.text('detail a'), findsNothing);
  });

  testWidgets('switching items clears what was pushed on top', (tester) async {
    await tester.pumpWidget(harness(width: 1000, selected: 'a'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('go deeper'));
    await tester.pumpAndSettle();
    expect(find.text('deeper'), findsOneWidget);

    await tester.pumpWidget(harness(width: 1000, selected: 'b'));
    await tester.pumpAndSettle();

    expect(
      find.text('deeper'),
      findsNothing,
      reason: "a page belonging to the previous item must not outlive it",
    );
    expect(find.text('detail b'), findsOneWidget);
  });

  testWidgets('the pane root offers a way out', (tester) async {
    // Its navigator has nothing to pop, so without this the page beside the
    // list is one the user cannot leave.
    var closed = 0;
    void close() => closed++;

    await tester.pumpWidget(
      harness(width: 1000, selected: 'a', onClose: close),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(BackButton));
    expect(closed, 1);
  });

  testWidgets('no way out where the host offers none', (tester) async {
    await tester.pumpWidget(harness(width: 1000, selected: 'a'));
    await tester.pumpAndSettle();

    expect(
      find.byType(BackButton),
      findsNothing,
      reason: 'a button that cannot do anything is worse than none',
    );
  });

  testWidgets('back inside the pane pops rather than closes it', (
    tester,
  ) async {
    var closed = 0;
    void close() => closed++;

    await tester.pumpWidget(
      harness(width: 1000, selected: 'a', onClose: close),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('go deeper'));
    await tester.pumpAndSettle();

    final deeperBar = find.ancestor(
      of: find.text('deeper'),
      matching: find.byType(CustomAppBar),
    );
    await tester.tap(
      find.descendant(of: deeperBar, matching: find.byType(BackButton)),
    );
    await tester.pumpAndSettle();

    expect(find.text('detail a'), findsOneWidget);
    expect(
      closed,
      0,
      reason: 'closing the pane here would skip the page in between',
    );
  });

  testWidgets('closing hands the width back to the list', (tester) async {
    await tester.pumpWidget(harness(width: 1000, selected: 'a'));
    await tester.pumpAndSettle();
    expect(find.text('list compact'), findsOneWidget);

    await tester.pumpWidget(harness(width: 1000));
    await tester.pumpAndSettle();

    expect(find.text('list'), findsOneWidget);
    expect(find.text('detail a'), findsNothing);
  });

  testWidgets('reopening while the old pane fades out keeps it working', (
    tester,
  ) async {
    // The pane is one subtree that survives being closed, rather than one torn
    // down and rebuilt beside the copy still fading out. So its navigator
    // outlives the round trip, and anything addressing that navigator — the
    // way out of its root, above all — has to still reach it.
    var closed = 0;
    void close() => closed++;

    await tester.pumpWidget(
      harness(width: 1000, selected: 'a', onClose: close),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(harness(width: 1000, onClose: close));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(
      harness(width: 1000, selected: 'a', onClose: close),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('detail a'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    expect(closed, 1, reason: 'a pane you cannot leave is a trap');
  });

  testWidgets('a window dragged across the breakpoint keeps the pane working', (
    tester,
  ) async {
    // The same round trip without a click: a resize crossing the breakpoint
    // twice inside one fade.
    var closed = 0;
    void close() => closed++;

    await tester.pumpWidget(
      harness(width: 1000, selected: 'a', onClose: close),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(harness(width: 700, selected: 'a', onClose: close));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pumpWidget(
      harness(width: 1000, selected: 'a', onClose: close),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('detail a'), findsOneWidget);

    await tester.tap(find.byType(BackButton));
    expect(closed, 1);
  });

  testWidgets('a wide window reports itself split before anything is picked', (
    tester,
  ) async {
    // The deadlock this exists to prevent: a list that only selects when a
    // pane is on screen, and a pane that only appears once something is
    // selected, means nothing ever opens beside anything.
    bool? split;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 1000,
            height: 600,
            child: AdaptivePanes(
              primaryBuilder: (ctx, _) {
                split = PaneScope.isSplit(ctx);
                return const Text('list');
              },
              detailBuilder: null,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      split,
      isTrue,
      reason: 'opening something here will land it beside the list',
    );
  });

  testWidgets('a narrow window reports itself not split', (tester) async {
    bool? split;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 700,
            height: 600,
            child: AdaptivePanes(
              primaryBuilder: (ctx, _) {
                split = PaneScope.isSplit(ctx);
                return const Text('list');
              },
              detailBuilder: (_) => const Text('detail'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(split, isFalse);
  });

  testWidgets('an item deleted while its detail is open gives the width back', (
    tester,
  ) async {
    // What deleting a server does. The host keeps its selection as an id and
    // resolves it to an item every build; once the item is gone the id
    // resolves to nothing, so both the id and the builder arrive null in the
    // same frame. Different from closing — nobody pressed anything — and the
    // pane must not be left holding a detail for something that no longer
    // exists.
    await tester.pumpWidget(harness(width: 1000, selected: 'a'));
    await tester.pumpAndSettle();
    expect(find.text('detail a'), findsOneWidget);
    expect(find.text('list compact'), findsOneWidget);

    await tester.pumpWidget(harness(width: 1000));
    await tester.pumpAndSettle();

    expect(find.text('detail a'), findsNothing);
    // The whole width, the same as a launch with nothing opened.
    expect(find.text('list'), findsOneWidget);
    expect(find.text('list compact'), findsNothing);
  });

  testWidgets('a deeper page inside it goes with it', (tester) async {
    // The pane has its own navigator, so a page pushed into it outlives a
    // detail that merely changed. When the item is deleted it must not.
    await tester.pumpWidget(harness(width: 1000, selected: 'a'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('go deeper'));
    await tester.pumpAndSettle();
    expect(find.text('deeper body'), findsOneWidget);

    await tester.pumpWidget(harness(width: 1000));
    await tester.pumpAndSettle();

    expect(find.text('deeper body'), findsNothing);
    expect(find.text('list'), findsOneWidget);
  });

  testWidgets('the list can open a page in the pane beside it', (tester) async {
    // What the whole arrangement exists for: NavTarget.pane from a widget that
    // is not itself inside the pane.
    final route = AppRouteNoArg<void>(
      page: ({Key? key}) => const Text('opened in pane'),
      path: '/opened',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 1000,
            height: 600,
            child: AdaptivePanes(
              detailId: 'a',
              primaryBuilder: (ctx, _) => TextButton(
                onPressed: () => route.go(ctx, target: NavTarget.pane),
                child: const Text('open'),
              ),
              detailBuilder: (_) => const Text('detail'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('opened in pane'), findsOneWidget);
    expect(
      find.text('open'),
      findsOneWidget,
      reason: 'the list stays put while the pane beside it changes',
    );
  });
}
