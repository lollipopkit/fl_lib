import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/theme/host.dart';

/// The absolute paths the settings keep to files under [Paths.doc], moved onto
/// where [Paths.doc] is now.
///
/// iOS gives an app a new data container when it is installed again or
/// updated, and carries the files across. A path written before that names the
/// old container, where nothing is: a theme's background, the user's own
/// background and the fonts would all be dropped without a word.
abstract final class StoredPaths {
  /// Once at launch, after the stores are open and before anything reads them.
  ///
  /// [alsoRepair] is the app's own paths under [Paths.doc] kept in the same
  /// store, such as a terminal font, repaired the same way.
  static void repair({Iterable<SqlitePropDefault<String>> alsoRepair = const []}) {
    final settings = ThemeHost.settings;
    for (final prop in [
      settings.appBackgroundPath,
      settings.appCustomBackgroundPath,
      settings.appImportedFontPath,
      ...alsoRepair,
    ]) {
      // TODO: remove `formerly` and `files` with `Paths.adoptIosDocuments`.
      final moved = rebase(
        prop.fetch(),
        doc: Paths.doc,
        formerly: Paths.iosFilesApp ? 'Documents' : null,
        files: Paths.iosFilesApp ? Paths.file : null,
      );
      if (moved == null) continue;
      // Not the user's edit: another device syncing this setting has paths of
      // its own either way.
      settings.set(prop.key, moved, updateLastUpdateTsOnSet: false);
    }
  }

  /// [path] under [doc], by what follows [doc]'s own name in it — or
  /// [formerly], the name of a directory [doc] used to be, whose `file/` is
  /// [files] now — when [path] is gone and the file is there. Null when there
  /// is nothing to move.
  static String? rebase(
    String path, {
    required String doc,
    String? formerly,
    String? files,
    bool Function(String path)? exists,
  }) {
    final isFile = exists ?? (p) => File(p).existsSync();
    if (path.isEmpty || isFile(path)) return null;
    String? under(String dirName) {
      final name = '/$dirName/';
      final at = path.indexOf(name);
      return at < 0 ? null : path.substring(at + name.length);
    }

    final candidates = <String>[];
    final docName = doc.getFileName();
    final inDoc = docName == null ? null : under(docName);
    if (inDoc != null) candidates.add(doc.joinPath(inDoc));
    final inFormer = formerly == null ? null : under(formerly);
    if (inFormer != null) {
      if (files != null && inFormer.startsWith('file/')) {
        candidates.add(files.joinPath(inFormer.substring(5)));
      }
      candidates.add(doc.joinPath(inFormer));
    }
    for (final moved in candidates) {
      if (moved != path && isFile(moved)) return moved;
    }
    return null;
  }
}
