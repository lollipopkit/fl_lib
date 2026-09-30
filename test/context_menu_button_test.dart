import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  late List<String> ran;

  setUp(() => ran = []);

  Future<void> open(WidgetTester tester, List<ContextMenuAction> actions) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ContextMenuButton(
              actions: () => actions,
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets('a choice ticks the one in effect, and runs after closing', (
    tester,
  ) async {
    await open(tester, [
      ContextMenuAction(text: 'a', checked: true, onTap: () => ran.add('a')),
      ContextMenuAction(text: 'b', checked: false, onTap: () => ran.add('b')),
    ]);
    expect(find.byIcon(Icons.check), findsOneWidget);

    await tester.tap(find.text('b'));
    await tester.pumpAndSettle();
    expect(ran, ['b']);
    expect(find.text('a'), findsNothing);
  });

  testWidgets('a disabled entry refuses the tap and stays open', (
    tester,
  ) async {
    await open(tester, [
      ContextMenuAction(text: 'off', enabled: false, onTap: () => ran.add('off')),
    ]);

    await tester.tap(find.text('off'));
    await tester.pumpAndSettle();
    expect(ran, isEmpty);
    expect(find.text('off'), findsOneWidget);
  });

  testWidgets('the trailing button runs its own action, not the row\'s', (
    tester,
  ) async {
    const key = ValueKey('close');
    await open(tester, [
      ContextMenuAction(
        text: 'pane',
        onTap: () => ran.add('select'),
        trailing: ContextMenuTrailing(
          key: key,
          icon: Icons.close,
          tooltip: 'close',
          onTap: () => ran.add('close'),
        ),
      ),
    ]);

    await tester.tap(find.byKey(key));
    await tester.pumpAndSettle();
    expect(ran, ['close']);
    expect(find.text('pane'), findsNothing);
  });

  testWidgets('a disabled button does not open', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ContextMenuButton(
            enabled: false,
            actions: () => [ContextMenuAction(text: 'x', onTap: () {})],
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('x'), findsNothing);
  });
}
