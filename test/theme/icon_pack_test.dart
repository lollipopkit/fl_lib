/// Icon packs: installed apart from themes, chosen apart from them, and drawn
/// over whichever theme is in use.
library;

import 'dart:io';

import 'package:archive/archive.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:toml/toml.dart';

import 'helper.dart';

const _svg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24">'
    '<circle cx="12" cy="12" r="10" fill="currentColor"/></svg>';

List<int> _zip(Map<String, Object?> manifest, Iterable<String> icons) {
  final archive = Archive()
    ..add(
      ArchiveFile.string(
        'manifest.toml',
        TomlDocument.fromMap(manifest).toString(),
      ),
    );
  for (final name in icons) {
    archive.add(ArchiveFile.string('icons/$name', _svg));
  }
  return ZipEncoder().encodeBytes(archive);
}

/// A pack carrying `tab.server` (colored `primary`) and `file.py`; [name]
/// makes another version of it.
List<int> _pack({String name = 'Devicons'}) => _zip({
  'format': 1,
  'schema': {'min': 4, 'max': 4},
  'id': 'example.devicons',
  'name': name,
  'kind': 'icons',
  'icons': {
    'images': {
      'tab.server': 'icons/tab_server.svg',
      'file.py': 'icons/file_py.svg',
    },
    'colors': {'tab.server': 'primary'},
  },
}, ['tab_server.svg', 'file_py.svg']);

/// A theme carrying `tab.server` and `nav.settings`.
List<int> _theme() => _zip({
  'format': 1,
  'schema': {'min': 2, 'max': 2},
  'id': 'example.amethyst',
  'name': 'Amethyst',
  'modes': ['light', 'dark'],
  'colors': {'mode': 0, 'seed': 4287106639, 'systemColor': false},
  'icons': {
    'style': 'classic',
    'images': {
      'tab.server': 'icons/tab_server.svg',
      'nav.settings': 'icons/nav_settings.svg',
    },
  },
  'background': {'type': 'gradient', 'opacity': 0.18, 'blur': 8},
  'shapes': {'card': 13, 'tile': 9, 'button': 30},
}, ['tab_server.svg', 'nav_settings.svg']);

void main() {
  final scheme = ColorScheme.fromSeed(seedColor: Colors.pink);

  setUpAll(() async {
    Paths.doc = (await Directory.systemTemp.createTemp('fsbt-icons-')).path;
  });

  tearDownAll(() => Directory(Paths.doc).delete(recursive: true));

  setUp(() async {
    await openTestThemeStore();
    final themes = Directory(ThemePackages.root);
    if (themes.existsSync()) themes.deleteSync(recursive: true);
  });

  tearDown(closeTestThemeStore);

  test('a pack installs apart from the themes', () async {
    final pack = await ThemePackages.installAny(_pack());
    expect(pack, isA<ThemeIconPack>());
    expect(pack.directory, startsWith(ThemeIconPacks.root));
    expect(ThemePackages.listInstalled(), isEmpty);
    expect(ThemeIconPacks.listInstalled().single.name, 'Devicons');
    expect(
      await ThemeIconPacks.sourceOf(pack.installationId),
      isNotNull,
      reason: 'kept for a backup like a theme',
    );
    await expectLater(ThemePackages.install(_pack()), throwsFormatException);
  });

  test('a chosen pack wins over the theme, key by key', () async {
    final theme = await ThemePackages.install(_theme());
    ThemePackages.apply(theme);
    final pack = await ThemePackages.installAny(_pack()) as ThemeIconPack;

    expect(
      ThemePackages.activeIconPath('tab.server'),
      theme.iconPath('tab.server'),
    );
    expect(ThemePackages.activeIconPath('file.py'), isNull);

    ThemeIconPacks.select(pack);
    expect(
      ThemePackages.activeIconPath('tab.server'),
      pack.iconPath('tab.server'),
    );
    expect(ThemePackages.activeIconColor('tab.server', scheme), scheme.primary);
    // What the pack does not carry is still the theme's.
    expect(
      ThemePackages.activeIconPath('nav.settings'),
      theme.iconPath('nav.settings'),
    );
    expect(ThemePackages.activeIconPath('file.py'), pack.iconPath('file.py'));
    // A key the app does not draw is not drawn, whoever carries it.
    expect(ThemePackages.activeIconPath('chat.py'), isNull);
    expect(ThemeHost.current.icons.tints('file.py'), isFalse);
    expect(ThemeHost.current.icons.tints('tab.server'), isTrue);

    ThemeIconPacks.preview.value = ThemeIconPack.none;
    expect(
      ThemePackages.activeIconPath('tab.server'),
      theme.iconPath('tab.server'),
      reason: 'previewing the theme\'s own icons',
    );
    ThemeIconPacks.preview.value = null;

    ThemeIconPacks.select(null);
    expect(
      ThemePackages.activeIconPath('tab.server'),
      theme.iconPath('tab.server'),
    );
  });

  test('a choice made before the pack is here draws it once it is', () async {
    final bytes = _pack();
    final id = (await ThemePackages.installAny(bytes)).installationId;
    await ThemeIconPacks.remove(id);
    // As a sync from another device leaves it.
    testThemeStore.appIconPack.put(id);
    expect(ThemeIconPacks.active, isNull);
    await ThemePackages.installAny(bytes);
    expect(ThemeIconPacks.active?.installationId, id);
  });

  test('a new version replaces the old and keeps the selection', () async {
    final old = await ThemePackages.installAny(_pack()) as ThemeIconPack;
    ThemeIconPacks.select(old);
    final next = await ThemePackages.installAny(_pack(name: 'Devicons 2'));
    expect(ThemeIconPacks.listInstalled().single.installationId,
        next.installationId);
    expect(testThemeStore.appIconPack.fetch(), next.installationId);
    expect(ThemeIconPacks.active?.name, 'Devicons 2');
  });

  test('removing the pack in use goes back to the theme', () async {
    final pack = await ThemePackages.installAny(_pack()) as ThemeIconPack;
    ThemeIconPacks.select(pack);
    expect(await ThemeIconPacks.remove(pack.installationId), isTrue);
    expect(testThemeStore.appIconPack.fetch(), isEmpty);
    expect(ThemeIconPacks.active, isNull);
  });

  test('removing a pack elsewhere leaves the app\'s choice alone', () async {
    final pack = await ThemePackages.installAny(_pack()) as ThemeIconPack;
    ThemeIconPacks.select(pack);
    final other = await Directory.systemTemp.createTemp('themes-c-');
    addTearDown(() => other.delete(recursive: true));
    final elsewhere = await ThemePackages.installAny(
      _pack(name: 'Elsewhere'),
      rootDirectory: other.path,
    );
    await ThemeIconPacks.remove(
      elsewhere.installationId,
      rootDirectory: ThemeIconPacks.rootIn(other.path),
    );
    expect(testThemeStore.appIconPack.fetch(), pack.installationId);
  });

  test('an unreadable installation is replaced in whole', () async {
    final pack = await ThemePackages.installAny(_pack()) as ThemeIconPack;
    File('${pack.directory}/manifest.toml').writeAsStringSync('broken');
    expect(ThemeIconPacks.installed(pack.installationId), isNull);
    final again = await ThemePackages.installAny(_pack());
    expect(again.installationId, pack.installationId);
    expect(ThemeIconPacks.installed(pack.installationId)?.name, 'Devicons');
    expect(
      Directory(ThemeIconPacks.root).listSync().map((e) => e.uri.pathSegments
          .where((p) => p.isNotEmpty).last).where((n) => n.startsWith('.installing')),
      isEmpty,
      reason: 'nothing staged is left behind',
    );
  });

  test('a backup carries a pack and its selection', () async {
    final device = await Directory.systemTemp.createTemp('themes-a-');
    final other = await Directory.systemTemp.createTemp('themes-b-');
    addTearDown(() => device.delete(recursive: true));
    addTearDown(() => other.delete(recursive: true));

    final pack = await ThemePackages.installAny(
      _pack(),
      rootDirectory: device.path,
    );
    final export = await ThemeBackup.export(rootDirectory: device.path);
    expect(export.skipped, isEmpty);
    expect((export.entries[pack.installationId]! as Map)['kind'], 'icons');

    final report = await ThemeBackup.restore(
      export.entries,
      rootDirectory: other.path,
    );
    expect(report.failed, isEmpty);
    expect(report.installedAs[pack.installationId], pack.installationId);
    expect(
      ThemeIconPacks.installed(
        pack.installationId,
        rootDirectory: ThemeIconPacks.rootIn(other.path),
      ),
      isNotNull,
    );
    expect(ThemePackages.listInstalled(rootDirectory: other.path), isEmpty);
  });
}
