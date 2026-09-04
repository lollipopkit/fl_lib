part of 'base.dart';

/// {@template remote_storage}
/// Remote storage interface.
///
/// All valid internal impls:
///   - [Webdav]
///   - [ICloud]
/// {@endtemplate}
abstract base class RemoteStorage<ListItemType> {
  /// Upload file to remote storage
  ///
  /// {@template remote_storage_upload}
  /// - [relativePath] is the path relative to [docDir],
  /// must not starts with `/`
  /// - [localPath] has higher priority than [relativePath], but only apply
  /// to the local path instead of iCloud path
  ///
  /// Return `(void, null)` if upload success, `(null, Object)` otherwise
  /// {@endtemplate}
  Future<void> upload({required String relativePath, String? localPath});

  /// List files in remote storage
  ///
  /// {@macro remote_storage_upload}
  Future<void> delete(String relativePath);

  /// Download file from remote storage
  ///
  /// {@macro remote_storage_upload}
  Future<void> download({required String relativePath, String? localPath});

  /// Check if a file exists in remote storage
  Future<bool> exists(String relativePath);

  /// List files in remote storage
  Future<List<ListItemType>> list();

  /// Which *configuration* of this backend this is.
  ///
  /// The runtime type is not enough to key a checkpoint on: pointing WebDAV at
  /// a different server, or naming a different gist, leaves the same class
  /// behind. A checkpoint recorded against the old one is then compared with
  /// the new one's tag, and two that happen to answer the same string skip the
  /// first sync against the new remote — which is the one with everything to
  /// do. A modification time and size collide across servers far more easily
  /// than an ETag does.
  ///
  /// Hashed by the caller, so nothing that names an endpoint is written into
  /// device-local preferences a second time.
  ///
  /// Empty means "this backend has one configuration", which is true of none
  /// of them and is the safe default: it reproduces the behaviour of not
  /// having this at all rather than claiming an identity that is not there.
  String get identity => '';

  /// An opaque token that changes when the remote copy of [relativePath] does.
  ///
  /// An ETag where the backend has one, a modification time and size where it
  /// does not. Never compared for order — only for equality with the token the
  /// last completed sync ended on.
  ///
  /// **Null means "assume it changed".** The file is absent, the backend
  /// cannot answer, or the lookup failed: all three take the same branch,
  /// because the two mistakes are not equally bad. Syncing when nothing
  /// changed costs a round trip; skipping a sync that was needed costs the
  /// user an edit.
  ///
  /// Defaulted rather than abstract so an existing implementation keeps
  /// working — it simply never takes the shortcut.
  Future<String?> versionTag(String relativePath) async => null;
}

abstract class Mergeable {
  /// Merge backup with current data
  Future<void> merge({bool force = false});

  /// Merge store with backup data.
  /// 
  /// Returns true if any changes were made to the store.
  static Future<bool> mergeStore({
    required Map<String, Object?> backupData,
    required KvStore store,
    required bool force,
  }) async {
    bool hasChanges = false;
    // Extract the timestamps from the backup data
    final rawLastModTs = backupData[store.lastUpdateTsKey];
    late final Map<String, dynamic> lastModTimeMap;

    if (rawLastModTs is String) {
      // Try parsing JSON string to a map; if that fails, treat it as a single int timestamp
      try {
        final decoded = json.decode(rawLastModTs);
        if (decoded is Map) {
          lastModTimeMap = Map<String, dynamic>.from(decoded);
        } else {
          final tsInt = int.tryParse(rawLastModTs) ?? 0;
          lastModTimeMap = <String, dynamic>{for (final k in backupData.keys.where((k) => k != store.lastUpdateTsKey)) k: tsInt};
        }
      } catch (_) {
        final tsInt = int.tryParse(rawLastModTs) ?? 0;
        lastModTimeMap = <String, dynamic>{for (final k in backupData.keys.where((k) => k != store.lastUpdateTsKey)) k: tsInt};
      }
    } else if (rawLastModTs is int) {
      lastModTimeMap = <String, dynamic>{
        for (final k in backupData.keys.where((k) => k != store.lastUpdateTsKey)) k: rawLastModTs
      };
    } else if (rawLastModTs is Map) {
      lastModTimeMap = Map<String, dynamic>.from(rawLastModTs);
    } else {
      lastModTimeMap = <String, dynamic>{};
    }

    // Get current data timestamps
    final curLastModTimeMap = store.lastUpdateTs ?? <String, int>{};

    // Get current and backup keys (excluding timestamp key)
    final curKeys = (await store.keys(includeInternalKeys: true)).where((key) => key != store.lastUpdateTsKey).toSet();
    final bakKeys = backupData.keys.where((key) => key != store.lastUpdateTsKey).toSet();

    final processedKeys = <String>{};

    Future<void> processKeys(Set<String> keys, bool isBackup) async {
      for (final key in keys) {
        if (processedKeys.contains(key)) continue;
        processedKeys.add(key);

        final bakTs = lastModTimeMap[key] is int ? lastModTimeMap[key] as int : 0;
        final curTs = curLastModTimeMap[key] ?? 0;

        final bakHasKey = bakKeys.contains(key);
        final curHasKey = curKeys.contains(key);

        if (bakHasKey && !curHasKey) {
          if (force || bakTs > curTs) {
            final value = backupData[key];
            if (value != null) {
              await store.set(key, value, updateLastUpdateTsOnSet: false);
              await store.updateLastUpdateTs(ts: bakTs, key: key);
              if (!store.isInternalKey(key)) {
                hasChanges = true;
              }
            }
          }
        } else if (!bakHasKey && curHasKey) {
          if (force || bakTs > curTs) {
            await store.remove(key, updateLastUpdateTsOnRemove: false);
            await store.updateLastUpdateTs(ts: curTs, key: key);
            if (!store.isInternalKey(key)) {
              hasChanges = true;
            }
          }
        } else if (bakHasKey && curHasKey) {
          if (force || bakTs > curTs) {
            final bakValue = backupData[key];
            final curValue = store.get(key);

            if (bakValue != curValue) {
              if (bakValue != null) {
                await store.set(key, bakValue, updateLastUpdateTsOnSet: false);
              } else {
                await store.remove(key, updateLastUpdateTsOnRemove: false);
              }
              await store.updateLastUpdateTs(ts: bakTs, key: key);
              if (!store.isInternalKey(key)) {
                hasChanges = true;
              }
            }
          }
        }
      }
    }

    await processKeys(bakKeys, true);
    await processKeys(curKeys, false);

    if (force) {
      int maxBakTs = 0;
      lastModTimeMap.forEach((key, value) {
        if (value is int && value > maxBakTs) {
          maxBakTs = value;
        }
      });

      if (maxBakTs > 0) {
        await store.updateLastUpdateTs(ts: maxBakTs, key: null);
        hasChanges = true;
      }
    }

    return hasChanges;
  }
}
