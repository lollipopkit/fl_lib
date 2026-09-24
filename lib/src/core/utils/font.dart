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
  static final Typography _typography = Typography.material2021();

  /// Fixes Chinese font display by applying appropriate font fallbacks.
  ///
  /// - [brightness] determines whether to use light or dark typography.
  TextTheme _fixChinese(Brightness brightness) {
    final newTextTheme = switch (brightness) {
      Brightness.dark =>
        _typography.white.apply(fontFamilyFallback: _fontFamilyFallback),
      Brightness.light =>
        _typography.black.apply(fontFamilyFallback: _fontFamilyFallback),
    };
    return newTextTheme.merge(this);
  }
}

/// Extension on [ThemeData] to provide Chinese font display fixes on Windows.
extension ChineseThemeData on ThemeData {
  /// Fixes Windows font rendering for Chinese locales.
  ///
  /// Returns the same theme data if not on Windows platform.
  /// For Chinese locales on Windows, applies font fallbacks to improve text rendering.
  ThemeData get fixWindowsFont {
    if (!isWindows) return this;

    return switch (Platform.localeName) {
      final locale when locale.startsWith('zh') =>
        copyWith(
          textTheme: textTheme._fixChinese(brightness),
          primaryTextTheme: primaryTextTheme._fixChinese(brightness),
        ),
      _ => this,
    };
  }
}
