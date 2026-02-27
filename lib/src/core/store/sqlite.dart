part of 'iface.dart';

class SqliteStore extends Store {
  SqliteStore(
    this.dbName, {
    super.lastUpdateTsKey,
    super.updateLastUpdateTsOnClear,
    super.updateLastUpdateTsOnRemove,
    super.updateLastUpdateTsOnSet,
  }) : super(name: dbName);

  final String dbName;
  late final _RawSqliteDatabase _db;
  final Map<String, Object?> _cache = <String, Object?>{};
  final Map<String, int> _removeOps = <String, int>{};
  final Map<String, int> _writeVersionByKey = <String, int>{};
  final _SqliteListenerManager _listeners = _SqliteListenerManager();
  Future<void> _pendingWrites = Future<void>.value();
  Future<void>? _initFuture;
  bool _inited = false;

  static const _tableName = 'kv_entries';
  static const _createTable = '''
CREATE TABLE IF NOT EXISTS kv_entries (
  key TEXT PRIMARY KEY NOT NULL,
  value_json TEXT NOT NULL,
  updated_at INTEGER NOT NULL
)
''';

  void _ensureInited() {
    if (_inited) return;
    throw StateError('SqliteStore.init() must be called before use.');
  }

  Future<void> init() {
    if (_inited) return Future<void>.value();
    return _initFuture ??= _initInternal();
  }

  Future<void> _initInternal() async {
    if (_inited) return;
    _RawSqliteDatabase? localDb;
    try {
      await _SqlCipherBootstrap.ensureConfigured();
      final cipherKey = await _SqlCipherBootstrap.loadOrCreateKey();

      final path = switch (Pfs.type) {
        Pfs.linux || Pfs.windows => Paths.doc,
        _ => (await getApplicationDocumentsDirectory()).path,
      };
      final file = File(path.joinPath('$dbName.db'));
      localDb = _RawSqliteDatabase(file: file, cipherKey: cipherKey);

      await localDb.customStatement(_createTable);
      await _reloadCache(localDb);
      _db = localDb;
      _inited = true;
    } catch (_) {
      if (localDb != null) {
        try {
          await localDb.close();
        } catch (_) {}
      }
      _initFuture = null;
      rethrow;
    }
  }

  Future<void> _reloadCache(_RawSqliteDatabase db) async {
    final rows = await db
        .customSelect('SELECT key, value_json FROM $_tableName')
        .get();
    _cache.clear();
    for (final row in rows) {
      final rawKey = row.data['key'];
      final rawVal = row.data['value_json'];
      if (rawKey is! String || rawVal is! String) continue;
      final parsed = _decodeValue(rawVal);
      try {
        final normalized = _normalizeValue(parsed, path: rawKey);
        if (normalized == null) {
          dprintWarn(
            '_reloadCache()',
            'skip key "$rawKey": normalized value is null',
          );
          continue;
        }
        _cache[rawKey] = normalized;
      } catch (e) {
        dprintWarn('_reloadCache()', 'skip key "$rawKey": $e');
      }
    }
  }

  @override
  T? get<T extends Object>(String key, {StoreFromObj<T>? fromObj}) {
    _ensureInited();
    final val = _cache[key];
    if (val == null) return null;
    if (val is T) return val;

    if (fromObj != null) {
      try {
        final converted = fromObj(val);
        if (converted is T) return converted;
      } catch (_) {
        dprintWarn('get("$key")', 'fromObj failed for key "$key"');
      }
    }

    dprintWarn('get("$key")', 'is: ${val.runtimeType}');
    return null;
  }

  /// Queues a write with optimistic cache update.
  ///
  /// Returning `true` means the write is queued, not that DB persistence has
  /// completed. If persistence confirmation is required, await [flush].
  ///
  /// On DB failure, `_enqueueWrite(onError: ...)` rolls back cache changes and
  /// notifies listeners.
  @override
  bool set<T extends Object>(
    String key,
    T val, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  }) {
    _ensureInited();
    updateLastUpdateTsOnSet ??= this.updateLastUpdateTsOnSet;
    try {
      final raw = toObj != null ? toObj(val) : val;
      if (raw == null) {
        dprintWarn('set("$key")', 'toObj returned null');
        return false;
      }

      final normalized = _normalizeValue(raw, path: key);
      if (normalized == null) {
        dprintWarn('set("$key")', 'normalized value is null');
        return false;
      }

      final encoded = _encodeValue(normalized);
      final hadPrevious = _cache.containsKey(key);
      final previous = _cache[key];
      final capturedVersion = _nextWriteVersion(key);
      _cache[key] = normalized;
      _listeners.notify(key);
      _enqueueWrite(
        () async {
          await _db.customStatement(
            '''
INSERT INTO $_tableName(key, value_json, updated_at)
VALUES (?, ?, ?)
ON CONFLICT(key) DO UPDATE SET
  value_json = excluded.value_json,
  updated_at = excluded.updated_at
''',
            [key, encoded, DateTimeX.timestamp],
          );
        },
        onSuccess: () {
          if (_writeVersionByKey[key] != capturedVersion) return;
          if (updateLastUpdateTsOnSet == true) {
            updateLastUpdateTs(key: key);
          }
        },
        onError: (e, _) {
          if (_writeVersionByKey[key] != capturedVersion) return;
          if (hadPrevious) {
            _cache[key] = previous;
          } else {
            _cache.remove(key);
          }
          dprintWarn('set("$key")', 'db write failed, rolled back cache: $e');
          _listeners.notify(key);
        },
      );
      return true;
    } catch (e) {
      dprintWarn('set("$key")', 'write failed: $e');
      return false;
    }
  }

  @override
  bool setAll<T extends Object>(
    Map<String, T> map, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  }) {
    _ensureInited();
    updateLastUpdateTsOnSet ??= this.updateLastUpdateTsOnSet;
    final prepared = <(String, Object, String, int)>[];
    for (final entry in map.entries) {
      final key = entry.key;
      final val = entry.value;
      final raw = toObj != null ? toObj(val) : val;
      if (raw == null) {
        dprintWarn('setAll()', 'toObj returned null for key `$key`');
        return false;
      }
      Object? normalized;
      try {
        normalized = _normalizeValue(raw, path: key);
      } catch (e) {
        dprintWarn(
          'setAll()',
          'failed to normalize key `$key`: $e',
        );
        return false;
      }
      if (normalized == null) {
        dprintWarn('setAll()', 'normalized value is null on `$key`');
        return false;
      }
      prepared.add((
        key,
        normalized,
        _encodeValue(normalized),
        DateTimeX.timestamp,
      ));
    }

    if (prepared.isEmpty) return true;

    final changed = prepared.map((item) => item.$1).toList(growable: false);
    final hadPrevious = <String, bool>{};
    final previousValues = <String, Object?>{};
    final capturedVersions = <String, int>{};
    for (final item in prepared) {
      final key = item.$1;
      hadPrevious[key] = _cache.containsKey(key);
      previousValues[key] = _cache[key];
      capturedVersions[key] = _nextWriteVersion(key);
      _cache[key] = item.$2;
    }
    _listeners.notifyMany(changed);

    _enqueueWrite(
      () async {
        await _runInTransaction(() async {
          for (final item in prepared) {
            await _db.customStatement(
              '''
INSERT INTO $_tableName(key, value_json, updated_at)
VALUES (?, ?, ?)
ON CONFLICT(key) DO UPDATE SET
  value_json = excluded.value_json,
  updated_at = excluded.updated_at
''',
              [item.$1, item.$3, item.$4],
            );
          }
        });
      },
      onSuccess: () {
        if (updateLastUpdateTsOnSet == true) {
          for (final key in changed) {
            if (_writeVersionByKey[key] != capturedVersions[key]) continue;
            updateLastUpdateTs(key: key);
          }
        }
      },
      onError: (e, _) {
        final rolledBackKeys = <String>[];
        for (final item in prepared) {
          final key = item.$1;
          if (_writeVersionByKey[key] != capturedVersions[key]) continue;
          if (hadPrevious[key] == true) {
            _cache[key] = previousValues[key];
          } else {
            _cache.remove(key);
          }
          rolledBackKeys.add(key);
        }
        if (rolledBackKeys.isEmpty) return;
        dprintWarn('setAll()', 'db write failed, rolled back cache: $e');
        _listeners.notifyMany(rolledBackKeys);
      },
    );

    return true;
  }

  Future<void> _runInTransaction(Future<void> Function() runner) async {
    await _db.customStatement('BEGIN IMMEDIATE');
    var committed = false;
    try {
      await runner();
      await _db.customStatement('COMMIT');
      committed = true;
    } finally {
      if (!committed) {
        try {
          await _db.customStatement('ROLLBACK');
        } catch (_) {}
      }
    }
  }

  @override
  Set<String> keys({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) {
    _ensureInited();
    if (includeInternalKeys) return _cache.keys.toSet();
    return _cache.keys.where((key) => !isInternalKey(key)).toSet();
  }

  @override
  bool remove(String key, {bool? updateLastUpdateTsOnRemove}) {
    _ensureInited();
    final opId = (_removeOps[key] ?? 0) + 1;
    _removeOps[key] = opId;
    _nextWriteVersion(key);
    final hadKey = _cache.containsKey(key);
    final previousValue = _cache[key];
    _cache.remove(key);
    _listeners.notify(key);
    updateLastUpdateTsOnRemove ??= this.updateLastUpdateTsOnRemove;
    _enqueueWrite(
      () async {
        await _db.customStatement('DELETE FROM $_tableName WHERE key = ?', [
          key,
        ]);
      },
      onSuccess: () {
        final currentOpId = _removeOps[key];
        if (currentOpId != opId) return;
        try {
          if (updateLastUpdateTsOnRemove == true) {
            updateLastUpdateTs(key: key);
          }
        } finally {
          if (_removeOps[key] == opId) {
            _removeOps.remove(key);
          }
        }
      },
      onError: (e, _) {
        final currentOpId = _removeOps[key];
        final isCurrent = currentOpId == opId;
        if (!isCurrent) return;
        if (isCurrent && !_cache.containsKey(key) && hadKey) {
          _cache[key] = previousValue;
        }
        dprintWarn('remove("$key")', 'db delete failed, rolled back cache: $e');
        try {
          _listeners.notify(key);
        } finally {
          if (_removeOps[key] == opId) {
            _removeOps.remove(key);
          }
        }
      },
    );
    return true;
  }

  @override
  bool clear({bool? updateLastUpdateTsOnClear}) {
    _ensureInited();
    final oldCache = Map<String, Object?>.from(_cache);
    final lastUpdateTsMap = oldCache[lastUpdateTsKey];
    final changed = oldCache.keys.toList(growable: false);
    final clearCapturedVersions = <String, int>{};
    for (final key in changed) {
      clearCapturedVersions[key] = _nextWriteVersion(key);
    }

    _cache.clear();
    if (lastUpdateTsMap != null) {
      _cache[lastUpdateTsKey] = lastUpdateTsMap;
    }
    _listeners.notifyMany(changed);

    updateLastUpdateTsOnClear ??= this.updateLastUpdateTsOnClear;
    _enqueueWrite(
      () async {
        await _runInTransaction(() async {
          await _db.customStatement('DELETE FROM $_tableName');
          if (lastUpdateTsMap == null) return;
          await _db.customStatement(
            '''
INSERT INTO $_tableName(key, value_json, updated_at)
VALUES (?, ?, ?)
ON CONFLICT(key) DO UPDATE SET
  value_json = excluded.value_json,
  updated_at = excluded.updated_at
''',
            [
              lastUpdateTsKey,
              _encodeValue(lastUpdateTsMap),
              DateTimeX.timestamp,
            ],
          );
        });
      },
      onSuccess: () {
        if (updateLastUpdateTsOnClear == true) {
          updateLastUpdateTs(key: null);
        }
      },
      onError: (e, _) {
        final restoredKeys = <String>[];
        for (final entry in oldCache.entries) {
          final key = entry.key;
          if (_writeVersionByKey[key] != clearCapturedVersions[key]) continue;
          _cache[key] = entry.value;
          restoredKeys.add(key);
        }
        dprintWarn('clear()', 'db clear failed, rolled back cache: $e');
        if (restoredKeys.isNotEmpty) {
          _listeners.notifyMany(restoredKeys);
        }
      },
    );
    return true;
  }

  int _nextWriteVersion(String key) {
    final next = (_writeVersionByKey[key] ?? 0) + 1;
    _writeVersionByKey[key] = next;
    return next;
  }

  @override
  Map<String, Object?> getAllMap({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) {
    _ensureInited();
    final keys = this.keys(includeInternalKeys: includeInternalKeys);
    return Map<String, Object?>.fromEntries(
      keys.map((key) => MapEntry(key, _cache[key])),
    );
  }

  @override
  Map<String, T> getAllMapTyped<T extends Object>({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
    StoreFromObj<T>? fromStr,
  }) {
    _ensureInited();
    final keys = this.keys(includeInternalKeys: includeInternalKeys);
    final map = <String, T>{};
    for (final key in keys) {
      final val = _cache[key];
      if (val is T) {
        map[key] = val;
        continue;
      }
      if (fromStr != null) {
        try {
          final converted = fromStr(val);
          if (converted is T) {
            map[key] = converted;
          }
        } catch (e) {
          dprintWarn('getAllMapTyped()', 'convert `$key` failed: $e');
        }
      }
    }
    return map;
  }

  Future<void> flush() async {
    _ensureInited();
    await _pendingWrites;
  }

  Future<void> vacuum() async {
    _ensureInited();
    await flush();
    await _db.customStatement('VACUUM');
  }

  SqliteProp<T> property<T extends Object>(
    String key, {
    bool updateLastModified = true,
    StoreFromObj<T>? fromObj,
    StoreToObj<T>? toObj,
  }) {
    return SqliteProp<T>(
      this,
      key,
      updateLastUpdateTsOnSetProp: updateLastModified,
      fromObj: fromObj,
      toObj: toObj,
    );
  }

  SqlitePropDefault<T> propertyDefault<T extends Object>(
    String key,
    T defaultValue, {
    bool updateLastModified = StoreDefaults.defaultUpdateLastUpdateTs,
    StoreFromObj<T>? fromObj,
    StoreToObj<T>? toObj,
  }) {
    return SqlitePropDefault<T>(
      this,
      key,
      defaultValue,
      updateLastUpdateTsOnSetProp: updateLastModified,
      fromObj: fromObj,
      toObj: toObj,
    );
  }

  SqlitePropDefault<List<T>> listProperty<T extends Object>(
    String key, {
    List<T> defaultValue = const [],
    bool updateLastModified = StoreDefaults.defaultUpdateLastUpdateTs,
    StoreFromObj<List<T>>? fromObj,
    StoreToObj<List<T>>? toObj,
  }) {
    return SqlitePropDefault<List<T>>(
      this,
      key,
      defaultValue,
      updateLastUpdateTsOnSetProp: updateLastModified,
      fromObj: fromObj ?? (obj) => List<T>.from(obj as Iterable),
      toObj: toObj,
    );
  }

  void _enqueueWrite(
    Future<void> Function() writer, {
    void Function()? onSuccess,
    void Function(Object error, StackTrace stackTrace)? onError,
  }) {
    _pendingWrites = _pendingWrites.then((_) async {
      try {
        await writer();
      } catch (e, s) {
        try {
          onError?.call(e, s);
        } catch (errorInCallback, callbackStack) {
          dprintWarn('writeQueue.onError', '$errorInCallback\n$callbackStack');
        }
        dprintWarn('writeQueue', '$e\n$s');
        return;
      }

      try {
        onSuccess?.call();
      } catch (e, s) {
        dprintWarn('writeQueue.onSuccess', '$e\n$s');
      }
    });
  }

  String _encodeValue(Object value) {
    return json.encode(value);
  }

  Object? _decodeValue(String valueJson) {
    try {
      return json.decode(valueJson);
    } catch (e) {
      dprintWarn('decodeValue()', '$e');
      return null;
    }
  }

  Object? _normalizeValue(Object? value, {String path = r'$'}) {
    if (value == null) return null;
    if (value is bool || value is int || value is double || value is String) {
      return value;
    }
    if (value is Enum) return value.name;
    if (value is List) {
      return List<Object?>.unmodifiable(
        List<Object?>.generate(
          value.length,
          (index) => _normalizeValue(value[index], path: '$path[$index]'),
        ),
      );
    }
    if (value is Map) {
      final normalizedMap = <String, Object?>{};
      for (final entry in value.entries) {
        final mapKey = entry.key.toString();
        normalizedMap[mapKey] = _normalizeValue(
          entry.value,
          path: '$path.$mapKey',
        );
      }
      return Map<String, Object?>.unmodifiable(normalizedMap);
    }
    try {
      final dynamic obj = value;
      final jsonObj = obj.toJson();
      return _normalizeValue(jsonObj, path: '$path.toJson()');
    } on UnsupportedError {
      rethrow;
    } on ArgumentError {
      rethrow;
    } catch (_) {
      throw UnsupportedError(
        'Unsupported value type at `$path`: ${value.runtimeType}',
      );
    }
  }
}

class SqliteProp<T extends Object> extends StoreProp<T> {
  @override
  final SqliteStore store;

  SqliteProp(
    this.store,
    super.key, {
    super.updateLastUpdateTsOnSetProp,
    super.fromObj,
    super.toObj,
  });

  T? fetch() => get();

  void put(T value) => set(value);

  void delete() => remove();

  @override
  ValueListenable<T?> listenable() {
    return SqlitePropListenable<T>(this, key);
  }
}

final class SqlitePropDefault<T extends Object> extends StorePropDefault<T>
    implements SqliteProp<T> {
  @override
  final SqliteStore store;

  SqlitePropDefault(
    this.store,
    super.key,
    super.defaultValue, {
    super.updateLastUpdateTsOnSetProp,
    super.fromObj,
    super.toObj,
  });

  @override
  ValueListenable<T> listenable() {
    return SqlitePropDefaultListenable<T>(this, key, defaultValue);
  }

  @override
  T fetch() => get();

  @override
  void put(T value) => set(value);

  @override
  void delete() => remove();
}

class SqlitePropListenable<T extends Object> extends ValueListenable<T?> {
  SqlitePropListenable(this.prop, this.key);

  final SqliteProp<T> prop;
  final String key;

  @override
  void addListener(VoidCallback listener) {
    prop.store._listeners.add(key, listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    prop.store._listeners.remove(key, listener);
  }

  @override
  T? get value => prop.get();
}

class SqlitePropDefaultListenable<T extends Object> extends ValueListenable<T> {
  SqlitePropDefaultListenable(this.prop, this.key, this.defaultValue);

  final SqlitePropDefault<T> prop;
  final String key;
  final T defaultValue;

  @override
  void addListener(VoidCallback listener) {
    prop.store._listeners.add(key, listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    prop.store._listeners.remove(key, listener);
  }

  @override
  T get value => prop.get();
}

class _SqliteListenerManager {
  final Map<String, Set<VoidCallback>> _keyListeners = {};

  void add(String key, VoidCallback listener) {
    _keyListeners.putIfAbsent(key, () => <VoidCallback>{}).add(listener);
  }

  void remove(String key, VoidCallback listener) {
    final listeners = _keyListeners[key];
    if (listeners == null) return;
    listeners.remove(listener);
    if (listeners.isEmpty) {
      _keyListeners.remove(key);
    }
  }

  void notify(String key) {
    final listeners = _keyListeners[key];
    if (listeners == null || listeners.isEmpty) return;
    final snapshot = List<VoidCallback>.of(listeners);
    for (final listener in snapshot) {
      try {
        listener();
      } catch (e, s) {
        debugPrint('notify("$key") listener error: $e\n$s');
      }
    }
  }

  void notifyMany(Iterable<String> keys) {
    for (final key in keys.toSet()) {
      try {
        notify(key);
      } catch (e, s) {
        debugPrint('notifyMany("$key") error: $e\n$s');
      }
    }
  }
}

class _RawSqliteDatabase extends GeneratedDatabase {
  _RawSqliteDatabase({required File file, required String cipherKey})
    : super(
        NativeDatabase(
          file,
          setup: (database) => _setupCipherDatabase(database, cipherKey),
        ),
      );

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
}

void _setupCipherDatabase(sqlite3.Database database, String cipherKey) {
  final escapedKey = cipherKey.replaceAll("'", "''");
  database.execute("PRAGMA key = '$escapedKey';");

  final cipherVersionRows = database.select('PRAGMA cipher_version;');
  final cipherVersion =
      cipherVersionRows.isEmpty || cipherVersionRows.first.values.isEmpty
      ? null
      : cipherVersionRows.first.values.first?.toString();
  if (cipherVersion == null || cipherVersion.isEmpty) {
    throw StateError(
      'SQLCipher is not available. Please ensure sqlcipher_flutter_libs is linked correctly.',
    );
  }

  database.execute('PRAGMA foreign_keys = ON;');
  database.execute('PRAGMA journal_mode = WAL;');
}

abstract final class _SqlCipherBootstrap {
  static bool _configured = false;
  static String? _cipherKey;
  static Completer<String>? _pendingLoad;

  static Future<void> ensureConfigured() async {
    if (_configured) return;
    await applyWorkaroundToOpenSqlCipherOnOldAndroidVersions();
    sqlite_open.open.overrideFor(
      sqlite_open.OperatingSystem.android,
      openCipherOnAndroid,
    );
    _configured = true;
  }

  static Future<String> loadOrCreateKey() async {
    final cached = _cipherKey;
    if (cached != null) return cached;

    final pending = _pendingLoad;
    if (pending != null) return pending.future;

    final completer = Completer<String>();
    _pendingLoad = completer;
    try {
      final existing = await SecureStoreProps.sqlitePwd.read();
      if (existing != null && existing.isNotEmpty) {
        _cipherKey = existing;
        completer.complete(existing);
        return existing;
      }

      final oldHiveKey = await SecureStoreProps.hivePwd.read();
      final generated = oldHiveKey?.isNotEmpty == true
          ? oldHiveKey!
          : _generateKey();
      await SecureStoreProps.sqlitePwd.write(generated);
      _cipherKey = generated;
      completer.complete(generated);
      return generated;
    } catch (e, s) {
      completer.completeError(e, s);
      rethrow;
    } finally {
      if (identical(_pendingLoad, completer)) {
        _pendingLoad = null;
      }
    }
  }

  static String _generateKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}
