/// Themes as a backup carries them (lollipopkit/flutter_server_box#1637).
///
/// A restore used to bring back the settings that chose a theme and not the
/// theme, so the app fell back to the default. What has to hold: a package
/// comes back as the same installation, a store theme is named rather than
/// copied, what cannot be described is said, and a device's own newer
/// version of a theme is not replaced by an older one from the backup.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:toml/toml.dart';

import 'helper.dart';

List<int> _fsbt({String id = 'example.amethyst', String name = 'Amethyst'}) {
  final manifest = {
    'format': 1,
    'schema': {'min': 1, 'max': 1},
    'id': id,
    'name': name,
    'modes': ['light', 'dark'],
    'colors': {'mode': 0, 'seed': 4287106639, 'systemColor': false},
    'icons': {'style': 'classic', 'images': <String, String>{}},
    'background': {'type': 'gradient', 'opacity': 0.18, 'blur': 8},
    'shapes': {'card': 13, 'tile': 9, 'button': 30},
  };
  final archive = Archive()
    ..add(
      ArchiveFile.string(
        'manifest.toml',
        TomlDocument.fromMap(manifest).toString(),
      ),
    );
  return ZipEncoder().encodeBytes(archive);
}

void main() {
  late Directory device;
  late Directory other;

  setUpAll(() async {
    Paths.doc = (await Directory.systemTemp.createTemp('fsbt-backup-')).path;
  });

  tearDownAll(() => Directory(Paths.doc).delete(recursive: true));

  setUp(() async {
    await openTestThemeStore();
    device = await Directory.systemTemp.createTemp('themes-a-');
    other = await Directory.systemTemp.createTemp('themes-b-');
  });

  tearDown(() async {
    await closeTestThemeStore();
    await device.delete(recursive: true);
    await other.delete(recursive: true);
  });

  test('an imported package comes back as the same installation', () async {
    final bytes = _fsbt();
    final theme = await ThemePackages.install(bytes, rootDirectory: device.path);

    final export = await ThemeBackup.export(rootDirectory: device.path);
    expect(export.skipped, isEmpty);
    final entry = export.entries[theme.installationId] as Map;
    expect(entry['id'], 'example.amethyst');
    expect(entry.containsKey('fsbt'), isTrue);

    final report = await ThemeBackup.restore(
      export.entries,
      rootDirectory: other.path,
    );
    expect(report.failed, isEmpty);
    expect(report.installedAs, {theme.installationId: theme.installationId});
    expect(
      ThemePackages.installed(theme.installationId, rootDirectory: other.path),
      isNotNull,
    );
  });

  test('a store theme is named, not copied', () async {
    final bytes = _fsbt();
    final digest = sha256.convert(bytes).toString();
    final listing = ThemeListing.parse(
      'id = "example.amethyst"\nname = "Amethyst"\ndescription = "Purple"\n'
      '[[version]]\nversion = "1.0.0"\nschema_min = 1\nschema_max = 1\n'
      'url = "https://example.org/amethyst-1.0.0.fsbt"\nsha256 = "$digest"\n',
      'themes/example.amethyst.toml',
    );
    testThemeStore.themeStoreCache.put(
      ThemeStore(
        items: [ThemeStoreItem(repo: 'example', listing: listing)],
        repos: const ['example'],
        catalogUrl: 'https://example.org/repos.toml',
        fetchedAt: DateTime.utc(2026, 10, 8),
      ).toJson(),
    );
    await ThemePackages.install(bytes, rootDirectory: device.path);

    final export = await ThemeBackup.export(rootDirectory: device.path);
    final entry = export.entries[digest] as Map;
    expect(entry.containsKey('fsbt'), isFalse);
    final item = ThemeStoreItem.fromJson(entry['store'])!;
    expect(item.release?.version, '1.0.0');
    expect(item.release?.sha256, digest);
  });

  test('an entry carrying another theme than it names is refused', () async {
    final bytes = _fsbt();
    final digest = sha256.convert(bytes).toString();
    final swapped = _fsbt(id: 'example.other', name: 'Other');
    final otherDigest = sha256.convert(swapped).toString();
    final listing = ThemeListing.parse(
      'id = "example.other"\nname = "Other"\n'
      '[[version]]\nversion = "1.0.0"\nschema_min = 1\nschema_max = 1\n'
      'url = "https://example.org/other.fsbt"\nsha256 = "$otherDigest"\n',
      'themes/example.other.toml',
    );
    final store = ThemeStoreItem(repo: 'example', listing: listing, release: listing.releases.single);

    final report = await ThemeBackup.restore({
      // A store release of another theme, under this one's id and digest.
      digest: {'id': 'example.amethyst', 'name': 'Amethyst', 'store': store.toJson()},
      // Another package's bytes under this one's digest.
      '0' * 64: {'id': 'example.amethyst', 'name': 'Swapped', 'fsbt': base64Encode(swapped)},
      // More than an export ever embeds, refused before it is decoded.
      '1' * 64: {'id': 'example.amethyst', 'name': 'Huge', 'fsbt': 'A' * (ThemeBackup.maxEmbeddedBytes * 2)},
    }, rootDirectory: other.path);
    expect(report.failed, unorderedEquals(['Amethyst', 'Swapped', 'Huge']));
    expect(report.installedAs, isEmpty);
    expect(ThemePackages.listInstalled(rootDirectory: other.path), isEmpty);
  });

  test('a theme with nothing to carry it is named as left out', () async {
    final theme = await ThemePackages.install(
      _fsbt(),
      rootDirectory: device.path,
    );
    // As one imported before packages were kept.
    await File(
      '${device.path}/.sources/${theme.installationId}.fsbt',
    ).delete();

    final export = await ThemeBackup.export(rootDirectory: device.path);
    expect(export.skipped, ['Amethyst']);

    // Listed all the same, so the restore can say what it could not bring.
    final report = await ThemeBackup.restore(
      export.entries,
      rootDirectory: other.path,
    );
    expect(report.failed, ['Amethyst']);
    expect(report.installedAs, isEmpty);
  });

  test('a theme already on the device is kept, and selected', () async {
    final old = await ThemePackages.install(
      _fsbt(name: 'Amethyst 1'),
      rootDirectory: device.path,
    );
    final export = await ThemeBackup.export(rootDirectory: device.path);

    final local = await ThemePackages.install(
      _fsbt(name: 'Amethyst 2'),
      rootDirectory: other.path,
    );
    final report = await ThemeBackup.restore(
      export.entries,
      rootDirectory: other.path,
    );
    expect(report.installedAs, {old.installationId: local.installationId});
    // Not installed beside it, and not in its place.
    expect(
      ThemePackages.installed(old.installationId, rootDirectory: other.path),
      isNull,
    );
    expect(
      ThemePackages.installed(local.installationId, rootDirectory: other.path),
      isNotNull,
    );
  });

  test('a theme the app no longer ships is looked for in the store', () async {
    // This host ships no themes and names no store: nothing to bring it from,
    // so it is said rather than thrown.
    final report = await ThemeBackup.restore({
      'a' * 64: {'id': 'example.piggy', 'name': 'Piggy', 'bundled': 'example.piggy'},
    }, rootDirectory: other.path);
    expect(report.failed, ['Piggy']);
    expect(report.installedAs, isEmpty);
  });

  test('an entry naming another shipped theme than its own is refused', () async {
    final report = await ThemeBackup.restore({
      'a' * 64: {'id': 'example.piggy', 'name': 'Piggy', 'bundled': 'example.pride'},
    }, rootDirectory: other.path);
    expect(report.failed, ['Piggy']);
    expect(ThemePackages.listInstalled(rootDirectory: other.path), isEmpty);
  });

  test('a theme the app no longer ships comes back from the store', () async {
    // The release the app shipped, now only in the store: found by its digest.
    final bytes = Uint8List.fromList(_fsbt(id: 'example.piggy', name: 'Piggy'));
    final digest = sha256.convert(bytes).toString();
    final listing = 'id = "example.piggy"\nname = "Piggy"\n[[version]]\nversion = "1.0.0"\n'
        'schema_min = 1\nschema_max = 1\nurl = "https://example.org/piggy.fsbt"\n'
        'sha256 = "$digest"\nsize = ${bytes.length}\n';
    final tree = Archive()
      ..add(ArchiveFile.string('repo.toml', 'schema = 1\nname = "Official"\n'))
      ..add(ArchiveFile.string('themes/example.piggy.toml', listing));
    final files = {
      'https://catalog.example/repos.toml': utf8.encode('schema = 1\nname = "Test"\n[[repo]]\nurl = "https://example.org/store.tar.gz"\n'),
      'https://example.org/store.tar.gz': const GZipEncoder().encode(TarEncoder().encode(tree)),
      'https://example.org/piggy.fsbt': bytes,
    };
    ThemePackages.debugFetch = (uri) async => Uint8List.fromList(files[uri.toString()] ?? (throw HttpException('404', uri: uri)));
    initTestThemeHost(catalogUrl: 'https://catalog.example/repos.toml');
    addTearDown(() {
      ThemePackages.debugFetch = null;
      initTestThemeHost();
    });

    final report = await ThemeBackup.restore({
      digest: {'id': 'example.piggy', 'name': 'Piggy', 'bundled': 'example.piggy'},
    }, rootDirectory: other.path);
    expect(report.failed, isEmpty);
    expect(report.installedAs, {digest: digest});
  });

  test('an entry this build cannot read is reported, not skipped', () async {
    final report = await ThemeBackup.restore(
      {'a' * 64: 'not an entry'},
      rootDirectory: other.path,
    );
    expect(report.failed, ['a' * 64]);
  });

  test('a damaged kept package is replaced, not kept', () async {
    final bytes = _fsbt();
    final theme = await ThemePackages.install(bytes, rootDirectory: device.path);
    final kept = File('${device.path}/.sources/${theme.installationId}.fsbt');
    // As a write cut short.
    await kept.writeAsBytes(bytes.sublist(0, 10));
    expect(
      await ThemePackages.sourceOf(
        theme.installationId,
        rootDirectory: device.path,
      ),
      isNull,
    );

    await ThemePackages.install(bytes, rootDirectory: device.path);
    expect(
      await ThemePackages.sourceOf(
        theme.installationId,
        rootDirectory: device.path,
      ),
      bytes,
    );
  });

  test('removing a theme drops the package kept for it', () async {
    final theme = await ThemePackages.install(
      _fsbt(),
      rootDirectory: device.path,
    );
    expect(
      await ThemePackages.sourceOf(
        theme.installationId,
        rootDirectory: device.path,
      ),
      isNotNull,
    );
    await ThemePackages.remove(theme.installationId, rootDirectory: device.path);
    expect(
      File('${device.path}/.sources/${theme.installationId}.fsbt').existsSync(),
      isFalse,
    );
  });
}
