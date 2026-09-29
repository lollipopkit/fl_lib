import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

abstract final class LocaleUtil {
  static Locale? resolve(
      List<Locale>? locales, Iterable<Locale> supportedLocales) {
    const defaultLocale = Locale('en');
    if (locales == null || locales.isEmpty) return defaultLocale;
    final match = locales.firstWhereOrNull(supportedLocales.contains);
    if (match != null) return match;
    return defaultLocale;
  }
}
