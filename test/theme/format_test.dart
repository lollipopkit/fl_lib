import 'dart:convert';

import 'package:fl_lib/src/rust/api/theme.dart';
import 'package:fl_lib/theme.dart';
import 'package:flutter_test/flutter_test.dart';

/// Packages are read and checked in Rust (`fl_theme`); what this side still
/// spells out about the format — its constants, and the component tables it
/// draws from — has to say what the reader says, or a field the reader takes
/// is one this side never draws, and a limit shown is not the one applied.
void main() {
  final format = jsonDecode(themeFormat()) as Map<String, dynamic>;
  final components = format['components'] as Map<String, dynamic>;
  final repo = format['repo'] as Map<String, dynamic>;

  Set<String> set(Object? list) => {...(list as List).cast<String>()};

  test('the package constants are the reader\'s', () {
    expect(ThemePackages.supportedSchemaMin, format['supportedSchemaMin']);
    expect(ThemePackages.supportedSchemaMax, format['supportedSchemaMax']);
    expect(ThemePackages.featureSchema, format['featureSchema']);
    expect(ThemePackages.componentSchema, format['componentSchema']);
    expect(ThemePackages.iconSchema, format['iconSchema']);
    expect(ThemePackages.maxPackageBytes, format['maxPackageBytes']);
    expect(ThemePackages.maxVariants, format['maxVariants']);
    expect(ThemePackages.maxNameLength, format['maxNameLength']);
    expect(ThemePackages.maxBackgroundOpacity, format['maxBackgroundOpacity']);
    expect(ThemePackages.maxBackgroundBlur, format['maxBackgroundBlur']);
    expect(ThemePackages.minBackgroundTile, format['minBackgroundTile']);
    expect(ThemePackages.maxBackgroundTile, format['maxBackgroundTile']);
    expect(ThemeSplash.minDuration, format['splashMinDuration']);
    expect(ThemeSplash.maxDuration, format['splashMaxDuration']);
    expect(ThemeSplash.defaultDuration, format['splashDefaultDuration']);
    expect(ThemePackages.sections, set(format['sections']));
    expect(ThemePackages.variantFields, set(format['variantFields']));
    expect(ThemePackages.iconFields, set(format['iconFields']));
    expect(ThemePackages.iconPackSections, set(format['iconPackSections']));
    expect(ThemePackages.iconPackFields, set(format['iconPackFields']));
    expect(ThemePackages.backgroundFields, set(format['backgroundFields']));
    expect(ThemePackages.splashFields, set(format['splashFields']));
    expect(ThemePackages.backgroundImages, set(format['backgroundImages']));
    expect(ThemePackages.splashLogos, set(format['splashLogos']));
    expect(ThemePackages.modes, set(format['modes']));
    expect(ThemePackages.iconStyles, set(format['iconStyles']));
    expect(ThemePackages.backgroundStyles, set(format['backgroundStyles']));
  });

  test('every component field the reader takes is one this side draws', () {
    final kinds = components['kinds'] as Map<String, dynamic>;
    expect(ThemeComponents.kinds.keys.toSet(), kinds.keys.toSet());
    for (final MapEntry(key: name, value: fields) in kinds.entries) {
      expect(
        {
          for (final MapEntry(:key, :value) in ThemeComponents.kinds[name]!.entries)
            key: value.name,
        },
        (fields as Map).cast<String, String>(),
        reason: name,
      );
    }
    final schema2 = components['schema2'] as Map<String, dynamic>;
    expect(ThemeComponents.schema2.keys.toSet(), schema2.keys.toSet());
    for (final MapEntry(key: name, value: fields) in schema2.entries) {
      expect(ThemeComponents.schema2[name], set(fields), reason: name);
    }
    expect(ThemeComponents.states, (components['states'] as List).cast<String>());
    expect(ThemeComponents.stateful, set(components['stateful']));
    expect(ThemeComponents.layoutFields, set(components['layoutFields']));
    expect(
      {for (final d in ThemeDensity.values) d.name},
      set(components['densities']),
    );
    expect(ThemeComponents.maxRadius, components['maxRadius']);
    expect(ThemeComponents.maxBorderWidth, components['maxBorderWidth']);
    expect(ThemeComponents.maxElevation, components['maxElevation']);
    expect(ThemeComponents.maxSize, components['maxSize']);
    expect(ThemeComponents.maxThickness, components['maxThickness']);
    expect(ThemeComponents.maxInset, components['maxInset']);
  });

  test('the store limits are the reader\'s', () {
    expect(ThemeRepoCatalog.schema, repo['catalogSchema']);
    expect(ThemeRepoCatalog.maxRepos, repo['maxRepos']);
    expect(ThemeRepos.maxCatalogBytes, repo['maxCatalogBytes']);
    expect(ThemeRepos.maxArchiveBytes, repo['maxArchiveBytes']);
    expect(ThemeRepos.maxUnpackedBytes, repo['maxUnpackedBytes']);
    expect(ThemeRepos.maxEntryBytes, repo['maxEntryBytes']);
    expect(ThemeRepos.maxTarBytes, repo['maxTarBytes']);
  });
}
