import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';

/// Font family fallback list for better Chinese text display.
const _fontFamilyFallback = [
  'system-font',
  'sans-serif',
  'Microsoft YaHei',
];

/// Extension on [TextTheme] to provide Chinese font display fixes.
extension ChineseTextTheme on TextTheme {
  /// The same slots, each with the Chinese families extended onto its fallback
  /// list.
  ///
  /// Extended rather than applied over the top, which is what
  /// [TextTheme.apply] does: a theme that carries fallbacks of its own would
  /// lose them, and those are the families the host app asked for. A family
  /// already on the list is not added twice.
  TextTheme get withChineseFontFallback => copyWith(
        displayLarge: displayLarge?._withChineseFontFallback(),
        displayMedium: displayMedium?._withChineseFontFallback(),
        displaySmall: displaySmall?._withChineseFontFallback(),
        headlineLarge: headlineLarge?._withChineseFontFallback(),
        headlineMedium: headlineMedium?._withChineseFontFallback(),
        headlineSmall: headlineSmall?._withChineseFontFallback(),
        titleLarge: titleLarge?._withChineseFontFallback(),
        titleMedium: titleMedium?._withChineseFontFallback(),
        titleSmall: titleSmall?._withChineseFontFallback(),
        bodyLarge: bodyLarge?._withChineseFontFallback(),
        bodyMedium: bodyMedium?._withChineseFontFallback(),
        bodySmall: bodySmall?._withChineseFontFallback(),
        labelLarge: labelLarge?._withChineseFontFallback(),
        labelMedium: labelMedium?._withChineseFontFallback(),
        labelSmall: labelSmall?._withChineseFontFallback(),
      );
}

extension on TextStyle {
  TextStyle _withChineseFontFallback() {
    final existing = fontFamilyFallback ?? const <String>[];
    return copyWith(
      fontFamilyFallback: [
        ...existing,
        ..._fontFamilyFallback.where((f) => !existing.contains(f)),
      ],
    );
  }
}

/// Extension on [ThemeData] to provide Chinese font display fixes on Windows.
extension ChineseThemeData on ThemeData {
  /// Fixes Windows font rendering for Chinese locales.
  ///
  /// Returns the same theme data if not on Windows platform.
  /// For Chinese locales on Windows, applies font fallbacks to improve text rendering.
  ///
  /// A fallback list on its own does not depend on the brightness: the
  /// families are the same either way, and the slots keep whatever they
  /// already carried. `primaryTextTheme` is included because the bar and the
  /// dialog title take their font from it, and it is built from the primary
  /// colour's brightness rather than the theme's.
  ThemeData get fixWindowsFont {
    if (!isWindows) return this;

    return switch (Platform.localeName) {
      final locale when locale.startsWith('zh') => copyWith(
            textTheme: textTheme.withChineseFontFallback,
            primaryTextTheme: primaryTextTheme.withChineseFontFallback,
          ),
      _ => this,
    };
  }
}
