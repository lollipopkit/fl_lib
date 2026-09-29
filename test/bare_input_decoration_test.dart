import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  // A theme whose form fields are boxed, as a store theme's are.
  const theme = InputDecorationTheme(
    filled: true,
    contentPadding: EdgeInsets.all(12),
    enabledBorder: OutlineInputBorder(),
    focusedBorder: OutlineInputBorder(),
  );

  test('a theme does not box a bare field', () {
    final decoration = bareInputDecoration(hintText: 'x').applyDefaults(theme);

    expect(decoration.filled, isFalse);
    expect(decoration.enabledBorder, InputBorder.none);
    expect(decoration.focusedBorder, InputBorder.none);
  });

  test('collapsed takes no padding from the theme', () {
    expect(
      bareInputDecoration(isCollapsed: true).applyDefaults(theme).contentPadding,
      EdgeInsets.zero,
    );
    expect(
      bareInputDecoration(
        isCollapsed: true,
        contentPadding: const EdgeInsets.all(2),
      ).applyDefaults(theme).contentPadding,
      const EdgeInsets.all(2),
    );
    expect(
      bareInputDecoration().applyDefaults(theme).contentPadding,
      const EdgeInsets.all(12),
    );
  });
}
