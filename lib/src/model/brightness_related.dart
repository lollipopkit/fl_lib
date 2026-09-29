import 'package:material_ui/material_ui.dart';

/// {@template brightness_related}
/// A class that holds two values, one for light mode and one for dark mode.
/// {@endtemplate}
class BrightnessRelated<T> {
  /// The value for light mode.
  final T light;

  /// The value for dark mode.
  final T dark;

  /// {@macro brightness_related}
  const BrightnessRelated({required this.light, required this.dark});

  /// Returns the value based on the current brightness.
  T fromBrightness(Brightness brightness) {
    return brightness == Brightness.dark ? dark : light;
  }

  /// Returns the value based on the current brightness.
  T fromBool(bool isDark) {
    return isDark ? dark : light;
  }

  /// Resolves the value based on the current brightness from the given [BuildContext].
  T resolve(BuildContext context) {
    return fromBrightness(MediaQuery.platformBrightnessOf(context));
  }
}

/// {@template dyn_color}
/// A dynamic color class that holds two colors, one for light mode and one for dark mode.
/// {@endtemplate}
final class DynColor extends BrightnessRelated<Color> {
  /// {@macro dyn_color}
  const DynColor({required super.light, required super.dark});
}
