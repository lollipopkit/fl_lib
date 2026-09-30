import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:dynamic_color/dynamic_color.dart';
import 'package:file_picker/file_picker.dart';

import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/theme/builtin.dart';
import 'package:fl_lib/src/theme/font.dart';
import 'package:fl_lib/src/theme/host.dart';
import 'package:fl_lib/src/theme/package.dart';
import 'package:fl_lib/src/theme/settings.dart';
import 'package:fl_lib/src/theme/style.dart';
import 'package:fl_lib/src/theme/view/store/page.dart';
import 'package:icons_plus/icons_plus.dart';
import 'package:material_ui/material_ui.dart';

/// One row of the appearance settings: [label] is what a search reads and
/// [build] is what is drawn, built lazily.
///
/// An app lays these out in its own settings page, in its own row type — the
/// shape is the one a searchable settings row needs, so turning one into the
/// other is a field for a field.
final class ThemeSettingRow {
  const ThemeSettingRow(this.label, this.build, {this.keywords});

  final String label;
  final Widget Function() build;

  /// Anything else this row answers to in a search.
  final String? keywords;
}

/// Where an install takes its package from.
///
/// A folder is a directory on this device, which only a desktop can pick, so it
/// is offered behind a platform test rather than refused afterwards.
enum _ThemeInstallSource { file, folder, url }

/// The appearance settings: the theme, the custom theme's parts, and the fonts.
///
/// Built by the settings page that shows them, with its context and its
/// [setState], because a row here changes what the others show — picking the
/// custom preset brings its own rows in.
final class ThemeAppearance {
  ThemeAppearance(
    this.context,
    this.setState, {
    this.storeTarget = NavTarget.nearest,
  });

  final BuildContext context;
  final void Function(VoidCallback fn) setState;

  /// Where the theme store opens: over the whole app, or in the pane the
  /// settings are in — the settings page's layout decides, not this.
  final NavTarget storeTarget;

  ThemeSettings get _setting => ThemeHost.settings;

  /// The theme group: its mode, color and preset, where a theme comes from,
  /// and — while the custom theme is selected — what it is made of.
  List<ThemeSettingRow> themeRows() => [
    _buildThemeMode(),
    _buildAppColor(),
    _buildThemePreset(),
    _buildThemeInstall(),
    if (ThemeHost.current.catalogUrl != null) _buildThemeStore(),
    if (_setting.appThemePreset.fetch() == ThemePackages.customPreset) ...[
      _buildAppIcons(),
      _buildCorners(),
      _buildAppBackground(),
      _buildAppBackgroundOpacity(),
      _buildAppBackgroundBlur(),
    ],
  ];

  /// The font group.
  List<ThemeSettingRow> fontRows() => [
    _buildAppFontFamilies(),
    _buildAppFontImport(),
  ];

  void _saveCustomTheme() => ThemePackages.saveCustomTheme();

  void _markCustomTheme() {
    if (_setting.appThemePreset.fetch() != ThemePackages.customPreset ||
        _setting.appBackgroundStyle.fetch() != BackgroundStyle.image ||
        _setting.appBackgroundPath.fetch().isEmpty) {
      return;
    }
    _setting.appThemePreset.put(ThemePackages.customPreset);
    _saveCustomTheme();
  }

  ThemeSettingRow _buildThemePreset() {
    final label = libL10n.appearancePreset;
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: const Icon(Icons.palette_outlined),
        title: Text(label),
        trailing: _setting.appThemePreset.listenable().listenVal(
          (preset) => Text(
            _presetLabel(BuiltinTheme.fromId(preset)) ??
                switch (ThemePackages.installationIdOf(preset)) {
                  final installationId? =>
                    ThemePackages.installed(
                          installationId,
                          variant: ThemePackages.variantOf(preset),
                        )?.label ??
                        libL10n.invalid,
                  _ => libL10n.custom,
                },
          ),
        ),
        onTap: () async {
          final names = ThemePackages.installedPresetNames();
          final original = _setting.appThemePreset.fetch();
          var open = true;
          var request = 0;
          Future<void> preview(String value) async {
            final current = ++request;
            try {
              final theme = value == original
                  ? null
                  : value == ThemePackages.customPreset
                  ? _readCustomTheme()
                  : switch (ThemePackages.installationIdOf(value)) {
                      final installationId? => ThemePackages.installed(
                        installationId,
                        variant: ThemePackages.variantOf(value),
                      ),
                      _ => await ThemePackages.loadBuiltin(
                        BuiltinTheme.fromId(value)!,
                      ),
                    };
              if (open && current == request) {
                ThemePackages.preview.value = theme;
              }
            } catch (_) {
              if (open && current == request) {
                ThemePackages.preview.value = null;
              }
            }
          }

          String? preset;
          try {
            preset = await showRowsSheet<String>(
              context,
              // The choices and nothing above them. The catalog used to be a
              // row at the top of this sheet as well, which is a way in that
              // leaves the sheet for a page and then comes back to a preset
              // list that no longer matches what was installed there — the
              // store is a row of its own in the appearance page instead.
              rows: (ctx) => [
                for (final value in [
                  ...BuiltinTheme.values.map((theme) => theme.id),
                  ThemePackages.customPreset,
                  ...names.keys,
                ])
                  SheetChoiceTile(
                    title:
                        _presetLabel(BuiltinTheme.fromId(value)) ??
                        (value == ThemePackages.customPreset
                            ? libL10n.custom
                            : names[value] ?? libL10n.invalid),
                    selected: value == original,
                    autofocus: value == original,
                    onFocusChange: (focused) {
                      if (focused) unawaited(preview(value));
                    },
                    onTap: () => Navigator.of(ctx).pop(value),
                  ),
              ],
            );
          } finally {
            open = false;
            ThemePackages.preview.value = null;
          }
          if (!context.mounted) return;
          if (preset == null) return;
          if (preset == ThemePackages.customPreset) {
            if (_setting.appThemePreset.fetch() != ThemePackages.customPreset) {
              await _restoreCustomTheme();
            }
            return;
          }
          if (ThemePackages.installationIdOf(preset)
              case final installationId?) {
            final package = ThemePackages.installed(
              installationId,
              variant: ThemePackages.variantOf(preset),
            );
            if (package == null) {
              Toast.error(libL10n.appearanceInvalidTheme);
              return;
            }
            _applyTheme(package, preset: package.preset);
            return;
          }
          await _applyThemePreset(BuiltinTheme.fromId(preset)!);
        },
      ),
      keywords:
          '${BuiltinTheme.values.map((theme) => theme.label).join(' ')} '
          '${libL10n.defaultLabel} custom theme',
    );
  }

  /// What a bundled theme is called in the picker: "Default" in the user's
  /// language, and the rest by their own names.
  String? _presetLabel(BuiltinTheme? theme) => switch (theme) {
    null => null,
    BuiltinTheme.defaultTheme => libL10n.defaultLabel,
    _ => theme.label,
  };

  /// Opens the catalog, which is reached from its own row in the appearance
  /// page and from nowhere else.
  void _openThemeStore() =>
      ThemeStorePage.route.go(context, target: storeTarget);

  void _applyTheme(ThemePackage package, {String? preset}) {
    ThemePackages.apply(package, preset: preset);
    setState(() {});
    RNodes.app.notify();
  }

  ThemeSettingRow _buildThemeInstall() {
    final label = libL10n.appearanceThemeInstall;
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: const Icon(Icons.install_desktop_outlined),
        title: TipText(
          label,
          '${libL10n.appearanceThemeSchemaRange}: ${ThemePackages.supportedSchemaRange}',
        ),
        trailing: const Icon(Icons.keyboard_arrow_right),
        onTap: () async {
          final source = await context
              .showPickSingleDialog<_ThemeInstallSource>(
            title: label,
            items: [
              _ThemeInstallSource.file,
              if (isDesktop) _ThemeInstallSource.folder,
              _ThemeInstallSource.url,
            ],
            display: (source) => switch (source) {
              _ThemeInstallSource.file => libL10n.file,
              _ThemeInstallSource.folder => libL10n.folder,
              _ThemeInstallSource.url => 'URL',
            },
          );
          if (source == null || !context.mounted) return;
          switch (source) {
            case _ThemeInstallSource.file:
              final picked = await FilePicker.pickFile(
                type: FileType.custom,
                allowedExtensions: ['fsbt'],
              );
              if (picked == null || !context.mounted) return;
              if (await picked.length() > ThemePackages.maxPackageBytes) {
                Toast.error(libL10n.appearanceInvalidTheme);
                return;
              }
              await _completeThemeInstall(
                () async => ThemePackages.install(await picked.readAsBytes()),
              );
            case _ThemeInstallSource.folder:
              final folder = await FilePicker.getDirectoryPath(
                dialogTitle: label,
              );
              if (folder == null || !context.mounted) return;
              await _completeThemeInstall(
                () => ThemePackages.installFolder(folder),
              );
            case _ThemeInstallSource.url:
              final url = await _promptAppText(
                label,
                hint: 'https://…/theme.fsbt',
              );
              if (url == null || url.isEmpty || !context.mounted) return;
              await _completeThemeInstall(() => ThemePackages.installUrl(url));
          }
        },
      ),
      keywords: 'fsbt theme folder URL import schema version',
    );
  }

  ThemeSettingRow _buildThemeStore() {
    final label = libL10n.appearanceThemeStore;
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: const Icon(Icons.storefront_outlined),
        title: Text(label),
        trailing: const Icon(Icons.keyboard_arrow_right),
        onTap: _openThemeStore,
      ),
      keywords: 'theme catalog store repository',
    );
  }

  Future<void> _completeThemeInstall(
    Future<ThemePackage> Function() install,
  ) async {
    final (package, error) = await context.showLoadingDialog<ThemePackage>(
      fn: install,
    );
    if (!context.mounted) return;
    if (error != null || package == null) {
      Loggers.app.warning('Theme installation failed: ${error.runtimeType}');
      Toast.error(libL10n.appearanceInvalidTheme);
      return;
    }
    _applyTheme(package);
    Toast.show(libL10n.success);
  }

  Future<String?> _promptAppText(
    String title, {
    String initial = '',
    String? hint,
  }) async {
    final controller = TextEditingController(text: initial);
    // Disposed with the field, not when the dialog answers: what the answer
    // starts (installing a theme, which rebuilds the app) runs while the
    // dialog is still animating out. See [DisposeWith].
    return (await context.showRoundDialog<String>(
      title: title,
      child: DisposeWith(
        notifiers: [controller],
        child: Input(
          controller: controller,
          autoFocus: true,
          hint: hint,
          onSubmitted: (_) => context.popDialog(controller.text.trim()),
        ),
      ),
      actions: [
        Btn.cancel(),
        Btn.ok(onTap: () => context.popDialog(controller.text.trim())),
      ],
    ))?.trim();
  }

  Future<void> _applyThemePreset(BuiltinTheme preset) async {
    try {
      final theme = await ThemePackages.loadBuiltin(preset);
      if (!context.mounted) return;
      _applyTheme(theme, preset: preset.id);
    } catch (error, stack) {
      Loggers.app.warning('Could not load built-in theme', error, stack);
      if (context.mounted) Toast.error(libL10n.appearanceInvalidTheme);
    }
  }

  ThemePackage _readCustomTheme() {
    final path = _setting.appCustomBackgroundPath.fetch();
    if (!_isOwnedAppBackground(path) || !File(path).existsSync()) {
      throw const FormatException('Custom background is unavailable');
    }
    final data =
        jsonDecode(_setting.appCustomTheme.fetch()) as Map<String, dynamic>;
    final mode = (data['mode'] as num).toInt();
    final seed = (data['seed'] as num).toInt();
    final systemColor = data['systemColor'] as bool;
    final icons = IconStyle.parse(data['icons']);
    final opacity = (data['opacity'] as num).toDouble();
    final blur = (data['blur'] as num).toDouble();
    final card = (data['card'] as num).toDouble();
    final tile = (data['tile'] as num).toDouble();
    final button = (data['button'] as num).toDouble();
    if (mode < 0 || mode > 2 || seed < 0 || seed > 0xffffffff || icons == null) {
      throw const FormatException('Invalid custom theme');
    }
    return ThemePackage(
      installationId: '',
      // The theme this app makes up is the one the preset names, so the two
      // spellings are one value.
      id: ThemePackages.customPreset,
      name: libL10n.custom,
      schemaMin: 1,
      schemaMax: 1,
      mode: mode,
      modes: const {ThemeMode.light, ThemeMode.dark},
      seed: seed,
      systemColor: systemColor,
      paletteLight: const {},
      paletteDark: const {},
      iconStyle: icons,
      // A custom theme is the user's own background and radii, so it carries no
      // package images and no splash: both of those are a package's.
      iconFiles: const {},
      backgroundStyle: BackgroundStyle.image,
      backgroundFile: path,
      directory: '',
      opacity: opacity.clamp(0.0, 0.6),
      blur: blur.clamp(0.0, 30.0),
      cardRadius: card.clamp(0.0, 40.0),
      tileRadius: tile.clamp(0.0, 40.0),
      buttonRadius: button.clamp(0.0, 40.0),
    );
  }

  Future<void> _restoreCustomTheme() async {
    try {
      final theme = _readCustomTheme();
      _applyTheme(theme, preset: ThemePackages.customPreset);
      _setting.appThemePaletteEnabled.put(false);
    } catch (_) {
      await _pickAppBackground();
    }
  }

  ThemeSettingRow _buildAppColor() {
    final label = libL10n.primaryColorSeed;
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: const Icon(Icons.colorize),
        title: Text(label),
        trailing: _setting.colorSeed.listenable().listenVal((_) {
          return ClipOval(
            child: Container(color: UIs.primaryColor, height: 23, width: 23),
          );
        }),
        onTap: _onTapAppColor,
      ),
    );
  }

  /// What each icon family is called. Neither is translated: one is the app's
  /// own set and the other is the one it borrows.
  String _iconStyleLabel(IconStyle style) => switch (style) {
    IconStyle.classic => 'Classic',
    IconStyle.mingcute => 'MingCute',
  };

  ThemeSettingRow _buildAppIcons() {
    final label = libL10n.appearanceIcons;
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: const Icon(Icons.widgets_outlined),
        title: Text(label),
        trailing: _setting.appIconStyle.listenable().listenVal(
          (style) => Text(_iconStyleLabel(style)),
        ),
        onTap: () async {
          final style = await context.showPickSingleDialog<IconStyle>(
            title: label,
            items: IconStyle.values,
            initial: _setting.appIconStyle.fetch(),
            display: _iconStyleLabel,
          );
          if (style == null) return;
          _setting.appIconStyle.put(style);
          _setting.appThemePackage.put('');
          _markCustomTheme();
          unawaited(RNodes.app.notify());
        },
      ),
      keywords: 'icons MingCute Classic',
    );
  }

  ThemeSettingRow _buildCorners() {
    final label = libL10n.appearanceCorners;
    return ThemeSettingRow(
      label,
      () => ExpansionTile(
        key: const PageStorageKey('theme-corners'),
        leading: const Icon(Icons.crop_square),
        title: Text(label),
        shape: const Border(),
        collapsedShape: const Border(),
        children: [
          _buildCornerRow(
            libL10n.appearanceCardCorners,
            Icons.crop_square,
            _setting.appCardRadius,
          ).build(),
          _buildCornerRow(
            libL10n.appearanceTileCorners,
            Icons.view_list_outlined,
            _setting.appTileRadius,
          ).build(),
          _buildCornerRow(
            libL10n.appearanceButtonCorners,
            Icons.smart_button_outlined,
            _setting.appButtonRadius,
          ).build(),
        ],
      ),
      keywords:
          '${libL10n.appearanceCardCorners} ${libL10n.appearanceTileCorners} '
          '${libL10n.appearanceButtonCorners} card tile button radius',
    );
  }

  ThemeSettingRow _buildCornerRow(
    String label,
    IconData icon,
    SqlitePropDefault<double> property,
  ) {
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: property.listenable().listenVal(
          (radius) => Text('${radius.round()}'),
        ),
        onTap: () async {
          final radius = await context.showPickSingleDialog<double>(
            title: label,
            items: [0.0, 6.0, 9.0, 13.0, 20.0, 30.0, 40.0],
            initial: property.fetch(),
            display: (value) => '${value.round()}',
          );
          if (radius == null) return;
          property.put(radius);
          _markCustomTheme();
          unawaited(RNodes.app.notify());
        },
      ),
      keywords: 'card tile button radius',
    );
  }

  ThemeSettingRow _buildAppBackground() {
    final label = libL10n.background;
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: const Icon(Icons.wallpaper_outlined),
        title: Text(label),
        trailing: Text(libL10n.image),
        onTap: _pickAppBackground,
      ),
    );
  }

  Future<void> _pickAppBackground() async {
    final path = await Pfs.pickFilePath();
    if (path == null) return;
    var stage = 'read';
    try {
      final source = File(path);
      if (await source.length() > 8 * 1024 * 1024) {
        throw const FormatException('Image exceeds 8 MB');
      }
      stage = 'decode';
      final buffer = await ui.ImmutableBuffer.fromFilePath(path);
      try {
        final descriptor = await ui.ImageDescriptor.encoded(buffer);
        try {
          if (descriptor.width > 8192 ||
              descriptor.height > 8192 ||
              descriptor.width * descriptor.height > 64 * 1024 * 1024) {
            throw const FormatException('Image resolution exceeds limit');
          }
        } finally {
          descriptor.dispose();
        }
      } finally {
        buffer.dispose();
      }
      stage = 'copy';
      final dest = File(
        Paths.img.joinPath(
          'app_bg_${DateTime.now().microsecondsSinceEpoch}.img',
        ),
      );
      await source.copy(dest.path);
      if (!context.mounted) {
        await dest.delete();
        return;
      }
      final oldPath = _setting.appBackgroundPath.fetch();
      _setting.appThemePackage.put('');
      _setting.appThemePaletteEnabled.put(false);
      _setting.appBackgroundPath.put(dest.path);
      _setting.appBackgroundStyle.put(BackgroundStyle.image);
      // The user's own picture is drawn once, not repeated like a theme's tile.
      _setting.appBackgroundTile.put(0);
      _setting.appThemePreset.put(ThemePackages.customPreset);
      _markCustomTheme();
      setState(() {});
      unawaited(RNodes.app.notify());
      unawaited(_deleteOwnedAppBackground(oldPath));
    } catch (error, stack) {
      Loggers.app.warning('Import background failed at $stage', error, stack);
      if (context.mounted) Toast.error(libL10n.invalid);
    }
  }

  Future<void> _deleteOwnedAppBackground(String path) async {
    if (!_isOwnedAppBackground(path)) return;
    try {
      await File(path).delete();
    } on FileSystemException {
      // The selected image may already have been removed outside the app.
    }
  }

  bool _isOwnedAppBackground(String path) =>
      path.isNotEmpty &&
      File(path).parent.path == Paths.img &&
      File(path).uri.pathSegments.last.startsWith('app_bg_');

  ThemeSettingRow _buildAppBackgroundOpacity() {
    final label = libL10n.opacity;
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: const Icon(Icons.opacity),
        title: Text(label),
        trailing: _setting.appBackgroundOpacity.listenable().listenVal(
          (opacity) => Text('${(opacity * 100).round()}%'),
        ),
        onTap: () async {
          final opacity = await context.showPickSingleDialog<double>(
            title: label,
            items: [0, 0.1, 0.18, 0.3, 0.45, 0.6],
            initial: _setting.appBackgroundOpacity.fetch(),
            display: (value) => '${(value * 100).round()}%',
          );
          if (opacity == null) return;
          _setting.appBackgroundOpacity.put(opacity);
          _markCustomTheme();
          unawaited(RNodes.app.notify());
        },
      ),
    );
  }

  ThemeSettingRow _buildAppBackgroundBlur() {
    final label = libL10n.blurRadius;
    return ThemeSettingRow(
      label,
      () => _setting.appBackgroundStyle.listenable().listenVal(
        (style) => ListTile(
          leading: const Icon(Icons.blur_on),
          title: Text(label),
          enabled:
              style == BackgroundStyle.image &&
              _setting.appBackgroundPath.fetch().isNotEmpty,
          trailing: _setting.appBackgroundBlur.listenable().listenVal(
            (radius) => Text('${radius.round()}'),
          ),
          onTap: () async {
            var radius = _setting.appBackgroundBlur.fetch().clamp(0.0, 30.0);
            final selected = await context.showRoundDialog<double>(
              title: label,
              child: StatefulBuilder(
                builder: (context, setState) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text('${radius.round()}'),
                    Slider(
                      value: radius,
                      min: 0,
                      max: 30,
                      divisions: 30,
                      label: '${radius.round()}',
                      onChanged: (value) => setState(() => radius = value),
                    ),
                  ],
                ),
              ),
              actions: [
                Btn.cancel(),
                Btn.ok(onTap: () => context.popDialog(radius)),
              ],
            );
            if (selected == null) return;
            _setting.appBackgroundBlur.put(selected);
            _markCustomTheme();
            unawaited(RNodes.app.notify());
          },
        ),
      ),
      keywords: 'background blur radius',
    );
  }

  ThemeSettingRow _buildAppFontFamilies() {
    final label = libL10n.appearanceFontFamilies;
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: const Icon(Icons.font_download_outlined),
        title: TipText(label, libL10n.appearanceFontFamiliesTip),
        trailing: _setting.appFontFamilies.listenable().listenVal(
          (_) => ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 180),
            child: Text(
              AppFont.families.isEmpty
                  ? libL10n.system
                  : AppFont.families.join(' → '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        onTap: () async {
          final controller = TextEditingController(
            text: AppFont.families.join('\n'),
          );
          // With the field: the answer rebuilds the whole app while the
          // dialog is still leaving. See [DisposeWith].
          final value = await context.showRoundDialog<String>(
            title: label,
            child: DisposeWith(
              notifiers: [controller],
              child: TextField(
                controller: controller,
                autofocus: true,
                minLines: 4,
                maxLines: 8,
                decoration: InputDecoration(
                  labelText: label,
                  hintText: 'Inter\nNoto Sans\nArial',
                  helperText: libL10n.appearanceFontFamiliesTip,
                ),
              ),
            ),
            actions: [
              Btn.cancel(),
              Btn.ok(onTap: () => context.popDialog(controller.text)),
            ],
          );
          if (value == null || !context.mounted) return;
          AppFont.saveFamilies(value.split(RegExp(r'[\r\n]+')));
          unawaited(RNodes.app.notify());
        },
      ),
      keywords: 'global font fallback families',
    );
  }

  ThemeSettingRow _buildAppFontImport() {
    final label = libL10n.appearanceFontImport;
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: const Icon(Icons.file_download_outlined),
        title: Text(label),
        trailing: _setting.appImportedFontName.listenable().listenVal(
          (name) => name.isEmpty
              ? const Icon(Icons.keyboard_arrow_right)
              : IconButton(
                  tooltip: libL10n.delete,
                  icon: const Icon(Icons.close),
                  onPressed: () async {
                    await AppFont.removeImported();
                    unawaited(RNodes.app.notify());
                  },
                ),
        ),
        onTap: () async {
          final picked = await FilePicker.pickFile(
            type: FileType.custom,
            allowedExtensions: ['ttf', 'otf'],
          );
          if (picked == null || !context.mounted) return;
          final path = picked.path;
          if (path == null || await picked.length() > AppFont.maxBytes) {
            Toast.error(libL10n.invalid);
            return;
          }
          final suggested = picked.name.replaceFirst(
            RegExp(r'\.(ttf|otf)$', caseSensitive: false),
            '',
          );
          final name = await _promptAppText(
            label,
            initial: suggested,
            hint: suggested,
          );
          if (name == null || name.isEmpty || !context.mounted) return;
          final (_, error) = await context.showLoadingDialog<void>(
            fn: () => AppFont.importFile(path, name),
          );
          if (!context.mounted) return;
          if (error != null) {
            Loggers.app.warning('Import app font failed: ${error.runtimeType}');
            Toast.error(libL10n.invalid);
            return;
          }
          unawaited(RNodes.app.notify());
          Toast.show(libL10n.success);
        },
      ),
      keywords: 'TTF OTF font file import',
    );
  }

  void _onTapAppColor() {
    withTextFieldController((ctrl) async {
      ctrl.text = Color(_setting.colorSeed.fetch()).toHex;
      await context.showRoundDialog(
        title: libL10n.primaryColorSeed,
        child: StatefulBuilder(
          builder: (context, setState) {
            final children = <Widget>[
              if (!isIOS)
                DynamicColorBuilder(
                  builder: (light, dark) {
                    final supported = light != null || dark != null;
                    if (!supported) {
                      if (_setting.useSystemPrimaryColor.fetch()) {
                        _setting.useSystemPrimaryColor.put(false);
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          setState(() {});
                        });
                      }
                      return const SizedBox.shrink();
                    }
                    return ListTile(
                      title: Text(libL10n.followSystem),
                      trailing: StoreSwitch(
                        prop: _setting.useSystemPrimaryColor,
                        callback: (_) {
                          _setting.appThemePaletteEnabled.put(false);
                          if (_setting.appThemePreset.fetch() ==
                              ThemePackages.customPreset) {
                            _saveCustomTheme();
                          }
                          RNodes.app.notify();
                          setState(() {});
                        },
                      ),
                    );
                  },
                ),
            ];
            if (!_setting.useSystemPrimaryColor.fetch()) {
              children.add(
                ColorPicker(
                  color: Color(_setting.colorSeed.fetch()),
                  onColorChanged: (c) => ctrl.text = c.toHex,
                ),
              );
            }
            return Column(mainAxisSize: MainAxisSize.min, children: children);
          },
        ),
        actions: [
          Btn.cancel(),
          Btn.ok(onTap: () => _onSaveColor(ctrl.text)),
        ],
      );
    });
  }

  void _onSaveColor(String s) {
    final color = s.fromColorHex;

    if (color == null) {
      Toast.error(libL10n.fail);
      return;
    }

    // Save the color seed to settings
    _setting.colorSeed.put(color.value255);
    _setting.appThemePaletteEnabled.put(false);
    if (_setting.appThemePreset.fetch() == ThemePackages.customPreset) {
      _saveCustomTheme();
    }

    // Only update UIs colors if we're not in system mode
    if (!_setting.useSystemPrimaryColor.fetch()) {
      UIs.primaryColor = color;
      UIs.colorSeed = color;
    }

    RNodes.app.notify();
    // `popDialog`: reached from the colour dialog's OK, with the settings
    // page's `context`.
    context.popDialog();
  }

  ThemeSettingRow _buildThemeMode() {
    final label = libL10n.themeMode;
    final locked = ThemePackages.activeTheme?.lockedMode;
    return ThemeSettingRow(
      label,
      () => ListTile(
        leading: const Icon(MingCute.moon_stars_fill),
        title: Text(label),
        subtitle: locked == null
            ? null
            : Text(
                libL10n.appearanceThemeModeLocked(
                  _buildThemeModeStr(locked.index),
                ),
              ),
        enabled: locked == null,
        onTap: locked != null
            ? null
            : () async {
                final selected = await context.showPickSingleDialog(
                  title: label,
                  items: List.generate(
                    ThemeMode.values.length,
                    (index) => index,
                  ),
                  display: (p0) => _buildThemeModeStr(p0),
                  initial: _setting.themeMode.fetch(),
                );
                if (selected != null) {
                  _setting.themeMode.put(selected);
                  if (_setting.appThemePreset.fetch() ==
                      ThemePackages.customPreset) {
                    _saveCustomTheme();
                  }
                  unawaited(RNodes.app.notify());
                }
              },
        trailing: ValBuilder(
          listenable: _setting.themeMode.listenable(),
          builder: (val) =>
              Text(_buildThemeModeStr(locked?.index ?? val), style: UIs.text15),
        ),
      ),
      keywords: '${libL10n.dark} ${libL10n.bright}',
    );
  }

  String _buildThemeModeStr(int n) {
    switch (n) {
      case 1:
        return libL10n.bright;
      case 2:
        return libL10n.dark;
      default:
        return libL10n.auto;
    }
  }
}
