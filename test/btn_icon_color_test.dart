import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

/// [Btn.icon] is this library's `IconButton`, and is drawn in the colour one
/// is.
///
/// It took whatever the ambient `IconTheme` said instead, which under
/// `ThemeData`'s defaults is pure white on dark and near-black on light. Every
/// other control in the bars it sits in — the switcher's glyph, a segmented
/// control's resting labels — asks the scheme for `onSurfaceVariant`, so a row
/// of these was the brightest thing in a bar that is not about them.
void main() {
  Future<void> pump(WidgetTester tester, Widget icon, ThemeData theme) =>
      tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: Center(child: Btn.icon(icon: icon, onTap: () {})),
          ),
        ),
      );

  /// The colour [icon] is actually painted in, which is what is in the text
  /// it is drawn as.
  Color? painted(WidgetTester tester, IconData icon) {
    final text = tester.widget<RichText>(
      find.descendant(
        of: find.byIcon(icon),
        matching: find.byType(RichText),
      ),
    );
    return text.text.style?.color;
  }

  for (final brightness in Brightness.values) {
    testWidgets('an icon with no colour of its own is the scheme\'s '
        '(${brightness.name})', (tester) async {
      final theme = ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.pink,
          brightness: brightness,
        ),
      );
      await pump(tester, const Icon(Icons.search), theme);

      expect(painted(tester, Icons.search), theme.colorScheme.onSurfaceVariant);
    });
  }

  testWidgets('and one that was given a colour keeps it', (tester) async {
    // A toggle drawn in the primary while it is on, for one.
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: Colors.pink,
        brightness: Brightness.dark,
      ),
    );
    await pump(
      tester,
      Icon(Icons.public, color: theme.colorScheme.primary),
      theme,
    );

    expect(painted(tester, Icons.public), theme.colorScheme.primary);
  });

  testWidgets('an icon under a badge is drawn as a bare one is', (
    tester,
  ) async {
    // What the icon slot is for besides a glyph: a count on its corner.
    final theme = ThemeData(
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.pink),
    );
    await pump(
      tester,
      Badge.count(count: 2, child: const Icon(Icons.cable)),
      theme,
    );

    expect(find.text('2'), findsOneWidget);
    expect(painted(tester, Icons.cable), theme.colorScheme.onSurfaceVariant);
  });
}
