part of 'iface.dart';

/// The store of Hive.
///
/// It implements [Store].
class HiveStore extends Store {
  /// The internal hive box for this [Store].
  ///
  /// Not `final`: [init] may run a second time on the same instance after
  /// `Hive.close()`, which is how an app recovers from box files it turned out
  /// not to be able to open.
  late Box<dynamic> box;

  /// The name of the box. Used for the hive box.
  final String boxName;

  /// Constructor.
  HiveStore(
    this.boxName, {
    super.lastUpdateTsKey,
    super.updateLastUpdateTsOnClear,
    super.updateLastUpdateTsOnRemove,
    super.updateLastUpdateTsOnSet,
  }) : super(name: boxName);

  /// Initialize the [HiveStore].
  Future<void> init() async {
    final cipher = await _HiveEnc.cipher;

    final path = switch (Pfs.type) {
      /// The default path of Hive is the HOME dir
      Pfs.linux || Pfs.windows => Paths.doc,

      /// The unsandboxed macOS build's documents directory is the user's own
      /// `~/Documents`. Boxes follow [Paths.doc] there, or they would be the
      /// one part of the app still writing into it.
      Pfs.macos when !Pfs.isMacSandboxed => Paths.doc,
      _ => (await getApplicationDocumentsDirectory()).path,
    };

    final enc = await Hive.openBox(
      '${boxName}_enc',
      path: path,
      encryptionCipher: cipher,
    );

    final unencryptedFile = File('${path.joinPath(boxName)}.hive');
    if (await unencryptedFile.exists()) {
      // Do migration
      Box<dynamic>? unencrypted;
      try {
        unencrypted = await Hive.openBox(boxName, path: path);
        final migrated = <dynamic, dynamic>{
          for (final key in unencrypted.keys)
            if (!enc.containsKey(key)) key: unencrypted.get(key),
        };
        if (migrated.isNotEmpty) {
          await enc.putAll(migrated);
          await enc.flush();
        }
        for (final entry in migrated.entries) {
          if (enc.get(entry.key) != entry.value) {
            throw StateError('Failed to verify migrated key ${entry.key}');
          }
        }
        await unencrypted.close();
        unencrypted = null;
        await unencryptedFile.delete();
        dprint('Migrated $boxName');
      } catch (e) {
        dprint('Failed to migrate $boxName: $e');
      } finally {
        await unencrypted?.close();
      }
    }

    box = enc;
  }

  @override
  T? get<T extends Object>(String key, {StoreFromObj<T>? fromObj}) {
    final val = box.get(key);
    if (val is! T?) {
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
    return val;
  }

  @override
  Future<bool> set<T extends Object>(
    String key,
    T val, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  }) async {
    updateLastUpdateTsOnSet ??= this.updateLastUpdateTsOnSet;
    try {
      if (toObj != null) {
        final converted = toObj(val);
        if (converted == null) {
          dprintWarn('set("$key")', 'toObj returned null');
          return false;
        }
        await box.put(key, converted);
        if (updateLastUpdateTsOnSet) await updateLastUpdateTs(key: key);
        return true;
      }
      await box.put(key, val);
      if (updateLastUpdateTsOnSet) await updateLastUpdateTs(key: key);
      return true;
    } on HiveError catch (e) {
      dprintWarn('set("$key")', 'HiveError: $e');
      return false;
    } catch (e) {
      dprintWarn('set("$key")', 'toObj or put failed: $e');
      return false;
    }
  }

  @override
  Future<bool> setAll<T extends Object>(
    Map<String, T> map, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  }) async {
    updateLastUpdateTsOnSet ??= this.updateLastUpdateTsOnSet;
    for (final entry in map.entries) {
      final res = await set(
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
  Set<String> keys({bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys}) {
    final set_ = <String>{};
    for (final key in box.keys) {
      if (key is String) {
        if (!includeInternalKeys && isInternalKey(key)) continue;
        set_.add(key);
      }
    }
    return set_;
  }

  @override
  Future<bool> remove(String key, {bool? updateLastUpdateTsOnRemove}) async {
    try {
      await box.delete(key);
      updateLastUpdateTsOnRemove ??= this.updateLastUpdateTsOnRemove;
      if (updateLastUpdateTsOnRemove) await updateLastUpdateTs(key: key);
      return true;
    } catch (e) {
      dprintWarn('remove("$key")', 'failed: $e');
      return false;
    }
  }

  @override
  Future<bool> clear({bool? updateLastUpdateTsOnClear}) async {
    final lastUpdateTsMap = lastUpdateTs;
    try {
      await box.clear();
      if (lastUpdateTsMap != null) {
        final restored = await set(
          lastUpdateTsKey,
          lastUpdateTsMap,
          updateLastUpdateTsOnSet: false,
        );
        if (!restored) return false;
      }

      updateLastUpdateTsOnClear ??= this.updateLastUpdateTsOnClear;
      if (updateLastUpdateTsOnClear &&
          !await updateLastUpdateTs(key: null)) {
        return false;
      }
      return true;
    } catch (e) {
      dprintWarn('clear()', 'failed: $e');
      return false;
    }
  }

  @override
  Map<String, Object?> getAllMap({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) {
    final keys = this.keys(includeInternalKeys: includeInternalKeys);
    return Map.fromIterables(keys, keys.map((key) => get(key)));
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

  /// A property of the [HiveStore].
  HiveProp<T> property<T extends Object>(
    String key, {
    T? defaultValue,
    bool updateLastModified = true,
    StoreFromObj<T>? fromObj,
    StoreToObj<T>? toObj,
  }) {
    return HiveProp<T>(
      this,
      key,
      updateLastUpdateTsOnSetProp: updateLastModified,
      fromObj: fromObj,
      toObj: toObj,
    );
  }

  HivePropDefault<T> propertyDefault<T extends Object>(
    String key,
    T defaultValue, {
    bool updateLastModified = StoreDefaults.defaultUpdateLastUpdateTs,
    StoreFromObj<T>? fromObj,
    StoreToObj<T>? toObj,
  }) {
    return HivePropDefault<T>(
      this,
      key,
      defaultValue,
      updateLastUpdateTsOnSetProp: updateLastModified,
      fromObj: fromObj,
      toObj: toObj,
    );
  }

  HivePropDefault<List<T>> listProperty<T extends Object>(
    String key, {
    List<T> defaultValue = const [],
    bool updateLastModified = StoreDefaults.defaultUpdateLastUpdateTs,
    StoreFromObj<List<T>>? fromObj,
    StoreToObj<List<T>>? toObj,
  }) {
    return HivePropDefault<List<T>>(
      this,
      key,
      defaultValue,
      updateLastUpdateTsOnSetProp: updateLastModified,
      fromObj: fromObj ?? (obj) => List<T>.from(obj as Iterable),
      toObj: toObj,
    );
  }
}

/// A property of the [HiveStore].
class HiveProp<T extends Object> extends StoreProp<T> {
  @override
  final HiveStore store;

  HiveProp(
    this.store,
    super.key, {
    super.updateLastUpdateTsOnSetProp,
    super.fromObj,
    super.toObj,
  });

  /// {@template hive_store_fn_backward_compatibility}
  /// It's preserved for backward compatibility.
  /// {@endtemplate}
  T? fetch() => get();

  /// {@macro hive_store_fn_backward_compatibility}
  Future<void> put(T value) => set(value);

  Future<void> delete() => remove();

  @override
  ValueListenable<T?> listenable() {
    return HivePropListenable<T>(this, key);
  }
}

final class HivePropDefault<T extends Object> extends StorePropDefault<T> implements HiveProp<T> {
  @override
  final HiveStore store;

  HivePropDefault(
    this.store,
    super.key,
    super.defaultValue, {
    super.updateLastUpdateTsOnSetProp,
    super.fromObj,
    super.toObj,
  });

  @override
  ValueListenable<T> listenable() {
    return HivePropDefaultListenable<T>(this, key, defaultValue);
  }

  @override
  T fetch() => get();

  @override
  Future<void> put(T value) => set(value);

  @override
  Future<void> delete() => remove();
}

class _BoxListenerManager {
  _BoxListenerManager(this.box);

  final Box<dynamic> box;
  StreamSubscription<BoxEvent>? _subscription;
  final Map<String, Set<VoidCallback>> _keyListeners = {};

  void _ensureSubscription() {
    _subscription ??= box.watch().listen((event) {
      final callbacks = _keyListeners[event.key];
      if (callbacks != null) {
        final snapshot = List<VoidCallback>.of(callbacks);
        for (final callback in snapshot) {
          callback();
        }
      }
    });
  }

  void addListener(String key, VoidCallback listener) {
    _ensureSubscription();
    _keyListeners.putIfAbsent(key, () => {}).add(listener);
  }

  void removeListener(String key, VoidCallback listener) {
    final callbacks = _keyListeners[key];
    if (callbacks != null) {
      callbacks.remove(listener);
      if (callbacks.isEmpty) {
        _keyListeners.remove(key);
        if (_keyListeners.isEmpty) {
          _subscription?.cancel();
          _subscription = null;
        }
      }
    }
  }
}

final _boxListenerManagers = Expando<_BoxListenerManager>();

class HivePropListenable<T extends Object> extends ValueListenable<T?> {
  HivePropListenable(this.prop, this.key);

  final HiveProp<T> prop;
  final String key;

  _BoxListenerManager get _manager {
    final box = prop.store.box;
    _boxListenerManagers[box] ??= _BoxListenerManager(box);
    return _boxListenerManagers[box]!;
  }

  @override
  void addListener(VoidCallback listener) {
    _manager.addListener(key, listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _manager.removeListener(key, listener);
  }

  @override
  T? get value => prop.get();
}

class HivePropDefaultListenable<T extends Object> extends ValueListenable<T> {
  HivePropDefaultListenable(this.prop, this.key, this.defaultValue);

  final HivePropDefault<T> prop;
  final String key;
  T defaultValue;

  _BoxListenerManager get _manager {
    final box = prop.store.box;
    _boxListenerManagers[box] ??= _BoxListenerManager(box);
    return _boxListenerManagers[box]!;
  }

  @override
  void addListener(VoidCallback listener) {
    _manager.addListener(key, listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _manager.removeListener(key, listener);
  }

  @override
  T get value => prop.get();
}

extension _HiveEnc on HiveStore {
  /// The cipher of the [HiveStore].
  static HiveAesCipher? _cipher;
  static Future<HiveAesCipher>? _cipherFuture;

  static const _hiveEncKey = 'hive_key';

  /// The encryption key of the [HiveStore].
  static Future<String?> get _encryptionKey async {
    final secureStoreHiveKey = await SecureStoreProps.hivePwd.read();
    if (secureStoreHiveKey != null && secureStoreHiveKey.isNotEmpty) {
      await _removeLegacyKeys();
      return secureStoreHiveKey;
    }
    final directKey = PrefStore.shared.get<String>(_hiveEncKey);
    final flutterKey = PrefStore.shared.get<String>('flutter.$_hiveEncKey');
    final hiveKey = directKey != null && directKey.isNotEmpty
        ? directKey
        : flutterKey != null && flutterKey.isNotEmpty
        ? flutterKey
        : null;
    if (hiveKey != null) {
      await SecureStoreProps.hivePwd.write(hiveKey);
      final persisted = await SecureStoreProps.hivePwd.read();
      if (persisted != hiveKey) {
        throw StateError('Failed to verify migrated Hive encryption key');
      }
      await _removeLegacyKeys();
    }
    return hiveKey;
  }

  static Future<void> _removeLegacyKeys() async {
    await PrefStore.shared.remove(_hiveEncKey);
    await PrefStore.shared.remove('flutter.$_hiveEncKey');
  }

  /// The single cipher initialization shared by every box opened at startup.
  static Future<HiveAesCipher> get cipher {
    final existing = _cipher;
    if (existing != null) return Future.value(existing);
    return _cipherFuture ??= _initCipher().then(
      (value) {
        _cipher = value;
        return value;
      },
      onError: (Object error, StackTrace stackTrace) {
        _cipherFuture = null;
        Error.throwWithStackTrace(error, stackTrace);
      },
    );
  }

  /// Initialize the [SecureStore].
  static Future<HiveAesCipher> _initCipher() async {
    var key = await _encryptionKey;
    if (key == null || key.isEmpty) {
      key = base64UrlEncode(Hive.generateSecureKey());
      await SecureStoreProps.hivePwd.write(key);
      final persisted = await SecureStoreProps.hivePwd.read();
      if (persisted != key) {
        throw StateError('Failed to verify generated Hive encryption key');
      }
    }
    return HiveAesCipher(base64Url.decode(key));
  }
}
