import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/rust/api/theme.dart';
import 'package:fl_lib/src/theme/host.dart';
import 'package:fl_lib/src/theme/installation.dart';
import 'package:fl_lib/src/theme/package.dart';
import 'package:fl_lib/src/theme/rust.dart';
import 'package:flutter/foundation.dart';

/// Installed icon packs ([ThemeIconPack]), and the one in use.
///
/// Chosen apart from the theme, like VS Code's file icon theme: a pack's
/// image wins over the theme's for the same key, and a key the pack does not
/// carry is the theme's to draw ([ThemePackages.activeIconPath]).
abstract final class ThemeIconPacks {
  /// Temporary choice only; preview never writes settings.
  /// [ThemeIconPack.none] previews following the theme.
  static final preview = ValueNotifier<ThemeIconPack?>(null);

  /// The icon packs' root inside a themes root: kept apart, so nothing that
  /// lists themes ever reads a pack as one.
  static String rootIn(String themesRoot) => themesRoot.joinPath('icons');

  static String get root => rootIn(ThemePackages.root);

  static const _maxManifestBytes = 64 * 1024;

  static String? _activeId;
  static ThemeIconPack? _active;

  /// The pack whose icons are drawn, or null to draw the theme's.
  static ThemeIconPack? get active {
    if (preview.value case final pack?) {
      return identical(pack, ThemeIconPack.none) ? null : pack;
    }
    final installationId = ThemeHost.settings.appIconPack.fetch();
    if (installationId.isEmpty) return null;
    if (_activeId != installationId) {
      _activeId = installationId;
      _active = installed(installationId);
    }
    return _active;
  }

  /// Draws [pack]'s icons from now on; null draws the theme's.
  static void select(ThemeIconPack? pack) =>
      ThemeHost.settings.appIconPack.put(pack?.installationId ?? '');

  /// One installed pack by installation id.
  static ThemeIconPack? installed(
    String installationId, {
    String? rootDirectory,
  }) {
    if (!installationIdPattern.hasMatch(installationId)) return null;
    if (!ThemeRust.ready) return null;
    final directory = (rootDirectory ?? root).joinPath(installationId);
    try {
      final manifest = installedManifest(
        directory,
        maxBytes: _maxManifestBytes,
      );
      if (manifest == null) return null;
      final data =
          jsonDecode(
                readInstalledIconPack(
                  manifest: manifest,
                  iconFiles: installedIconFiles(directory),
                ),
              )
              as Map<String, dynamic>;
      return ThemeIconPack(
        installationId: installationId,
        id: data['id'] as String,
        name: data['name'] as String,
        schemaMin: data['schemaMin'] as int,
        schemaMax: data['schemaMax'] as int,
        iconFiles: (data['iconFiles'] as Map).cast<String, String>(),
        iconColors: (data['iconColors'] as Map).cast<String, Object>(),
        directory: directory,
      );
    } catch (_) {
      return null;
    }
  }

  static List<ThemeIconPack> listInstalled({String? rootDirectory}) {
    final rootPath = rootDirectory ?? root;
    return [
      for (final id in installationIds(rootPath))
        ?installed(id, rootDirectory: rootPath),
    ]..sort((a, b) => a.name.compareTo(b.name));
  }

  /// Writes a pack `fl_theme` checked. Called by [ThemePackages.installAny],
  /// which knows a pack from a theme only once it is checked.
  static Future<ThemeIconPack> installPrepared(
    PreparedTheme prepared, {
    String? rootDirectory,
  }) async {
    final rootPath = rootDirectory ?? root;
    final existing = installed(
      prepared.installationId,
      rootDirectory: rootPath,
    );
    if (existing != null) return existing;
    await writeInstallation(rootPath, prepared);
    // A choice synced from another device may name this pack already.
    _activeId = null;
    final pack = installed(prepared.installationId, rootDirectory: rootPath);
    if (pack == null) {
      throw const FormatException('Icon pack installed but unreadable');
    }
    await _replaceOlder(pack, rootDirectory: rootDirectory);
    ThemePackages.installedChanged.value++;
    return pack;
  }

  /// Removes every other installation of [pack]'s manifest id: installed
  /// again, a pack is an update, and the one in use hands its selection over.
  static Future<void> _replaceOlder(
    ThemeIconPack pack, {
    String? rootDirectory,
  }) async {
    // No directory given is the app's own, the only one a selection names.
    final selecting = rootDirectory == null;
    final rootPath = rootDirectory ?? root;
    for (final old in listInstalled(rootDirectory: rootPath)) {
      if (old.id != pack.id || old.installationId == pack.installationId) {
        continue;
      }
      if (selecting &&
          old.installationId == ThemeHost.settings.appIconPack.fetch()) {
        select(pack);
      }
      await Directory(
        rootPath.joinPath(old.installationId),
      ).delete(recursive: true);
      await dropSource(rootPath, old.installationId);
    }
    _activeId = null;
    _active = null;
  }

  /// Deletes one installed pack, answering whether it was there. Safe on the
  /// pack in use: the app goes back to the theme's icons.
  static Future<bool> remove(
    String installationId, {
    String? rootDirectory,
  }) async {
    if (!installationIdPattern.hasMatch(installationId)) return false;
    final rootPath = rootDirectory ?? root;
    final directory = Directory(rootPath.joinPath(installationId));
    if (!await directory.exists()) return false;
    await directory.delete(recursive: true);
    await dropSource(rootPath, installationId);
    // No directory given is the app's own, the only one a selection names.
    if (rootDirectory == null) {
      _activeId = null;
      _active = null;
      reconcileSelection();
    }
    ThemePackages.installedChanged.value++;
    return true;
  }

  /// The `.fsbt` [installationId] was installed from; see
  /// [ThemePackages.sourceOf].
  static Future<Uint8List?> sourceOf(
    String installationId, {
    String? rootDirectory,
  }) => readSource(rootDirectory ?? root, installationId);

  /// Goes back to the theme's icons when the chosen pack is gone.
  static void reconcileSelection() {
    final chosen = ThemeHost.settings.appIconPack.fetch();
    if (chosen.isNotEmpty && installed(chosen) == null) select(null);
  }
}
