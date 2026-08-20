import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget harness({
    required List<String> names,
    int index = 0,
    void Function(int)? onTap,
    void Function(int)? onClose,
    List<Widget> actions = const [],
    List<Widget>? targets,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: SessionSideBar(
            names: names,
            index: index,
            onTap: onTap ?? (_) {},
            onClose: onClose ?? (_) {},
            actions: actions,
            targets:
                targets ??
                const [
                  SideBarTile(title: 'prod-1'),
                ],
          ),
        ),
      ),
    );
  }

  testWidgets('the leading page is not one of the entries', (tester) async {
    await tester.pumpWidget(harness(names: const ['add', 'alpine']));

    expect(
      find.text('add'),
      findsNothing,
      reason: 'the rail is that page, so an entry for it goes nowhere new',
    );
    expect(find.text('alpine'), findsOneWidget);
  });

  testWidgets('nothing running leaves only what can be started', (
    tester,
  ) async {
    await tester.pumpWidget(harness(names: const ['add']));

    expect(find.text('prod-1'), findsOneWidget);
    expect(find.byType(SideBarTile), findsOneWidget);
  });

  testWidgets('a running entry is marked and a target is not', (tester) async {
    await tester.pumpWidget(
      harness(names: const ['add', 'alpine'], index: 1),
    );

    final running = tester.widget<SideBarTile>(
      find.widgetWithText(SideBarTile, 'alpine'),
    );
    final target = tester.widget<SideBarTile>(
      find.widgetWithText(SideBarTile, 'prod-1'),
    );

    expect(running.live, isTrue);
    expect(running.selected, isTrue);
    expect(
      target.live,
      isFalse,
      reason: 'the same name in both sections must not read the same',
    );
  });

  testWidgets('only the entry being shown is selected', (tester) async {
    await tester.pumpWidget(
      harness(names: const ['add', 'alpine', 'alpine(1)'], index: 2),
    );

    expect(
      tester
          .widget<SideBarTile>(
            find.widgetWithText(SideBarTile, 'alpine'),
          )
          .selected,
      isFalse,
    );
    expect(
      tester
          .widget<SideBarTile>(
            find.widgetWithText(SideBarTile, 'alpine(1)'),
          )
          .selected,
      isTrue,
    );
  });

  testWidgets('tapping reports the position the rail drew', (tester) async {
    final tapped = <int>[];
    await tester.pumpWidget(
      harness(
        names: const ['add', 'alpine', 'alpine(1)'],
        index: 1,
        onTap: tapped.add,
      ),
    );

    await tester.tap(find.text('alpine(1)'));
    expect(tapped, [2], reason: 'index 0 is the leading page, not a session');
  });

  testWidgets('closing reports the same positions as tapping', (tester) async {
    final closed = <int>[];
    await tester.pumpWidget(
      harness(
        names: const ['add', 'alpine', 'alpine(1)'],
        index: 1,
        onClose: closed.add,
      ),
    );

    await tester.tap(find.byType(IconButton).last);
    expect(closed, [2]);
  });

  testWidgets('only a running entry can be closed', (tester) async {
    await tester.pumpWidget(
      harness(names: const ['add', 'alpine'], index: 1),
    );

    expect(
      find.descendant(
        of: find.widgetWithText(SideBarTile, 'prod-1'),
        matching: find.byType(IconButton),
      ),
      findsNothing,
    );
    expect(
      find.descendant(
        of: find.widgetWithText(SideBarTile, 'alpine'),
        matching: find.byType(IconButton),
      ),
      findsOneWidget,
    );
  });

  testWidgets('no actions means no room spent on an empty row', (
    tester,
  ) async {
    await tester.pumpWidget(harness(names: const ['add']));
    final without = tester.getTopLeft(find.text('prod-1')).dy;

    await tester.pumpWidget(
      harness(
        names: const ['add'],
        actions: [IconButton(icon: const Icon(Icons.add), onPressed: () {})],
      ),
    );
    expect(tester.getTopLeft(find.text('prod-1')).dy, greaterThan(without));
  });

  testWidgets('a heading longer than the rail elides instead of running past', (
    tester,
  ) async {
    // Its callers pass a single word, so this never showed up — until a rail
    // used a real sentence for a heading and the row ran 52px past a column
    // 220 wide. The same thing happens to "RUNNING" in a language that spells
    // it longer, in a rail dragged to its narrowest.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 160,
            child: SideBarSection('a heading nobody would fit in a rail'),
          ),
        ),
      ),
    );

    // No assertion of its own: an overflow is an exception, so reaching here
    // is the result. What is checked is that the heading is still drawn —
    // eliding must not mean eliding to nothing.
    expect(find.byType(SideBarSection), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a trailing control does not make the row taller', (
    tester,
  ) async {
    // A Material control sizes itself to a 48pt tap target whatever its own
    // constraints say, and `_CloseButton` already asked for 26 and got 40. So
    // a row with a close button measured 58pt against 35pt without one, and
    // the name of a target grew by two thirds the moment a session opened
    // behind it and moved it into the running section.
    await tester.pumpWidget(
      harness(names: const ['add', 'alpine'], index: 1),
    );

    final running = tester
        .getSize(find.widgetWithText(SideBarTile, 'alpine'))
        .height;
    final target = tester
        .getSize(find.widgetWithText(SideBarTile, 'prod-1'))
        .height;

    // Not equality: the button is a point taller than the text beside it, and
    // pinning the exact figure would fail on a font metric change that costs
    // the rail nothing.
    expect(running - target, lessThanOrEqualTo(2.0));
  });
}
