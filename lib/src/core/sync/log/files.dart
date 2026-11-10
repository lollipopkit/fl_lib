import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_lib/src/core/logger.dart';
import 'package:fl_lib/src/core/store/iface.dart';
import 'package:fl_lib/src/core/sync/base.dart';
import 'package:fl_lib/src/core/sync/log/groups.dart';
import 'package:fl_lib/src/core/sync/log/errors.dart';
import 'package:fl_lib/src/core/sync/log/host.dart';
import 'package:fl_lib/src/core/sync/log/keys.dart';
import 'package:fl_lib/src/core/sync/log/recorder.dart';
import 'package:fl_lib/src/rust/api/sync.dart';
import 'package:fl_lib/src/rust/api/sync_engine.dart';
import 'package:flutter/widgets.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// [run] with a path named [name] in a directory of its own, removed after.
Future<T> _withTempFile<T>(String name, Future<T> Function(String path) run) async {
  final dir = await Directory.systemTemp.createTemp('fl-sync-');
  try {
    return await run('${dir.path}/$name');
  } finally {
    await dir.delete(recursive: true);
  }
}

/// The segment sync's folder on WebDAV: `<prefix><folder>/`.
final class WebdavSyncFiles implements SyncFiles {
  WebdavSyncFiles(this._webdav, this.folder);

  /// Read on each call: a new one is made when the settings change, and what
  /// is kept of this one must not hold the old.
  final Webdav Function() _webdav;

  final String folder;

  WebdavClient get _client => _webdav().client ?? (throw StateError('WebDAV is not set up'));

  String get _dir => '${_webdav().prefix}$folder/';

  /// The folder made, for the client it was made with.
  (WebdavClient, Future<void>)? _made;

  Future<void> _mkdir() {
    final client = _client;
    if (_made case (final c, final made) when identical(c, client)) return made;
    final made = client.mkdirAll(_dir).catchError((Object e, StackTrace s) {
      _made = null;
      Error.throwWithStackTrace(e, s);
    });
    _made = (client, made);
    return made;
  }

  static int? _status(Object e) => switch (e) {
    WebdavException(:final statusCode) => statusCode,
    DioException(:final response) => response?.statusCode,
    _ => null,
  };

  @override
  Future<void> write(String name, Uint8List body) async {
    await _mkdir();
    await _client.write('$_dir$name', body);
  }

  @override
  Future<Uint8List?> read(String name) async {
    try {
      return await _client.read('$_dir$name');
    } catch (e) {
      if (_status(e) == 404) return null;
      rethrow;
    }
  }

  @override
  Future<List<({String name, DateTime? at})>> list(String prefix) async {
    final List<WebdavFile> files;
    try {
      files = await _client.readDir(_dir);
    } catch (e) {
      if (_status(e) == 404) return const [];
      rethrow;
    }
    return [
      for (final f in files)
        if (!f.isDir && f.name.startsWith(prefix)) (name: f.name, at: f.modified),
    ];
  }

  @override
  Future<void> delete(String name) async {
    try {
      await _client.remove('$_dir$name');
    } catch (e) {
      if (_status(e) != 404) rethrow;
    }
  }
}

/// The segment sync's folder in the app's iCloud container: `<folder>/`.
final class ICloudSyncFiles implements SyncFiles {
  ICloudSyncFiles(this._icloud, String folder) : _dir = '$folder/';

  final ICloud _icloud;
  final String _dir;

  /// A download iCloud says nothing of for this long fails, and is tried
  /// again at the next sync: the reads are one at a time, and one iCloud
  /// never ended held every later sync behind it.
  static const _downloadIdle = Duration(minutes: 2);

  @override
  Future<void> write(String name, Uint8List body) => _withTempFile(name, (path) async {
    await File(path).writeAsBytes(body, flush: true);
    await _icloud.upload(relativePath: '$_dir$name', localPath: path);
  });

  @override
  Future<Uint8List?> read(String name) => _withTempFile(name, (path) async {
    try {
      await _icloud.download(relativePath: '$_dir$name', localPath: path, idle: _downloadIdle);
    } on TimeoutException {
      rethrow;
    } catch (_) {
      if (!await _icloud.exists('$_dir$name')) return null;
      rethrow;
    }
    return File(path).readAsBytes();
  });

  @override
  Future<List<({String name, DateTime? at})>> list(String prefix) async => [
    for (final f in await _icloud.list())
      if (!f.isDirectory && f.relativePath.startsWith('$_dir$prefix'))
        (name: f.relativePath.substring(_dir.length), at: f.contentChangeDate),
  ];

  @override
  Future<void> delete(String name) => _icloud.delete('$_dir$name');
}

/// The sync key's file beside the segments: `identity.age`. The store does
/// not order writes: a write checks the file just before, and two devices
/// that make a key at the same moment each write theirs, which the next
/// check merges.
final class FilesKeyFile implements SyncKeyFile {
  FilesKeyFile(this._files, this.id);

  final SyncFiles _files;

  static const _name = 'identity.age';

  /// The store's: another store's keys are not taken to it.
  @override
  final String id;

  /// The file itself: a few hundred bytes.
  static String _versionOf(Uint8List body) => base64.encode(body);

  @override
  Future<({Uint8List body, String version})?> read() async {
    final body = await _files.read(_name);
    return body == null ? null : (body: body, version: _versionOf(body));
  }

  /// Only beside nothing synced (no segment, no snapshot): with one there,
  /// its key may not have arrived yet.
  @override
  Future<bool> canCreate() async =>
      !(await _files.list('')).any((f) => f.name.startsWith('seg-') || f.name.startsWith('snap-'));

  @override
  Future<String?> write(Uint8List body, {required String? ifVersion}) async {
    final now = await read();
    if (now?.version != ifVersion) return null;
    await _files.write(_name, body);
    return _versionOf(body);
  }
}

/// The segment sync while the app syncs to WebDAV or iCloud: on this device's
/// edits (after [_debounce]), at launch, on resume, and every [_every] in the
/// foreground, as neither tells of another device's write.
final class FileLogSync {
  /// [remote] is where the app syncs now (null: neither); [folder] the folder
  /// beside its backup (`srvbox_sync`); [webdavAccount] what tells two WebDAV
  /// accounts on one server apart.
  FileLogSync({required this.remote, required this.folder, required this.on, this.webdavAccount, this.changes = const []});

  final RemoteStorage<Object?>? Function() remote;
  final String folder;

  /// Whether WebDAV or iCloud sync is on.
  final bool Function() on;

  final String? Function()? webdavAccount;

  /// What turns [on] or [remote] around, to sync on.
  final List<Listenable> changes;

  static const _debounce = Duration(seconds: 2);
  static const _every = Duration(minutes: 5);

  Future<SyncSegmentEngine>? _opening;

  /// The store [_opening] is of.
  String? _openedFor;
  Timer? _soon;

  final tooNew = ValueNotifier(false);
  final lastFailure = ValueNotifier<Object?>(null);

  ({String id, SyncFiles files})? _storeOf(RemoteStorage<Object?>? rs) => switch (rs) {
    final ICloud icloud => (id: 'icloud:${icloud.containerId}', files: ICloudSyncFiles(icloud, folder)),
    // Named by a keyed hash: no endpoint written to device-local state.
    final Webdav webdav when webdav.client != null => (
      id: 'webdav:${syncBlobName(secret: folder, data: utf8.encode('${webdav.identity}|${webdavAccount?.call() ?? ''}'))}',
      files: WebdavSyncFiles(() => remote() as Webdav? ?? webdav, folder),
    ),
    _ => null,
  };

  /// [rs]'s sync key, opened with the password here: what its segments and
  /// the backup are sealed with.
  Future<SyncKeyHandle> keyOf(RemoteStorage<Object?> rs) {
    final store = _storeOf(rs);
    if (store == null) throw StateError('Not a store of segments: ${rs.runtimeType}');
    return SyncKeyring.ofFiles(FilesKeyFile(store.files, store.id));
  }

  void init() {
    SyncRecorder.onLocal.add(() {
      if (!on()) return;
      _soon?.cancel();
      _soon = Timer(_debounce, () => unawaited(sync()));
    });
    // A category carried or not: every device is read again from its start,
    // and everything here sent, so neither side misses what was left out.
    SyncGroups.changes.addListener(() {
      if (!SqliteDb.isOpen) return;
      final opening = _opening;
      if (opening == null) {
        unawaited(SyncSegmentEngine.forget(host: SyncHost().call));
        return;
      }
      unawaited(opening.then((s) => s.reset()).then((_) => sync(), onError: (Object _) => SyncSegmentEngine.forget(host: SyncHost().call)));
    });
    for (final c in changes) {
      c.addListener(() => unawaited(sync()));
    }
    AppLifecycleListener(onResume: () => unawaited(sync()));
    Timer.periodic(_every, (_) {
      final state = WidgetsBinding.instance.lifecycleState;
      if (state == null || state == AppLifecycleState.resumed || state == AppLifecycleState.inactive) {
        unawaited(sync());
      }
    });
    unawaited(sync());
  }

  /// Reads what other devices wrote, then writes what this one has.
  Future<void> sync() async {
    if (!SqliteDb.isOpen) return;
    final rs = on() ? remote() : null;
    final store = _storeOf(rs);
    if (store?.id != _openedFor) {
      // Off: read again when on. Another store in its place: this one is
      // gone from this device.
      if (_openedFor case final was?) {
        store == null ? SyncKeyring.release(was) : await SyncKeyring.forget(was);
      }
      _opening = null;
      _openedFor = store?.id;
    }
    if (rs == null || store == null) return;
    final SyncSegmentEngine engine;
    try {
      engine = await (_opening ??= _open(rs, store));
      // The password still opens the key: nothing syncs while it does not.
      await keyOf(rs);
    } catch (e, s) {
      _opening = null;
      lastFailure.value = e;
      if (e is! SyncPasswordMismatch && e is! SyncPasswordMissing) {
        Loggers.app.warning('File log sync: opening', e, s);
      }
      return;
    }
    try {
      await syncCall(engine.run);
      lastFailure.value = null;
    } catch (e, s) {
      lastFailure.value = e;
      Loggers.app.warning('File log sync', e, s);
    } finally {
      tooNew.value = engine.tooNew();
    }
  }

  Future<SyncSegmentEngine> _open(RemoteStorage<Object?> rs, ({String id, SyncFiles files}) store) async {
    final key = await keyOf(rs);
    final host = SyncHost(files: store.files);
    await syncCall(() => SyncSegmentEngine.bind(store: store.id, host: host.call));
    return SyncSegmentEngine(key: key, host: host.call);
  }

  /// The key or the store changed: opened again for the next sync.
  void reset() {
    _soon?.cancel();
    _opening = null;
  }
}
