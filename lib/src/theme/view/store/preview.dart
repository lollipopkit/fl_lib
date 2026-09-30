import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:fl_lib/src/theme/package.dart';
import 'package:fl_lib/src/theme/view/background.dart';
import 'package:fl_lib/src/theme/view/app_theme.dart';
import 'package:fl_lib/src/theme/view/package_image.dart';
import 'package:fl_lib/src/theme/host.dart';

/// A theme drawn with the app's own widgets, the way the app draws it once
/// applied: the theme [buildAppTheme] makes of the package, its background,
/// and a bar, cards, rows, a search pill, buttons and the navigation bar in
/// it.
///
/// Built only when a store row is opened, so a list of themes costs nothing
/// until one is looked at.
class ThemeStorePreview extends StatefulWidget {
  const ThemeStorePreview({super.key, required this.theme, this.rootDirectory});

  /// The package, as any of its variants.
  final ThemePackage theme;

  /// Where [theme] is installed, for reading its other variants; null for the
  /// app's own themes directory.
  final String? rootDirectory;

  @override
  State<ThemeStorePreview> createState() => _ThemeStorePreviewState();
}

class _ThemeStorePreviewState extends State<ThemeStorePreview> {
  late ThemePackage _theme = widget.theme;
  Brightness? _brightness;

  /// The brightness the preview starts in: the app's own, where the theme has
  /// it.
  Brightness _initialBrightness(BuildContext context) {
    final own = Theme.of(context).brightness;
    final modes = _theme.modes;
    if (modes.length == 1) {
      return modes.single == ThemeMode.dark ? Brightness.dark : Brightness.light;
    }
    return own;
  }

  void _pickVariant(ThemeVariant variant) {
    final next = ThemePackages.installed(
      _theme.installationId,
      variant: variant.key,
      rootDirectory: widget.rootDirectory,
    );
    if (next != null) setState(() => _theme = next);
  }

  @override
  Widget build(BuildContext context) {
    final brightness = _brightness ?? _initialBrightness(context);
    final both = _theme.modes.length > 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_theme.variants.isNotEmpty || both)
          Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: Wrap(
              spacing: 9,
              runSpacing: 9,
              children: [
                if (_theme.variant case final current?)
                  SegmentedTabs<ThemeVariant>(
                    segments: [
                      for (final variant in _theme.variants)
                        SegmentedTab(value: variant, label: variant.name),
                    ],
                    selected: current,
                    onSelected: _pickVariant,
                  ),
                if (both)
                  SegmentedTabs<Brightness>(
                    segments: [
                      SegmentedTab(
                        value: Brightness.light,
                        label: libL10n.bright,
                        icon: Icons.light_mode_outlined,
                      ),
                      SegmentedTab(
                        value: Brightness.dark,
                        label: libL10n.dark,
                        icon: Icons.dark_mode_outlined,
                      ),
                    ],
                    selected: brightness,
                    onSelected: (value) => setState(() => _brightness = value),
                  ),
              ],
            ),
          ),
        _PreviewScreen(theme: _theme, brightness: brightness),
      ],
    );
  }
}

class _PreviewScreen extends StatelessWidget {
  const _PreviewScreen({required this.theme, required this.brightness});

  final ThemePackage theme;
  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final data = buildAppTheme(
      AppThemeSource.of(theme),
      seed: Color(theme.seed),
      brightness: brightness,
    );
    final background = BackgroundLayer.of(theme);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 380,
        child: Theme(
          data: data,
          child: Builder(
            builder: (context) {
              final scheme = Theme.of(context).colorScheme;
              final content = ThemeHost.current.preview;
              Widget icon(String key, IconData fallback) =>
                  _icon(context, key, fallback);
              return Material(
                color: background == null ? scheme.surface : Colors.transparent,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    ?background,
                    Column(
                      children: [
                        AppBar(
                          primary: false,
                          automaticallyImplyLeading: false,
                          title: Text(ThemeHost.current.appName),
                          actions: [
                            for (final (key, fallback) in content?.actions ?? const <(String, IconData)>[])
                              IconButton(
                                onPressed: () {},
                                icon: icon(key, fallback),
                              ),
                          ],
                        ),
                        Expanded(
                          child: ListView(
                            physics: const NeverScrollableScrollPhysics(),
                            padding: const EdgeInsets.symmetric(horizontal: 7),
                            children: [
                              ...?content?.body(context, icon),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(6, 7, 6, 0),
                                child: Row(
                                  children: [
                                    Expanded(child: _search(context)),
                                    UIs.width7,
                                    TextButton(
                                      onPressed: () {},
                                      child: Text(libL10n.cancel),
                                    ),
                                    FilledButton(
                                      onPressed: () {},
                                      child: Text(libL10n.ok),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                        if ((content?.tabs.length ?? 0) > 1)
                          NavigationBar(
                            height: 62,
                            selectedIndex: 0,
                            labelBehavior:
                                NavigationDestinationLabelBehavior.alwaysHide,
                            destinations: [
                              for (final (key, fallback) in content!.tabs)
                                NavigationDestination(
                                  icon: _icon(context, 'tab.$key', fallback),
                                  selectedIcon: _icon(
                                    context,
                                    'tab.$key.selected',
                                    fallback,
                                    or: 'tab.$key',
                                  ),
                                  label: key,
                                ),
                            ],
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  /// The package's own image for [key], tinted as the app tints it, or the
  /// built-in glyph.
  Widget _icon(
    BuildContext context,
    String key,
    IconData fallback, {
    String? or,
  }) {
    final path = theme.iconPath(key) ?? (or == null ? null : theme.iconPath(or));
    final glyph = Icon(fallback);
    if (path == null) return glyph;
    final iconTheme = IconTheme.of(context);
    final scheme = Theme.of(context).colorScheme;
    return PackageImage(
      path: path,
      size: iconTheme.size ?? 24,
      color:
          theme.iconColor(key, scheme) ??
          iconTheme.color ??
          scheme.onSurface,
      fallback: glyph,
    );
  }

  Widget _search(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = ComponentStyles.of(context).search;
    return Container(
      height: style.height ?? 34,
      padding: style.padding ?? const EdgeInsets.symmetric(horizontal: 11),
      decoration: ShapeDecoration(
        shape: style.shape(const StadiumBorder()),
        color: style.backgroundColor ?? scheme.surfaceContainerLow,
      ),
      child: Row(
        children: [
          Icon(Icons.search, size: 17, color: style.iconColor ?? scheme.outline),
          UIs.width7,
          Text(
            libL10n.search,
            style: TextStyle(
              fontSize: 13,
              color: style.hintColor ?? scheme.outline,
            ),
          ),
        ],
      ),
    );
  }
}
