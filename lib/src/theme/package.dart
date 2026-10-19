import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart'
    show AssetBundle, AssetManifest, rootBundle;
import 'package:material_ui/material_ui.dart'
    show Color, ColorScheme, ThemeMode;
import 'package:fl_lib/src/theme/components.dart';
import 'package:fl_lib/src/theme/palette.dart';

import 'package:fl_lib/src/theme/builtin.dart';

import 'package:fl_lib/src/theme/style.dart';

import 'package:fl_lib/src/theme/host.dart';
import 'package:fl_lib/src/theme/icon_pack.dart';
import 'package:fl_lib/src/theme/installation.dart';
import 'package:fl_lib/src/theme/rust.dart';
import 'package:fl_lib/src/rust/api/theme.dart';

/// The splash a package asks for: a background color, an optional logo beside
/// the manifest, and how long the app stays behind it before fading out.
final class ThemeSplash {
  const ThemeSplash({
    required this.color,
    required this.duration,
    this.logo,
  });

  static const defaultDuration = 600;
  static const minDuration = 100;
  static const maxDuration = 3000;

  /// An ARGB integer or a [ThemePalette] role name, resolved per brightness.
  final Object color;

  /// The logo's file name in the package root, or null for a plain color.
  final String? logo;

  /// Milliseconds the splash stays up. It covers the app's first frames, so
  /// what it delays is the launch, which is why the ceiling is low.
  final int duration;

  Color resolve(ColorScheme scheme) =>
      ThemePalette.spec(color, scheme) ?? scheme.surface;
}

/// Where a package's icon files live: the directory once installed, and the
/// prefix of their path inside an archive. One spelling for both, since a path
/// in the archive is read back as a path on disk. The manifest table of the
/// same name is a schema key and stays spelled out with the rest of them.
const _iconsDir = 'icons';

/// Where a package's variants live, one directory each: in an archive, what a
/// variant carries in place of the package's files, and once installed, each
/// variant as a complete theme.
const _variantsDir = 'variants';

/// One of the themes a package carries under `[variants]`: `Trans` of the
/// `Pride` package. Schema 3.
///
/// A package with variants is one install and one version; each variant is
/// the package's base tables with its own drawn over them, and the picker
/// offers each as a theme of its own.
@immutable
final class ThemeVariant {
  const ThemeVariant(this.key, this.name);

  /// The table's key under `[variants]`, and the directory it installs to.
  final String key;

  /// What the variant is called, e.g. `Trans`.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is ThemeVariant && other.key == key && other.name == name;

  @override
  int get hashCode => Object.hash(key, name);
}

/// What a theme and an icon pack share once installed: a directory named by
/// [installationId] under a root of its kind, written from a package
/// `fl_theme` checked.
sealed class ThemeInstallation {
  const ThemeInstallation();

  /// SHA-256 of the package, lowercase hex, and the directory's name.
  String get installationId;

  /// The manifest's `id`: the same across versions.
  String get id;
  String get name;
  int get schemaMin;
  int get schemaMax;
  String get directory;
}

/// An icon pack (`kind = "icons"`): icons chosen apart from the theme and
/// drawn over whichever one is in use. Schema 4. See [ThemeIconPacks].
final class ThemeIconPack extends ThemeInstallation {
  const ThemeIconPack({
    required this.installationId,
    required this.id,
    required this.name,
    required this.schemaMin,
    required this.schemaMax,
    required this.iconFiles,
    required this.directory,
    this.iconColors = const {},
  });

  /// No pack: what previewing "follow the theme" shows while one is chosen.
  static const none = ThemeIconPack(
    installationId: '',
    id: '',
    name: '',
    schemaMin: 0,
    schemaMax: 0,
    iconFiles: {},
    directory: '',
  );

  @override
  final String installationId;
  @override
  final String id;
  @override
  final String name;
  @override
  final int schemaMin;
  @override
  final int schemaMax;
  @override
  final String directory;

  /// Icon key to the file that carries it, inside `icons/`.
  final Map<String, String> iconFiles;

  /// Icon key to an ARGB integer or a [ThemePalette] role name, resolved
  /// against the theme in use.
  final Map<String, Object> iconColors;

  String? iconPath(String key) => switch (iconFiles[key]) {
    final String file => directory.joinPath(_iconsDir).joinPath(file),
    _ => null,
  };

  Color? iconColor(String key, ColorScheme scheme) =>
      ThemePalette.spec(iconColors[key], scheme);
}

/// A versioned .fsbt resource bundle. Fonts and launcher icons are separate.
final class ThemePackage extends ThemeInstallation {
  const ThemePackage({
    required this.installationId,
    required this.id,
    required this.name,
    required this.schemaMin,
    required this.schemaMax,
    required this.mode,
    required this.modes,
    required this.seed,
    required this.systemColor,
    required this.paletteLight,
    required this.paletteDark,
    required this.iconStyle,
    required this.iconFiles,
    required this.backgroundStyle,
    required this.opacity,
    required this.blur,
    required this.cardRadius,
    required this.tileRadius,
    required this.buttonRadius,
    required this.directory,
    this.iconColors = const {},
    this.splash,
    this.backgroundFile,
    this.backgroundTile = 0,
    this.variant,
    this.variants = const [],
    this.components = const ThemeComponents.empty(),
  });

  @override
  final String installationId;
  @override
  final String id;
  @override
  final String name;
  @override
  final int schemaMin;
  @override
  final int schemaMax;
  final int mode;
  final Set<ThemeMode> modes;

  ThemeMode? get lockedMode => modes.length == 1 ? modes.single : null;

  ThemeMode resolveMode(int preference) =>
      lockedMode ??
      (preference >= 0 && preference < ThemeMode.values.length
          ? ThemeMode.values[preference]
          : ThemeMode.system);
  final int seed;
  final bool systemColor;
  final Map<String, int> paletteLight;
  final Map<String, int> paletteDark;
  final IconStyle iconStyle;

  /// Icon key to the file that carries it, inside `icons/`. The extension is
  /// part of the value because the file decides how it is drawn: a PNG is
  /// decoded by the engine, an SVG by `flutter_svg`.
  final Map<String, String> iconFiles;

  /// Icon key to an ARGB integer or a [ThemePalette] role name. A key without
  /// one follows the ambient icon color, which is what an icon did before a
  /// package could say otherwise.
  final Map<String, Object> iconColors;
  final BackgroundStyle backgroundStyle;
  final double opacity;
  final double blur;
  final double cardRadius;
  final double tileRadius;
  final double buttonRadius;
  @override
  final String directory;
  final ThemeSplash? splash;
  final String? backgroundFile;

  /// The logical width the background image is repeated at, or 0 to draw it
  /// once, `cover`-fitted. Schema 3.
  final double backgroundTile;

  /// Which of the package's [variants] this is; null for a package without.
  final ThemeVariant? variant;

  /// Every variant the package carries, in the manifest's order; empty for a
  /// package without.
  final List<ThemeVariant> variants;
  final ThemeComponents components;

  /// What a list of every theme calls this one: `Pride · Trans` for a variant,
  /// the package's own name otherwise.
  String get label => switch (variant) {
    final variant? => '$name · ${variant.name}',
    null => name,
  };

  /// The preset value that selects this theme, variant included.
  String get preset =>
      ThemePackages.presetOf(installationId, variant: variant?.key);

  String? get backgroundPath =>
      backgroundStyle == BackgroundStyle.image
      ? backgroundFile ?? directory.joinPath('background.img')
      : null;

  /// The splash logo, which sits beside the manifest rather than under any
  /// directory of its own — there is only ever one.
  String? get splashLogoPath => switch (splash?.logo) {
    final String logo => directory.joinPath(logo),
    _ => null,
  };

  String? iconPath(String key) => switch (iconFiles[key]) {
    final String file => directory.joinPath(_iconsDir).joinPath(file),
    _ => null,
  };

  Color? iconColor(String key, ColorScheme scheme) =>
      ThemePalette.spec(iconColors[key], scheme);
}

/// Loads one bundled folder on demand and shares concurrent requests.
final class BuiltinThemeLoader {
  BuiltinThemeLoader({
    AssetBundle? bundle,
    this.rootDirectory,
    this.assetRoot = defaultAssetRoot,
  }) : _bundle = bundle ?? rootBundle;

  /// Where the built-in folders are in an app depending on fl_lib: a
  /// package's assets are keyed under `packages/<name>/`.
  static const defaultAssetRoot = 'packages/fl_lib/assets/themes/';

  final AssetBundle _bundle;
  final String? rootDirectory;

  /// The asset directory holding one folder per built-in theme. fl_lib's own
  /// tests are the root package, where the same files are `assets/themes/`.
  final String assetRoot;
  final _loaded = <BuiltinTheme, ThemePackage>{};
  final _pending = <BuiltinTheme, Future<ThemePackage>>{};

  ThemePackage? loaded(BuiltinTheme theme) => theme == BuiltinTheme.defaultTheme
      ? ThemePackages.defaultTheme
      : _loaded[theme];

  Future<ThemePackage> load(BuiltinTheme theme) async {
    final cached = loaded(theme);
    if (cached != null) return cached;
    final pending = _pending[theme];
    if (pending != null) return pending;
    final future = _loadFolder(theme);
    _pending[theme] = future;
    try {
      final package = await future;
      _loaded[theme] = package;
      return package;
    } finally {
      unawaited(_pending.remove(theme));
    }
  }

  Future<ThemePackage> _loadFolder(BuiltinTheme builtin) async {
    final manifest = await AssetManifest.loadFromAssetBundle(_bundle);
    final prefix = '$assetRoot${builtin.id}/';
    final assets = <String, Uint8List>{};
    for (final asset in manifest.listAssets().where(
      (path) => path.startsWith(prefix),
    )) {
      final bytes = await _bundle.load(asset);
      assets[asset.substring(prefix.length)] = bytes.buffer.asUint8List(
        bytes.offsetInBytes,
        bytes.lengthInBytes,
      );
    }
    final prepared = await ThemeRust.prepareFiles(assets);
    if (prepared.id != builtin.id || prepared.name != builtin.label) {
      throw const FormatException('Built-in theme metadata mismatch');
    }
    final directory = rootDirectory ?? ThemePackages.root.joinPath('builtin');
    final package = ThemePackages._onlyTheme(
      await ThemePackages._installPrepared(prepared, rootDirectory: directory),
    );
    ThemePackages._removeUnreadable(directory);
    return package;
  }
}

abstract final class ThemePackages {
  /// Temporary appearance only; preview never writes settings.
  static final preview = ValueNotifier<ThemePackage?>(null);

  /// Bumped whenever a theme is installed or removed, so a list of installed
  /// themes on screen can read it again. Installs happen off screen too: a
  /// bundled theme is installed after launch, while a page restored at
  /// launch may already be showing the list without it.
  static final installedChanged = ValueNotifier<int>(0);

  static const supportedSchemaMin = 1;
  static const supportedSchemaMax = 4;

  /// What schema 2 added: SVG icons, per-icon colors, and [ThemeSplash]. A
  /// package that uses one of them has to say it needs 2, because a build that
  /// reads only schema 1 installs the same bytes and then drops the feature
  /// without saying so.
  static const featureSchema = 2;

  /// What schema 3 added: the components beyond schema 2's seven, the fields
  /// they gained (`button.minHeight`), and `[layout]`. See
  /// [ThemeComponents.neededSchema]. A build that reads only 2 refuses such a
  /// package outright (an unknown table), so saying so up front is what lets
  /// the store show it as needing a newer app rather than failing to install.
  static const componentSchema = 3;

  /// What schema 4 added: more than 48 icons, and icon packs
  /// ([ThemeIconPack]). A build that reads only 3 refuses either, so a
  /// package has to say it needs 4.
  static const iconSchema = 4;
  static String get supportedSchemaRange =>
      'v$supportedSchemaMin–v$supportedSchemaMax';

  static const maxPackageBytes = 16 * 1024 * 1024;
  static const _maxBackgroundBytes = 8 * 1024 * 1024;
  static const _maxSplashLogoBytes = 512 * 1024;
  static const _maxIconBytes = 256 * 1024;
  static const _maxManifestBytes = 64 * 1024;
  static const _maxIcons = 128;

  /// Files a package may carry: the manifest, its icons, a background and a
  /// splash logo, and for each variant a background, a splash logo and its
  /// directory entry.
  static const _maxAssets = _maxIcons + 3 + maxVariants * 3;
  static final _digestPattern = installationIdPattern;

  /// Every top-level table a package may carry. One that is not here is refused
  /// rather than ignored, because an ignored one is a theme that silently does
  /// not do what its author wrote — a mistyped `[splas]` costs nothing to
  /// report and is invisible otherwise.
  @visibleForTesting
  static const sections = {
    'format',
    'schema',
    'id',
    'name',
    'modes',
    'colors',
    'icons',
    'background',
    'shapes',
    'components',
    'layout',
    'splash',
    'variants',
  };

  /// What a `[variants.<key>]` table may carry: its name, and any of the
  /// tables that draw the theme. Not what identifies the package — `id`,
  /// `schema`, `modes` — which every variant shares.
  static const variantFields = {
    'name',
    'colors',
    'icons',
    'background',
    'splash',
    'shapes',
    'components',
    'layout',
  };
  static const maxVariants = 8;
  static final variantKeyPattern = RegExp(r'^[a-z0-9][a-z0-9_-]{0,31}$');
  /// The fields `[icons]` and `[splash]` may carry, held against the schema's
  /// properties by the same test that holds the enums above.
  static const iconFields = {'style', 'images', 'colors'};

  /// What an icon pack ([ThemeIconPack]) may carry, and the fields of its
  /// `[icons]`: no `style`, which is the theme's.
  static const iconPackSections = {
    'format',
    'schema',
    'id',
    'name',
    'kind',
    'icons',
  };
  static const iconPackFields = {'images', 'colors'};
  static const backgroundFields = {'type', 'image', 'opacity', 'blur', 'tile'};
  static const splashFields = {'color', 'logo', 'duration'};

  /// What the format allows where a value is one of a few, which
  /// `docs/schemas/fsbt-manifest.schema.json` enumerates for editors as well:
  /// `test/unit/theme_schema_test.dart` holds the two lists equal, so a value
  /// added here and not there is an author writing what the schema offers and
  /// this build refusing it.
  ///
  /// Each is the enum's own `name`, which is the spelling a manifest carries,
  /// so the set cannot drift from the type the value is read into.
  static final modes = {
    for (final mode in _declaredModes) mode.name,
  };
  static final iconStyles = {
    for (final style in IconStyle.values) style.name,
  };
  static final backgroundStyles = {
    for (final style in BackgroundStyle.values) style.name,
  };

  /// The modes a package may declare. Absent `system` on purpose: a package
  /// either works in a brightness or refuses to carry it.
  static const _declaredModes = {ThemeMode.light, ThemeMode.dark};

  /// The one file name a background image may have, at the archive root.
  static const backgroundImages = {
    'background.png',
    'background.jpg',
    'background.jpeg',
  };

  /// The longest `name` a package may carry.
  static const maxNameLength = 80;

  /// The largest image opacity and blur radius. Stated in the schema too, and
  /// held equal by the same test. The splash's own range is on [ThemeSplash].
  static const maxBackgroundOpacity = 0.6;
  static const maxBackgroundBlur = 30.0;

  /// The range of `background.tile`, the logical width of one repeat.
  static const minBackgroundTile = 16.0;
  static const maxBackgroundTile = 1024.0;

  /// The one logo a splash may name, kept here so the test that holds this
  /// list and the schema's together can read it.
  @visibleForTesting
  static const splashLogos = {
    'splash_logo.png',
    'splash_logo.jpg',
    'splash_logo.jpeg',
    'splash_logo.svg',
  };

  /// What a theme's id may be, and therefore what a repository file for one may
  /// be called: a repository names the theme its file describes, so the two are
  /// one spelling and one pattern — see [ThemeRepoLayout.pathOf].
  static final idPattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');
  static String? _activeId;
  static ThemePackage? _active;
  static const defaultTheme = ThemePackage(
    installationId: '',
    id: 'default',
    name: 'Default',
    schemaMin: 1,
    schemaMax: 1,
    mode: 0,
    modes: {ThemeMode.light, ThemeMode.dark},
    seed: 0xFF880E4F,
    systemColor: false,
    paletteLight: {},
    paletteDark: {},
    iconStyle: IconStyle.classic,
    iconFiles: {},
    backgroundStyle: BackgroundStyle.none,
    opacity: 0.18,
    blur: 0,
    cardRadius: 13,
    tileRadius: 9,
    buttonRadius: 30,
    directory: '',
  );
  static final _builtinLoader = BuiltinThemeLoader();

  static Future<ThemePackage> loadBuiltin(BuiltinTheme theme) =>
      _builtinLoader.load(theme);

  static Future<void> prepareSelectedTheme() async {
    try {
      // Every theme is read in Rust; nothing installed shows until it loads.
      await ThemeRust.ensureInitialized();
      // TODO: Remove migration after legacy AMOLED mode settings age out.
      final legacyMode = ThemeHost.settings.themeMode.fetch();
      if (legacyMode == 3 || legacyMode == 4) {
        select(
          await loadBuiltin(BuiltinTheme.amoled),
          preset: BuiltinTheme.amoled.id,
        );
        ThemeHost.settings.themeMode.put(
          legacyMode == 3 ? ThemeMode.dark.index : ThemeMode.system.index,
        );
      }
      final preset = BuiltinTheme.fromId(ThemeHost.settings.appThemePreset.fetch());
      if (preset == null) return;
      await loadBuiltin(preset);
    } catch (error, stack) {
      Loggers.app.warning(
        'Could not load selected built-in theme',
        error,
        stack,
      );
      _selectDefaultFallback();
    }
  }

  /// Installs each theme the app ships that this device has not had yet.
  ///
  /// A bundled theme is an ordinary installation, as if from the store: the
  /// same bytes, so the same installation id the store's listing records, and
  /// the store updates it like any theme it installed. Each is installed once:
  /// one the user removed stays removed, and one already on the device — from
  /// the store, or a newer version — is left as it is.
  static Future<void> seedBundled({
    AssetBundle? bundle,
    String? rootDirectory,
  }) async {
    // Called without waiting at launch: nothing here may escape as an
    // unhandled error, and a failure is tried again at the next launch.
    try {
      final bundledDir = ThemeHost.current.bundledThemesDir;
      if (bundledDir == null) return;
      final assets = bundle ?? rootBundle;
      final seeded = ThemeHost.settings.bundledThemesSeeded;
      final done = {...seeded.fetch()};
      final manifest = await AssetManifest.loadFromAssetBundle(assets);
      for (final path in manifest.listAssets()) {
        if (!path.startsWith(bundledDir) || !path.endsWith('.fsbt')) continue;
        final id = path.substring(bundledDir.length, path.length - '.fsbt'.length);
        if (done.contains(id)) continue;
        try {
          final onDevice = [
            ...listInstalled(rootDirectory: rootDirectory),
            ...ThemeIconPacks.listInstalled(
              rootDirectory: rootDirectory == null
                  ? null
                  : ThemeIconPacks.rootIn(rootDirectory),
            ),
          ].any((installed) => installed.id == id);
          if (!onDevice) {
            final data = await assets.load(path);
            final installed = await installAny(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
              rootDirectory: rootDirectory,
            );
            if (installed.id != id) {
              throw FormatException('$path installs as ${installed.id}');
            }
          }
          done.add(id);
        } catch (error, stack) {
          // Tried again at the next launch: nothing was recorded.
          Loggers.app.warning('Installing bundled theme $id', error, stack);
        }
      }
      seeded.put(done.toList()..sort());
    } catch (error, stack) {
      Loggers.app.warning('Installing bundled themes', error, stack);
    }
  }

  /// What an icon key may look like: dotted lowercase words, such as
  /// `tab.server.selected` or `nav.settings`.
  ///
  /// A package is checked against this rather than against the keys this app
  /// draws ([ThemeIcons.keys]): the format is shared by more than one app,
  /// and a package made for another carries keys this one has never heard of.
  /// Those are kept and never drawn. The pattern is what stops a key from
  /// naming a file outside the package, since the key becomes a file name.
  static final iconKeyPattern = RegExp(r'^[a-z][a-z0-9]*(\.[a-z][a-zA-Z0-9]*)+$');

  /// The keys this app draws; see [ThemeIcons.keys].
  static Set<String> get iconKeys => ThemeHost.current.icons.keys;


  static String get root => Paths.doc.joinPath('themes');

  static Uri httpsUri(String input) {
    final uri = Uri.tryParse(input.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasFragment) {
      throw const FormatException('Use an HTTPS URL without credentials');
    }
    return uri;
  }

  /// What [download] answers with instead of the network: a test's files.
  @visibleForTesting
  static Future<Uint8List> Function(Uri uri)? debugFetch;

  static Future<Uint8List> download(
    String url, {
    int maxBytes = maxPackageBytes,
  }) async {
    var uri = httpsUri(url);
    if (debugFetch case final fetch?) return fetch(uri);
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    try {
      for (var redirect = 0; redirect < 4; redirect++) {
        final request = await client.getUrl(uri);
        request.followRedirects = false;
        final response = await request.close().timeout(
          const Duration(seconds: 30),
        );
        if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (location == null) {
            throw const FormatException('Missing redirect URL');
          }
          uri = httpsUri(uri.resolve(location).toString());
          await response.drain<void>();
          continue;
        }
        if (response.statusCode != HttpStatus.ok) {
          throw HttpException('HTTP ${response.statusCode}', uri: uri);
        }
        if (response.contentLength > maxBytes) {
          throw const FormatException('Download exceeds size limit');
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.timeout(
          const Duration(seconds: 60),
        )) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const FormatException('Download exceeds size limit');
          }
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      }
      throw const FormatException('Too many redirects');
    } finally {
      client.close(force: true);
    }
  }

  static Future<ThemePackage> installUrl(
    String url, {
    String? expectedSha256,
  }) async => _onlyTheme(await installUrlAny(url, expectedSha256: expectedSha256));

  /// A theme or an icon pack from [url].
  static Future<ThemeInstallation> installUrlAny(
    String url, {
    String? expectedSha256,
  }) async {
    final bytes = await download(url);
    if (expectedSha256 != null &&
        sha256.convert(bytes).toString() != expectedSha256) {
      throw const FormatException('Theme checksum mismatch');
    }
    return installAny(bytes);
  }

  /// Installs a theme; an icon pack is refused here, see [installAny].
  static Future<ThemePackage> install(
    List<int> bytes, {
    String? rootDirectory,
  }) async => _onlyTheme(await installAny(bytes, rootDirectory: rootDirectory));

  /// Installs a theme into [rootDirectory], or an icon pack into the icon
  /// packs' root inside it ([ThemeIconPacks.rootIn]).
  static Future<ThemeInstallation> installAny(
    List<int> bytes, {
    String? rootDirectory,
  }) async {
    if (bytes.isEmpty || bytes.length > maxPackageBytes) {
      throw const FormatException('Invalid theme package size');
    }
    final installed = await _installPrepared(
      await ThemeRust.preparePackage(bytes),
      rootDirectory: rootDirectory,
    );
    await keepSource(
      _rootOf(installed, rootDirectory),
      installed.installationId,
      bytes,
    );
    return installed;
  }

  static ThemePackage _onlyTheme(ThemeInstallation installed) =>
      switch (installed) {
        final ThemePackage theme => theme,
        ThemeIconPack() => throw const FormatException(
          'This is an icon pack, not a theme',
        ),
      };

  /// The root [installed] is under, given the themes' root it was installed
  /// into.
  static String _rootOf(ThemeInstallation installed, String? rootDirectory) =>
      switch (installed) {
        ThemePackage() => rootDirectory ?? root,
        ThemeIconPack() => ThemeIconPacks.rootIn(rootDirectory ?? root),
      };

  /// The `.fsbt` [installationId] was installed from, or null for one
  /// installed from a folder, or before these were kept. Checked against the
  /// id, which is its digest: a file changed on disk is no source of it.
  static Future<Uint8List?> sourceOf(
    String installationId, {
    String? rootDirectory,
  }) => readSource(rootDirectory ?? root, installationId);

  /// Imports a development directory without requiring a ZIP build step.
  static Future<ThemePackage> installFolder(
    String folderPath, {
    String? rootDirectory,
  }) async => _onlyTheme(
    await installFolderAny(folderPath, rootDirectory: rootDirectory),
  );

  /// A theme or an icon pack from a development directory.
  static Future<ThemeInstallation> installFolderAny(
    String folderPath, {
    String? rootDirectory,
  }) async {
    if (await FileSystemEntity.type(folderPath, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FormatException('Invalid theme folder');
    }
    final assets = <String, Uint8List>{};
    var total = 0;
    Future<void> readFile(File file, String path, int maxBytes) async {
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        throw const FormatException('Invalid theme asset');
      }
      final size = await file.length();
      if (size <= 0 || size > maxBytes || total + size > maxPackageBytes) {
        throw const FormatException('Theme asset exceeds size limit');
      }
      final bytes = await file.readAsBytes();
      if (bytes.length != size) {
        throw const FormatException('Theme asset changed during import');
      }
      assets[path] = bytes;
      total += bytes.length;
    }

    final folder = Directory(folderPath);
    await readFile(
      File(folder.path.joinPath('manifest.toml')),
      'manifest.toml',
      _maxManifestBytes,
    );
    await for (final entry in folder.list(followLinks: false)) {
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (name == 'manifest.toml') continue;
      if (name == _iconsDir) {
        if (entry is! Directory) {
          throw const FormatException('Invalid icons directory');
        }
        await for (final icon in entry.list(followLinks: false)) {
          final iconName = icon.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last;
          if (!iconName.endsWith('.png') && !iconName.endsWith('.svg')) {
            continue;
          }
          if (icon is! File) {
            throw const FormatException('Invalid theme icon');
          }
          await readFile(icon, '$_iconsDir/$iconName', _maxIconBytes);
          if (assets.length > _maxAssets) {
            throw const FormatException('Too many theme assets');
          }
        }
      } else if (name == _variantsDir) {
        // `variants/<key>/`, each with what that variant carries in place of
        // the package's own background and splash logo.
        if (entry is! Directory) {
          throw const FormatException('Invalid variants directory');
        }
        await for (final variant in entry.list(followLinks: false)) {
          final key = variant.uri.pathSegments
              .where((part) => part.isNotEmpty)
              .last;
          if (variant is! Directory || !variantKeyPattern.hasMatch(key)) {
            throw const FormatException('Invalid variant directory');
          }
          await for (final file in variant.list(followLinks: false)) {
            final fileName = file.uri.pathSegments
                .where((part) => part.isNotEmpty)
                .last;
            final max = backgroundImages.contains(fileName)
                ? _maxBackgroundBytes
                : splashLogos.contains(fileName)
                ? _maxSplashLogoBytes
                : null;
            if (max == null) continue;
            if (file is! File) {
              throw const FormatException('Invalid variant asset');
            }
            await readFile(file, '$_variantsDir/$key/$fileName', max);
            if (assets.length > _maxAssets) {
              throw const FormatException('Too many theme assets');
            }
          }
        }
      } else if (backgroundImages.contains(name)) {
        if (entry is! File) {
          throw const FormatException('Invalid theme background');
        }
        await readFile(entry, name, _maxBackgroundBytes);
      } else if (splashLogos.contains(name)) {
        if (entry is! File) {
          throw const FormatException('Invalid splash logo');
        }
        await readFile(entry, name, _maxSplashLogoBytes);
      }
    }
    return _installPrepared(
      await ThemeRust.prepareFiles(assets),
      rootDirectory: rootDirectory,
    );
  }

  /// Installs uncompressed assets from a local folder or the Flutter bundle.
  ///
  /// The installation id is a digest of every path and its bytes, so the same
  /// files are the same installation however they were read (`fl_theme`).
  static Future<ThemePackage> installAssets(
    Map<String, Uint8List> assets, {
    String? rootDirectory,
  }) async => _onlyTheme(
    await _installPrepared(
      await ThemeRust.prepareFiles(assets),
      rootDirectory: rootDirectory,
    ),
  );

  /// Writes a package `fl_theme` checked into its installation directory: a
  /// theme under [rootDirectory], an icon pack under its root inside it.
  static Future<ThemeInstallation> _installPrepared(
    PreparedTheme prepared, {
    String? rootDirectory,
  }) async {
    if (prepared.iconPack) {
      return ThemeIconPacks.installPrepared(
        prepared,
        rootDirectory: rootDirectory == null
            ? null
            : ThemeIconPacks.rootIn(rootDirectory),
      );
    }
    final installationId = prepared.installationId;
    final rootPath = rootDirectory ?? root;
    final existing = installed(installationId, rootDirectory: rootPath);
    if (existing != null) return existing;
    await writeInstallation(rootPath, prepared);
    _activeId = null;
    final package = installed(installationId, rootDirectory: rootPath);
    if (package == null) {
      throw const FormatException('Theme installed but unreadable');
    }
    await _replaceOlder(package, rootDirectory: rootDirectory);
    installedChanged.value++;
    return package;
  }

  /// Removes every other installation of [package]'s manifest id: a package
  /// installed again — a newer version, or a folder edited and imported once
  /// more — is an update of the theme, not a second theme beside it.
  ///
  /// Within the directory it was installed to. In the app's own, the one in
  /// use hands its selection to [package], variant and all, so an update never
  /// sends the app back to the default theme.
  static Future<void> _replaceOlder(
    ThemePackage package, {
    String? rootDirectory,
  }) async {
    // No directory given is the app's own, and the only one a selection
    // points into.
    final selecting = rootDirectory == null;
    final rootPath = rootDirectory ?? root;
    for (final old in listInstalled(rootDirectory: rootPath)) {
      if (old.id != package.id ||
          old.installationId == package.installationId) {
        continue;
      }
      if (selecting &&
          old.installationId == ThemeHost.settings.appThemePackage.fetch()) {
        final variant = variantOf(ThemeHost.settings.appThemePreset.fetch());
        final next =
            installed(package.installationId, variant: variant) ?? package;
        // An update is not a choice of theme: the mode the user set stays,
        // unless the new version locks one.
        final mode = ThemeHost.settings.themeMode.fetch();
        select(next, preset: next.preset);
        if (next.lockedMode == null) ThemeHost.settings.themeMode.put(mode);
      }
      await Directory(
        rootPath.joinPath(old.installationId),
      ).delete(recursive: true);
      await dropSource(rootPath, old.installationId);
    }
    _activeId = null;
    _active = null;
  }

  /// The preset value that selects one installed theme, and one of its
  /// variants when it has them: `package:<installation id>#<variant>`.
  static String presetOf(String installationId, {String? variant}) =>
      variant == null
      ? '$_packagePrefix$installationId'
      : '$_packagePrefix$installationId#$variant';

  /// The variant a preset names, or null for none — a package without
  /// variants, or its first.
  static String? variantOf(String preset) {
    if (!preset.startsWith(_packagePrefix)) return null;
    final at = preset.indexOf('#');
    return at < 0 ? null : preset.substring(at + 1);
  }

  /// The installation id a preset names, or null when it names something else —
  /// a builtin theme, or the custom one.
  ///
  /// The one place the prefix is known. Written out at each call site instead,
  /// a length that stops matching the prefix turns into a preset that names no
  /// install, which reads as "not installed": the user's theme is reset rather
  /// than reported.
  static String? installationIdOf(String preset) {
    if (!preset.startsWith(_packagePrefix)) return null;
    final at = preset.indexOf('#');
    return preset.substring(_packagePrefix.length, at < 0 ? null : at);
  }

  static const _packagePrefix = 'package:';

  /// The preset naming the theme this app's own appearance settings make up.
  ///
  /// It is not a package, so it has no installation id and no directory, and it
  /// is the value `appThemePreset` held before packages existed — which is why
  /// the spelling is this one. Every comparison against it goes through the
  /// constant: a literal that stops matching the written value reads as "not
  /// the custom theme", and the settings a user arranged would be replaced
  /// without anything reporting it.
  static const customPreset = 'custom';

  /// One installed theme by **installation id** — the digest of the package
  /// bytes, which is also its directory name.
  ///
  /// Not the `id` its manifest declares: that names the theme across versions
  /// and releases, and it is not the digest this looks up, so passing one here
  /// answers null without saying why. [ThemePackage.installationId] is the one
  /// to hand over; see [ThemePackage.id] for the other.
  ///
  /// A package with variants answers [variant], or its first when that is null
  /// or names none it has.
  static ThemePackage? installed(
    String installationId, {
    String? variant,
    String? rootDirectory,
  }) {
    if (!_digestPattern.hasMatch(installationId)) return null;
    if (!ThemeRust.ready) return null;
    final directory = (rootDirectory ?? root).joinPath(installationId);
    try {
      final manifest = _manifestAt(directory);
      if (manifest == null) return null;
      final listed = installedThemeVariants(manifest: manifest);
      if (listed != null) {
        final variants = [for (final v in listed) ThemeVariant(v.key, v.name)];
        final chosen =
            variants.where((v) => v.key == variant).firstOrNull ??
            variants.first;
        return _readInstalled(
          directory.joinPath(_variantsDir).joinPath(chosen.key),
          installationId,
          variant: chosen,
          variants: variants,
        );
      }
      return _readInstalled(directory, installationId);
    } catch (_) {
      return null;
    }
  }

  static String? _manifestAt(String directory) =>
      installedManifest(directory, maxBytes: _maxManifestBytes);

  /// One installed theme, read back by `fl_theme` from the manifest written at
  /// install; the files it names are this side's to find.
  static ThemePackage? _readInstalled(
    String directory,
    String installationId, {
    ThemeVariant? variant,
    List<ThemeVariant> variants = const [],
  }) {
    try {
      final manifest = _manifestAt(directory);
      if (manifest == null) return null;
      final data =
          jsonDecode(
                readInstalledTheme(
                  manifest: manifest,
                  iconFiles: installedIconFiles(directory),
                ),
              )
              as Map<String, dynamic>;
      final background = data['background'] as Map<String, dynamic>;
      final shapes = data['shapes'] as Map<String, dynamic>;
      final splash = data['splash'] as Map<String, dynamic>?;
      final package = ThemePackage(
        installationId: installationId,
        id: data['id'] as String,
        name: data['name'] as String,
        variant: variant,
        variants: variants,
        schemaMin: data['schemaMin'] as int,
        schemaMax: data['schemaMax'] as int,
        mode: data['mode'] as int,
        modes: {
          for (final mode in data['modes'] as List)
            _declaredModes.firstWhere((m) => m.name == mode),
        },
        seed: data['seed'] as int,
        systemColor: data['systemColor'] as bool,
        paletteLight: (data['paletteLight'] as Map).cast<String, int>(),
        paletteDark: (data['paletteDark'] as Map).cast<String, int>(),
        components: ThemeComponents.checked(
          (data['components'] as Map).cast<String, dynamic>(),
          density: data['density'] as String?,
          neededSchema: data['componentsSchema'] as int,
        ),
        iconStyle: IconStyle.parse(data['iconStyle'])!,
        iconFiles: (data['iconFiles'] as Map).cast<String, String>(),
        iconColors: (data['iconColors'] as Map).cast<String, Object>(),
        backgroundStyle: BackgroundStyle.parse(background['style'])!,
        opacity: (background['opacity'] as num).toDouble(),
        blur: (background['blur'] as num).toDouble(),
        backgroundTile: (background['tile'] as num).toDouble(),
        cardRadius: (shapes['card'] as num).toDouble(),
        tileRadius: (shapes['tile'] as num).toDouble(),
        buttonRadius: (shapes['button'] as num).toDouble(),
        directory: directory,
        splash: splash == null
            ? null
            : ThemeSplash(
                color: splash['color'] as Object,
                logo: splash['logo'] as String?,
                duration: splash['duration'] as int,
              ),
      );
      if (package.backgroundPath case final path?
          when !File(path).existsSync()) {
        return null;
      }
      if (package.splashLogoPath case final logo? when !File(logo).existsSync()) {
        return null;
      }
      return package;
    } catch (_) {
      return null;
    }
  }

  /// Removes every installation in [rootDirectory] this build cannot read.
  /// Only for the built-in directory, a copy of the app's own assets: an
  /// installation there that does not read (written by a build with another
  /// format) is never selected again, and as it does not read, no update of
  /// its theme finds it to replace. A user's installations are never removed
  /// for it: they may be read again by the build that wrote them.
  static void _removeUnreadable(String rootDirectory) {
    // Before the reader is loaded nothing reads, and nothing may go.
    if (!ThemeRust.ready) return;
    final directory = Directory(rootDirectory);
    if (!directory.existsSync()) return;
    for (final entry in directory.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = entry.uri.pathSegments.where((part) => part.isNotEmpty).last;
      // Staging directories are not digests; an installation is renamed to
      // its digest only once complete.
      if (!_digestPattern.hasMatch(name)) continue;
      if (installed(name, rootDirectory: rootDirectory) == null) {
        entry.deleteSync(recursive: true);
      }
    }
  }

  static List<ThemePackage> listInstalled({String? rootDirectory}) {
    final directory = Directory(rootDirectory ?? root);
    if (!directory.existsSync()) return [];
    final themes = <ThemePackage>[];
    for (final entry in directory.listSync(followLinks: false)) {
      if (entry is! Directory) continue;
      final installationId = entry.uri.pathSegments
          .where((part) => part.isNotEmpty)
          .last;
      final theme = installed(installationId, rootDirectory: directory.path);
      if (theme != null) themes.add(theme);
    }
    themes.sort((a, b) => a.name.compareTo(b.name));
    return themes;
  }

  /// Every installed theme the picker offers, by preset: one per package, or
  /// one per variant of a package that has them.
  static Map<String, String> installedPresetNames({String? rootDirectory}) => {
    for (final theme in listInstalled(rootDirectory: rootDirectory))
      if (theme.variants.isEmpty)
        presetOf(theme.installationId): theme.name
      else
        for (final variant in theme.variants)
          presetOf(theme.installationId, variant: variant.key):
              '${theme.name} · ${variant.name}',
  };

  /// Deletes one installed theme, answering whether it was there.
  ///
  /// **Safe to call on the theme in use**, which is the only thing that makes a
  /// remove button worth having: deleting it would otherwise leave the app on a
  /// preset whose assets are gone, and [activeTheme] answering null is not a
  /// state anything else in the app draws. The selection is reconciled here
  /// rather than at the next launch, so what a caller can observe afterwards is
  /// a theme that exists.
  ///
  /// Nothing is refused for being in use — a user who wants it gone wants it
  /// gone, and the answer is the default theme, not a dialog that will not
  /// close.
  static Future<bool> remove(
    String installationId, {
    String? rootDirectory,
  }) async {
    if (!_digestPattern.hasMatch(installationId)) return false;
    final directory = Directory(
      (rootDirectory ?? root).joinPath(installationId),
    );
    if (!await directory.exists()) return false;
    await directory.delete(recursive: true);
    await dropSource(rootDirectory ?? root, installationId);

    if (_activeId?.split('#').first == installationId) {
      _activeId = null;
      _active = null;
    }
    reconcileSelection();
    installedChanged.value++;
    return true;
  }

  /// The image drawn for [key]: the chosen icon pack's, else the theme's.
  static String? activeIconPath(String key) {
    if (!ThemeHost.current.icons.draws(key)) return null;
    return ThemeIconPacks.active?.iconPath(key) ?? activeTheme?.iconPath(key);
  }

  /// The color the package whose image [activeIconPath] draws gives [key],
  /// or `null` to follow the ambient one.
  static Color? activeIconColor(String key, ColorScheme scheme) {
    if (!ThemeHost.current.icons.draws(key)) return null;
    final pack = ThemeIconPacks.active;
    if (pack != null && pack.iconFiles.containsKey(key)) {
      return pack.iconColor(key, scheme);
    }
    return activeTheme?.iconColor(key, scheme);
  }

  static ThemePackage? get activeTheme {
    if (preview.value case final theme?) return theme;
    final preset = BuiltinTheme.fromId(ThemeHost.settings.appThemePreset.fetch());
    if (preset != null) return _builtinLoader.loaded(preset);
    final installationId = ThemeHost.settings.appThemePackage.fetch();
    final variant = variantOf(ThemeHost.settings.appThemePreset.fetch());
    final key = variant == null ? installationId : '$installationId#$variant';
    if (_activeId != key) {
      _activeId = key;
      _active = installed(installationId, variant: variant);
    }
    return _active;
  }

  static ThemeMode get effectiveMode =>
      preview.value?.resolveMode(preview.value!.mode) ??
      activeTheme?.resolveMode(ThemeHost.settings.themeMode.fetch()) ??
      defaultTheme.resolveMode(ThemeHost.settings.themeMode.fetch());

  static Map<String, int> activePalette({required bool dark}) {
    final theme = activeTheme;
    return dark
        ? (theme?.paletteDark ?? const {})
        : (theme?.paletteLight ?? const {});
  }

  static ColorScheme applyPalette(ColorScheme base, Map<String, int> palette) =>
      ThemePalette.apply(base, palette);

  static void select(ThemePackage theme, {required String preset}) {
    final settings = ThemeHost.settings;
    settings.themeMode.put(theme.resolveMode(theme.mode).index);
    settings.colorSeed.put(theme.seed);
    settings.useSystemPrimaryColor.put(theme.systemColor);
    settings.appIconStyle.put(theme.iconStyle);
    settings.appThemePackage.put(installationIdOf(preset) ?? '');
    settings.appThemePaletteEnabled.put(true);
    settings.appBackgroundStyle.put(theme.backgroundStyle);
    settings.appBackgroundPath.put(theme.backgroundPath ?? '');
    settings.appBackgroundOpacity.put(theme.opacity);
    settings.appBackgroundBlur.put(theme.blur);
    settings.appBackgroundTile.put(theme.backgroundTile);
    settings.appCardRadius.put(theme.cardRadius);
    settings.appTileRadius.put(theme.tileRadius);
    settings.appButtonRadius.put(theme.buttonRadius);
    settings.appThemePreset.put(preset);
  }

  /// Selects a package, keeping the custom theme it is about to replace.
  ///
  /// The one entry point for "the app switches to this theme", so that every
  /// way in — the preset sheet, the store, an import — leaves the same state
  /// behind. [select] alone overwrites every setting a custom theme is made of,
  /// so the snapshot has to come first.
  static void apply(ThemePackage theme, {String? preset}) {
    if (ThemeHost.settings.appThemePreset.fetch() == customPreset) {
      saveCustomTheme();
    }
    select(theme, preset: preset ?? theme.preset);
  }

  /// Writes the settings a custom theme is made of.
  ///
  /// Read back by the settings page's own reader, which rebuilds the package
  /// from exactly these keys, so the two are one shape in two places and have
  /// to be changed together.
  static void saveCustomTheme() {
    final settings = ThemeHost.settings;
    settings.appCustomBackgroundPath.put(settings.appBackgroundPath.fetch());
    settings.appCustomTheme.put(
      jsonEncode({
        'mode': settings.themeMode.fetch(),
        'seed': settings.colorSeed.fetch(),
        'systemColor': settings.useSystemPrimaryColor.fetch(),
        'icons': settings.appIconStyle.fetch().name,
        'opacity': settings.appBackgroundOpacity.fetch(),
        'blur': settings.appBackgroundBlur.fetch(),
        'card': settings.appCardRadius.fetch(),
        'tile': settings.appTileRadius.fetch(),
        'button': settings.appButtonRadius.fetch(),
      }),
    );
  }

  static void reconcileSelection() {
    final preset = ThemeHost.settings.appThemePreset.fetch();
    if (installationIdOf(preset) case final installationId?
        when installed(installationId) == null) {
      // A backup reinstalls what it can first; see [ThemeBackup.restore].
      _selectDefaultFallback();
    } else if (installationIdOf(preset) == null &&
        preset != customPreset &&
        BuiltinTheme.fromId(preset) == null) {
      // A bundled theme this build no longer carries (the ones that moved to
      // the theme store), or a preset from a newer build: nothing to show it.
      _selectDefaultFallback();
    }
    final background = ThemeHost.settings.appBackgroundPath.fetch();
    if (preset == customPreset &&
        (ThemeHost.settings.appBackgroundStyle.fetch() != BackgroundStyle.image ||
            background.isEmpty ||
            !File(background).existsSync())) {
      _selectDefaultFallback();
    } else if (preset == customPreset) {
      ThemeHost.settings.appThemePackage.put('');
      ThemeHost.settings.appThemePaletteEnabled.put(false);
    }
  }

  static void _selectDefaultFallback() =>
      select(defaultTheme, preset: BuiltinTheme.defaultTheme.id);
}
