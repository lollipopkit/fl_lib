part of 'iface.dart';

// ignore_for_file: unnecessary_this

/// A mock implementation of [KvStore] that keeps data in memory.
/// Persistence operations complete asynchronously, matching production stores.
class MockStore extends KvStore {
  final Map<String, Object> _mem = {};

  MockStore({
    super.updateLastUpdateTsOnSet,
    super.updateLastUpdateTsOnRemove,
    super.updateLastUpdateTsOnClear,
    super.lastUpdateTsKey,
    super.name = 'Mock',
  });

  @override
  T? get<T extends Object>(String key, {StoreFromObj<T>? fromObj}) {
    final value = _mem[key];
    if (value == null) {
      return null;
    }

    if (value is T) {
      return value;
    }

    if (fromObj != null && value is String) {
      try {
        return fromObj(value);
      } catch (e, s) {
        dprintWarn('get<$T>()', 'fromStr failed for key "$key": $e\n$s');
        return null;
      }
    }
    if (T == String && value is! String) {
      try {
        return value.toString() as T;
      } catch (e, s) {
        dprintWarn('get<$T>()', 'Failed to convert value to String for key "$key": $e\n$s');
        return null;
      }
    }

    if (fromObj == null && value is! T) {
      try {
        return value as T;
      } catch (e, s) {
        dprintWarn('get<$T>()', 'Cast failed for key "$key": $e\n$s');
        return null;
      }
    }

    if (fromObj != null && value is! String) {
      dprintWarn('get<$T>()', 'fromStr provided for key "$key" but value is not a String. Value type: ${value.runtimeType}');
      return null;
    }

    dprintWarn('get<$T>()', 'Unhandled case for key "$key". Value type: ${value.runtimeType}, Expected type: $T');
    return null;
  }

  @override
  Future<bool> set<T extends Object>(
    String key,
    T val, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  }) async {
    Object? valueToStore;
    if (toObj != null) {
      final strVal = toObj(val);
      if (strVal == null) {
        dprintWarn('set<$T>()', 'toStr returned null for key "$key". Value not set.');
        return false;
      }
      valueToStore = strVal;
    } else {
      valueToStore = val; // Store the object directly if no toStr is provided
    }

    _mem[key] = valueToStore;
    updateLastUpdateTsOnSet ??= this.updateLastUpdateTsOnSet;
    if (updateLastUpdateTsOnSet) {
      if (!await updateLastUpdateTs(key: key)) return false;
    }
    return true;
  }

  @override
  Set<String> keys({bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys}) {
    if (includeInternalKeys) {
      return _mem.keys.toSet();
    }
    return _mem.keys.where((key) => !isInternalKey(key)).toSet();
  }

  @override
  Future<bool> remove(String key, {bool? updateLastUpdateTsOnRemove}) async {
    final existed = _mem.containsKey(key);
    _mem.remove(key);

    updateLastUpdateTsOnRemove ??= this.updateLastUpdateTsOnRemove;
    if (updateLastUpdateTsOnRemove && existed) {
      if (!await updateLastUpdateTs(key: key)) return false;
    }
    return true;
  }

  @override
  Future<bool> clear({bool? updateLastUpdateTsOnClear}) =>
      _serializeLastUpdateTsMutation(() async {
        final lastUpTsMap = _mem[this.lastUpdateTsKey];
        _mem.clear();
        if (lastUpTsMap != null) {
          _mem[this.lastUpdateTsKey] = lastUpTsMap;
        }

        final shouldUpdateLastUpdateTs =
            updateLastUpdateTsOnClear ?? this.updateLastUpdateTsOnClear;
        if (shouldUpdateLastUpdateTs &&
            !await _updateMockLastUpdateTs(key: null)) {
          return false;
        }
        return true;
      });

  @override
  Future<bool> updateLastUpdateTs({int? ts, required String? key}) =>
      _serializeLastUpdateTsMutation(
        () => _updateMockLastUpdateTs(ts: ts, key: key),
      );

  Future<bool> _updateMockLastUpdateTs({int? ts, required String? key}) async {
    if (key != null && isInternalKey(key)) {
      dprintWarn('updateLastUpdateTs()', 'Attempted to update timestamp for internal key "$key". Ignored.');
      return false;
    }

    final timestampMap = Map<String, int>.from(
      (_mem[this.lastUpdateTsKey] as Map?)?.cast<String, int>() ?? {},
    );
    final currentTs = ts ?? DateTimeX.timestamp;

    if (key != null) {
      timestampMap[key] = currentTs;
    } else {
      // When key is null (on clear), update all existing tracked keys in the timestamp map.
      final List<String> keysInMap = timestampMap.keys.toList();
      for (final k in keysInMap) {
        timestampMap[k] = currentTs;
      }
    }
    return await set(
      lastUpdateTsKey,
      timestampMap,
      updateLastUpdateTsOnSet: false,
    );
  }

  @override
  Map<String, int>? get lastUpdateTs {
    return _mem[this.lastUpdateTsKey] as Map<String, int>?;
  }

  // Override async methods to call sync versions
  @override
  Stream<(String, Object?)> getAll({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) async* {
    for (final key in keys(includeInternalKeys: includeInternalKeys)) {
      yield (key, get(key));
    }
  }

  @override
  Map<String, Object?> getAllMap({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) {
    final result = <String, Object?>{};
    for (final key in keys(includeInternalKeys: includeInternalKeys)) {
      result[key] = get(key);
    }
    return result;
  }

  @override
  Map<String, T> getAllMapTyped<T extends Object>({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
    StoreFromObj<T>? fromStr,
  }) {
    final result = <String, T>{};
    for (final key in keys(includeInternalKeys: includeInternalKeys)) {
      final val = get(key);
      if (val is T) {
        result[key] = val;
        continue;
      }
      if (val is String && fromStr != null) {
        try {
          final converted = fromStr(val);
          if (converted is T) {
            result[key] = converted;
            continue;
          }
        } catch (e) {
          dprintWarn('getAllMapTypedSync()', 'convert `$key`: $e');
        }
      }
    }
    return result;
  }

  @override
  Future<bool> setAll<T extends Object>(
    Map<String, T> map, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  }) async {
    for (final entry in map.entries) {
      final res = await set(
        entry.key,
        entry.value,
        toObj: toObj,
        updateLastUpdateTsOnSet: updateLastUpdateTsOnSet,
      );
      if (!res) {
        dprintWarn('setAllSync()', 'failed to set ${entry.key}');
        return false;
      }
    }
    return true;
  }
}

/// Mock implementation of [StoreProp] for [MockStore].
class MockStoreProp<T extends Object> extends StoreProp<T> {
  @override
  final MockStore store;

  MockStoreProp(
    this.store, // Store instance
    String key, // Positional key
    {
    super.fromObj,
    super.toObj,
    super.updateLastUpdateTsOnSetProp = StoreDefaults.defaultUpdateLastUpdateTs,
  }) : super(key);

  // `get`, `set`, `remove` are inherited from StoreProp and will use the MockStore's methods via `this.store`.

  @override
  ValueListenable<T?> listenable() {
    // This ValueNotifier is basic and won't auto-update with store changes
    // unless explicitly managed by test code.
    return ValueNotifier<T?>(this.get());
  }
}

/// Mock implementation of [StorePropDefault] for [MockStore].
class MockStorePropDefault<T extends Object> extends StorePropDefault<T> {
  @override
  final MockStore store;

  MockStorePropDefault(
    this.store, // Store instance
    String key, // Positional key
    T defaultValue, // Positional defaultValue
    {
    super.fromObj,
    super.toObj,
    super.updateLastUpdateTsOnSetProp = StoreDefaults.defaultUpdateLastUpdateTs,
  }) : super(key, defaultValue);

  // `get` (overridden in StorePropDefault), `set` are inherited and will use MockStore methods via `this.store`.

  @override
  ValueListenable<T> listenable() {
    // Similar to MockStoreProp, this is a basic notifier.
    return ValueNotifier<T>(this.get());
  }
}
