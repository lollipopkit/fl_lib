part of 'iface.dart';

/// Properties saved in SharedPreferences.
abstract final class PrefProps {
  /// Used for migration
  static const lastVer = PrefPropDefault('last_ver', 0, updateLastUpdateTsOnSetProp: false);

  /// `null` means not set, `''` means empty password
  static const bakPwd = PrefProp<String>('bak_pwd');

  /// Soft IME suggestions
  static const imeSuggestions = PrefProp<bool>('ime_suggestions');

  /// {@template webdav_settings}
  /// WebDAV settings
  /// {@endtemplate}
  static const webdavUrl = PrefProp<String>('webdav_url');

  /// {@macro webdav_settings}
  static const webdavUser = PrefProp<String>('webdav_user');

  /// {@macro webdav_settings}
  @Deprecated('Use SecureStoreProps.webdavPwd')
  static const webdavPwd = PrefProp<String>('webdav_pwd');

  /// {@macro webdav_settings}
  static const webdavSync = PrefPropDefault('webdav_sync', false, updateLastUpdateTsOnSetProp: false);

  /// iCloud sync
  static const icloudSync = PrefPropDefault('icloud_sync', false, updateLastUpdateTsOnSetProp: false);

  /// GitHub token used for Gist access
  @Deprecated('Use SecureStoreProps.githubToken')
  static const githubToken = PrefProp<String>('github_token');

  /// Gist id holding backup file(s)
  static const gistId = PrefProp<String>('gist_id');

  /// Enable GitHub Gist sync
  static const gistSync = PrefPropDefault('gist_sync', false, updateLastUpdateTsOnSetProp: false);

  /// Whether automatic backup sync should include app settings. On unless
  /// turned off: settings are the person's, like the rest of what syncs.
  static const syncAppSettings = PrefPropDefault('sync_app_settings', true, updateLastUpdateTsOnSetProp: false);
}

/// SharedPreferences store.
///
/// {@template PrefStore.init}
/// `MUST` call [init] before using any pref stores.
/// {@endtemplate}
final class PrefStore extends KvStore {
  /// The prefix of SharedPreferences.
  ///
  /// Defaults to `''`.
  final String? prefix;

  /// Who watches which key: told of each value set or removed through this
  /// store, after it is stamped.
  final _listeners = _StoreListenerManager();

  /// Due to the limit of the SharedPreferences singleton, only [shared] is recommended.
  ///
  /// {@macro PrefStore.init}
  PrefStore({
    this.prefix,
    super.name = 'Pref',
    super.lastUpdateTsKey,
    super.updateLastUpdateTsOnSet,
    super.updateLastUpdateTsOnClear,
    super.updateLastUpdateTsOnRemove,
  });

  /// Single instance for the whole app.
  ///
  /// - The [prefix] is `''`.
  static final shared = PrefStore();

  SharedPreferences? _instance;

  /// Initialize the store.
  ///
  /// `MUST` call this before using any pref stores.
  Future<void> init({String prefix = ''}) async {
    if (_instance != null) return;
    SharedPreferences.setPrefix(prefix);
    if (await (prefsFileForTest ?? _prefsFile)() case final file?) {
      SharedPreferencesStorePlatform.instance = AtomicFilePrefs(file);
    }
    _instance = await SharedPreferences.getInstance();
  }

  /// The file the Windows and Linux plugins keep them in, for [AtomicFilePrefs]
  /// to take over; null elsewhere, and under a test's mock.
  static Future<File?> _prefsFile() async {
    if (!Platform.isWindows && !Platform.isLinux) return null;
    final current = SharedPreferencesStorePlatform.instance;
    if (current is InMemorySharedPreferencesStore || current is MethodChannelSharedPreferencesStore) return null;
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}${Platform.pathSeparator}shared_preferences.json');
  }

  /// Stands in for [_prefsFile].
  @visibleForTesting
  static Future<File?> Function()? prefsFileForTest;

  /// Get the value of the key.
  ///
  /// {@template pref_store_types}
  /// Native support types: [bool], [double], [int], [String], `List<String>`, `Map<String, dynamic>`.
  ///
  /// If not supported, you can use [fromObj] to convert the string value to the desired type.
  /// {@endtemplate}
  @override
  T? get<T extends Object>(String key, {StoreFromObj<T>? fromObj}) {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('get("$key")', 'instance not initialized');
      return null;
    }

    try {
      final res = switch (T) {
        const (bool) => instance.getBool(key),
        const (double) => instance.getDouble(key),
        const (int) => instance.getInt(key),
        const (String) => instance.getString(key),
        const (List<String>) => instance.getStringList(key),
        const (Map<String, dynamic>) => () {
            final str = instance.getString(key);
            if (str == null) return null;
            return json.decode(str) as Map<String, dynamic>;
          }(),
        _ => () {
            final str = instance.getString(key);
            if (str == null) return null;
            return fromObj?.call(str);
          }(),
      };
      if (res is! T?) {
        dprintWarn('get("$key")', 'is: ${res.runtimeType}, expected: $T');
        return null;
      }

      return res;
    } catch (e) {
      dprintWarn('get("$key")', 'error: $e');
      return null;
    }
  }

  /// Set the value of the key.
  ///
  /// {@macro pref_store_types}
  @override
  Future<bool> set<T extends Object>(
    String key,
    T val, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  }) async {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('set("$key")', 'instance not initialized');
      return Future.value(false);
    }

    final res = await _set(key, val, ifNotSupported: () async {
      if (toObj == null) {
        dprintWarn('set("$key")', 'invalid type: ${val.runtimeType}');
        return false;
      }
      final obj = toObj(val);
      if (obj != null) {
        return _set(key, obj, ifNotSupported: () {
          dprintWarn('set("$key")', 'unsupported type: ${obj.runtimeType}');
          return Future.value(false);
        });
      }
      return instance.remove(key);
    });
    if (!res) return false;
    // Stamped first: a listener reading the stamps, or syncing on the change,
    // sees this one. Told either way, as the value changed.
    final stamped = !(updateLastUpdateTsOnSet ?? this.updateLastUpdateTsOnSet) || await updateLastUpdateTs(key: key);
    _listeners.notify(key);
    return stamped;
  }

  /// Get all keys.
  @override
  Set<String> keys({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('keys()', 'instance not initialized');
      return {};
    }

    final set_ = <String>{};
    try {
      for (final key in instance.getKeys()) {
        if (!includeInternalKeys && isInternalKey(key)) continue;
        set_.add(key);
      }
    } catch (e) {
      dprintWarn('keys()', 'error: $e');
    }
    return set_;
  }

  /// Remove the key.
  @override
  Future<bool> remove(String key, {bool? updateLastUpdateTsOnRemove}) async {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('remove("$key")', 'instance not initialized');
      return Future.value(false);
    }

    final existed = instance.containsKey(key);
    final ret = await instance.remove(key);
    if (!ret) return false;
    if (!existed) return ret;
    // As [set]: stamped, then told.
    final stamped = !(updateLastUpdateTsOnRemove ?? this.updateLastUpdateTsOnRemove) || await updateLastUpdateTs(key: key);
    _listeners.notify(key);
    return stamped;
  }

  /// Clear the store.
  @override
  Future<bool> clear({bool? updateLastUpdateTsOnClear}) =>
      _serializeLastUpdateTsMutation(() async {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('clear()', 'instance not initialized');
      return Future.value(false);
    }

    final lastUpTsMap = lastUpdateTs;
    final cleared = instance.getKeys();
    final ret = await instance.clear();
    if (!ret) return false;
    // Not the internal ones: the stamps are put back below.
    for (final key in cleared) {
      if (!isInternalKey(key)) _listeners.notify(key);
    }
    if (lastUpTsMap != null) {
      final restored = await set(
        lastUpdateTsKey,
        lastUpTsMap,
        updateLastUpdateTsOnSet: false,
      );
      if (!restored) return false;
    }

    final shouldUpdateLastUpdateTs = updateLastUpdateTsOnClear ?? this.updateLastUpdateTsOnClear;
    if (shouldUpdateLastUpdateTs &&
        !await _updateLastUpdateTs(key: null)) {
      return false;
    }
    return ret;
      });

  Future<bool> _set<T extends Object>(
    String key,
    T val, {
    required Future<bool> Function() ifNotSupported,
  }) {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('set("$key")', 'instance not initialized');
      return Future.value(false);
    }

    return switch (val) {
      final bool obj => instance.setBool(key, obj),
      final double obj => instance.setDouble(key, obj),
      final int obj => instance.setInt(key, obj),
      final String obj => instance.setString(key, obj),
      final List<String> obj => instance.setStringList(key, obj),
      final Map<String, dynamic> obj => instance.setString(key, json.encode(obj)),
      _ => ifNotSupported(),
    };
  }
}

/// A single Property in SharedPreferences.
///
/// {@macro pref_store_types}
///
/// You can define a property like this:
/// ```dart
/// const userToken = PrefProp<String>('user_token');
/// ```
final class PrefProp<T extends Object> extends StoreProp<T> {
  final PrefStore? _store;

  const PrefProp(
    super.key, {
    this._store,
    super.fromObj,
    super.toObj,
    super.updateLastUpdateTsOnSetProp,
  });

  @override
  PrefStore get store => _store ?? PrefStore.shared;

  @override
  ValueListenable<T?> listenable() => PrefPropListenable<T>(store, key);

  /// Override it, so the return type is `T?` instead of `FutureOr<T?>`.
  @override
  T? get() => store.get<T>(key);
}

/// A single Property in SharedPreferences with default value.
///
/// {@macro pref_store_types}
///
/// You can define a property like this:
/// ```dart
/// const userToken = PrefPropDefault<String>('user_token', 'default_token');
/// ```
final class PrefPropDefault<T extends Object> extends StorePropDefault<T> {
  final PrefStore? _store;

  const PrefPropDefault(
    super.key,
    super.defaultValue, {
    this._store,
    super.fromObj,
    super.toObj,
    super.updateLastUpdateTsOnSetProp,
  });

  @override
  PrefStore get store => _store ?? PrefStore.shared;

  @override
  ValueListenable<T> listenable() => PrefPropDefaultListenable<T>(store, key, defaultValue);
}

/// Base class for PrefProp listenables to avoid code duplication
abstract class _BasePrefPropListenable {
  final PrefStore store;
  final String key;

  const _BasePrefPropListenable(this.store, this.key);

  void addListener(VoidCallback listener) => store._listeners.addListener(key, listener);

  void removeListener(VoidCallback listener) => store._listeners.removeListener(key, listener);
}

/// The [ValueListenable] of the key.
final class PrefPropListenable<T extends Object> extends _BasePrefPropListenable implements ValueListenable<T?> {
  const PrefPropListenable(super.store, super.key);

  @override
  T? get value => store.get<T>(key);
}

/// The [ValueListenable] of the key with default value.
final class PrefPropDefaultListenable<T extends Object> extends _BasePrefPropListenable implements ValueListenable<T> {
  final T defaultValue;

  PrefPropDefaultListenable(super.store, super.key, this.defaultValue);

  @override

  /// Since the value is retrieved from the store, so the value is not guaranteed
  /// to be the same as expected(the actual modified value).
  T get value => store.get<T>(key) ?? defaultValue;
}
