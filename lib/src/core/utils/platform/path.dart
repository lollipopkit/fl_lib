import 'dart:io';

import 'package:fl_lib/src/core/ext/string.dart';
import 'package:fl_lib/src/core/utils/platform/base.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:logging/logging.dart';
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
      final path = await _dirPath(dir, appName);
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
      final base = switch (Pfs.type) {
        // XDG's data home. `$XDG_CONFIG_HOME` is for configuration, and a
        // database, an image and a font are not that.
        Pfs.linux => _xdgDir('XDG_DATA_HOME', '.local/share'),
        // Local rather than roaming. `%APPDATA%` is copied to and from a
        // domain server at every logon: it is meant for small settings, and
        // the boxes here grow without bound, are written on every poll, and
        // conflict outright if the same account is signed in on two machines.
        // This app syncs what is worth syncing itself.
        Pfs.windows =>
          Platform.environment['LOCALAPPDATA'] ??
              Platform.environment['APPDATA'],
        _ => null,
      };
      final path = base?.joinPath(appName) ?? '.${appName}_data';

      // Where the released builds put it. `$XDG_CONFIG_HOME` is not consulted
      // for this one on purpose: those builds never read it either, so an
      // install that set it still has its data under `$HOME/.config`.
      //
      // TODO: remove once no install can still be writing the old location.
      await adoptLegacyDoc(
        from: switch (Pfs.type) {
          Pfs.linux => Pfs.homeDir?.joinPath('.config').joinPath(appName),
          Pfs.windows => Platform.environment['APPDATA']?.joinPath(appName),
          _ => null,
        },
        to: path,
      );

      final p = (await Directory(path).create(recursive: true)).path;

      // Move the db data created wrongly in the doc dir
      if (isLinux) {
        // $DOC/*.hive -> $XDG_DATA_HOME/$APP/*.hive
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

  /// One of XDG's base directories, or the default the spec gives for it.
  ///
  /// A relative path in one of these variables is invalid and has to be
  /// ignored, which is why this is not a `??` over the environment.
  static String? _xdgDir(String envName, String defaultSuffix) {
    final env = Platform.environment[envName];
    if (env != null && env.startsWith('/')) return env;
    return Pfs.homeDir?.joinPath(defaultSuffix);
  }

  /// Takes over a data directory a released build left somewhere else.
  ///
  /// A whole-directory rename where that is available: [from] and [to] are
  /// usually both under `$HOME` on Linux and both under `AppData` on Windows,
  /// so it is one operation on one filesystem. `$XDG_DATA_HOME` can point at
  /// another one, and the fallback there copies to `<to>.incoming` and swaps
  /// that in — either way [to] appears whole or not at all, and [from] is
  /// dropped only once it has.
  ///
  /// Does nothing once [to] holds anything, so it runs at most once per
  /// install and never overwrites data this build has since written.
  ///
  /// - [move] is how the rename is attempted, for a test that needs it to
  ///   fail the way a second filesystem does.
  @visibleForTesting
  static Future<void> adoptLegacyDoc({
    required String? from,
    required String to,
    Future<void> Function(Directory legacy, String to)? move,
  }) async {
    if (from == null || from == to) return;
    final staging = Directory('$to.incoming');
    try {
      final legacy = Directory(from);
      if (!await legacy.exists()) return;
      final dest = Directory(to);
      if (await dest.exists()) {
        if (!await dest.list().isEmpty) return;
        // Empty: `rename` takes an empty destination on POSIX and refuses one
        // on Windows, and this has to behave the same on both. Only once
        // there is something to put in its place.
        await dest.delete();
      }
      await dest.parent.create(recursive: true);
      // Left by an attempt that died halfway, and no part of it can be
      // trusted.
      if (await staging.exists()) await staging.delete(recursive: true);

      try {
        await (move ?? _renameDir)(legacy, to);
      } on FileSystemException catch (e) {
        Logger.root.info('Rename $from -> $to unavailable, copying: $e');
        await _copyDir(legacy, staging);
        await staging.rename(to);
        await legacy.delete(recursive: true);
      }
      Logger.root.info('Moved $from -> $to');
    } catch (e, s) {
      // The original is untouched until the whole of it is in place, so the
      // app starts on an empty directory rather than not at all, and the next
      // launch tries again. Loud, because the user is looking at an app that
      // appears to have forgotten them.
      Logger.root.warning('Move $from -> $to', e, s);
      try {
        if (await staging.exists()) await staging.delete(recursive: true);
      } catch (_) {}
    }
  }

  static Future<void> _renameDir(Directory legacy, String to) =>
      legacy.rename(to).then((_) {});

  static Future<void> _copyDir(Directory from, Directory to) async {
    await to.create(recursive: true);
    await for (final entity in from.list(followLinks: false)) {
      final name = entity.path.getFileName();
      if (name == null) continue;
      final dest = to.path.joinPath(name);
      switch (entity) {
        case final File file:
          await file.copy(dest);
        case final Directory dir:
          await _copyDir(dir, Directory(dest));
        case final Link link:
          await Link(dest).create(await link.target());
      }
    }
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

  /// Where one of the [dirs] goes: under [doc], unless the platform keeps that
  /// kind of thing in a tree of its own.
  static Future<String> _dirPath(PathDir dir, String appName) async {
    // XDG separates caches from data, so that dropping them does not mean
    // picking through the app's own directory. Everywhere else [doc] already
    // is that directory and there is nothing to separate out.
    //
    // TODO: the released Linux builds made `$doc/cache`, which the move in
    // [adoptLegacyDoc] carries along and nothing reads afterwards. Delete it
    // together with that move.
    if (dir == PathDir.cache && isLinux) {
      final base = _xdgDir('XDG_CACHE_HOME', '.cache');
      if (base != null) {
        final cacheDir = Directory(base.joinPath(appName));
        return (await cacheDir.create(recursive: true)).path;
      }
    }
    return _initDir(dir.name);
  }

  static Future<String> _initDir(String subPath) async {
    final dir = Directory(doc.joinPath(subPath));
    if (!await dir.exists()) {
      await dir.create();
    }
    return dir.path;
  }
}
