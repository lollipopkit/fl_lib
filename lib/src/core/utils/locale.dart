import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

abstract final class LocaleUtil {
  static const _traditionalRegions = {'TW', 'HK', 'MO'};

  /// The first of [locales] that [match]es something in [supportedLocales],
  /// English for none.
  static Locale? resolve(
      List<Locale>? locales, Iterable<Locale> supportedLocales) {
    const defaultLocale = Locale('en');
    for (final locale in locales ?? const <Locale>[]) {
      final match = LocaleUtil.match(locale, supportedLocales);
      if (match != null) return match;
    }
    return defaultLocale;
  }

  /// The supported locale closest to [locale]; null when none shares its
  /// language.
  ///
  /// Not equality: a system reports `zh_Hans_SG` or `en_US`, and apps list
  /// `zh` and `en`. Chinese is told apart by script, which a tag may give only
  /// as its region: `Hant`, or `TW`/`HK`/`MO` without a script, is
  /// Traditional, and a supported locale is Traditional by the same rule.
  static Locale? match(Locale locale, Iterable<Locale> supportedLocales) {
    final lang = locale.languageCode.toLowerCase();
    final candidates =
        supportedLocales.where((s) => s.languageCode.toLowerCase() == lang);
    if (candidates.isEmpty) return null;
    final region = locale.countryCode?.toUpperCase();
    if (lang == 'zh') {
      final traditional = _isTraditional(locale);
      final sameScript =
          candidates.where((s) => _isTraditional(s) == traditional);
      if (sameScript.isEmpty) return candidates.first;
      return sameScript.firstWhereOrNull(
              (s) => s.countryCode?.toUpperCase() == region) ??
          sameScript.first;
    }
    return candidates.firstWhereOrNull(
            (s) => region != null && s.countryCode?.toUpperCase() == region) ??
        candidates.firstWhereOrNull((s) => s.countryCode == null) ??
        candidates.first;
  }

  static bool _isTraditional(Locale l) => switch (l.scriptCode) {
        'Hant' => true,
        'Hans' => false,
        _ => _traditionalRegions.contains(l.countryCode?.toUpperCase()),
      };
}
