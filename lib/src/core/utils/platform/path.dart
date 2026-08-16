import 'dart:io';

import 'package:fl_lib/src/core/ext/string.dart';
import 'package:fl_lib/src/core/utils/platform/base.dart';
import 'package:path_provider/path_provider.dart';

/// The working directories [Paths] can create under [Paths.doc].
///
/// An app names the ones it uses. The fields of the rest are never assigned,
/// so reading one throws instead of handing back an empty directory that
/// nothing in that app writes to.
enum PathDir { dl, audio, video, img, cache, font }

abstract final class Paths {
  static late final String doc;
  static late final String dl;
  static late final String file;
  static late final String audio;
  static late final String video;
  static late final String img;
  static late final String cache;
  static late final String bakName;
  static late final String bak;
  static late final String font;

  static const _allDirs = {
    PathDir.dl,
    PathDir.audio,
    PathDir.video,
    PathDir.img,
    PathDir.cache,
    PathDir.font,
  };

  /// Await [Paths.init] before using any of the paths
  ///
  /// - [dirs] are the working directories this app uses; see [PathDir].
  static Future<void> init(
    String appName, {
    String? bakName,
    Set<PathDir> dirs = _allDirs,
  }) async {
    doc = await _getDoc(appName);
    file = await _getFile(appName);
    for (final dir in dirs) {
      final path = await _initDir(dir.name);
      switch (dir) {
        case PathDir.dl:
          dl = path;
        case PathDir.audio:
          audio = path;
        case PathDir.video:
          video = path;
        case PathDir.img:
          img = path;
        case PathDir.cache:
          cache = path;
        case PathDir.font:
          font = path;
      }
    }
    final bakName_ = bakName ?? '${appName}_bak.json';
    Paths.bakName = bakName_;
    bak = doc.joinPath(bakName_);
  }

  static Future<String> _getDoc(String appName) async {
    assert(!isWeb);

    if (isAndroid) {
      final dir = await getExternalStorageDirectory();
      if (dir != null) return dir.path;
    }

    if (isLinux || isWindows) {
      final path = switch (Pfs.type) {
        Pfs.linux => Platform.environment['HOME']?.joinPath('.config'),
        Pfs.windows => Platform.environment['APPDATA'],
        _ => null,
      };
      final dir = Directory(path?.joinPath(appName) ?? '.${appName}_data');
      final p = (await dir.create()).path;

      // Move the db data created wrongly in the doc dir
      if (isLinux) {
        // $DOC/*.hive -> $HOME/.config/$APP/*.hive
        final wrong = await getApplicationDocumentsDirectory();
        await for (final file in wrong.list()) {
          if (file is! File || !file.path.endsWith('.hive')) continue;
          file.rename(p.joinPath(file.path.split('/').last));
        }
      }
      return p;
    }

    // macOS without the sandbox: the documents directory is the user's own
    // `~/Documents`, which is no place for a database and the app's working
    // directories — and which macOS gates behind a permission prompt this app
    // would have no way to explain. [file] is the exception, and goes there on
    // purpose; see [_fileGoesToUserDocs].
    //
    // The sandboxed build keeps the documents directory, because there it
    // *is* the container: `~/Library/Containers/<id>/Data/Documents`, private
    // to the app and where every install to date has its data.
    if (isMacOS && !Pfs.isMacSandboxed) {
      final home = Pfs.homeDir;
      if (home != null) {
        final dir = Directory(
          home.joinPath('Library').joinPath('Application Support').joinPath(appName),
        );
        return (await dir.create(recursive: true)).path;
      }
    }

    // macOS (sandboxed) / iOS
    final dir = await getApplicationDocumentsDirectory();
    return dir.path;
  }

  /// Whether [file] belongs in the user's own documents directory rather than
  /// under [doc].
  ///
  /// True on a desktop build that is not confined to a container: [doc] is
  /// `~/Library/Application Support`, `~/.config` or `%APPDATA%` there, which
  /// is the app's to keep and not somewhere the user is expected to open — and
  /// [file] is the one directory holding files that are theirs.
  ///
  /// False in the macOS sandbox and on mobile, where [doc] *is* the app's
  /// container and there is nothing to separate it from.
  static bool get _fileGoesToUserDocs =>
      isLinux || isWindows || (isMacOS && !Pfs.isMacSandboxed);

  /// The user's own files: what was downloaded, and what they put there.
  ///
  /// Resolved but deliberately not created when [_fileGoesToUserDocs]. macOS
  /// gates `~/Documents` behind a permission prompt, and one raised while the
  /// app is still starting has nothing to explain it. [ensureFile] makes the
  /// directory at the point something is about to go in it.
  static Future<String> _getFile(String appName) async {
    if (_fileGoesToUserDocs) {
      final docs = await getApplicationDocumentsDirectory();
      return docs.path.joinPath(appName);
    }
    return _initDir('file');
  }

  /// Creates [file] if it isn't there yet, and answers with it.
  ///
  /// Idempotent. Call it before listing [file] or writing into it — see
  /// [_getFile] for why it is not done at [init].
  static Future<Directory> ensureFile() =>
      Directory(file).create(recursive: true);

  static final temp = Directory.systemTemp.path;

  static Future<String> _initDir(String subPath) async {
    final dir = Directory(doc.joinPath(subPath));
    if (!await dir.exists()) {
      await dir.create();
    }
    return dir.path;
  }
}
