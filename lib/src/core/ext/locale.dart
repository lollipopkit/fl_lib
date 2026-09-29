import 'package:material_ui/material_ui.dart';
import 'package:locale_names/locale_names.dart';

/// Extensions on [Locale] and related helpers.
extension LocaleX on Locale {
  /// Returns the standardized locale code, for example `en` or `en_US`.
  String get code {
    if (countryCode == null) {
      return languageCode;
    }
    return '${languageCode}_$countryCode';
  }

  /// Returns the native display name of this locale, e.g. `English (en_US)`.
  String get nativeName => '$nativeDisplayLanguage ($code)';
}

/// Context-based helpers for locale and display.
extension BuildContextLocaleX on BuildContext {
  /// Returns the current [Locale] for this context.
  Locale get locale => Localizations.localeOf(this);

  /// Returns the native display name for the current context locale.
  String get localeNativeName => locale.nativeName;
}

/// Converts a locale code string to [Locale].
extension String2Locale on String {
  /// Parses a locale code like `en` or `en_US` to [Locale].
  /// Returns null for empty strings.
  Locale? get toLocale {
    // Issue #151
    if (isEmpty) return null;

    final parts = split('_');
    if (parts.length == 1) {
      return Locale(parts[0]);
    }
    return Locale(parts[0], parts[1]);
  }
}
