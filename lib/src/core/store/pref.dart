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

  /// Whether automatic backup sync should include app settings.
  static const syncAppSettings = PrefPropDefault('sync_app_settings', false, updateLastUpdateTsOnSetProp: false);
}

/// The listener of the SharedPreferences.
///
/// - [key] is the changed key.
typedef PrefStoreKeyListener = void Function(String key);

/// SharedPreferences store.
///
/// {@template PrefStore.init}
/// `MUST` call [init] before using any pref stores.
/// {@endtemplate}
final class PrefStore extends Store {
  /// The prefix of SharedPreferences.
  ///
  /// Defaults to `''`.
  final String? prefix;

  /// Value changes listeners.
  final Set<PrefStoreKeyListener> listeners;

  /// Due to the limit of the SharedPreferences singleton, only [shared] is recommended.
  ///
  /// {@macro PrefStore.init}
  PrefStore({
    this.prefix,
    super.name = 'Pref',
    Set<PrefStoreKeyListener>? listeners,
    super.lastUpdateTsKey,
    super.updateLastUpdateTsOnSet,
    super.updateLastUpdateTsOnClear,
    super.updateLastUpdateTsOnRemove,
  }) : listeners = listeners ?? {};

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
    _instance = await SharedPreferences.getInstance();
  }

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
    if (updateLastUpdateTsOnSet ?? this.updateLastUpdateTsOnSet) {
      if (!await updateLastUpdateTs(key: key)) return false;
    }
    return res;
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

    final ret = await instance.remove(key);
    if (!ret) return false;
    updateLastUpdateTsOnRemove ??= this.updateLastUpdateTsOnRemove;
    if (updateLastUpdateTsOnRemove &&
        !await updateLastUpdateTs(key: key)) {
      return false;
    }
    return ret;
  }

  /// Clear the store.
  @override
  Future<bool> clear({bool? updateLastUpdateTsOnClear}) async {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('clear()', 'instance not initialized');
      return Future.value(false);
    }

    final lastUpTsMap = lastUpdateTs;
    final ret = await instance.clear();
    if (!ret) return false;
    if (lastUpTsMap != null) {
      final restored = await set(
        lastUpdateTsKey,
        lastUpTsMap,
        updateLastUpdateTsOnSet: false,
      );
      if (!restored) return false;
    }

    updateLastUpdateTsOnClear ??= this.updateLastUpdateTsOnClear;
    if (updateLastUpdateTsOnClear &&
        !await updateLastUpdateTs(key: null)) {
      return false;
    }
    return ret;
  }

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
    PrefStore? store,
    super.fromObj,
    super.toObj,
    super.updateLastUpdateTsOnSetProp,
  }) : _store = store;

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
    PrefStore? store,
    super.fromObj,
    super.toObj,
    super.updateLastUpdateTsOnSetProp,
  }) : _store = store;

  @override
  PrefStore get store => _store ?? PrefStore.shared;

  @override
  ValueListenable<T> listenable() => PrefPropDefaultListenable<T>(store, key, defaultValue);
}

/// Base class for PrefProp listenables to avoid code duplication
abstract class _BasePrefPropListenable {
  final PrefStore store;
  final String key;

  /// The internal map of prop key listeners.
  static final _map = <int, PrefStoreKeyListener>{};

  const _BasePrefPropListenable(this.store, this.key);

  void addListener(VoidCallback listener) {
    final lis = _map.putIfAbsent(listener.hashCode, () {
      // The actual listener
      void lis(String k) {
        if (k == key) listener();
      }

      return lis;
    });
    store.listeners.add(lis);
  }

  void removeListener(VoidCallback listener) {
    final actualListener = _map.remove(listener.hashCode);
    if (actualListener != null) {
      store.listeners.remove(actualListener);
    }
  }
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
