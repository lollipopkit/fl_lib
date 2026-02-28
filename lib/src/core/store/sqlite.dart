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
  late final sqlite3.Database _db;
  final _SqliteListenerManager _listeners = _SqliteListenerManager();
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
    sqlite3.Database? localDb;
    try {
      await _SqlCipherBootstrap.ensureConfigured();
      final cipherKey = await _SqlCipherBootstrap.loadOrCreateKey();

      final path = switch (Pfs.type) {
        Pfs.linux || Pfs.windows => Paths.doc,
        _ => (await getApplicationDocumentsDirectory()).path,
      };
      final file = File(path.joinPath('$dbName.db'));
      localDb = sqlite3.sqlite3.open(file.path);
      _setupCipherDatabase(localDb, cipherKey);

      localDb.execute(_createTable);
      _db = localDb;
      _inited = true;
    } catch (_) {
      if (localDb != null) {
        try {
          localDb.dispose();
        } catch (_) {}
      }
      _initFuture = null;
      rethrow;
    }
  }

  Object? _readNormalizedValue(String key) {
    final rows = _db.select(
      'SELECT value_json FROM $_tableName WHERE key = ? LIMIT 1',
      [key],
    );
    if (rows.isEmpty) return null;
    final rawVal = rows.first['value_json'];
    if (rawVal is! String) return null;
    final parsed = _decodeValue(rawVal);
    if (parsed == null) return null;
    try {
      return _normalizeValue(parsed, path: key);
    } catch (e) {
      dprintWarn('get("$key")', 'normalize failed: $e');
      return null;
    }
  }

  @override
  T? get<T extends Object>(String key, {StoreFromObj<T>? fromObj}) {
    _ensureInited();
    final val = _readNormalizedValue(key);
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
      _db.execute(
        '''
INSERT INTO $_tableName(key, value_json, updated_at)
VALUES (?, ?, ?)
ON CONFLICT(key) DO UPDATE SET
  value_json = excluded.value_json,
  updated_at = excluded.updated_at
''',
        [key, encoded, DateTimeX.timestamp],
      );
      _listeners.notify(key);
      if (updateLastUpdateTsOnSet == true) {
        updateLastUpdateTs(key: key);
      }
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
        dprintWarn('setAll()', 'failed to normalize key `$key`: $e');
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
    try {
      _runInTransaction(() {
        for (final item in prepared) {
          _db.execute(
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
    } catch (e) {
      dprintWarn('setAll()', 'write failed: $e');
      return false;
    }

    _listeners.notifyMany(changed);
    if (updateLastUpdateTsOnSet == true) {
      for (final key in changed) {
        updateLastUpdateTs(key: key);
      }
    }

    return true;
  }

  void _runInTransaction(void Function() runner) {
    _db.execute('BEGIN IMMEDIATE');
    var committed = false;
    try {
      runner();
      _db.execute('COMMIT');
      committed = true;
    } finally {
      if (!committed) {
        try {
          _db.execute('ROLLBACK');
        } catch (_) {}
      }
    }
  }

  @override
  Set<String> keys({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) {
    _ensureInited();
    final rows = _db.select('SELECT key FROM $_tableName');
    final result = <String>{};
    for (final row in rows) {
      final key = row['key'];
      if (key is! String) continue;
      if (!includeInternalKeys && isInternalKey(key)) continue;
      result.add(key);
    }
    return result;
  }

  @override
  bool remove(String key, {bool? updateLastUpdateTsOnRemove}) {
    _ensureInited();
    updateLastUpdateTsOnRemove ??= this.updateLastUpdateTsOnRemove;
    try {
      _db.execute('DELETE FROM $_tableName WHERE key = ?', [key]);
      _listeners.notify(key);
      if (updateLastUpdateTsOnRemove == true) {
        updateLastUpdateTs(key: key);
      }
      return true;
    } catch (e) {
      dprintWarn('remove("$key")', 'delete failed: $e');
      return false;
    }
  }

  @override
  bool clear({bool? updateLastUpdateTsOnClear}) {
    _ensureInited();
    final changed = keys(includeInternalKeys: true).toList(growable: false);
    final lastUpdateTsMap = lastUpdateTs;
    updateLastUpdateTsOnClear ??= this.updateLastUpdateTsOnClear;
    try {
      _runInTransaction(() {
        _db.execute('DELETE FROM $_tableName');
        if (lastUpdateTsMap == null) return;
        _db.execute(
          '''
INSERT INTO $_tableName(key, value_json, updated_at)
VALUES (?, ?, ?)
ON CONFLICT(key) DO UPDATE SET
  value_json = excluded.value_json,
  updated_at = excluded.updated_at
''',
          [lastUpdateTsKey, _encodeValue(lastUpdateTsMap), DateTimeX.timestamp],
        );
      });
      _listeners.notifyMany(changed);
      if (updateLastUpdateTsOnClear == true) {
        updateLastUpdateTs(key: null);
      }
      return true;
    } catch (e) {
      dprintWarn('clear()', 'clear failed: $e');
      return false;
    }
  }

  @override
  Map<String, Object?> getAllMap({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) {
    _ensureInited();
    final rows = _db.select('SELECT key, value_json FROM $_tableName');
    final map = <String, Object?>{};
    for (final row in rows) {
      final key = row['key'];
      final rawVal = row['value_json'];
      if (key is! String || rawVal is! String) continue;
      if (!includeInternalKeys && isInternalKey(key)) continue;

      final parsed = _decodeValue(rawVal);
      if (parsed == null) continue;
      try {
        final normalized = _normalizeValue(parsed, path: key);
        if (normalized == null) continue;
        map[key] = normalized;
      } catch (e) {
        dprintWarn('getAllMap()', 'skip key `$key`: $e');
      }
    }
    return map;
  }

  @override
  Map<String, T> getAllMapTyped<T extends Object>({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
    StoreFromObj<T>? fromStr,
  }) {
    _ensureInited();
    final map = <String, T>{};
    final all = getAllMap(includeInternalKeys: includeInternalKeys);
    for (final entry in all.entries) {
      final key = entry.key;
      final val = entry.value;
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
  }

  Future<void> vacuum() async {
    _ensureInited();
    _db.execute('VACUUM');
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
