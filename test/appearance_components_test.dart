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
      find.descendant(
        of: find.byType(SideBarTile),
        matching: find.byType(InkWell),
      ).first,
    );
    expect(tileInk.borderRadius, BorderRadius.circular(16));
    final buttonInk = tester.widget<InkWell>(
      find.descendant(
        of: find.byType(Btn),
        matching: find.byType(InkWell),
      ).first,
    );
    expect(buttonInk.borderRadius, BorderRadius.circular(11));
  });
}
