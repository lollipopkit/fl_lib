import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:icloud_storage_plus/icloud_storage.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

part 'webdav.dart';
part 'icloud.dart';
part 'iface.dart';
part 'gist.dart';

/// Impl this interface to provide a backup service.
abstract class SyncIface<T extends Mergeable, I> {
  SyncIface();

  Timer? _syncTimer;
  Completer<void>? _scheduledSync;
  RemoteStorage<I>? _scheduledStorage;
  Future<void>? _syncInFlight;
  RemoteStorage<I>? _pendingStorage;
  bool _syncDirty = false;

  /// Init
  FutureOr<void> init() {}

  /// Load backup from file
  FutureOr<T> fromFile(String path);

  /// Save backup to file
  FutureOr<void> saveToFile();

  /// {@macro remote_storage}
  FutureOr<RemoteStorage<I>?> get remoteStorage;

  /// A cheap fingerprint of what [saveToFile] would write.
  ///
  /// Cheap is the requirement: this is read on every sync, and a sync runs on
  /// every launch. Hashing the produced file is not an option — the payload is
  /// encrypted with a fresh nonce each time, so identical data gives a
  /// different file every time.
  ///
  /// Null disables [_skippable], which is what an implementer with no cheap
  /// answer should return.
  FutureOr<String?> get localVersionTag => null;

  /// The `(remote, local)` pair the last *completed* sync ended on.
  ///
  /// Device-local bookkeeping, and it must not be part of what gets synced —
  /// it describes this device's position, not the user's data.
  FutureOr<(String, String)?> get syncCheckpoint => null;

  /// Records a new [syncCheckpoint]. Called only after a full cycle succeeded.
  FutureOr<void> saveSyncCheckpoint(String remote, String local) {}

  /// Whether both sides are still exactly where the last sync left them.
  ///
  /// The tags are compared for equality only, never for order: an ETag has no
  /// order, and a clock that went backwards would make one wrong anyway.
  ///
  /// Either tag being null means "cannot tell", and that always syncs. So does
  /// having no checkpoint, which is the first sync on this device and the one
  /// that must not be skipped.
  Future<bool> _skippable(
    RemoteStorage<I> rs,
    String? localTag,
    String? remoteTag,
  ) async {
    if (localTag == null || remoteTag == null) return false;
    final last = await syncCheckpoint;
    if (last == null) return false;
    return last.$1 == _remoteKey(rs, remoteTag) && last.$2 == localTag;
  }

  /// The backend's identity travels with its tag.
  ///
  /// Without it, moving a user from one remote to another leaves a checkpoint
  /// describing a file on the old one, and two backends answering the same
  /// string would skip the first sync against the new remote — which is the
  /// one that had everything to do.
  String _remoteKey(RemoteStorage<I> rs, String tag) => '${rs.runtimeType}:$tag';

  /// Backup data to remote storage.
  FutureOr<void> backup([RemoteStorage<I>? rs]) async {
    rs ??= await remoteStorage;
    if (rs == null) {
      Loggers.app.warning('No remote storage available');
      return;
    }

    await saveToFile();
    await rs.upload(relativePath: Paths.bakName);
  }

  /// Sync data with remote storage.
  Future<void> sync({
    int throttleMilli = 5000,
    RemoteStorage<I>? rs,
    int milliDelay = 0,
  }) async {
    if (milliDelay > 0) {
      await Future.delayed(Duration(milliseconds: milliDelay));
    }
    if (throttleMilli == 0) return _enqueueSync(rs);

    _scheduledStorage = rs ?? _scheduledStorage;
    _syncTimer?.cancel();
    final completer = _scheduledSync ??= Completer<void>();
    _syncTimer = Timer(Duration(milliseconds: throttleMilli), () async {
      final storage = _scheduledStorage;
      _scheduledStorage = null;
      _syncTimer = null;
      _scheduledSync = null;
      try {
        await _enqueueSync(storage);
        if (!completer.isCompleted) completer.complete();
      } catch (error, stackTrace) {
        if (!completer.isCompleted) {
          completer.completeError(error, stackTrace);
        }
      }
    });
    return completer.future;
  }

  Future<void> _enqueueSync(RemoteStorage<I>? rs) {
    _pendingStorage = rs ?? _pendingStorage;
    _syncDirty = true;

    final running = _syncInFlight;
    if (running != null) return running;

    final future = _drainSyncQueue();
    _syncInFlight = future;
    return future;
  }

  Future<void> _drainSyncQueue() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      while (_syncDirty) {
        _syncDirty = false;
        final storage = _pendingStorage;
        _pendingStorage = null;
        try {
          await _sync(storage);
        } catch (error, stackTrace) {
          firstError ??= error;
          firstStackTrace ??= stackTrace;
        }
      }
      if (firstError != null) {
        Error.throwWithStackTrace(firstError, firstStackTrace!);
      }
    } finally {
      _syncInFlight = null;
    }
  }

  FutureOr<void> _sync([RemoteStorage<I>? rs]) async {
    rs ??= await remoteStorage;
    if (rs == null) {
      Loggers.app.warning('No remote storage available');
      return;
    }

    // The common case, and the reason this check comes first: a sync runs on
    // every launch, and most launches changed nothing on either side. What
    // used to happen then was a full download, a decrypt, a merge that wrote
    // nothing, a re-encrypt and a full upload. This is one request.
    final localTag = await localVersionTag;
    final beforeRemote = localTag == null
        ? null
        : await rs.versionTag(Paths.bakName);
    if (await _skippable(rs, localTag, beforeRemote)) return;

    final remoteExists = await rs.exists(Paths.bakName);

    // Only try to merge if the remote backup file exists
    if (remoteExists) {
      try {
        await rs.download(relativePath: Paths.bakName);
      } catch (e, s) {
        Loggers.app.warning('Download backup', e, s);
        return;
      }

      try {
        final isoToken = RootIsolateToken.instance;
        final dlBak = await compute((args) {
          final isoToken = args.$2;
          if (isoToken == null) {
            throw Exception('Isolate token is null');
          }
          BackgroundIsolateBinaryMessenger.ensureInitialized(isoToken);
          return fromFile(args.$1);
        }, (Paths.bak, isoToken));
        await dlBak.merge();
      } catch (e, s) {
        Loggers.app.warning('Merge backup', e, s);
        return;
      }
    }

    // Upload merged or new backup
    await Future.delayed(const Duration(milliseconds: 77));
    await backup(rs);

    // Only here, and only on the path that got this far. Every early return
    // above leaves the checkpoint alone, so a failed download or an unreadable
    // remote is retried on the next launch rather than recorded as done.
    //
    // Both tags are re-read: the merge may have changed local data, and the
    // upload should have changed the remote.
    final afterLocal = await localVersionTag;
    if (afterLocal == null) return;
    final afterRemote = await rs.versionTag(Paths.bakName);
    if (afterRemote == null) return;

    // **The remote has to have actually moved.** [backup] is overridable and
    // an override may decline to upload by *returning* rather than throwing —
    // this app's refuses when the remote turned out to be newer than it can
    // read, and `_inheritLegacyRemote` can leave that flag set on a path where
    // nothing clears it. Recording a checkpoint then describes a file this
    // device never wrote, and every later launch matches it and skips: the
    // sync stops for good, silently, which is the one outcome worse than
    // syncing too often.
    //
    // Safe when a backend answers the same tag for a real upload as well: the
    // cycle simply is not recorded, and the next launch does it again. Getting
    // here at all means one of the two sides had changed, so an upload that
    // did happen wrote different bytes.
    if (afterRemote == beforeRemote) {
      Loggers.app.info('Sync checkpoint skipped: the remote did not change');
      return;
    }
    await saveSyncCheckpoint(_remoteKey(rs, afterRemote), afterLocal);
  }
}
