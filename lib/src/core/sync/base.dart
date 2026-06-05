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
  const SyncIface();

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
  FutureOr<void> sync({int throttleMilli = 5000, RemoteStorage<I>? rs, int milliDelay = 0}) async {
    if (milliDelay > 0) {
      await Future.delayed(Duration(milliseconds: milliDelay));
    }
    if (throttleMilli == 0) return await _sync(rs);
    Fns.throttle(() => _sync(rs), id: 'SyncIface.sync', duration: throttleMilli);
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
      }
    }

    // Upload merged or new backup
    await Future.delayed(const Duration(milliseconds: 77));
    await backup();
  }
}
