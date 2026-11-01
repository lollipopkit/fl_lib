import 'dart:async';
import 'dart:convert';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
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

  _SlidingWindowRateLimiter({required this.maxRequests, required this.windowSize});

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

  void reset() => _timestamps.clear();
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

  static void reset() {
    _readLimiter.reset();
    _writeLimiter.reset();
  }
}

/// Secure Store Properties
abstract final class SecureStoreProps {
  /// Password for the backup. In iCloud Keychain on iOS and macOS: every
  /// device of the person's that syncs the backup needs the same one. One
  /// set before, or iCloud Keychain refused, stays on the device
  /// ([SecureProp.legacy]).
  static const bakPwd = SecureProp(
    'bakPwd',
    storage: SecureStore.synced,
    legacy: SecureStore.storage,
  );

  /// Password of [HiveStore].
  static const hivePwd = SecureProp('hivePwd');

  /// Password used to authenticate to WebDAV.
  static const webdavPwd = SecureProp('webdavPwd');

  /// GitHub token used for Gist access.
  static const githubToken = SecureProp('githubToken');

  /// LK Cloud's IdP tokens, see [LkcClient].
  static const lkcToken = SecureProp('lkcToken');

  /// Moves secrets written by older builds out of SharedPreferences.
  static Future<void> migrateLegacyPrefs() async {
    try {
      // ignore: deprecated_member_use_from_same_package
      await _migrateLegacyPref(PrefProps.webdavPwd, webdavPwd);
    } catch (e) {
      dprint('Failed to migrate WebDAV password: $e');
    }
    try {
      // ignore: deprecated_member_use_from_same_package
      await _migrateLegacyPref(PrefProps.githubToken, githubToken);
    } catch (e) {
      dprint('Failed to migrate GitHub token: $e');
    }
  }

  static Future<void> _migrateLegacyPref(
    PrefProp<String> legacy,
    SecureProp secure,
  ) async {
    final secured = await secure.read();
    if (secured != null) {
      await legacy.remove();
      return;
    }

    final value = legacy.get();
    if (value == null) return;
    await secure.write(value);
    if (await secure.read() != value) {
      throw StateError('Failed to verify migrated secret ${legacy.key}');
    }
    await legacy.remove();
  }
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
    // Off: on a Keystore error the plugin would delete every secret, the
    // store's key included, and the next read would make a new one — an
    // error that may pass by the next launch became data lost for good
    // (ServerBox #1780).
    aOptions: AndroidOptions(
      resetOnError: false,
    ),
    iOptions: _iOptions,
    mOptions: _mOptions,
  );

  /// The entries iCloud Keychain carries to the person's other Apple
  /// devices; [storage] everywhere else. Its own account, so [reset] leaves
  /// them alone: a delete there would reach every device.
  ///
  /// Only for what each device needs the same of. Never a token: two devices
  /// refreshing one end every session, and never the database key, which
  /// each device's file has its own of.
  static const synced = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock,
      accountName: '${defaultAccountName}_synced',
      synchronizable: true,
      groupId: null,
    ),
    mOptions: MacOsOptions(
      accountName: '${defaultAccountName}_synced',
      synchronizable: true,
      accessibility: KeychainAccessibility.first_unlock,
      groupId: null,
    ),
  );

  /// [storage] with the plugin's own reset allowed, for [reset] only.
  static const _resetting = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: true),
    iOptions: _iOptions,
    mOptions: _mOptions,
  );

  static const _iOptions = IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    accountName: defaultAccountName,
    synchronizable: false,
    groupId: null,
  );

  static const _mOptions = MacOsOptions(
    accountName: defaultAccountName,
    synchronizable: false,
    accessibility: KeychainAccessibility.first_unlock_this_device,
    groupId: null,
  );

  /// Deletes every entry, and on Android the key that encrypts them.
  ///
  /// For a vault that cannot decrypt its own key (ServerBox #1784): [storage]
  /// never gets past initialization then, and only `resetOnError` lets the
  /// plugin discard that key. Only on the user's explicit choice.
  ///
  /// The plugin keeps one instance per preferences name, configured by the
  /// first call that initializes it: after this, [storage] also resets on
  /// error until the process ends.
  static Future<void> reset() => _resetting.deleteAll();

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

  /// Where an older build kept it, and where a value [storage] refuses is
  /// kept instead. Only on iOS and macOS, where [SecureStore.synced] is a
  /// store apart; elsewhere the two are one.
  ///
  /// Read when [storage] has nothing, never copied there on its own: that
  /// may only be iCloud Keychain not having brought another device's newer
  /// value yet, which a copy would replace on every device. A [write] moves
  /// it.
  final FlutterSecureStorage? legacy;

  /// The key of the property.
  final String key;

  /// Creates a [SecureProp] with the given [key] and optional [storage].
  const SecureProp(this.key, {this.storage = SecureStore.storage, this.legacy});

  /// Whether [legacy] is a store apart from [storage]; a test sets it.
  @visibleForTesting
  static bool? legacyApart;

  FlutterSecureStorage? get _legacy =>
      (legacyApart ?? (isIOS || isMacOS)) ? legacy : null;

  /// Forgets the reads and writes counted against the rate limits, so each
  /// test starts with the whole allowance.
  @visibleForTesting
  static void resetRateLimits() => _RateLimiter.reset();

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
    final legacy = _legacy;
    if (legacy == null) return storage.read(key: key);
    try {
      final value = await storage.read(key: key);
      if (value != null) return value;
    } catch (e) {
      // Not entitled to iCloud Keychain, say: [write] kept it in [legacy].
      dprint('SecureProp $key not read from its store: $e');
    }
    return legacy.read(key: key);
  }

  /// Whether the value is in [storage] while [legacy] is a store apart: on
  /// iOS and macOS, in iCloud Keychain, where removing it removes it from
  /// every device. False with no value, or one kept on this device only.
  Future<bool> inSyncedStore() async {
    if (_legacy == null) return false;
    try {
      return await storage.read(key: key) != null;
    } catch (_) {
      return false;
    }
  }

  /// Whether the value is only in [legacy], a store apart: set by an older
  /// build, or refused by [storage]. [write] moves it.
  Future<bool> inLegacyOnly() async {
    final legacy = _legacy;
    if (legacy == null) return false;
    try {
      if (await storage.read(key: key) != null) return false;
    } catch (_) {
      return false;
    }
    return await legacy.read(key: key) != null;
  }

  /// Writes the value of the property.
  /// Throws [RateLimitExceededException] if rate limit is exceeded.
  Future<void> write(String? value) async {
    if (!_RateLimiter.canWrite()) {
      dprint('SecureProp write rate limit exceeded');
      throw RateLimitExceededException(
        'Write rate limit exceeded. Try again later.',
        remaining: _RateLimiter.writeRemaining(),
      );
    }
    final legacy = _legacy;
    if (legacy == null) return storage.write(key: key, value: value);
    try {
      await storage.write(key: key, value: value);
    } catch (e, s) {
      // iCloud Keychain off, or a build not entitled to it: on this device
      // only, rather than not at all — once what it replaces is gone there,
      // or [read] would go on answering that. If it cannot go, nothing has
      // changed, and the caller hears so.
      try {
        await storage.delete(key: key);
      } catch (_) {
        Error.throwWithStackTrace(e, s);
      }
      dprint('SecureProp $key kept on this device: $e');
      await legacy.write(key: key, value: value);
      return;
    }
    // Or [read] would bring it back once this is cleared. Stored either way.
    try {
      await legacy.delete(key: key);
    } catch (e) {
      dprint('SecureProp $key: device-only copy not removed: $e');
    }
  }
}
