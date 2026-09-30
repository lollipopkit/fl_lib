import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/theme.dart';
import 'package:material_ui/material_ui.dart';

/// A settings store with the theme's keys, as an app's own would have.
final class TestThemeStore extends SqliteStore with ThemeSettings {
  TestThemeStore() : super('setting_test');
}

TestThemeStore? _store;

/// The store [openTestThemeStore] opened, which the host reads.
TestThemeStore get testThemeStore =>
    _store ?? (throw StateError('openTestThemeStore was not called'));

/// Opens an in-memory database and a fresh theme store on it.
Future<TestThemeStore> openTestThemeStore() async {
  await SqliteDb.close();
  SqliteDb.openInMemory();
  return _store = TestThemeStore();
}

Future<void> closeTestThemeStore() async {
  // A store writes its per-key timestamp through a microtask; let it land
  // before the handle closes under it.
  await Future<void>.delayed(Duration.zero);
  _store = null;
  await SqliteDb.close();
}

/// The icons the tests' app draws: `tab.server[.selected]`, `nav.settings`
/// and `nav.folder`.
final testIcons = ThemeIcons(
  tabs: ['server'],
  symbols: {
    Icons.settings_outlined: const ThemeSymbol('nav.settings'),
    Icons.folder_outlined: const ThemeSymbol('nav.folder'),
  },
);

/// The host these tests run under: see `flutter_test_config.dart`.
void initTestThemeHost({ThemePreviewContent? preview}) => ThemeHost.init(
  ThemeHost(
    store: () => testThemeStore,
    appName: 'fl_lib',
    icons: testIcons,
    preview: preview,
  ),
);
