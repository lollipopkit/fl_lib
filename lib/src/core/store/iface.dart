import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

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

/// The interface of any [KvStore].
///
/// The provider of the store can be `shared_preferences`, `hive`, `sqflite`, etc.
///
/// {@template store_last_update_ts}
/// The last update timestamp is used to check whether the data's has been updated.
///
/// It's designed that only one timestamp for all the data in one store.
/// {@endtemplate}
sealed class KvStore {
  /// Serializes changes that read, replace, or restore [lastUpdateTs].
  ///
  /// The map is persisted as one value, so two asynchronous writers cannot
  /// safely read it independently and both write their own modified copy.
  Future<void>? _lastUpdateTsMutation;

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

  KvStore({
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
      final res = await set(entry.key, entry.value, toObj: toObj, updateLastUpdateTsOnSet: updateLastUpdateTsOnSet);
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
  FutureOr<Set<String>> keys({bool includeInternalKeys = StoreDefaults.defaultIncludeInternalKeys});

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
  ///
  /// [mutation] must not call [updateLastUpdateTs] or [clear] on this store:
  /// this queue is intentionally non-reentrant.
  Future<T> _serializeLastUpdateTsMutation<T>(
    FutureOr<T> Function() mutation,
  ) {
    final previous = _lastUpdateTsMutation;
    final current = previous == null
        ? Future<T>.sync(mutation)
        : previous.then((_) => Future<T>.sync(mutation));

    // Keep the queue usable after a failed persistence operation.
    final completion = current.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _lastUpdateTsMutation = completion;
    completion.then<void>((_) {
      if (identical(_lastUpdateTsMutation, completion)) {
        _lastUpdateTsMutation = null;
      }
    });
    return current;
  }

  Future<bool> _updateLastUpdateTs({int? ts, required String? key}) async {
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
    return await set(
      lastUpdateTsKey,
      json.encode(map),
      updateLastUpdateTsOnSet: false,
    );
  }

  Future<bool> updateLastUpdateTs({int? ts, required String? key}) =>
      _serializeLastUpdateTsMutation(
        () => _updateLastUpdateTs(ts: ts, key: key),
      );

  /// Get the last update timestamp.
  ///
  /// {@macro store_last_update_ts}
  Map<String, int>? get lastUpdateTs {
    final ts = get<Map<String, int>>(lastUpdateTsKey, fromObj: (raw) {
      if (raw is String) {
        return json.decode(raw).cast<String, int>();
      } else if (raw is Map<String, int>) {
        return raw;
      } else if (raw is Map) {
        // A JSON round-trip widens this to `Map<String, dynamic>`, and so did
        // a Hive box to `Map<dynamic, dynamic>`. Matching only the exact type
        // above meant any store that had been through either handed back null
        // and silently restarted its timestamps from zero.
        return {
          for (final e in raw.entries)
            if (e.key is String && e.value is num)
              e.key as String: (e.value as num).toInt(),
        };
      }
      return null;
    });
    return ts;
  }

  /// Whether the key is an internal key.
  bool isInternalKey(String key) {
    return key.startsWith(StoreDefaults.prefixKey) || key.startsWith(StoreDefaults.prefixKeyOld);
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

/// The interface of a single Property in any [KvStore].
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
  ///of this [KvStore] when setting a value for this property.
  /// {@endtemplate}
  const StoreProp(
    this.key, {
    this.fromObj,
    this.toObj,
    this.updateLastUpdateTsOnSetProp = StoreDefaults.defaultUpdateLastUpdateTs,
  });

  /// It's [KvStore].
  KvStore get store;

  /// Get the value of the key.
  T? get() => store.get(key, fromObj: fromObj);

  /// Set the value of the key.
  ///
  /// If you want to set `null`, use `remove()` instead.
  Future<void> set(T value) async {
    final saved = await store.set(
      key,
      value,
      toObj: toObj,
      updateLastUpdateTsOnSet: updateLastUpdateTsOnSet,
    );
    if (!saved) {
      throw StateError('Failed to persist "$key"');
    }
  }

  /// Remove the key.
  Future<void> remove() async {
    if (!await store.remove(key)) {
      throw StateError('Failed to remove "$key"');
    }
  }

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
  bool get updateLastUpdateTsOnSet => store.updateLastUpdateTsOnSet && updateLastUpdateTsOnSetProp;
}

/// The interface of a single Property in any [KvStore] which has a default value.
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
  Future<void> set(T value) => super.set(value);

  /// {@macro store_prop_listenable}
  @override
  ValueListenable<T> listenable();
}

/// The keys used internally in the store.
extension StoreDefaults on KvStore {
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
