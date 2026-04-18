import 'package:fl_lib/src/view/widget/adaptive_list.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('adapts columns based on available width', (tester) async {
    final items = List<int>.generate(6, (index) => index);

    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SizedBox(
            width: 1200,
            child: AdaptiveReorderableList.builder(
              items: items,
              itemKey: (item) => item,
              columnWidth: 200,
              onReorder: (oldIndex, newIndex) {},
              itemBuilder: (context, item, index, animation) => FadeTransition(
                key: ValueKey('item-$item'),
                opacity: animation,
                child: SizedBox(
                  height: 40,
                  child: Center(child: Text('Item $item')),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final first = tester.getTopLeft(find.byKey(const ValueKey('item-0')));
    final second = tester.getTopLeft(find.byKey(const ValueKey('item-1')));

    expect(first.dy, equals(second.dy));
    expect(second.dx, greaterThan(first.dx));
  });

  testWidgets('separated constructor inserts separators for non-last items', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: SizedBox(
            width: 280,
            child: AdaptiveReorderableList.separated(
              items: const [1, 2, 3],
              itemKey: (item) => item,
              columnWidth: 300,
              onReorder: (oldIndex, newIndex) {},
              separatorBuilder: (context, index) =>
                  Divider(key: ValueKey('sep-$index')),
              itemBuilder: (context, item, index, animation) => FadeTransition(
                key: ValueKey('item-$item'),
                opacity: animation,
                child: ListTile(title: Text('Item $item')),
              ),
            ),
          ),
        ),
      ),
    );

    expect(find.byType(Divider), findsNWidgets(2));
  });

  testWidgets('reorders items and reports new ordering via callbacks', (
    tester,
  ) async {
    final items = <int>[1, 2, 3];
    final recordedOrders = <List<int>>[];

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return Material(
              child: SizedBox(
                width: 280,
                child: AdaptiveReorderableList.builder(
                  items: List<int>.from(items),
                  itemKey: (item) => item,
                  columnWidth: 320,
                  onReorder: (oldIndex, newIndex) {
                    setState(() {
                      final value = items.removeAt(oldIndex);
                      items.insert(newIndex, value);
                    });
                  },
                  onReorderComplete: (ordered) =>
                      recordedOrders.add(List<int>.from(ordered)),
                  itemBuilder: (context, item, index, animation) => ListTile(
                    key: ValueKey('tile-$item'),
                    title: FadeTransition(
                      opacity: animation,
                      child: Text('Item $item'),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );

    final firstItem = find.byKey(const ValueKey('tile-1'));
    final thirdItem = find.byKey(const ValueKey('tile-3'));

    final gesture = await tester.startGesture(tester.getCenter(firstItem));
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
    await gesture.moveTo(tester.getCenter(thirdItem));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(items, equals(<int>[2, 3, 1]));
    expect(recordedOrders, isNotEmpty);
    expect(recordedOrders.last, equals(<int>[2, 3, 1]));
  });

  testWidgets('animates inserted and removed items to their final visible state', (
    tester,
  ) async {
    final items = <int>[1, 2];

    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) {
            return Material(
              child: Column(
                children: [
                  Row(
                    children: [
                      TextButton(
                        onPressed: () {
                          setState(() {
                            items.add(3);
                          });
                        },
                        child: const Text('add'),
                      ),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            items.remove(1);
                          });
                        },
                        child: const Text('remove'),
                      ),
                    ],
                  ),
                  Expanded(
                    child: SizedBox(
                      width: 280,
                      child: AdaptiveReorderableList.builder(
                        items: List<int>.from(items),
                        itemKey: (item) => item,
                        columnWidth: 320,
                        onReorder: (oldIndex, newIndex) {},
                        itemBuilder: (context, item, index, animation) =>
                            ListTile(
                              key: ValueKey('anim-tile-$item'),
                              title: FadeTransition(
                                opacity: animation,
                                child: Text('Animated Item $item'),
                              ),
                            ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );

    expect(find.text('Animated Item 3'), findsNothing);

    await tester.tap(find.text('add'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Animated Item 3'), findsOneWidget);

    await tester.tap(find.text('remove'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Animated Item 1'), findsNothing);
    expect(find.text('Animated Item 2'), findsOneWidget);
    expect(find.text('Animated Item 3'), findsOneWidget);
  });
}
