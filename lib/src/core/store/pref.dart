part of 'iface.dart';

/// Properties saved in SharedPreferences.
abstract final class PrefProps {
  /// Used for migration
  static const lastVer = PrefPropDefault(
    'last_ver',
    0,
    updateLastUpdateTsOnSetProp: false,
  );

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
  static const webdavPwd = PrefProp<String>('webdav_pwd');

  /// {@macro webdav_settings}
  static const webdavSync = PrefPropDefault(
    'webdav_sync',
    false,
    updateLastUpdateTsOnSetProp: false,
  );

  /// iCloud sync
  static const icloudSync = PrefPropDefault(
    'icloud_sync',
    false,
    updateLastUpdateTsOnSetProp: false,
  );

  /// GitHub token used for Gist access
  static const githubToken = PrefProp<String>('github_token');

  /// Gist id holding backup file(s)
  static const gistId = PrefProp<String>('gist_id');

  /// Enable GitHub Gist sync
  static const gistSync = PrefPropDefault(
    'gist_sync',
    false,
    updateLastUpdateTsOnSetProp: false,
  );
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

  String _realKey(String key) {
    final p = prefix;
    if (p == null || p.isEmpty) return key;
    return '$p.$key';
  }

  String? _logicalKey(String realKey) {
    final p = prefix;
    if (p == null || p.isEmpty) return realKey;
    final prefixWithDot = '$p.';
    if (!realKey.startsWith(prefixWithDot)) return null;
    return realKey.substring(prefixWithDot.length);
  }

  /// Initialize the store.
  ///
  /// `MUST` call this before using any pref stores.
  Future<void> init({String prefix = ''}) async {
    if (_instance != null) return;
    if (identical(this, PrefStore.shared)) {
      SharedPreferences.setPrefix(prefix);
      _instance = await SharedPreferences.getInstance();
      return;
    }
    await PrefStore.shared.init(prefix: prefix);
    _instance = PrefStore.shared._instance;
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

    final realKey = _realKey(key);
    try {
      if (T == Object) {
        return instance.get(realKey) as T?;
      }

      final res = switch (T) {
        const (bool) => instance.getBool(realKey),
        const (double) => instance.getDouble(realKey),
        const (int) => instance.getInt(realKey),
        const (String) => instance.getString(realKey),
        const (List<String>) => instance.getStringList(realKey),
        const (Map<String, dynamic>) => () {
          final str = instance.getString(realKey);
          if (str == null) return null;
          return json.decode(str) as Map<String, dynamic>;
        }(),
        _ => () {
          final str = instance.getString(realKey);
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
  }) {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('set("$key")', 'instance not initialized');
      return Future.value(false);
    }

    final realKey = _realKey(key);
    final res = _set(
      realKey,
      val,
      ifNotSupported: () async {
        if (toObj == null) {
          dprintWarn('set("$key")', 'invalid type: ${val.runtimeType}');
          return false;
        }
        final obj = toObj(val);
        if (obj != null) {
          return _set(
            realKey,
            obj,
            ifNotSupported: () {
              dprintWarn('set("$key")', 'unsupported type: ${obj.runtimeType}');
              return Future.value(false);
            },
          );
        }
        return instance.remove(realKey);
      },
    );
    if (updateLastUpdateTsOnSet ?? this.updateLastUpdateTsOnSet) {
      updateLastUpdateTs(key: key);
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
      for (final realKey in instance.getKeys()) {
        final key = _logicalKey(realKey);
        if (key == null) continue;
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
  Future<bool> remove(String key, {bool? updateLastUpdateTsOnRemove}) {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('remove("$key")', 'instance not initialized');
      return Future.value(false);
    }

    final ret = instance.remove(_realKey(key));
    updateLastUpdateTsOnRemove ??= this.updateLastUpdateTsOnRemove;
    if (updateLastUpdateTsOnRemove) updateLastUpdateTs(key: key);
    return ret;
  }

  /// Clear the store.
  @override
  Future<bool> clear({bool? updateLastUpdateTsOnClear}) {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('clear()', 'instance not initialized');
      return Future.value(false);
    }

    final existingKeys = keys(includeInternalKeys: true);
    final ret = Future.wait(
      existingKeys.map((key) => instance.remove(_realKey(key))),
    ).then((results) => results.every((ok) => ok));

    updateLastUpdateTsOnClear ??= this.updateLastUpdateTsOnClear;
    if (updateLastUpdateTsOnClear) {
      updateLastUpdateTs(key: null);
    }
    return ret;
  }

  Future<bool> _set<T extends Object>(
    String realKey,
    T val, {
    required Future<bool> Function() ifNotSupported,
  }) {
    final instance = _instance;
    if (instance == null) {
      dprintWarn('set("$realKey")', 'instance not initialized');
      return Future.value(false);
    }

    return switch (val) {
      final bool obj => instance.setBool(realKey, obj),
      final double obj => instance.setDouble(realKey, obj),
      final int obj => instance.setInt(realKey, obj),
      final String obj => instance.setString(realKey, obj),
      final List<String> obj => instance.setStringList(realKey, obj),
      final Map<String, dynamic> obj => instance.setString(
        realKey,
        json.encode(obj),
      ),
      final List<Object?> obj => instance.setString(realKey, json.encode(obj)),
      final Map<Object?, Object?> obj => instance.setString(
        realKey,
        json.encode({
          for (final entry in obj.entries) entry.key.toString(): entry.value,
        }),
      ),
      _ => ifNotSupported(),
    };
  }

  PrefProp<T> property<T extends Object>(
    String key, {
    bool updateLastModified = true,
    StoreFromObj<T>? fromObj,
    StoreToObj<T>? toObj,
  }) {
    return PrefProp<T>(
      key,
      store: this,
      updateLastUpdateTsOnSetProp: updateLastModified,
      fromObj: fromObj,
      toObj: toObj,
    );
  }

  PrefPropDefault<T> propertyDefault<T extends Object>(
    String key,
    T defaultValue, {
    bool updateLastModified = StoreDefaults.defaultUpdateLastUpdateTs,
    StoreFromObj<T>? fromObj,
    StoreToObj<T>? toObj,
  }) {
    return PrefPropDefault<T>(
      key,
      defaultValue,
      store: this,
      updateLastUpdateTsOnSetProp: updateLastModified,
      fromObj: fromObj,
      toObj: toObj,
    );
  }

  PrefPropDefault<List<T>> listProperty<T extends Object>(
    String key, {
    List<T> defaultValue = const [],
    bool updateLastModified = StoreDefaults.defaultUpdateLastUpdateTs,
    StoreFromObj<List<T>>? fromObj,
    StoreToObj<List<T>>? toObj,
  }) {
    return PrefPropDefault<List<T>>(
      key,
      defaultValue,
      store: this,
      updateLastUpdateTsOnSetProp: updateLastModified,
      fromObj:
          fromObj ??
          (obj) {
            final raw = switch (obj) {
              final String s => json.decode(s),
              _ => obj,
            };
            return List<T>.from(raw as Iterable);
          },
      toObj:
          toObj ??
          (value) {
            if (value == null) return null;
            final list = List<Object?>.from(value);
            final allString = list.every((e) => e is String);
            return allString ? list.cast<String>() : list;
          },
    );
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

  T? fetch() => get();

  FutureOr<void> put(T value) => set(value);

  FutureOr<void> delete() => remove();
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
  ValueListenable<T> listenable() =>
      PrefPropDefaultListenable<T>(store, key, defaultValue);

  T fetch() => get();

  FutureOr<void> put(T value) => set(value);

  FutureOr<void> delete() => remove();
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
final class PrefPropListenable<T extends Object> extends _BasePrefPropListenable
    implements ValueListenable<T?> {
  const PrefPropListenable(super.store, super.key);

  @override
  T? get value => store.get<T>(key);
}

/// The [ValueListenable] of the key with default value.
final class PrefPropDefaultListenable<T extends Object>
    extends _BasePrefPropListenable
    implements ValueListenable<T> {
  final T defaultValue;

  PrefPropDefaultListenable(super.store, super.key, this.defaultValue);

  @override
  /// Since the value is retrieved from the store, so the value is not guaranteed
  /// to be the same as expected(the actual modified value).
  T get value => store.get<T>(key) ?? defaultValue;
}
