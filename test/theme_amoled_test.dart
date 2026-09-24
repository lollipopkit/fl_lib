import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('toAmoled', () {
    test('component typography survives the background change', () {
      const style = TextStyle(
        fontFamily: 'Test UI',
        fontFamilyFallback: ['Test CJK'],
        fontSize: 17,
        inherit: false,
      );
      const labels = WidgetStatePropertyAll<TextStyle>(style);
      final theme = ThemeData(
        appBarTheme: const AppBarTheme(titleTextStyle: style, toolbarTextStyle: style),
        dialogTheme: const DialogThemeData(titleTextStyle: style, contentTextStyle: style),
        navigationBarTheme: const NavigationBarThemeData(labelTextStyle: labels),
        navigationRailTheme: const NavigationRailThemeData(
          selectedLabelTextStyle: style, unselectedLabelTextStyle: style,
        ),
        popupMenuTheme: const PopupMenuThemeData(textStyle: style),
      ).toAmoled;

      expect(theme.appBarTheme.titleTextStyle, style);
      expect(theme.appBarTheme.toolbarTextStyle, style);
      expect(theme.dialogTheme.titleTextStyle, style);
      expect(theme.dialogTheme.contentTextStyle, style);
      expect(theme.navigationBarTheme.labelTextStyle, labels);
      expect(theme.navigationRailTheme.selectedLabelTextStyle, style);
      expect(theme.navigationRailTheme.unselectedLabelTextStyle, style);
      expect(theme.popupMenuTheme.textStyle, style);
      expect(theme.appBarTheme.backgroundColor, Colors.black);
    });

    test('a sheet is opaque, so the page it was raised over does not show', () {
      final theme = ThemeData(brightness: Brightness.dark).toAmoled;

      expect(theme.bottomSheetTheme.backgroundColor?.a, 1.0);
    });

    test('a sheet keeps what the theme already said about it', () {
      const shape = RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
      );
      final theme = ThemeData(
        brightness: Brightness.dark,
        bottomSheetTheme: const BottomSheetThemeData(
          shape: shape,
          showDragHandle: true,
        ),
      ).toAmoled;

      expect(theme.bottomSheetTheme.shape, shape);
      expect(theme.bottomSheetTheme.showDragHandle, isTrue);
    });
  });
}
