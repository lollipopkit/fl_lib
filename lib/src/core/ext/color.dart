import 'package:material_ui/material_ui.dart';

/// Color related extensions and helpers.
///
/// This file adds utilities to convert between ARGB values and hex strings,
/// estimate brightness, lighten/darken colors, and build Material theming
/// helpers like `WidgetStateProperty<Color?>` and `MaterialColor`.

/// A set of interactive widget states used to resolve [materialStateColor].
const _interactiveStates = <WidgetState>{
  WidgetState.pressed,
  WidgetState.hovered,
  WidgetState.focused,
  WidgetState.selected,
};

/// Extensions on [Color] with common conversions and Material helpers.
extension ColorX on Color {
  /// {@template color_argb_255}
  /// Get the alpha, red, green, blue channels in 0-255.
  /// {@endtemplate}
  int get alpha255 => (a * 255).round();

  /// {macro color_argb_255}
  int get red255 => (r * 255).round();

  /// {macro color_argb_255}
  int get green255 => (g * 255).round();

  /// {macro color_argb_255}
  int get blue255 => (b * 255).round();

  /// Get the value of the color.
  ///
  /// 0xffffffff => 4294967295
  int get value255 {
    final a = alpha255 << 24;
    final r = red255 << 16;
    final g = green255 << 8;
    final b = blue255;
    return a | r | g | b;
  }

  /// Returns the color hex like `#FF112233`.
  String get toHex {
    final alphaStr = alpha255.toRadixString(16).padLeft(2, '0');
    final redStr = red255.toRadixString(16).padLeft(2, '0');
    final greenStr = green255.toRadixString(16).padLeft(2, '0');
    final blueStr = blue255.toRadixString(16).padLeft(2, '0');
    return '#$alphaStr$redStr$greenStr$blueStr';
  }

  /// Returns the color hex like `#112233`.
  String get toHexRGB {
    final redStr = red255.toRadixString(16).padLeft(2, '0');
    final greenStr = green255.toRadixString(16).padLeft(2, '0');
    final blueStr = blue255.toRadixString(16).padLeft(2, '0');
    return '#$redStr$greenStr$blueStr';
  }

  /// Whether this color is bright.
  bool get isBrightColor => estimateBrightness == Brightness.light;

  /// Plus the [val] to each channel.
  Color operator +(int val) {
    final r = (red255 + val).clamp(0, 255);
    final g = (green255 + val).clamp(0, 255);
    final b = (blue255 + val).clamp(0, 255);
    return Color.fromARGB(alpha255, r, g, b);
  }

  /// Subtract [val] from each channel.
  Color operator -(int val) {
    final r = (red255 - val).clamp(0, 255);
    final g = (green255 - val).clamp(0, 255);
    final b = (blue255 - val).clamp(0, 255);
    return Color.fromARGB(alpha255, r, g, b);
  }

  /// Get the brightness of the color.
  Brightness get estimateBrightness => ThemeData.estimateBrightnessForColor(this);

  /// Get the [WidgetStateProperty] of the color.
  WidgetStateProperty<Color?> get materialStateColor {
    return WidgetStateProperty.resolveWith((states) {
      if (states.any(_interactiveStates.contains)) {
        return this;
      }
      return null;
    });
  }

  /// Get the [MaterialColor] of the color.
  MaterialColor get materialColor => MaterialColor(
        value255,
        {
          50: withValues(alpha: 0.05),
          100: withValues(alpha: 0.1),
          200: withValues(alpha: 0.2),
          300: withValues(alpha: 0.3),
          400: withValues(alpha: 0.4),
          500: withValues(alpha: 0.5),
          600: withValues(alpha: 0.6),
          700: withValues(alpha: 0.7),
          800: withValues(alpha: 0.8),
          900: withValues(alpha: 0.9),
        },
      );
}
