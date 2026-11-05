import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/theme/host.dart';
import 'package:fl_lib/src/theme/package.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:material_ui/material_ui.dart';

/// The theme mode row: system, light or dark, picked from a list; disabled
/// with the mode named when the active theme locks one.
final class ThemeModeTile extends StatelessWidget {
  const ThemeModeTile({super.key});

  static String label(int mode) => switch (mode) {
    1 => libL10n.bright,
    2 => libL10n.dark,
    _ => libL10n.auto,
  };

  @override
  Widget build(BuildContext context) {
    final title = libL10n.themeMode;
    final settings = ThemeHost.settings;
    final locked = ThemePackages.activeTheme?.lockedMode;
    return ListTile(
      leading: const Icon(MingCute.moon_stars_fill),
      title: Text(title),
      subtitle: locked == null
          ? null
          : Text(libL10n.appearanceThemeModeLocked(label(locked.index))),
      enabled: locked == null,
      onTap: locked != null
          ? null
          : () async {
              final selected = await context.showPickSingleDialog(
                title: title,
                items: List.generate(ThemeMode.values.length, (i) => i),
                display: label,
                initial: settings.themeMode.fetch(),
              );
              if (selected == null) return;
              settings.themeMode.put(selected);
              if (settings.appThemePreset.fetch() ==
                  ThemePackages.customPreset) {
                ThemePackages.saveCustomTheme();
              }
              unawaited(RNodes.app.notify());
            },
      trailing: ValBuilder(
        listenable: settings.themeMode.listenable(),
        builder: (val) =>
            Text(label(locked?.index ?? val), style: UIs.text15),
      ),
    );
  }
}
