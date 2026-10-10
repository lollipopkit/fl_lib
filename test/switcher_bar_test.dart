import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// [SwitcherBar]: the switcher keeps its width, the buttons fold into a menu,
/// and nothing overflows down to the narrowest list column.
void main() {
  final taps = <String>[];
  final actions = [
    for (final (icon, label) in [
      (Icons.search, 'Search'),
      (Icons.refresh, 'Refresh'),
      (Icons.add, 'New'),
    ])
      BarAction(icon: icon, label: label, onTap: () => taps.add(label)),
  ];

  /// The bar's own trailing gap, outside what the buttons are counted in.
  const gap = 7.0;

  Future<void> pump(
    WidgetTester tester,
    double width, {
    List<BarAction>? with_,
    List<ContextMenuAction> Function()? menu,
  }) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const [LibLocalizations.delegate],
      supportedLocales: LibLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: SwitcherBar(
              switcher: const SessionSwitcherLabel(
                name: 'pve',
                position: 1,
                total: 2,
                onTap: _noop,
              ),
              actions: with_ ?? actions,
              menu: menu,
            ),
          ),
        ),
      ),
    ),
  );

  setUp(taps.clear);

  testWidgets('the bar is as tall as every tab bar', (tester) async {
    await pump(tester, 600);
    expect(tester.getSize(find.byType(SwitcherBar)).height, SwitcherBar.height);
  });

  testWidgets('a button is as wide as the slot it is counted as', (tester) async {
    await pump(tester, 600);
    expect(tester.getSize(find.byType(Btn).first).width, SwitcherBar.slot);
  });

  testWidgets('with room, every button; narrow, the rest behind a menu', (
    tester,
  ) async {
    await pump(tester, 600);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);

    // Just enough for all three beside the switcher.
    await pump(tester, 104 + 3 * SwitcherBar.slot + gap);
    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.more_vert), findsNothing);

    // Short of the third slot: the menu takes the second, so one button and
    // the menu for the other two.
    await pump(tester, 104 + 3 * SwitcherBar.slot + gap - 1);
    expect(find.byIcon(Icons.search), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);

    // The narrowest a list column drags to: room for one slot, which the menu
    // takes.
    await pump(tester, 160);
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.search), findsNothing);
    expect(find.byIcon(Icons.more_vert), findsOneWidget);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    await tester.tap(find.text('New'));
    await tester.pumpAndSettle();
    expect(taps, ['New']);
  });

  testWidgets('a menu of its own comes first, and takes a slot', (
    tester,
  ) async {
    await pump(
      tester,
      104 + 3 * SwitcherBar.slot + gap,
      menu: () => [ContextMenuAction(text: 'Reconnect', onTap: () {})],
    );
    // Three slots: two buttons and the menu, which also holds the third.
    expect(find.byIcon(Icons.refresh), findsOneWidget);
    expect(find.byIcon(Icons.add), findsNothing);
    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    final reconnect = tester.getTopLeft(find.text('Reconnect'));
    final add = tester.getTopLeft(find.text('New'));
    expect(reconnect.dy, lessThan(add.dy));
  });

  testWidgets('a loading action is a spinner in its slot, and not a tap', (
    tester,
  ) async {
    var refreshed = 0;
    await pump(
      tester,
      400,
      with_: [
        BarAction(
          icon: Icons.refresh,
          label: 'Refresh',
          onTap: () => refreshed++,
          loading: true,
        ),
      ],
    );
    // One frame, not `pumpAndSettle`: a spinner never settles.
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsNothing);
    await tester.tap(find.byType(CircularProgressIndicator));
    await tester.pump();
    expect(refreshed, 0);
  });

  testWidgets('a listening action follows its state, and can be nothing', (
    tester,
  ) async {
    final on = ValueNotifier<bool?>(false);
    addTearDown(on.dispose);
    await pump(
      tester,
      400,
      with_: [
        BarAction.listen(
          listenable: on,
          build: (_) => switch (on.value) {
            null => null,
            final value => BarAction(
              icon: value ? Icons.lock : Icons.lock_open,
              label: 'Lock',
              onTap: () => on.value = !value,
            ),
          },
        ),
      ],
    );
    expect(find.byIcon(Icons.lock_open), findsOneWidget);
    await tester.tap(find.byIcon(Icons.lock_open));
    await tester.pump();
    expect(find.byIcon(Icons.lock), findsOneWidget);
    on.value = null;
    await tester.pump();
    expect(find.byIcon(Icons.lock), findsNothing);
    expect(find.byType(Btn), findsNothing);
  });
}

void _noop() {}
