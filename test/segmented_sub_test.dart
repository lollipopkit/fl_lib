import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

enum _View { overview, console, snapshots }

enum _Console { text, screen }

void main() {
  const marker = ValueKey('segmented-marker');

  /// Overview / Console / Snapshots, the console holding Terminal / Screen.
  Future<(ValueNotifier<_View>, ValueNotifier<_Console>)> pump(
    WidgetTester tester, {
    _View view = _View.overview,
  }) async {
    final selected = ValueNotifier(view);
    final console = ValueNotifier(_Console.text);
    addTearDown(selected.dispose);
    addTearDown(console.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ListenableBuilder(
              listenable: Listenable.merge([selected, console]),
              builder: (_, _) => SegmentedTabs<_View>(
                selected: selected.value,
                onSelected: (v) => selected.value = v,
                segments: [
                  const SegmentedTab(value: _View.overview, label: 'Overview'),
                  SegmentedTab(
                    value: _View.console,
                    label: 'Console',
                    sub: SegmentedSub<_Console>(
                      selected: console.value,
                      onSelected: (v) => console.value = v,
                      segments: const [
                        SegmentedTab(value: _Console.text, label: 'Terminal'),
                        SegmentedTab(value: _Console.screen, label: 'Screen'),
                      ],
                    ),
                  ),
                  const SegmentedTab(value: _View.snapshots, label: 'Snapshots'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    return (selected, console);
  }

  testWidgets('the second level shows only while its segment is selected', (
    tester,
  ) async {
    final (selected, _) = await pump(tester);
    expect(find.text('Terminal'), findsNothing);

    await tester.tap(find.text('Console'));
    await tester.pumpAndSettle();
    expect(selected.value, _View.console);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.text('Screen'), findsOneWidget);

    // To the right of its parent, before the next segment.
    final console = tester.getCenter(find.text('Console')).dx;
    final terminal = tester.getCenter(find.text('Terminal')).dx;
    final screen = tester.getCenter(find.text('Screen')).dx;
    final snapshots = tester.getCenter(find.text('Snapshots')).dx;
    expect(console < terminal && terminal < screen && screen < snapshots, isTrue);

    // Under the parent's marker, all of it.
    final rect = tester.getRect(find.byKey(marker));
    expect(rect.left, lessThan(tester.getRect(find.text('Console')).left));
    expect(rect.right, greaterThan(tester.getRect(find.text('Screen')).right));

    await tester.tap(find.text('Snapshots'));
    await tester.pumpAndSettle();
    expect(find.text('Terminal'), findsNothing);
  });

  testWidgets('choosing in the second level, under its own marker', (
    tester,
  ) async {
    final (selected, console) = await pump(tester, view: _View.console);
    Rect subMarker() => tester.getRect(
      find.byKey(const ValueKey(('segmented-sub-marker', _View.console))),
    );
    expect(
      subMarker().center.dx,
      closeTo(tester.getCenter(find.text('Terminal')).dx, 1),
    );

    await tester.tap(find.text('Screen'));
    await tester.pumpAndSettle();
    expect(console.value, _Console.screen);
    expect(selected.value, _View.console, reason: 'the first level stays');
    expect(
      subMarker().center.dx,
      closeTo(tester.getCenter(find.text('Screen')).dx, 1),
    );
  });

  /// Eight segments with icons, the console one open, in [width].
  Future<void> pumpWide(WidgetTester tester, double width) async {
    // A window wider than any row here: the width under test is [width].
    tester.view.physicalSize = const Size(1600, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: SegmentedTabs<int>(
                selected: 1,
                onSelected: (_) {},
                segments: [
                  const SegmentedTab(value: 0, label: 'Overview', icon: Icons.show_chart),
                  SegmentedTab(
                    value: 1,
                    label: 'Console',
                    icon: Icons.monitor,
                    sub: SegmentedSub<int>(
                      selected: 0,
                      onSelected: (_) {},
                      segments: const [
                        SegmentedTab(value: 0, label: 'Terminal', icon: Icons.terminal),
                        SegmentedTab(value: 1, label: 'Graphical', icon: Icons.monitor),
                      ],
                    ),
                  ),
                  for (var i = 2; i < 8; i++)
                    SegmentedTab(value: i, label: 'Tab $i', icon: Icons.circle),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    // Measured in one frame, switched in the next.
    for (var i = 0; i < 3; i++) {
      await tester.pump();
    }
  }

  testWidgets('with room, every label shows — the open segment\'s three too', (
    tester,
  ) async {
    await pumpWide(tester, 1400);
    for (final label in ['Console', 'Terminal', 'Graphical', 'Tab 7']) {
      expect(find.text(label), findsOneWidget, reason: label);
      final p = tester.renderObject<RenderParagraph>(find.text(label));
      expect(p.didExceedMaxLines, isFalse, reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('without room, icons only, labels as tooltips; back with room', (
    tester,
  ) async {
    await pumpWide(tester, 360);
    expect(tester.takeException(), isNull);
    expect(find.text('Console'), findsNothing);
    expect(find.text('Terminal'), findsNothing);
    expect(find.byTooltip('Terminal'), findsOneWidget);
    expect(find.byTooltip('Tab 7'), findsOneWidget);

    await pumpWide(tester, 1400);
    expect(find.text('Terminal'), findsOneWidget);
    expect(find.byTooltip('Terminal'), findsNothing);
  });

  testWidgets('switching width and segment back and forth measures nothing '
      'that has left the tree', (tester) async {
    for (final width in [360.0, 1400.0, 360.0, 1400.0]) {
      await pumpWide(tester, width);
      expect(tester.takeException(), isNull, reason: '$width');
    }
  });
}
