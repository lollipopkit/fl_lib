import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// A choice in a form is a row of it, as an [Input] is, and opens the app's
/// own menu. Material's dropdown took `enabledBorder` from a theme that styles
/// fields and drew an outline with a notched label among inputs that draw
/// none, and opened a list of its own.
void main() {
  Widget app(Widget child) => MaterialApp(
    theme: ThemeData(
      inputDecorationTheme: const InputDecorationTheme(
        enabledBorder: OutlineInputBorder(),
        focusedBorder: OutlineInputBorder(),
        contentPadding: EdgeInsets.all(24),
      ),
    ),
    home: Scaffold(
      body: Center(child: SizedBox(width: 300, child: child)),
    ),
  );

  Widget dropdown({
    Key? key,
    int value = 1,
    ValueChanged<int>? onChanged,
  }) => InputDropdown<int>(
    key: key,
    label: 'Protocol',
    value: value,
    items: const [1, 2],
    itemText: (v) => 'option $v',
    onChanged: onChanged,
  );

  testWidgets('draws no border of its own, whatever the theme', (tester) async {
    await tester.pumpWidget(app(dropdown(onChanged: (_) {})));
    final deco = tester
        .widget<InputDecorator>(find.byType(InputDecorator))
        .decoration;
    expect(deco.enabledBorder, InputBorder.none);
    expect(deco.focusedBorder, InputBorder.none);
    expect(deco.filled, isFalse);
    expect(find.byType(CardX), findsOneWidget);
  });

  testWidgets('is as tall as an Input beside it', (tester) async {
    await tester.pumpWidget(
      app(
        Column(
          children: [
            const Input(label: 'Name', key: Key('input')),
            dropdown(key: const Key('dropdown'), onChanged: (_) {}),
          ],
        ),
      ),
    );
    final input = tester.getSize(find.byKey(const Key('input')));
    final choice = tester.getSize(find.byKey(const Key('dropdown')));
    expect((choice.height - input.height).abs(), lessThan(0.5));
  });

  testWidgets('chooses from the context menu', (tester) async {
    int? chosen;
    await tester.pumpWidget(app(dropdown(onChanged: (v) => chosen = v)));
    await tester.tap(find.text('option 1'));
    await tester.pumpAndSettle();
    expect(find.byType(ContextMenuRow), findsNWidgets(2));
    await tester.tap(find.widgetWithText(ContextMenuRow, 'option 2'));
    await tester.pumpAndSettle();
    expect(chosen, 2);
    expect(find.byType(ContextMenuRow), findsNothing);
  });

  testWidgets('without onChanged, opens nothing', (tester) async {
    await tester.pumpWidget(app(dropdown()));
    await tester.tap(find.text('option 1'));
    await tester.pumpAndSettle();
    expect(find.byType(ContextMenuRow), findsNothing);
  });
}
