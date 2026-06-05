import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all highlight themes resolve to flutter_highlight theme maps', () {
    for (final theme in HighlightTheme.values) {
      expect(theme.theme, isNotNull, reason: theme.name);
    }
  });

  test('parses flutter_highlight theme map keys', () {
    expect(
      HighlightTheme.fromThemeMapKey('a11y-light'),
      HighlightTheme.a11y_light,
    );
    expect(HighlightTheme.fromThemeMapKey('monokai'), HighlightTheme.monokai);
    expect(
      HighlightTheme.fromThemeMapKey('default'),
      HighlightTheme.defaultTheme,
    );
    expect(
      HighlightTheme.fromThemeMapKey('kimbie.dark'),
      HighlightTheme.kimbie_dark,
    );
    expect(
      HighlightTheme.fromThemeMapKey('qtcreator_dark'),
      HighlightTheme.qtcreator_dark,
    );
    expect(HighlightTheme.fromThemeMapKey('unknown-theme'), isNull);
    expect(HighlightTheme.fromThemeMapKey(null), isNull);
  });
}
