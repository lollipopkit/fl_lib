part of 'iface.dart';

/// The 32 random bytes every encrypted store on this device is keyed with.
///
/// One secret for the whole app, held by the platform's vault. It is read
/// through [SecureStoreProps.hivePwd] — the name is what shipped installs have
/// in their keychain, and renaming the entry would orphan every existing key.
///
/// TODO: rename to a neutral key once no install can still be on Hive, which
/// is the same moment [HiveStore] can be deleted.
abstract final class _StoreSecret {
  /// Where installs older than [SecureStoreProps] kept the key.
  static const _legacyPrefKey = 'hive_key';

  /// Reads the key, generating one the first time.
  ///
  /// Returns the raw bytes rather than the stored base64, because both callers
  /// want bytes and the encoding is an artifact of the vault taking strings.
  static Future<Uint8List> read() async {
    final existing = await _stored();
    if (existing != null) return base64Url.decode(existing);

    // `Random.secure()` rather than a counter or a hash of anything on the
    // device: this is the only thing standing between a copied `.db` file and
    // its contents.
    final generated = Uint8List.fromList(
      List<int>.generate(32, (_) => Random.secure().nextInt(256)),
    );
    await SecureStoreProps.hivePwd.write(base64UrlEncode(generated));

    // Read back rather than returning `generated`: a write that silently did
    // not land would otherwise produce a database nothing can ever open again.
    final confirmed = await _stored();
    if (confirmed == null) {
      throw StateError('Failed to persist the store encryption key');
    }
    return base64Url.decode(confirmed);
  }

  static Future<String?> _stored() async {
    final fromVault = await SecureStoreProps.hivePwd.read();
    if (fromVault != null) return fromVault;

    // Installs that predate the vault kept it in preferences. Move it across
    // on sight, so this branch stops being reachable for that device.
    final fromPrefs =
        PrefStore.shared.get<String>(_legacyPrefKey) ??
        PrefStore.shared.get<String>('flutter.$_legacyPrefKey');
    if (fromPrefs != null) await SecureStoreProps.hivePwd.write(fromPrefs);
    return fromPrefs;
  }
}

/// The single encrypted database file behind every [SqliteStore].
///
/// One file for all stores rather than one per store: they are opened together
/// at launch and rewritten together by a backup restore, and one connection is
/// what lets that be a single transaction. The `store` column keeps them apart.
abstract final class SqliteDb {
  /// Name on disk. Beside the `.hive` files it replaces, so the two are found
  /// and copied together by a sandbox import and by anyone reading a bug
  /// report.
  static const fileName = 'store.db';

  /// Cipher scheme, named rather than defaulted.
  ///
  /// ChaCha20-Poly1305 is SQLite3MultipleCiphers' own default today. Naming it
  /// means a future release changing that default cannot silently change what
  /// new databases on new installs are encrypted with — existing files record
  /// their scheme in the header and are unaffected either way.
  static const _cipher = 'chacha20';

  static Database? _db;
  static Future<Database>? _opening;

  /// The open database.
  ///
  /// Throws when [open] has not completed. Every caller reaches this through
  /// `SqliteStore.init`, so arriving early is a wiring bug rather than a state
  /// worth recovering from.
  static Database get instance {
    final db = _db;
    if (db == null) throw StateError('SqliteDb.open() has not completed');
    return db;
  }

  static bool get isOpen => _db != null;

  /// Full path of the file, or `null` before it is opened.
  static String? get path => _path;
  static String? _path;

  /// Opens, keys and migrates the database at [dir].
  ///
  /// Concurrent callers share one attempt: `Stores.init` opens every store at
  /// once through `Future.wait`, and two of them racing to key the same file
  /// would make it a coin flip which connection the app ends up holding.
  static Future<Database> open(String dir) {
    final db = _db;
    if (db != null) return Future.value(db);
    return _opening ??= _open(dir).whenComplete(() => _opening = null);
  }

  static Future<Database> _open(String dir) async {
    final key = await _StoreSecret.read();
    final path = dir.joinPath(fileName);
    final db = sqlite3.open(path);

    try {
      // Before the key, and both before anything reads a page: the scheme
      // decides how `PRAGMA key` is interpreted.
      db.execute("PRAGMA cipher = '$_cipher';");

      // Raw key, not a passphrase. The bytes are already 32 bytes of CSPRNG
      // output, so the PBKDF2 pass a quoted string would trigger costs a
      // launch delay and adds nothing. The `x'..'` literal is the only syntax
      // SQLite3MultipleCiphers accepts for this.
      db.execute('PRAGMA key = "x\'${_hex(key)}\'";');

      // The first statement that actually reads a page, and so the first that
      // can fail on a wrong key. Doing it here means a bad key surfaces as a
      // failure to open rather than as an empty store.
      db.select('SELECT count(*) FROM sqlite_master;');

      db.execute('PRAGMA journal_mode = WAL;');
      db.execute('PRAGMA foreign_keys = ON;');
      db.execute('''
CREATE TABLE IF NOT EXISTS kv (
  store      TEXT    NOT NULL,
  key        TEXT    NOT NULL,
  value      TEXT    NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (store, key)
) WITHOUT ROWID;
''');
    } catch (_) {
      db.close();
      rethrow;
    }

    _db = db;
    _path = path;
    return db;
  }

  /// Opens an unencrypted in-memory database, for tests.
  ///
  /// No key: a test that has to reach the platform vault is a test that cannot
  /// run on a bare CI machine.
  @visibleForTesting
  static Database openInMemory() {
    final db = sqlite3.openInMemory();
    db.execute('''
CREATE TABLE IF NOT EXISTS kv (
  store      TEXT    NOT NULL,
  key        TEXT    NOT NULL,
  value      TEXT    NOT NULL,
  updated_at INTEGER NOT NULL,
  PRIMARY KEY (store, key)
) WITHOUT ROWID;
''');
    _db = db;
    _path = null;
    return db;
  }

  static Future<void> close() async {
    _db?.close();
    _db = null;
    _path = null;
  }

  /// Rewrites the file without its free pages.
  ///
  /// What `box.compact()` was for, except that it is one call for the whole
  /// app rather than one per store — there is one file now.
  static void vacuum() => instance.execute('VACUUM;');

  /// Size of the database on disk, or 0 before it is opened or in memory.
  static Future<int> size() async {
    final path = _path;
    if (path == null) return 0;
    final file = File(path);
    if (!await file.exists()) return 0;

    // The WAL holds committed pages that have not been checkpointed back, so
    // the main file alone understates what the app is actually using.
    var total = await file.length();
    for (final suffix in const ['-wal', '-shm']) {
      final side = File('$path$suffix');
      if (await side.exists()) total += await side.length();
    }
    return total;
  }

  static String _hex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }
}

/// The store of SQLite.
///
/// It implements [Store]. Values are JSON, so what comes back out of [get] is
/// what `jsonDecode` produces — a `Map`, a `List` or a primitive — and the
/// `fromObj` hook every caller already passes is what turns it back into a
/// model. That is the same path [HiveStore] used for anything without a
/// `TypeAdapter`, now the only path.
class SqliteStore extends Store {
  /// Constructor.
  SqliteStore(
    String name, {
    super.lastUpdateTsKey,
    super.updateLastUpdateTsOnClear,
    super.updateLastUpdateTsOnRemove,
    super.updateLastUpdateTsOnSet,
  }) : super(name: name);

  Database get _db => SqliteDb.instance;

  final _listeners = _StoreListenerManager();

  /// Statements kept across calls, rebuilt when the database changes under
  /// them.
  ///
  /// Preparing one is most of what a read costs — measured at 5.5us per read
  /// against 0.8us for a statement that is reused — and a property read happens
  /// inside `build`, where under Hive it was a lookup in an in-memory map.
  ///
  /// Rebuilt rather than disposed on change: sqlite3 disposes a database's
  /// statements along with it, so the old ones are already gone and disposing
  /// them a second time would throw. A store outlives any number of
  /// open/close cycles, which is why this cannot assume one database for ever.
  final Map<String, PreparedStatement> _stmts = {};
  Database? _stmtsFor;

  PreparedStatement _stmt(String sql) {
    final db = _db;
    if (!identical(db, _stmtsFor)) {
      _stmts.clear();
      _stmtsFor = db;
    }
    return _stmts[sql] ??= db.prepare(sql);
  }

  static const _sqlGet = 'SELECT value FROM kv WHERE store = ? AND key = ?;';
  static const _sqlSet =
      'INSERT INTO kv (store, key, value, updated_at) VALUES (?, ?, ?, ?) '
      'ON CONFLICT (store, key) DO UPDATE SET '
      'value = excluded.value, updated_at = excluded.updated_at;';
  static const _sqlKeys = 'SELECT key FROM kv WHERE store = ?;';
  static const _sqlAll = 'SELECT key, value FROM kv WHERE store = ?;';
  static const _sqlRemove = 'DELETE FROM kv WHERE store = ? AND key = ?;';

  /// Opens the shared database, if it is not open yet.
  ///
  /// **Await this once before constructing or initialising anything that reads
  /// the database**, rather than relying on a store's own [init] to do it as a
  /// side effect. A store that touches [SqliteDb.instance] synchronously — one
  /// creating its own tables, say — cannot be started in the same
  /// `Future.wait` batch as the stores that are still opening the file: the
  /// batch's elements are all *invoked* before any of them is awaited, so it
  /// would reach a database that is still null.
  ///
  /// [dir] follows the same rule as the boxes did: the unsandboxed macOS
  /// build's documents directory is the user's own `~/Documents`, so it uses
  /// [Paths.doc] there rather than being the one part of the app writing into
  /// it.
  static Future<void> openDatabase({String? dir}) async {
    if (SqliteDb.isOpen) return;
    final path =
        dir ??
        switch (Pfs.type) {
          Pfs.linux || Pfs.windows => Paths.doc,
          Pfs.macos when !Pfs.isMacSandboxed => Paths.doc,
          _ => (await getApplicationDocumentsDirectory()).path,
        };
    await SqliteDb.open(path);
  }

  /// Kept so a store can still be brought up on its own.
  ///
  /// Does nothing beyond [openDatabase]: a K-V store owns no schema of its
  /// own, every row of every store lives in the one `kv` table.
  Future<void> init({String? dir}) => openDatabase(dir: dir);

  @override
  T? get<T extends Object>(String key, {StoreFromObj<T>? fromObj}) {
    final rows = _stmt(_sqlGet).select([name, key]);
    if (rows.isEmpty) return null;

    final Object? val;
    try {
      val = json.decode(rows.first['value'] as String);
    } catch (e) {
      dprintWarn('get("$key")', 'stored value is not JSON: $e');
      return null;
    }

    if (val is T) return val;
    if (val == null) return null;

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
    updateLastUpdateTsOnSet ??= this.updateLastUpdateTsOnSet;

    final Object? raw;
    if (toObj != null) {
      raw = toObj(val);
      if (raw == null) {
        dprintWarn('set("$key")', 'toObj returned null');
        return false;
      }
    } else {
      raw = val;
    }

    final String encoded;
    try {
      encoded = json.encode(raw, toEncodable: _toEncodable);
    } catch (e) {
      dprintWarn('set("$key")', 'not JSON-encodable (${raw.runtimeType}): $e');
      return false;
    }

    try {
      _stmt(_sqlSet).execute([name, key, encoded, DateTimeX.timestamp]);
    } catch (e) {
      dprintWarn('set("$key")', 'write failed: $e');
      return false;
    }

    if (updateLastUpdateTsOnSet) updateLastUpdateTs(key: key);
    _listeners.notify(key);
    return true;
  }

  @override
  bool setAll<T extends Object>(
    Map<String, T> map, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  }) {
    updateLastUpdateTsOnSet ??= this.updateLastUpdateTsOnSet;
    for (final entry in map.entries) {
      final res = set(
        entry.key,
        entry.value,
        toObj: toObj,
        updateLastUpdateTsOnSet: updateLastUpdateTsOnSet,
      );
      if (!res) {
        dprintWarn('setAll()', 'failed to set ${entry.key}');
        return false;
      }
    }
    return true;
  }

  @override
  Set<String> keys({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) {
    final rows = _stmt(_sqlKeys).select([name]);
    final set_ = <String>{};
    for (final row in rows) {
      final key = row['key'] as String;
      if (!includeInternalKeys && isInternalKey(key)) continue;
      set_.add(key);
    }
    return set_;
  }

  @override
  bool remove(String key, {bool? updateLastUpdateTsOnRemove}) {
    _stmt(_sqlRemove).execute([name, key]);
    updateLastUpdateTsOnRemove ??= this.updateLastUpdateTsOnRemove;
    if (updateLastUpdateTsOnRemove) updateLastUpdateTs(key: key);
    _listeners.notify(key);
    return true;
  }

  /// Empties the store of everything the user put in it.
  ///
  /// Internal keys stay. They are this build's own bookkeeping — which
  /// migrations have run, when each key last changed — and none of it is what
  /// somebody means by "clear this". `lastUpdateTs` was already being read out
  /// and put back for that reason; the rule is the same for every internal key,
  /// and applying it to only one of them is what let a "delete all settings"
  /// erase a migration's "already done" marker and have it run a second time
  /// over the data that replaced it.
  @override
  bool clear({bool? updateLastUpdateTsOnClear}) {
    final cleared = keys();
    if (cleared.isNotEmpty) {
      // By key rather than one predicate: `_` is a wildcard in `LIKE`, and the
      // internal prefixes both start with one.
      final placeholders = List.filled(cleared.length, '?').join(', ');
      _db.execute(
        'DELETE FROM kv WHERE store = ? AND key IN ($placeholders);',
        [name, ...cleared],
      );
    }

    updateLastUpdateTsOnClear ??= this.updateLastUpdateTsOnClear;
    if (updateLastUpdateTsOnClear) updateLastUpdateTs(key: null);
    for (final key in cleared) {
      _listeners.notify(key);
    }
    return true;
  }

  /// One query for the whole store.
  ///
  /// The base class reads each key in turn, which was free over a Hive box and
  /// is a prepared-statement round trip each here.
  @override
  Map<String, Object?> getAllMap({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) {
    final rows = _stmt(_sqlAll).select([name]);
    final map = <String, Object?>{};
    for (final row in rows) {
      final key = row['key'] as String;
      if (!includeInternalKeys && isInternalKey(key)) continue;
      try {
        map[key] = json.decode(row['value'] as String);
      } catch (e) {
        dprintWarn('getAllMap()', 'stored value for "$key" is not JSON: $e');
      }
    }
    return map;
  }

  @override
  Map<String, T> getAllMapTyped<T extends Object>({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
    StoreFromObj<T>? fromStr,
  }) {
    final keys = this.keys(includeInternalKeys: includeInternalKeys);
    final map = <String, T>{};
    for (final key in keys) {
      final val = get(key);
      if (val is T) {
        map[key] = val;
        continue;
      }
      if (val is String) {
        try {
          final converted = fromStr?.call(val);
          if (converted is T) {
            map[key] = converted;
            continue;
          }
        } catch (e) {
          dprintWarn('getAllMapTyped()', 'convert `$key`: $e');
        }
      }
    }
    return map;
  }

  /// Runs [body] as one transaction.
  ///
  /// Every write is otherwise its own commit, which for a bulk one — restoring
  /// a backup, importing a device's data — means a durability barrier per key
  /// and a half-applied result if the process dies part way. This is the reason
  /// the stores share one database file, so it is worth actually using.
  ///
  /// Not reentrant: SQLite has no nested transactions without savepoints, and
  /// nothing here needs them.
  static int _transactDepth = 0;

  static T transact<T>(T Function() body) {
    final db = SqliteDb.instance;
    // Savepoints rather than `BEGIN`/`COMMIT`, so this nests. The outermost
    // one starts a transaction and releasing it commits, which is the same
    // thing `BEGIN`/`COMMIT` did — but an inner call is now a nested unit
    // instead of "cannot start a transaction within a transaction". Without
    // that, anything wanting to be atomic could only be used where no caller
    // had already opened a transaction, which is not a property a store method
    // can know about itself.
    final name = 'fl_tx_${_transactDepth++}';
    db.execute('SAVEPOINT $name;');
    try {
      final result = body();
      db.execute('RELEASE $name;');
      return result;
    } catch (_) {
      try {
        db.execute('ROLLBACK TO $name;');
        // `ROLLBACK TO` undoes the work but leaves the savepoint standing.
        db.execute('RELEASE $name;');
      } catch (_) {
        // Some errors make SQLite roll the whole transaction back on their
        // own, taking the savepoint with it. Nothing left to undo.
      }
      rethrow;
    } finally {
      _transactDepth--;
    }
  }

  /// The keys written in this store, as they are written.
  ///
  /// Only writes that went through this store: it is the store that reports
  /// them, not the database. Nothing else can reach the rows, so that is every
  /// write — but it is worth knowing which of the two this is.
  Stream<String> watch() => _listeners.stream;

  /// A property of the [SqliteStore].
  SqliteProp<T> property<T extends Object>(
    String key, {
    T? defaultValue,
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

  /// Turns the values `jsonEncode` cannot take on its own into ones it can.
  ///
  /// Enums by name rather than index: an index silently changes meaning when a
  /// case is inserted, and these values outlive the build that wrote them.
  /// Everything else falls through to `toJson()`, which is what `jsonEncode`
  /// would have called anyway.
  static Object? _toEncodable(Object? value) {
    if (value is Enum) return value.name;
    return (value as dynamic).toJson();
  }
}

/// A property of the [SqliteStore].
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

  /// {@template sqlite_store_fn_backward_compatibility}
  /// It's preserved for backward compatibility.
  /// {@endtemplate}
  T? fetch() => get();

  /// {@macro sqlite_store_fn_backward_compatibility}
  void put(T value) => set(value);

  void delete() => remove();

  @override
  ValueListenable<T?> listenable() => SqlitePropListenable<T>(this, key);
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
  ValueListenable<T> listenable() =>
      SqlitePropDefaultListenable<T>(this, key, defaultValue);

  @override
  T fetch() => get();

  @override
  void put(T value) => set(value);

  @override
  void delete() => remove();
}

/// Fans one store's writes out to the widgets watching individual keys.
///
/// Hive had `box.watch()` to subscribe to; SQLite has no change feed, so the
/// store reports its own writes. That makes this exact rather than eventual —
/// and it also means a write that bypasses [SqliteStore] is invisible here,
/// which is why nothing outside the store is given the [Database].
class _StoreListenerManager {
  final Map<String, Set<VoidCallback>> _keyListeners = {};

  StreamController<String>? _all;

  /// Every key written in this store, for watchers that care that *something*
  /// changed rather than about one key. What `box.watch()` was.
  Stream<String> get stream => (_all ??= StreamController<String>.broadcast())
      .stream;

  void notify(String key) {
    _all?.add(key);

    final callbacks = _keyListeners[key];
    if (callbacks == null) return;
    // Over a copy: a callback is allowed to remove itself, and several do.
    for (final callback in List<VoidCallback>.of(callbacks)) {
      callback();
    }
  }

  void addListener(String key, VoidCallback listener) {
    _keyListeners.putIfAbsent(key, () => {}).add(listener);
  }

  void removeListener(String key, VoidCallback listener) {
    final callbacks = _keyListeners[key];
    if (callbacks == null) return;
    callbacks.remove(listener);
    if (callbacks.isEmpty) _keyListeners.remove(key);
  }
}

class SqlitePropListenable<T extends Object> extends ValueListenable<T?> {
  SqlitePropListenable(this.prop, this.key);

  final SqliteProp<T> prop;
  final String key;

  @override
  void addListener(VoidCallback listener) =>
      prop.store._listeners.addListener(key, listener);

  @override
  void removeListener(VoidCallback listener) =>
      prop.store._listeners.removeListener(key, listener);

  @override
  T? get value => prop.get();
}

class SqlitePropDefaultListenable<T extends Object> extends ValueListenable<T> {
  SqlitePropDefaultListenable(this.prop, this.key, this.defaultValue);

  final SqlitePropDefault<T> prop;
  final String key;
  T defaultValue;

  @override
  void addListener(VoidCallback listener) =>
      prop.store._listeners.addListener(key, listener);

  @override
  void removeListener(VoidCallback listener) =>
      prop.store._listeners.removeListener(key, listener);

  @override
  T get value => prop.get();
}
