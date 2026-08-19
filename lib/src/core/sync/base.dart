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
    try {
      while (_syncDirty) {
        _syncDirty = false;
        final storage = _pendingStorage;
        _pendingStorage = null;
        await _sync(storage);
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
  }
}
