import 'dart:async';
import 'dart:convert';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class RateLimitExceededException implements Exception {
  final String message;
  final int remaining;

  RateLimitExceededException(this.message, {required this.remaining});

  @override
  String toString() => message;
}

class _SlidingWindowRateLimiter {
  final int maxRequests;
  final Duration windowSize;
  final List<int> _timestamps = [];

  _SlidingWindowRateLimiter({
    required this.maxRequests,
    required this.windowSize,
  });

  bool allowRequest() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final windowStart = now - windowSize.inMilliseconds;

    _timestamps.removeWhere((ts) => ts < windowStart);

    if (_timestamps.length >= maxRequests) {
      return false;
    }

    _timestamps.add(now);
    return true;
  }

  int get remainingRequests => maxRequests - _timestamps.length;
}

final class _RateLimiter {
  static final _readLimiter = _SlidingWindowRateLimiter(
    maxRequests: 60,
    windowSize: const Duration(seconds: 30),
  );

  static final _writeLimiter = _SlidingWindowRateLimiter(
    maxRequests: 10,
    windowSize: const Duration(seconds: 30),
  );

  static bool canRead() => _readLimiter.allowRequest();
  static bool canWrite() => _writeLimiter.allowRequest();
  static int readRemaining() => _readLimiter.remainingRequests;
  static int writeRemaining() => _writeLimiter.remainingRequests;
}

/// Secure Store Properties
abstract final class SecureStoreProps {
  /// Password for the backup.
  static const bakPwd = SecureProp('bakPwd');

  /// Legacy password of [HiveStore].
  ///
  /// Kept for migration compatibility only. Prefer [sqlitePwd].
  @Deprecated(
    'Use sqlitePwd instead; Hive store is deprecated and will be removed in a future release.',
  )
  static const hivePwd = SecureProp('hivePwd');

  /// Password of [SqliteStore].
  static const sqlitePwd = SecureProp('sqlitePwd');
}

/// The secure store.
///
/// It uses system built-in vault to store the data.
abstract final class SecureStore {
  /// The name of default user account. Such as 'debug.user1' or 'release.user1'.
  ///
  /// - Only available on iOS and macOS.
  /// - Not [IOSOptions.groupId].
  static const defaultAccountName = 'fllib_secure_store';

  /// The secure storage instance.
  ///
  /// With [defaultAccountName], [KeychainAccessibility.first_unlock_this_device],
  static const storage = FlutterSecureStorage(
    aOptions: AndroidOptions(
      encryptedSharedPreferences: true,
      resetOnError: true,
    ),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
      accountName: defaultAccountName,
      synchronizable: false,
      groupId: null,
    ),
    mOptions: MacOsOptions(
      accountName: defaultAccountName,
      synchronizable: false,
      accessibility: KeychainAccessibility.first_unlock_this_device,
      groupId: null,
    ),
  );

  static Future<T?> readJson<T>(String key, JsonFromJson<T> fromJson) {
    return storage.readJson<T>(key, fromJson);
  }

  static Future<bool> writeJson<T>(String key, T value, JsonToJson<T> toJson) {
    return storage.writeJson<T>(key, value, toJson);
  }
}

/// Includes [readJson] and [writeJson].
extension SecureStoreExt on FlutterSecureStorage {
  /// Read a JSON object from secure storage.
  Future<T?> readJson<T>(String key, JsonFromJson<T> fromJson) async {
    try {
      final jsonStr = await read(key: key);
      if (jsonStr == null) return null;
      final obj = fromJson(json.decode(jsonStr));
      return obj;
    } catch (e) {
      dprint('Error reading JSON from secure storage: $e');
      return null;
    }
  }

  /// Write a JSON object to secure storage.
  Future<bool> writeJson<T>(String key, T value, JsonToJson<T> toJson) async {
    try {
      final jsonStr = json.encode(toJson(value));
      await write(key: key, value: jsonStr);
      return true;
    } catch (e) {
      dprint('Error writing JSON to secure storage: $e');
    }
    return false;
  }

  Future<int?> readInt(String key) async {
    final value = await read(key: key);
    if (value == null) return null;
    return int.tryParse(value);
  }

  Future<void> writeInt(String key, int? value) {
    if (value == null) {
      return write(key: key, value: null);
    }
    return write(key: key, value: value.toString());
  }

  Future<bool?> readBool(String key) async {
    final value = await read(key: key);
    if (value == null) return null;
    return value == '1';
  }

  Future<void> writeBool(String key, bool? value) {
    if (value == null) {
      return write(key: key, value: null);
    }
    return write(key: key, value: value ? '1' : '0');
  }
}

/// A property that stored in [FlutterSecureStorage].
final class SecureProp {
  /// The secure storage instance.
  ///
  /// Default is [SecureStore.storage].
  final FlutterSecureStorage storage;

  /// The key of the property.
  final String key;

  /// Creates a [SecureProp] with the given [key] and optional [storage].
  const SecureProp(this.key, {this.storage = SecureStore.storage});

  /// Reads the value of the property.
  /// Throws [RateLimitExceededException] if rate limit is exceeded.
  Future<String?> read() async {
    if (!_RateLimiter.canRead()) {
      dprint('SecureProp read rate limit exceeded');
      throw RateLimitExceededException(
        'Read rate limit exceeded. Try again later.',
        remaining: _RateLimiter.readRemaining(),
      );
    }
    return storage.read(key: key);
  }

  /// Writes the value of the property.
  /// Throws [RateLimitExceededException] if rate limit is exceeded.
  Future<void> write(String? value) {
    if (!_RateLimiter.canWrite()) {
      dprint('SecureProp write rate limit exceeded');
      throw RateLimitExceededException(
        'Write rate limit exceeded. Try again later.',
        remaining: _RateLimiter.writeRemaining(),
      );
    }
    return storage.write(key: key, value: value);
  }
}
