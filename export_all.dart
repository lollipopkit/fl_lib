#!/usr/bin/env dart

import 'dart:convert';
import 'dart:io';

void main() async {
  final exportAll = StringBuffer();
  exportAll.writeln('library;\n');

  // Collect all files to export, organized by category
  final Map<String, List<String>> categories = {
    'Resources': [],
    'Core - Initialization': [],
    'Core - Extensions': [],
    'Core - Utilities': [],
    'Core - Backend': [],
    'Core - Storage': [],
    'Core - Sync': [],
    'Core - Mixins': [],
    'Core - Other': [],
    'Providers': [],
    'Models': [],
    'Views - Pages': [],
    'Views - Widgets': [],
  };

  final skipDartFiles = [
    RegExp(r'\.(g|freezed)\.dart$'),
    RegExp(r'lib/src/core/utils/platform/image_(io|stub|web)\.dart$'),
  ];

  await for (final entity in Directory('lib/src').list(recursive: true)) {
    if (entity is File && entity.path.endsWith('.dart')) {
      // Skip the l10n directory and l10n.dart file.
      if (entity.path.startsWith('l10n')) continue;
      if (skipDartFiles.any(entity.path.contains)) continue;
      if (entity.path == 'lib/src/res/l10n.dart') continue;

      // If first line starts with `part of`, skip it.
      final firstLine = await entity
          .openRead()
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .first;
      if (firstLine.startsWith('part of')) continue;

      final exportPath = entity.path.replaceFirst('lib/', '');

      // Categorize the exports
      if (exportPath.startsWith('src/res/')) {
        categories['Resources']!.add(exportPath);
      } else if (exportPath.contains('src/core/init') ||
          exportPath.contains('src/core/update') ||
          exportPath.contains('src/core/build') ||
          exportPath.contains('src/core/route')) {
        categories['Core - Initialization']!.add(exportPath);
      } else if (exportPath.startsWith('src/core/ext/')) {
        categories['Core - Extensions']!.add(exportPath);
      } else if (exportPath.startsWith('src/core/utils/')) {
        categories['Core - Utilities']!.add(exportPath);
      } else if (exportPath.startsWith('src/core/backend/')) {
        categories['Core - Backend']!.add(exportPath);
      } else if (exportPath.startsWith('src/core/store/')) {
        categories['Core - Storage']!.add(exportPath);
      } else if (exportPath.startsWith('src/core/sync/')) {
        categories['Core - Sync']!.add(exportPath);
      } else if (exportPath.startsWith('src/core/mixin/')) {
        categories['Core - Mixins']!.add(exportPath);
      } else if (exportPath.startsWith('src/core/')) {
        categories['Core - Other']!.add(exportPath);
      } else if (exportPath.startsWith('src/provider/')) {
        categories['Providers']!.add(exportPath);
      } else if (exportPath.startsWith('src/model/')) {
        categories['Models']!.add(exportPath);
      } else if (exportPath.startsWith('src/view/page/')) {
        categories['Views - Pages']!.add(exportPath);
      } else if (exportPath.startsWith('src/view/widget/')) {
        categories['Views - Widgets']!.add(exportPath);
      }
    }
  }

  // Generate exports with comments
  _writeResourcesSection(exportAll, categories['Resources']!);
  _writeCoreSection(exportAll, categories);
  _writeProvidersSection(exportAll, categories['Providers']!);
  _writeModelsSection(exportAll, categories['Models']!);
  _writeViewsSection(exportAll, categories);

  await File('lib/fl_lib.dart').writeAsString(exportAll.toString());
}

void _writeResourcesSection(StringBuffer buffer, List<String> resources) {
  if (resources.isEmpty) return;

  buffer.writeln(
    '// =============================================================================',
  );
  buffer.writeln('// Resources');
  buffer.writeln(
    '// =============================================================================',
  );
  buffer.writeln(
    '// UI constants, themes, syntax highlighting, and other resource definitions',
  );
  buffer.writeln('');

  resources.sort();
  for (final path in resources) {
    buffer.writeln("export '$path';");
  }
  buffer.writeln('');
}

void _writeCoreSection(
  StringBuffer buffer,
  Map<String, List<String>> categories,
) {
  buffer.writeln(
    '// =============================================================================',
  );
  buffer.writeln('// Core Framework');
  buffer.writeln(
    '// =============================================================================',
  );
  buffer.writeln(
    '// Foundation functionality including initialization, extensions, utilities,',
  );
  buffer.writeln(
    '// backend services, storage, synchronization, and platform abstractions',
  );
  buffer.writeln('');

  // Initialization
  final initialization = categories['Core - Initialization']!;
  if (initialization.isNotEmpty) {
    buffer.writeln('// --- Initialization & App Setup ---');
    buffer.writeln(
      '// Library initialization, app updates, build info, and routing',
    );
    initialization.sort();
    for (final path in initialization) {
      buffer.writeln("export '$path';");
    }
    buffer.writeln('');
  }

  // Extensions
  final extensions = categories['Core - Extensions']!;
  if (extensions.isNotEmpty) {
    buffer.writeln('// --- Extensions ---');
    buffer.writeln(
      '// Dart/Flutter type extensions for enhanced APIs and convenience methods',
    );
    extensions.sort();
    for (final path in extensions) {
      buffer.writeln("export '$path';");
    }
    buffer.writeln('');
  }

  // Mixins
  final mixins = categories['Core - Mixins']!;
  if (mixins.isNotEmpty) {
    buffer.writeln('// --- Mixins ---');
    buffer.writeln(
      '// Reusable mixins for common patterns like after-layout callbacks',
    );
    mixins.sort();
    for (final path in mixins) {
      buffer.writeln("export '$path';");
    }
    buffer.writeln('');
  }

  // Utilities
  final utilities = categories['Core - Utilities']!;
  if (utilities.isNotEmpty) {
    buffer.writeln('// --- Utilities ---');
    buffer.writeln(
      '// Platform abstractions, UI helpers, crypto, localization, and common functions',
    );
    utilities.sort();
    for (final path in utilities) {
      buffer.writeln("export '$path';");
    }
    buffer.writeln('');
  }

  // Backend
  final backend = categories['Core - Backend']!;
  if (backend.isNotEmpty) {
    buffer.writeln('// --- Backend & HTTP ---');
    buffer.writeln('// HTTP client, API abstractions, and file caching');
    backend.sort();
    for (final path in backend) {
      buffer.writeln("export '$path';");
    }
    buffer.writeln('');
  }

  // Storage
  final storage = categories['Core - Storage']!;
  if (storage.isNotEmpty) {
    buffer.writeln('// --- Storage ---');
    buffer.writeln(
      '// Data persistence with secure storage, preferences, and database interfaces',
    );
    storage.sort();
    for (final path in storage) {
      buffer.writeln("export '$path';");
    }
    buffer.writeln('');
  }

  // Sync
  final sync = categories['Core - Sync']!;
  if (sync.isNotEmpty) {
    buffer.writeln('// --- Synchronization ---');
    buffer.writeln(
      '// Cloud sync base classes and implementations (iCloud, WebDAV)',
    );
    sync.sort();
    for (final path in sync) {
      buffer.writeln("export '$path';");
    }
    buffer.writeln('');
  }

  // Other Core
  final other = categories['Core - Other']!;
  if (other.isNotEmpty) {
    buffer.writeln('// --- Other Core ---');
    buffer.writeln(
      '// Logging, app links, HTTP overrides, and other core functionality',
    );
    other.sort();
    for (final path in other) {
      buffer.writeln("export '$path';");
    }
    buffer.writeln('');
  }
}

void _writeProvidersSection(StringBuffer buffer, List<String> providers) {
  if (providers.isEmpty) return;

  buffer.writeln(
    '// =============================================================================',
  );
  buffer.writeln('// Providers');
  buffer.writeln(
    '// =============================================================================',
  );
  buffer.writeln(
    '// Riverpod providers for state management and dependency injection',
  );
  buffer.writeln('');

  providers.sort();
  for (final path in providers) {
    buffer.writeln("export '$path';");
  }
  buffer.writeln('');
}

void _writeModelsSection(StringBuffer buffer, List<String> models) {
  if (models.isEmpty) return;

  buffer.writeln(
    '// =============================================================================',
  );
  buffer.writeln('// Models');
  buffer.writeln(
    '// =============================================================================',
  );
  buffer.writeln(
    '// Data models, business logic, error handling, and serialization',
  );
  buffer.writeln('');

  models.sort();
  for (final path in models) {
    buffer.writeln("export '$path';");
  }
  buffer.writeln('');
}

void _writeViewsSection(
  StringBuffer buffer,
  Map<String, List<String>> categories,
) {
  buffer.writeln(
    '// =============================================================================',
  );
  buffer.writeln('// Views');
  buffer.writeln(
    '// =============================================================================',
  );
  buffer.writeln(
    '// UI components including complete pages and reusable widgets',
  );
  buffer.writeln('');

  final pages = categories['Views - Pages']!;
  if (pages.isNotEmpty) {
    buffer.writeln('// --- Pages ---');
    buffer.writeln('// Complete page implementations for common use cases');
    pages.sort();
    for (final path in pages) {
      buffer.writeln("export '$path';");
    }
    buffer.writeln('');
  }

  final widgets = categories['Views - Widgets']!;
  if (widgets.isNotEmpty) {
    buffer.writeln('// --- Widgets ---');
    buffer.writeln('// Reusable UI components and specialized widgets');
    widgets.sort();
    for (final path in widgets) {
      buffer.writeln("export '$path';");
    }
    buffer.writeln('');
  }
}
