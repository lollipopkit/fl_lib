import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';

extension ThemeDataX on ThemeData {
  static const bgInDark = Color.fromARGB(64, 15, 15, 15);

  ThemeData get toAmoled => copyWith(
        scaffoldBackgroundColor: Colors.black,
        drawerTheme: drawerTheme.copyWith(backgroundColor: Colors.black),
        appBarTheme: appBarTheme.copyWith(backgroundColor: Colors.black, scrolledUnderElevation: 0),
        dialogTheme: dialogTheme.copyWith(backgroundColor: Colors.black),
        // Opaque, where a card and a tile are not: those sit on the black
        // scaffold, so [bgInDark] composites to black. A sheet sits over the
        // page it was raised from, and at a quarter alpha that page read
        // through it — through every sheet whose content is transparent and
        // shows the sheet's colour.
        bottomSheetTheme:
            bottomSheetTheme.copyWith(backgroundColor: Colors.black),
        // Copied onto what the theme already carries, not replaced with. These
        // two slots are the ones an app configures for shape — a tile's
        // padding and height, a card's radius — and a fresh `…ThemeData`
        // holding one colour silently drops all of it, in the AMOLED theme
        // only, which is not where anyone looks for a metric that moved.
        listTileTheme: listTileTheme.copyWith(tileColor: bgInDark),
        cardTheme: cardTheme.copyWith(color: bgInDark),
        navigationBarTheme:
            navigationBarTheme.copyWith(backgroundColor: Colors.black),
        popupMenuTheme: popupMenuTheme.copyWith(color: Colors.black),
        navigationRailTheme: navigationRailTheme.copyWith(
          backgroundColor: Colors.black,
          // The icons are copied onto as well, for the reason `listTileTheme`
          // and `cardTheme` are above: a fresh `IconThemeData` holding one
          // colour drops the size the app set for the rail.
          selectedIconTheme:
              (navigationRailTheme.selectedIconTheme ?? const IconThemeData())
                  .copyWith(color: Colors.white),
          unselectedIconTheme:
              (navigationRailTheme.unselectedIconTheme ?? const IconThemeData())
                  .copyWith(color: Colors.white70),
        ),
      );
}

extension ThemeModeX on ThemeMode {
  String get i18n => switch (this) {
        ThemeMode.dark => l10n.dark,
        ThemeMode.light => l10n.bright,
        ThemeMode.system => l10n.auto,
      };
}
