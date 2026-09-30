import 'package:material_ui/material_ui.dart';
import 'package:fl_lib/src/theme/package.dart';
import 'package:fl_lib/src/theme/style.dart';

import 'package:fl_lib/src/theme/view/package_image.dart';
import 'package:fl_lib/src/theme/host.dart';

/// A package image tinted like an icon, with the built-in glyph as fallback.
class ThemeIconAsset extends StatelessWidget {
  const ThemeIconAsset({
    required this.keyName,
    required this.fallback,
    super.key,
  });

  final String keyName;
  final Widget fallback;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      ThemeHost.settings.appThemePackage.listenable(),
      // A variant of the same package changes the preset and not the package,
      // and its icon colors can differ.
      ThemeHost.settings.appThemePreset.listenable(),
      ThemePackages.preview,
    ]),
    builder: (context, _) {
      final path = ThemePackages.activeIconPath(keyName);
      if (path == null) return fallback;
      final iconTheme = IconTheme.of(context);
      final scheme = Theme.of(context).colorScheme;
      return PackageImage(
        path: path,
        size: iconTheme.size ?? 24,
        // A package that names a color for this icon overrides the one the
        // ambient icon theme would give it; without one it follows that theme,
        // which is what every icon did before a package could say otherwise.
        color:
            ThemePackages.activeIconColor(keyName, scheme) ??
            iconTheme.color ??
            scheme.onSurface,
        fallback: fallback,
      );
    },
  );
}

/// Resolves shared navigation symbols through the active in-app icon family.
/// Symbols without a semantic counterpart keep their original glyph.
class ThemedIcon extends StatelessWidget {
  const ThemedIcon(this.icon, {super.key, this.size, this.color});

  final IconData icon;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        ThemeHost.settings.appIconStyle.listenable(),
        ThemePackages.preview,
      ]),
      builder: (context, _) {
        final symbol = ThemeHost.current.icons.symbols[icon];
        final selected =
            (ThemePackages.preview.value?.iconStyle ??
                    ThemeHost.settings.appIconStyle.fetch()) ==
                IconStyle.mingcute
            ? (symbol?.mingcute ?? icon)
            : icon;
        final fallback = Icon(selected, size: size, color: color);
        final key = symbol?.iconKey;
        if (key == null) return fallback;
        return IconTheme.merge(
          data: IconThemeData(size: size, color: color),
          child: ThemeIconAsset(keyName: key, fallback: fallback),
        );
      },
    );
  }
}
