import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/theme/host.dart';
import 'package:fl_lib/src/theme/package.dart';
import 'package:fl_lib/src/theme/repo.dart';
import 'package:flutter/services.dart';

/// The installed theme packages as an app's backup carries them, and the way
/// back from one.
///
/// A backup used to leave themes out: an installation is rewritten from its
/// package and cannot be packed back into the same bytes, so a restore kept
/// the settings that chose a theme and dropped the theme, and the app fell
/// back to the default (#1637). Now each installation is described by the
/// cheapest thing that brings the same bytes back:
///
/// - `bundled`: the app ships it, under this manifest id;
/// - `store`: a theme store release, by its listing and version — installed
///   again from the store, checked against the same digest;
/// - `fsbt`: the package itself, base64, for one imported by hand — when it
///   was kept ([ThemePackages.sourceOf]) and is at most [maxEmbeddedBytes].
///
/// One none of them can describe — installed from a folder, or imported
/// before packages were kept — is still listed, by name with nothing to
/// install it from, so a restore names it rather than quietly falling back to
/// the default theme; [ThemeBackupExport.skipped] names it at backup time.
abstract final class ThemeBackup {
  /// The largest package a backup carries whole. A backup is synced on every
  /// edit, and a gist past a megabyte is truncated by the API that serves it.
  static const maxEmbeddedBytes = 512 * 1024;

  static Future<ThemeBackupExport> export({
    String? rootDirectory,
    AssetBundle? bundle,
  }) async {
    final installed = ThemePackages.listInstalled(rootDirectory: rootDirectory);
    if (installed.isEmpty) return const ThemeBackupExport({}, []);

    final bundled = await _bundledDigests(bundle ?? rootBundle);
    final store = ThemeStore.fromJson(ThemeHost.settings.themeStoreCache.fetch());
    final entries = <String, Object?>{};
    final skipped = <String>[];
    for (final theme in installed) {
      final id = theme.installationId;
      final base = {'id': theme.id, 'name': theme.name};
      if (bundled[id] case final manifestId?) {
        entries[id] = {...base, 'bundled': manifestId};
        continue;
      }
      if (_storeItemFor(store, id) case final item?) {
        entries[id] = {...base, 'store': item.toJson()};
        continue;
      }
      final source = await ThemePackages.sourceOf(
        id,
        rootDirectory: rootDirectory,
      );
      if (source != null && source.length <= maxEmbeddedBytes) {
        entries[id] = {...base, 'fsbt': base64Encode(source)};
        continue;
      }
      entries[id] = base;
      skipped.add(theme.name);
    }
    return ThemeBackupExport(entries, skipped);
  }

  /// Installs what [entries] describe and this device does not have.
  ///
  /// A theme already here under the same manifest id is kept as it is, at
  /// whatever version: installing the backup's would replace it, and a
  /// backup older than the device would take its themes back a version. The
  /// selection is pointed at it instead — see [reselect].
  static Future<ThemeRestoreReport> restore(
    Map<String, Object?> entries, {
    String? rootDirectory,
    AssetBundle? bundle,
  }) async {
    final installedAs = <String, String>{};
    final failed = <String>[];
    for (final MapEntry(key: id, value: raw) in entries.entries) {
      if (raw is! Map) {
        // Not something this or any build wrote: said, as one that failed.
        failed.add(id);
        continue;
      }
      final name = raw['name'] is String ? raw['name'] as String : id;
      if (ThemePackages.installed(id, rootDirectory: rootDirectory) != null) {
        installedAs[id] = id;
        continue;
      }
      final manifestId = raw['id'];
      final local = ThemePackages.listInstalled(rootDirectory: rootDirectory)
          .where((t) => t.id == manifestId)
          .firstOrNull;
      if (local != null) {
        installedAs[id] = local.installationId;
        continue;
      }
      try {
        final theme = await _install(raw, rootDirectory, bundle ?? rootBundle);
        installedAs[id] = theme.installationId;
      } catch (error, stack) {
        Loggers.app.warning('Restoring theme $name', error, stack);
        failed.add(name);
      }
    }
    return ThemeRestoreReport(installedAs, failed);
  }

  static Future<ThemePackage> _install(
    Map<Object?, Object?> raw,
    String? rootDirectory,
    AssetBundle bundle,
  ) async {
    if (raw['store'] case final store?) {
      final item = ThemeStoreItem.fromJson(store);
      if (item == null) throw const FormatException('Invalid store reference');
      return ThemeRepos.install(item, rootDirectory: rootDirectory);
    }
    final Uint8List bytes;
    if (raw['bundled'] case final String manifestId) {
      final dir = ThemeHost.current.bundledThemesDir;
      if (dir == null) throw const FormatException('No bundled themes');
      final data = await bundle.load('$dir$manifestId.fsbt');
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    } else if (raw['fsbt'] case final String encoded) {
      bytes = base64Decode(encoded);
    } else {
      // Listed so the restore can say it is missing; see the class doc.
      throw const FormatException('The backup does not carry this theme');
    }
    return ThemePackages.install(bytes, rootDirectory: rootDirectory);
  }

  /// Brings the settings a restore wrote back to this device.
  ///
  /// Only what a selection derives from where the theme is installed: which
  /// installation it is, and the path of its background. The rest — the mode,
  /// dynamic color, the radii — is what the user set, restored as it was;
  /// [ThemePackages.select] would overwrite it with the theme's defaults.
  /// A theme that could not be installed leaves nothing to point at, and
  /// [ThemePackages.reconcileSelection] falls back to the default.
  static void reselect(ThemeRestoreReport report) {
    final settings = ThemeHost.settings;
    final preset = settings.appThemePreset.fetch();
    final from = ThemePackages.installationIdOf(preset);
    final to = from == null ? null : report.installedAs[from];
    if (from != null && to != null) {
      final variant = ThemePackages.variantOf(preset);
      final theme = ThemePackages.installed(to, variant: variant);
      if (theme != null) {
        // The installation's own preset, variant and all.
        if (to != from) settings.appThemePreset.put(theme.preset);
        settings.appThemePackage.put(to);
        settings.appBackgroundPath.put(theme.backgroundPath ?? '');
      }
    }
    ThemePackages.reconcileSelection();
  }

  static ThemeStoreItem? _storeItemFor(ThemeStore? store, String digest) {
    for (final item in store?.items ?? const <ThemeStoreItem>[]) {
      for (final release in item.listing.releases) {
        if (release.sha256 != digest) continue;
        return ThemeStoreItem(
          repo: item.repo,
          repoUrl: item.repoUrl,
          listing: item.listing,
          release: release,
        );
      }
    }
    return null;
  }

  /// The installation id each bundled package installs as, to its manifest id.
  static Future<Map<String, String>> _bundledDigests(AssetBundle bundle) async {
    final dir = ThemeHost.current.bundledThemesDir;
    if (dir == null) return const {};
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(bundle);
      final digests = <String, String>{};
      for (final path in manifest.listAssets()) {
        if (!path.startsWith(dir) || !path.endsWith('.fsbt')) continue;
        final data = await bundle.load(path);
        final bytes = data.buffer.asUint8List(
          data.offsetInBytes,
          data.lengthInBytes,
        );
        digests[sha256.convert(bytes).toString()] = path.substring(
          dir.length,
          path.length - '.fsbt'.length,
        );
      }
      return digests;
    } catch (error, stack) {
      // Described another way instead, or left out and named.
      Loggers.app.warning('Reading bundled themes', error, stack);
      return const {};
    }
  }
}

/// What [ThemeBackup.export] found: the entries, by installation id, and the
/// names of the themes it could not describe.
final class ThemeBackupExport {
  const ThemeBackupExport(this.entries, this.skipped);

  final Map<String, Object?> entries;
  final List<String> skipped;
}

/// What [ThemeBackup.restore] did: the installation each backed-up one is on
/// this device as, and the names of those it could not install.
final class ThemeRestoreReport {
  const ThemeRestoreReport(this.installedAs, this.failed);

  final Map<String, String> installedAs;
  final List<String> failed;
}
