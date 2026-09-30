/// The app theme shared by the apps built on fl_lib: theme packages (`.fsbt`),
/// the theme store, and the widgets that draw a theme.
///
/// A library of its own rather than part of `fl_lib.dart`, so an app that does
/// not theme does not import it. An app that does sets [ThemeHost.init] at
/// launch and mixes [ThemeSettings] into its settings store.
library;

export 'src/theme/builtin.dart';
export 'src/theme/components.dart';
export 'src/theme/font.dart';
export 'src/theme/host.dart';
export 'src/theme/package.dart';
export 'src/theme/palette.dart';
export 'src/theme/repo.dart';
export 'src/theme/settings.dart';
export 'src/theme/sort.dart';
export 'src/theme/stored_path.dart';
export 'src/theme/style.dart';
export 'src/theme/view/app_theme.dart';
export 'src/theme/view/appearance.dart';
export 'src/theme/view/background.dart';
export 'src/theme/view/package_image.dart';
export 'src/theme/view/splash.dart';
export 'src/theme/view/store/page.dart';
export 'src/theme/view/store/preview.dart';
export 'src/theme/view/store/rows.dart';
export 'src/theme/view/themed_icon.dart';
