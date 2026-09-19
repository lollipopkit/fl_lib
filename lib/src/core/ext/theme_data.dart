import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';

extension ThemeDataX on ThemeData {
  static const bgInDark = Color.fromARGB(64, 15, 15, 15);

  ThemeData get toAmoled => copyWith(
        scaffoldBackgroundColor: Colors.black,
        drawerTheme: const DrawerThemeData(backgroundColor: Colors.black),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.black, scrolledUnderElevation: 0),
        dialogTheme: const DialogThemeData(backgroundColor: Colors.black),
        bottomSheetTheme: const BottomSheetThemeData(backgroundColor: bgInDark),
        // Copied onto what the theme already carries, not replaced with. These
        // two slots are the ones an app configures for shape — a tile's
        // padding and height, a card's radius — and a fresh `…ThemeData`
        // holding one colour silently drops all of it, in the AMOLED theme
        // only, which is not where anyone looks for a metric that moved.
        listTileTheme: listTileTheme.copyWith(tileColor: bgInDark),
        cardTheme: cardTheme.copyWith(color: bgInDark),
        navigationBarTheme:
            const NavigationBarThemeData(backgroundColor: Colors.black),
        popupMenuTheme: const PopupMenuThemeData(color: Colors.black),
        navigationRailTheme: const NavigationRailThemeData(
          backgroundColor: Colors.black,
          selectedIconTheme: IconThemeData(color: Colors.white),
          unselectedIconTheme: IconThemeData(color: Colors.white70),
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
