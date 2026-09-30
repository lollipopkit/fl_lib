import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/theme/builtin.dart';
import 'package:fl_lib/src/theme/sort.dart';
import 'package:fl_lib/src/theme/style.dart';

/// The settings the shared theme code reads and writes, on the app's own
/// settings store.
///
/// A mixin rather than a store of its own: the keys already live in the
/// app's `setting` table, where a theme was stored before this code was
/// shared, so mixing this in reads what an existing install wrote with no
/// migration. The key names are therefore fixed — changing one here loses
/// that setting on every device.
mixin ThemeSettings on SqliteStore {
  /// Seed color used to generate the color scheme.
  late final colorSeed = propertyDefault('primaryColor', 4287106639);

  /// Whether the platform's accent color is used instead of [colorSeed].
  late final useSystemPrimaryColor = propertyDefault(
    'useSystemPrimaryColor',
    false,
  );

  /// Built-in, installed, or custom image theme currently selected.
  late final appThemePreset = propertyDefault(
    'appThemePreset',
    BuiltinTheme.defaultTheme.id,
  );

  /// Last custom theme, so selecting a built-in preset does not discard it.
  late final appCustomTheme = propertyDefault('appCustomTheme', '');

  /// Hash of the installed theme whose image/icon assets are active.
  late final appThemePackage = propertyDefault('appThemePackage', '');
  late final appThemePaletteEnabled = propertyDefault(
    'appThemePaletteEnabled',
    true,
  );

  /// How the theme store's list is ordered, by [ThemeSort.name].
  late final themeStoreSort = propertyDefault(
    'themeStoreSort',
    ThemeSort.inUse.name,
  );

  /// The theme store's last answer, as the JSON it was read from.
  ///
  /// Held so a page can open on the themes it showed last time instead of on a
  /// spinner. A map rather than a decoded model: [ThemeStore.toJson] writes it
  /// and [ThemeStore.fromJson] reads it back, and the store only owns the key.
  ///
  /// A map rather than a string holding one, which is what a second
  /// `jsonEncode` on the way in would make it.
  ///
  /// Not a user edit, so it does not stamp the store's last-modified time — a
  /// refresh is the app re-reading a catalog, and a sync that took it for a
  /// change would push one device's cache at every other device. It is also
  /// device-local, so a backup should not carry it: a list of what a catalog
  /// offered when one phone last looked is not something to restore onto
  /// another, which would show it as what the catalog offers now.
  late final themeStoreCache = propertyDefault<Map<String, dynamic>>(
    'themeStoreCache',
    const {},
    updateLastModified: false,
  );

  /// App-wide icon family. The launcher icon is selected by the platform.
  ///
  /// Stored as the enum's name, which is what was stored before it was one, so
  /// an install that wrote the string reads back unchanged.
  late final appIconStyle = propertyDefault(
    'appIconStyle',
    IconStyle.classic,
    fromObj: IconStyle.parse,
    toObj: (style) => style?.name,
  );

  /// Component shapes can be edited in the custom image theme.
  late final appCardRadius = propertyDefault('appCardRadius', 13.0);
  late final appTileRadius = propertyDefault('appTileRadius', 9.0);
  late final appButtonRadius = propertyDefault('appButtonRadius', 30.0);

  /// A device-local image behind the app's surfaces.
  late final appBackgroundStyle = propertyDefault(
    'appBackgroundStyle',
    BackgroundStyle.none,
    fromObj: BackgroundStyle.parse,
    toObj: (style) => style?.name,
  );
  late final appBackgroundPath = propertyDefault('appBackgroundPath', '');
  late final appCustomBackgroundPath = propertyDefault(
    'appCustomBackgroundPath',
    '',
  );
  late final appBackgroundOpacity = propertyDefault(
    'appBackgroundOpacity',
    0.18,
  );
  late final appBackgroundBlur = propertyDefault('appBackgroundBlur', 0.0);

  /// The logical width the background image repeats at; 0 draws it once,
  /// `cover`-fitted. Set by a theme package, never by the settings page.
  late final appBackgroundTile = propertyDefault('appBackgroundTile', 0.0);

  /// Font names are tried in order; the platform's default follows the list.
  late final appFontFamilies = listProperty<String>('appFontFamilies');
  late final appImportedFontPath = propertyDefault('appImportedFontPath', '');
  late final appImportedFontName = propertyDefault('appImportedFontName', '');

  /// ThemeMode: 0 -> system, 1 -> light, 2 -> dark.
  late final themeMode = propertyDefault('themeMode', 0);

  /// The bundled store themes already installed once, by manifest id, so one
  /// the user removed is not installed again at the next launch.
  late final bundledThemesSeeded = listProperty<String>(
    'bundledThemesSeeded',
    // Written by the app, not the user.
    updateLastModified: false,
  );
}
