import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the collapse handle clicks while only the divider resizes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    bool? collapsed;
    double? savedWidth;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptivePanes.surface(
            listBuilder: (_, _) => const ColoredBox(color: Colors.grey),
            surfaceBuilder: (_, _) => const ColoredBox(color: Colors.white),
            onCollapsedChanged: (value) => collapsed = value,
            onListWidthChanged: (value) => savedWidth = value,
            collapseTooltip: 'Hide list',
            expandTooltip: 'Show list',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final handle = find.byType(PaneCollapseHandle);
    final pointerRegion = find.descendant(
      of: handle,
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is MouseRegion && widget.cursor == SystemMouseCursors.click,
      ),
    );
    expect(
      tester.widget<MouseRegion>(pointerRegion).cursor,
      SystemMouseCursors.click,
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Hide list')),
      matchesSemantics(label: 'Hide list', isButton: true, hasTapAction: true),
    );

    await tester.drag(handle, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(savedWidth, isNull);
    expect(collapsed, isNull);

    await tester.tap(handle);
    expect(collapsed, isTrue);
  });

  testWidgets('a missing tooltip falls back to the localized action', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: PaneCollapseHandle(collapsed: true, onTap: () {})),
    );

    expect(
      tester.getSemantics(find.bySemanticsLabel('Expand')),
      matchesSemantics(label: 'Expand', isButton: true, hasTapAction: true),
    );
  });
}
