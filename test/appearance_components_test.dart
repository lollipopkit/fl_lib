import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shared components read their shapes from the theme', (
    tester,
  ) async {
    final theme = ThemeData(
      cardTheme: CardThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ButtonStyle(
          shape: WidgetStatePropertyAll(
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
          ),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: const Scaffold(
          body: Column(
            children: [
              CardX(child: Text('Card')),
              SideBarTile(title: 'Tile'),
              Btn.row(text: 'Button', icon: Icon(Icons.add)),
            ],
          ),
        ),
      ),
    );

    final card = tester.widget<Card>(find.byType(Card));
    expect(
      (card.shape! as RoundedRectangleBorder).borderRadius,
      BorderRadius.circular(22),
    );
    final tileInk = tester.widget<InkWell>(
      find
          .descendant(
            of: find.byType(SideBarTile),
            matching: find.byType(InkWell),
          )
          .first,
    );
    expect(tileInk.borderRadius, BorderRadius.circular(16));
    final buttonInk = tester.widget<InkWell>(
      find
          .descendant(of: find.byType(Btn), matching: find.byType(InkWell))
          .first,
    );
    expect(buttonInk.borderRadius, BorderRadius.circular(11));
  });
  testWidgets('nearest component themes override ThemeData shapes', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          cardTheme: const CardThemeData(shape: RoundedRectangleBorder()),
          listTileTheme: const ListTileThemeData(
            shape: RoundedRectangleBorder(),
          ),
          elevatedButtonTheme: const ElevatedButtonThemeData(
            style: ButtonStyle(
              shape: WidgetStatePropertyAll(RoundedRectangleBorder()),
            ),
          ),
        ),
        home: Scaffold(
          body: CardTheme(
            data: CardThemeData(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(22),
              ),
            ),
            child: ListTileTheme(
              data: ListTileThemeData(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: ElevatedButtonTheme(
                data: ElevatedButtonThemeData(
                  style: ButtonStyle(
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                      ),
                    ),
                  ),
                ),
                child: const Column(
                  children: [
                    CardX(child: Text('Card')),
                    SideBarTile(title: 'Tile'),
                    Btn.tile(text: 'Card button', icon: Icon(Icons.add)),
                    Btn.row(text: 'Row button', icon: Icon(Icons.add)),
                    Btn.elevated(text: 'Elevated button'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(
      (tester.widget<Card>(find.byType(Card)).shape! as RoundedRectangleBorder)
          .borderRadius,
      BorderRadius.circular(22),
    );
    for (final (finder, radius) in [
      (find.byType(SideBarTile), 16.0),
      (find.widgetWithText(Btn, 'Card button'), 22.0),
      (find.widgetWithText(Btn, 'Row button'), 11.0),
    ]) {
      final ink = tester.widget<InkWell>(
        find.descendant(of: finder, matching: find.byType(InkWell)).first,
      );
      expect(ink.borderRadius, BorderRadius.circular(radius));
    }
    final button = tester.widget<ElevatedButton>(find.byType(ElevatedButton));
    expect(
      (button.style!.shape!.resolve({})! as RoundedRectangleBorder)
          .borderRadius,
      BorderRadius.circular(11),
    );
  });

  testWidgets('elevated shapes resolve each state and explicit radius wins', (
    tester,
  ) async {
    final themedShape = WidgetStateProperty.resolveWith<OutlinedBorder>((
      states,
    ) {
      final radius = states.contains(WidgetState.disabled)
          ? 3.0
          : states.contains(WidgetState.pressed)
          ? 7.0
          : states.contains(WidgetState.hovered)
          ? 15.0
          : 11.0;
      return RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(radius),
      );
    });
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ElevatedButtonTheme(
            data: ElevatedButtonThemeData(
              style: ButtonStyle(shape: themedShape),
            ),
            child: const Column(
              children: [
                Btn.elevated(text: 'Themed'),
                Btn.elevated(
                  text: 'Explicit',
                  borderRadius: BorderRadius.all(Radius.circular(24)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final buttons = tester
        .widgetList<ElevatedButton>(find.byType(ElevatedButton))
        .toList();
    for (final states in <Set<WidgetState>>[
      {},
      {WidgetState.hovered},
      {WidgetState.pressed},
      {WidgetState.disabled},
    ]) {
      expect(
        buttons.first.style!.shape!.resolve(states),
        themedShape.resolve(states),
      );
      expect(
        (buttons.last.style!.shape!.resolve(states)! as RoundedRectangleBorder)
            .borderRadius,
        BorderRadius.circular(24),
      );
    }
  });
}
