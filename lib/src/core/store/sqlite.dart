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
  final _SqliteListenerManager _listeners = _SqliteListenerManager();
  Future<void> _pendingWrites = Future<void>.value();
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

  Future<void> init() async {
    if (_inited) return;
    await _SqlCipherBootstrap.ensureConfigured();
    final cipherKey = await _SqlCipherBootstrap.loadOrCreateKey();

    final path = switch (Pfs.type) {
      Pfs.linux || Pfs.windows => Paths.doc,
      _ => (await getApplicationDocumentsDirectory()).path,
    };
    final file = File(path.joinPath('$dbName.db'));
    _db = _RawSqliteDatabase(file: file, cipherKey: cipherKey);

    await _db.customStatement(_createTable);
    await _reloadCache();
    _inited = true;
  }

  Future<void> _reloadCache() async {
    final rows = await _db
        .customSelect('SELECT key, value_json FROM $_tableName')
        .get();
    _cache.clear();
    for (final row in rows) {
      final rawKey = row.data['key'];
      final rawVal = row.data['value_json'];
      if (rawKey is! String || rawVal is! String) continue;
      final parsed = _decodeValue(rawVal);
      _cache[rawKey] = parsed;
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

      final normalized = _normalizeValue(raw);
      if (normalized == null) {
        dprintWarn('set("$key")', 'unsupported type: ${raw.runtimeType}');
        return false;
      }

      final encoded = _encodeValue(normalized);
      final hadPrevious = _cache.containsKey(key);
      final previous = _cache[key];
      _cache[key] = normalized;
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
          if (updateLastUpdateTsOnSet == true) {
            updateLastUpdateTs(key: key);
          }
          _listeners.notify(key);
        },
        onError: (e, _) {
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
      final normalized = _normalizeValue(raw);
      if (normalized == null) {
        dprintWarn(
          'setAll()',
          'unsupported type on `$key`: ${raw.runtimeType}',
        );
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
    for (final item in prepared) {
      final key = item.$1;
      hadPrevious[key] = _cache.containsKey(key);
      previousValues[key] = _cache[key];
      _cache[key] = item.$2;
    }

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
            updateLastUpdateTs(key: key);
          }
        }
        _listeners.notifyMany(changed);
      },
      onError: (e, _) {
        for (final key in changed) {
          if (hadPrevious[key] == true) {
            _cache[key] = previousValues[key];
          } else {
            _cache.remove(key);
          }
        }
        dprintWarn('setAll()', 'db write failed, rolled back cache: $e');
        _listeners.notifyMany(changed);
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
    final hadKey = _cache.containsKey(key);
    final previousValue = _cache[key];
    _cache.remove(key);
    updateLastUpdateTsOnRemove ??= this.updateLastUpdateTsOnRemove;
    _enqueueWrite(
      () async {
        await _db.customStatement('DELETE FROM $_tableName WHERE key = ?', [
          key,
        ]);
      },
      onSuccess: () {
        if (updateLastUpdateTsOnRemove == true) {
          updateLastUpdateTs(key: key);
        }
        _listeners.notify(key);
      },
      onError: (e, _) {
        if (hadKey) {
          _cache[key] = previousValue;
        }
        dprintWarn('remove("$key")', 'db delete failed, rolled back cache: $e');
        _listeners.notify(key);
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

    _cache.clear();
    if (lastUpdateTsMap != null) {
      _cache[lastUpdateTsKey] = lastUpdateTsMap;
    }

    updateLastUpdateTsOnClear ??= this.updateLastUpdateTsOnClear;
    _enqueueWrite(
      () async {
        await _db.customStatement('DELETE FROM $_tableName');
        if (lastUpdateTsMap != null) {
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
        }
      },
      onSuccess: () {
        if (updateLastUpdateTsOnClear == true) {
          updateLastUpdateTs(key: null);
        }
        _listeners.notifyMany(changed);
      },
      onError: (e, _) {
        _cache
          ..clear()
          ..addAll(oldCache);
        dprintWarn('clear()', 'db clear failed, rolled back cache: $e');
        _listeners.notifyMany(changed);
      },
    );
    return true;
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
        onError?.call(e, s);
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

  Object? _normalizeValue(Object? value) {
    if (value == null) return null;
    if (value is bool || value is int || value is double || value is String) {
      return value;
    }
    if (value is Enum) return value.name;
    if (value is List) {
      return value.map(_normalizeValue).toList(growable: false);
    }
    if (value is Map) {
      final map = <String, Object?>{};
      for (final entry in value.entries) {
        map[entry.key.toString()] = _normalizeValue(entry.value);
      }
      return map;
    }
    try {
      final dynamic obj = value;
      final jsonObj = obj.toJson();
      return _normalizeValue(jsonObj);
    } catch (_) {
      return null;
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
      listener();
    }
  }

  void notifyMany(Iterable<String> keys) {
    for (final key in keys.toSet()) {
      notify(key);
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

    final existing = await SecureStoreProps.sqlitePwd.read();
    if (existing != null && existing.isNotEmpty) {
      _cipherKey = existing;
      return existing;
    }

    final oldHiveKey = await SecureStoreProps.hivePwd.read();
    final generated = oldHiveKey?.isNotEmpty == true
        ? oldHiveKey!
        : _generateKey();
    await SecureStoreProps.sqlitePwd.write(generated);
    _cipherKey = generated;
    return generated;
  }

  static String _generateKey() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return base64UrlEncode(bytes);
  }
}
