import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlcipher_flutter_libs/sqlcipher_flutter_libs.dart';
import 'package:sqlite3/open.dart' as sqlite_open;
import 'package:sqlite3/sqlite3.dart' as sqlite3;

part 'hive.dart';
part 'pref.dart';
part 'mock.dart';
part 'sqlite.dart';

/// {@template store_from_to}
/// If there is a type which is not supported by the store, the store will call
/// this function to convert the value between the type.
///
/// **DO NOT** use this if the raw value will effect the performance significantly, since it runs synchronously on the main thread.
/// {@endtemplate}
typedef StoreFromObj<T extends Object> = T? Function(Object? val);

/// {@macro store_from_to}
typedef StoreToObj<T extends Object> = Object? Function(T? value);

/// The interface of any [Store].
///
/// The provider of the store can be `shared_preferences`, `hive`, `sqflite`, etc.
///
/// {@template store_last_update_ts}
/// The last update timestamp is used to check whether the data's has been updated.
///
/// It's designed that only one timestamp for all the data in one store.
/// {@endtemplate}
sealed class Store {
  /// Get the key for the last update timestamp.
  final String lastUpdateTsKey;

  /// {@template store_updateLastUpdateTsOn}
  /// Whether to update the last update timestamp when modifying the store.
  /// Default is [StoreDefaults.defaultUpdateLastUpdateTs].
  /// {@endtemplate}
  final bool updateLastUpdateTsOnSet;

  /// {@macro store_updateLastUpdateTsOn}
  final bool updateLastUpdateTsOnRemove;

  /// {@macro store_updateLastUpdateTsOn}
  final bool updateLastUpdateTsOnClear;

  /// Name of the store
  final String name;

  const Store({
    required this.name,
    this.updateLastUpdateTsOnSet = StoreDefaults.defaultUpdateLastUpdateTs,
    this.updateLastUpdateTsOnRemove = StoreDefaults.defaultUpdateLastUpdateTs,
    this.updateLastUpdateTsOnClear = StoreDefaults.defaultUpdateLastUpdateTs,
    this.lastUpdateTsKey = StoreDefaults.defaultLastUpdateTsKey,
  });

  /// Get the value of the key.
  ///
  /// If [T] is specified, the store will try to convert the value to [T] by
  /// calling [fromObj].
  T? get<T extends Object>(String key, {StoreFromObj<T>? fromObj});

  /// Set the value of the key.
  ///
  /// {@template store_set}
  /// - If [T] is specified, the store will try to convert the value to string by
  /// calling [toObj].
  /// - If you want to set to `null`, use [remove] instead.
  /// {@endtemplate}
  FutureOr<bool> set<T extends Object>(
    String key,
    T val, {
    StoreToObj<T>? toObj,
    bool? updateLastUpdateTsOnSet,
  });

  /// Set the map of key-value pairs.
  ///
  /// {@macro store_set}
  FutureOr<bool> setAll<T extends Object>(
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
        dprintWarn('setAll()', 'failed to set ${entry.key}');
        return false;
      }
    }
    return true;
  }

  /// Get all keys.
  ///
  /// {@template store_include_internal_keys}
  /// - [includeInternalKeys] is whether to include the internal keys.
  /// {@endtemplate}
  FutureOr<Set<String>> keys({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  });

  /// Remove the key.
  FutureOr<bool> remove(String key, {bool? updateLastUpdateTsOnRemove});

  /// Clear the store.
  FutureOr<bool> clear({bool? updateLastUpdateTsOnClear});

  /// Update the last update timestamp.
  ///
  /// - [ts] You can override the timestamp by this.
  /// - [key] is the key of map(`store.lastUpdateTsKey`) to the last update timestamp.
  /// If [key] is `null`, it's triggered by [clear].
  ///
  /// {@macro store_last_update_ts}
  FutureOr<bool> updateLastUpdateTs({int? ts, required String? key}) async {
    if (key != null && isInternalKey(key)) {
      // dprintWarn('updateLastUpdateTs()', 'key `$key` is an internal key, ignored.');
      return false;
    }

    var map = <String, int>{};
    try {
      final fetched = lastUpdateTs;
      if (fetched != null) {
        map = fetched;
      }
    } catch (_) {}
    ts ??= DateTimeX.timestamp;
    if (key != null) {
      map[key] = ts;
    } else {
      // Set all keys to the current timestamp.
      for (final k in map.keys) {
        map[k] = ts;
      }
    }
    return set(
      lastUpdateTsKey,
      json.encode(map),
      updateLastUpdateTsOnSet: false,
    );
  }

  /// Get the last update timestamp.
  ///
  /// {@macro store_last_update_ts}
  Map<String, int>? get lastUpdateTs {
    int? parseIntValue(Object? value) {
      if (value is int) return value;
      if (value is String) return int.tryParse(value);
      if (value is num) {
        final intVal = value.toInt();
        return intVal.toDouble() == value.toDouble() ? intVal : null;
      }
      return null;
    }

    Map<String, int> parseMap(Map<dynamic, dynamic> map) {
      final parsed = <String, int>{};
      for (final entry in map.entries) {
        final intVal = parseIntValue(entry.value);
        if (intVal == null) continue;
        parsed[entry.key.toString()] = intVal;
      }
      return parsed;
    }

    final ts = get<Map<String, int>>(
      lastUpdateTsKey,
      fromObj: (raw) {
        if (raw is String) {
          try {
            final decoded = json.decode(raw);
            if (decoded is Map) return parseMap(decoded);
            return <String, int>{};
          } catch (_) {
            return <String, int>{};
          }
        } else if (raw is Map) {
          return parseMap(raw);
        }
        return null;
      },
    );
    return ts;
  }

  /// Whether the key is an internal key.
  bool isInternalKey(String key) {
    return key.startsWith(StoreDefaults.prefixKey) ||
        key.startsWith(StoreDefaults.prefixKeyOld);
  }

  /// Get all the key-value pairs.
  ///
  /// If you want a map result, use [getAllMap] instead.
  ///
  /// {@macro store_include_internal_keys}
  Stream<(String, Object?)> getAll({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) async* {
    for (final key in await keys(includeInternalKeys: includeInternalKeys)) {
      yield (key, get(key));
    }
  }

  /// Get all the key-value pairs as a map.
  ///
  /// If you want a stream result, use [getAll] instead.
  ///
  /// {@macro store_include_internal_keys}
  FutureOr<Map<String, Object?>> getAllMap({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
  }) async {
    final keys = await this.keys(includeInternalKeys: includeInternalKeys);
    final map = Map.fromIterables(keys, keys.map((key) => get(key)));
    return map;
  }

  /// Get all the key-value pairs as a [Map<T>].
  ///
  /// Generic version of [getAllMap].
  ///
  /// {@macro store_include_internal_keys}
  FutureOr<Map<String, T>> getAllMapTyped<T extends Object>({
    bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys,
    StoreFromObj<T>? fromStr,
  }) async {
    final keys = await this.keys(includeInternalKeys: includeInternalKeys);
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

  /// Print the formatted warning msg.
  void dprintWarn(String fn, String msg) {
    dprint('$runtimeType.$fn $msg');
  }
}

/// The interface of a single Property in any [Store].
///
/// Such as the `user_token` in `shared_preferences`, `user` in `hive`, etc.
abstract class StoreProp<T extends Object> {
  /// The key of the property.
  final String key;

  /// Convert the value(string) to [T].
  final StoreFromObj<T>? fromObj;

  /// Convert the value to string.
  final StoreToObj<T>? toObj;

  /// Whether to update the last update timestamp when setting a value for this property.
  ///
  /// {@macro store_last_update_ts}
  final bool updateLastUpdateTsOnSetProp;

  /// {@template store_prop_constructor}
  /// Constructor.
  ///
  /// - [key] is the key of the property.
  /// - [fromObj] & [toObj], you can refer to [StoreFromObj] & [StoreToObj].
  /// - [store] is the store of the property.
  /// - [updateLastUpdateTsOnSetProp] is whether to update the last update timestamp
  ///of this [Store] when setting a value for this property.
  /// {@endtemplate}
  const StoreProp(
    this.key, {
    this.fromObj,
    this.toObj,
    this.updateLastUpdateTsOnSetProp = StoreDefaults.defaultUpdateLastUpdateTs,
  });

  /// It's [Store].
  Store get store;

  /// Get the value of the key.
  T? get() => store.get(key, fromObj: fromObj);

  /// Set the value of the key.
  ///
  /// If you want to set `null`, use `remove()` instead.
  FutureOr<void> set(T value) => store.set(
    key,
    value,
    toObj: toObj,
    updateLastUpdateTsOnSet: updateLastUpdateTsOnSet,
  );

  /// Remove the key.
  FutureOr<void> remove() => store.remove(key);

  /// {@template store_prop_listenable}
  /// Get the [ValueListenable] of the key.
  ///
  /// It's used to listen to the value changes.
  /// {@endtemplate}
  ValueListenable<T?> listenable();

  /// Whether to update the last update timestamp when setting a value depends on
  /// both [updateLastUpdateTsOnSetProp] && [updateLastUpdateTsOnSet].
  ///
  /// {@macro store_last_update_ts}
  bool get updateLastUpdateTsOnSet =>
      store.updateLastUpdateTsOnSet && updateLastUpdateTsOnSetProp;
}

/// The interface of a single Property in any [Store] which has a default value.
///
/// Such as the `user_token` in `shared_preferences`, `user` in `hive`, etc.
abstract class StorePropDefault<T extends Object> extends StoreProp<T> {
  /// The default value of the property.
  final T defaultValue;

  /// Constructor.
  ///
  /// - [key] is the key of the property.
  /// - [defaultValue] is the default value of the property.
  /// - [fromObj] & [toObj], you can refer to [StoreFromObj] & [StoreToObj].
  const StorePropDefault(
    super.key,
    this.defaultValue, {
    super.fromObj,
    super.toObj,
    super.updateLastUpdateTsOnSetProp = StoreDefaults.defaultUpdateLastUpdateTs,
  });

  /// Get the value of the key.
  @override
  T get() => store.get(key, fromObj: fromObj) ?? defaultValue;

  /// Set the value of the key.
  @override
  FutureOr<void> set(T value) => store.set(
    key,
    value,
    toObj: toObj,
    updateLastUpdateTsOnSet: updateLastUpdateTsOnSet,
  );

  /// {@macro store_prop_listenable}
  @override
  ValueListenable<T> listenable();
}

/// The keys used internally in the store.
extension StoreDefaults on Store {
  /// {@template store_defaults_prefix_key}
  /// The prefix of the internal keys.
  ///
  /// If you want to export data from the store, you can ignore the keys with this prefix.
  /// {@endtemplate}
  static const prefixKey = '__lkpt_';

  /// {@macro store_defaults_prefix_key}
  static const prefixKeyOld = '_sbi_';

  /// The key for the last update timestamp.
  static const defaultLastUpdateTsKey = '${prefixKey}lastUpdateTs';

  /// Update the last update timestamp by default.
  static const defaultUpdateLastUpdateTs = true;

  /// NOT Include the internal keys by default.
  static const defaultIncludeInternalKeys = false;
}
