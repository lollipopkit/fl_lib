import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the collapse handle both folds and resizes', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    bool? collapsed;
    var paneCollapsed = false;
    double? savedWidth;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AdaptivePanes.surface(
              listBuilder: (_, _) => const ColoredBox(color: Colors.grey),
              surfaceBuilder: (_, _) => const ColoredBox(color: Colors.white),
              collapsed: paneCollapsed,
              onCollapsedChanged: (value) {
                collapsed = value;
                setState(() => paneCollapsed = value);
              },
              onListWidthChanged: (value) => savedWidth = value,
              collapseTooltip: 'Hide list',
              expandTooltip: 'Show list',
            ),
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

    // It covers the middle of the seam, which is where a pointer aims for the
    // line — so a drag landing on it has to resize rather than be swallowed.
    await tester.drag(handle, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(savedWidth, isNotNull);
    expect(
      savedWidth,
      greaterThan(0),
      reason: 'the drag reached onListWidthChanged',
    );
    // A resize is not a fold: the arena gave the pointer to the drag, so the
    // tap callback must not also have fired.
    expect(collapsed, isNull);

    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(collapsed, isTrue);
    expect(find.bySemanticsLabel('Hide list'), findsNothing);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Show list')),
      matchesSemantics(label: 'Show list', isButton: true, hasTapAction: true),
    );
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

  /// `_kPullToUnfold` is documented as "how far *the grip* has to be dragged
  /// away from the edge to unfold" — which it could not be, while the grip
  /// swallowed every drag that landed on it and only the line could do this.
  testWidgets('dragging the folded grip away from the edge unfolds it', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    bool? collapsed;
    var paneCollapsed = true;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => AdaptivePanes.surface(
              listBuilder: (_, _) => const ColoredBox(color: Colors.grey),
              surfaceBuilder: (_, _) => const ColoredBox(color: Colors.white),
              collapsed: paneCollapsed,
              onCollapsedChanged: (value) {
                collapsed = value;
                setState(() => paneCollapsed = value);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Only that the drag reaches `_onSeamDrag` at all, which is what the grip
    // used to swallow. Well past `_kPullToUnfold` on purpose: `drag` spends
    // the touch slop before any of the offset is delivered, and a short one
    // is a tap rather than a drag — which would unfold it down the other
    // path and prove nothing.
    await tester.drag(find.byType(PaneCollapseHandle), const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(collapsed, isFalse);
  });
}
