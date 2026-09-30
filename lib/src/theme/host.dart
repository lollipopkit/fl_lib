import 'package:fl_lib/src/theme/settings.dart';
import 'package:material_ui/material_ui.dart';

/// What the shared theme code needs from the app using it.
///
/// Set once with [ThemeHost.init], before anything reads a theme — the app's
/// launch path, after its settings store is open. Everything under
/// `package:fl_lib/theme.dart` reads it from there rather than taking it as
/// an argument, because the theme is read from build methods all over an app
/// and threading a value through each of them would be the same value every
/// time.
final class ThemeHost {
  const ThemeHost({
    required this.store,
    required this.appName,
    required this.icons,
    this.bundledThemesDir,
    this.catalogUrl,
    this.catalogAsset,
    this.packageDocUrl,
    this.preview,
  });

  /// Where the theme is stored: the app's settings store with
  /// [ThemeSettings] mixed in.
  ///
  /// Asked each time rather than held, so an app whose store is replaced —
  /// tests open a fresh one per case — is always read where it is now.
  final ThemeSettings Function() store;

  /// The app's name as the user sees it: the title of a store preview, and
  /// part of the temporary directory a previewed theme is unpacked into.
  final String appName;

  /// The icons this app draws that a theme package may replace.
  final ThemeIcons icons;

  /// The asset directory holding the store themes this app ships, one
  /// `<id>.fsbt` each, installed once on first launch; null when it ships
  /// none. Ends with `/`.
  final String? bundledThemesDir;

  /// Where the theme store's catalog of repositories is; null for an app
  /// without a theme store.
  final String? catalogUrl;

  /// The copy of that catalog the app ships, read when [catalogUrl] does not
  /// answer, so a first run with no network still offers the official
  /// repositories.
  final String? catalogAsset;

  /// How to make a theme package, linked from the store.
  final String? packageDocUrl;

  /// What a theme store preview shows inside its frame.
  final ThemePreviewContent? preview;

  static ThemeHost? _current;

  /// The host set by [init].
  static ThemeHost get current =>
      _current ??
      (throw StateError('ThemeHost.init was not called before a theme was read'));

  static ThemeSettings get settings => current.store();

  static void init(ThemeHost host) => _current = host;

  /// Clears [init], for tests that set up a host of their own.
  @visibleForTesting
  static void reset() => _current = null;
}

/// Draws a glyph the way the theme being previewed would: the package's image
/// for [iconKey], tinted as the app tints it, or [fallback].
typedef ThemePreviewIcon = Widget Function(String iconKey, IconData fallback);

/// The app's own widgets, drawn in a store preview under the theme being
/// looked at, so a theme is judged on what the app actually shows rather than
/// on a generic sample.
///
/// The frame around them — the background, a search pill and buttons — is
/// the same for every app and drawn by the preview itself.
final class ThemePreviewContent {
  const ThemePreviewContent({
    required this.body,
    this.actions = const [],
    this.tabs = const [],
  });

  /// The rows under the bar. Icons are drawn with the given [ThemePreviewIcon]
  /// so they show the previewed package's images, not the active one's.
  final List<Widget> Function(BuildContext context, ThemePreviewIcon icon)
  body;

  /// The bar's buttons: an icon key and the glyph drawn without one.
  final List<(String iconKey, IconData fallback)> actions;

  /// The navigation bar: a tab's name, whose icons are `tab.<name>` and
  /// `tab.<name>.selected`, and the glyph drawn without them. Fewer than two
  /// draws no bar.
  final List<(String tab, IconData fallback)> tabs;
}

/// The icons of one app that a theme package may replace: the part of the
/// shared format that differs between apps.
///
/// Every app on fl_lib draws different tabs and glyphs, so none of this is
/// fixed here. A package may carry icons for any of them — a key only has to
/// be well formed (`ThemePackages.iconKeyPattern`) — and an app draws the ones
/// it declares here and ignores the rest. So one package can theme two apps.
final class ThemeIcons {
  ThemeIcons({this.tabs = const [], this.symbols = const {}});

  /// The app's navigation tabs, by name. Each has two keys: [tabKey] with
  /// `selected` false and true.
  final List<String> tabs;

  /// The app's own glyphs that [ThemedIcon] swaps, keyed by the glyph the app
  /// draws, so a call site keeps passing the icon it always did and the theme
  /// decides what is drawn.
  final Map<IconData, ThemeSymbol> symbols;

  /// The key a tab's icon is stored under.
  static String tabKey(String tab, {required bool selected}) =>
      'tab.$tab${selected ? '.selected' : ''}';

  /// Every key this app draws: what a package's `icons.images` and
  /// `icons.colors` may name to change something here.
  late final Set<String> keys = {
    for (final tab in tabs) ...[
      tabKey(tab, selected: false),
      tabKey(tab, selected: true),
    ],
    for (final symbol in symbols.values) symbol.iconKey,
  };
}

/// One of the app's glyphs, as a theme sees it: see [ThemeIcons.symbols].
final class ThemeSymbol {
  const ThemeSymbol(this.iconKey, {this.mingcute});

  /// What a package's `icons.images` and `icons.colors` name this glyph by.
  final String iconKey;

  /// Drawn instead under [IconStyle.mingcute]; null keeps the glyph.
  final IconData? mingcute;
}
