part of 'iface.dart';

// ignore_for_file: unnecessary_this

/// A mock implementation of [Store] that keeps data in memory.
/// All operations are synchronous.
class MockStore extends Store {
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
  bool set<T extends Object>(
    String key,
    T val, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  }) {
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
      updateLastUpdateTs(key: key);
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
  bool remove(String key, {bool? updateLastUpdateTsOnRemove}) {
    final existed = _mem.containsKey(key);
    _mem.remove(key);

    updateLastUpdateTsOnRemove ??= this.updateLastUpdateTsOnRemove;
    if (updateLastUpdateTsOnRemove && existed) {
      updateLastUpdateTs(key: key);
    }
    return true;
  }

  @override
  bool clear({bool? updateLastUpdateTsOnClear}) {
    final lastUpTsMap = _mem[this.lastUpdateTsKey];
    _mem.clear();
    if (lastUpTsMap != null) {
      _mem[this.lastUpdateTsKey] = lastUpTsMap;
    }

    updateLastUpdateTsOnClear ??= this.updateLastUpdateTsOnClear;
    if (updateLastUpdateTsOnClear) {
      updateLastUpdateTs(key: null);
    }
    return true;
  }

  @override
  bool updateLastUpdateTs({int? ts, required String? key}) {
    if (key != null && isInternalKey(key)) {
      dprintWarn('updateLastUpdateTs()', 'Attempted to update timestamp for internal key "$key". Ignored.');
      return false;
    }

    final timestampMap = (_mem[this.lastUpdateTsKey] as Map?)?.cast<String, int>() ?? {};
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
    _mem[this.lastUpdateTsKey] = timestampMap;
    return true;
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
  bool setAll<T extends Object>(
    Map<String, T> map, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  }) {
    for (final entry in map.entries) {
      final res = set(entry.key, entry.value, toObj: toObj, updateLastUpdateTsOnSet: updateLastUpdateTsOnSet);
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
