import 'dart:async';
import 'dart:convert';

import 'package:fl_lib/src/core/store/iface.dart';
import 'package:fl_lib/src/core/store/secure.dart';
import 'package:fl_lib/src/core/sync/log/errors.dart';
import 'package:fl_lib/src/core/sync/log/host.dart';
import 'package:fl_lib/src/rust/api/lkc.dart';
import 'package:fl_lib/src/rust/api/sync_engine.dart';
import 'package:fl_lib/src/rust/api/sync_engine.dart' as rust_sync;
import 'package:flutter/foundation.dart';

/// Where a remote's sync key is kept beside what it seals: `identity.age`.
abstract interface class SyncKeyFile {
  /// Which keys these are in the synced keychain (`syncIdentity.<id>`).
  String get id;

  /// The file and its version, null when there is none.
  Future<({Uint8List body, String version})?> read();

  /// [body] as the file if it is still at [ifVersion] (none there for null):
  /// its new version, null when it is not.
  Future<String?> write(Uint8List body, {required String? ifVersion});

  /// Whether a file may be made where none is read.
  Future<bool> canCreate();
}

/// The app's sync keys, one per remote, each opened with the backup password
/// here (`fl_sync_engine::key`). The keys are kept in the synced keychain;
/// each key file's epoch and a password change waiting to be sealed, on this
/// device.
abstract final class SyncKeyring {
  static SyncKeys? _keys;

  /// The key files the backup password here does not open. Nothing syncs to
  /// their remotes meanwhile.
  static final passwordMismatch = ValueNotifier<Set<String>>(const {});

  /// Whether a remote key file could not be opened because this device has no
  /// client-side secret key yet.
  static final secretKeyMissing = ValueNotifier<bool>(false);

  /// Set when this device auto-generates a new client-side secret key so the
  /// UI can prompt the user once to back it up.
  static final secretKeyGenerated = ValueNotifier<String?>(null);

  /// Optional policy gate controlling whether background sync may auto-generate
  /// a new secret key when none is stored yet. Defaults to allowed when null.
  static bool Function()? allowAutoGenerateSecretKey;

  /// Generates a fresh 128-bit client-side secret key (`S1-XXXXX-…`).
  static String generateSecretKey() => rust_sync.generateSecretKey();

  /// Validates and canonicalizes a user-entered or scanned secret key; null if
  /// the format or checksum is invalid.
  static String? normalizeSecretKey(String input) => rust_sync.normalizeSecretKey(input: input);

  /// Derives the combined `age scrypt` passphrase from [password] and
  /// [secretKey]; null if [secretKey] is invalid.
  static String? derivePassphrase(String password, String secretKey) =>
      rust_sync.deriveSyncPassphrase(password: password, secretKey: secretKey);

  static String? _label;

  /// [label] begins the key file's comment line (`ServerBox sync key`). Once,
  /// at launch. The keys are made when first asked for: without fl_lib's
  /// Rust, asking fails and the app runs on.
  static void init({required String label}) => _label ??= label;

  static SyncKeys get _ring =>
      _keys ??= SyncKeys(label: _label ?? (throw StateError('SyncKeyring.init was not called')), secrets: _secrets);

  static Future<T> _said<T>(Future<T> Function() run) async {
    try {
      return await syncCall(run);
    } finally {
      _syncNotifiers();
    }
  }

  /// The LK Cloud account whose account key is sealed with a secret key this
  /// device does not hold; cleared on account change, sign-out, [release],
  /// [forget], or [recheck].
  static String? _accountKeySealedFor;

  static void _syncNotifiers() {
    final ring = _keys;
    final mismatchNow = ring == null ? const <String>{} : ring.mismatch().toSet();
    if (!setEquals(mismatchNow, passwordMismatch.value)) passwordMismatch.value = mismatchNow;
    final missingNow = _accountKeySealedFor != null || (ring != null && ring.secretKeyMissing().isNotEmpty);
    if (missingNow != secretKeyMissing.value) secretKeyMissing.value = missingNow;
  }

  /// The key of [account] on LK Cloud. Without [create] (a restore, nothing
  /// synced), none is made where there is none: [SyncKeyNotHere].
  static Future<SyncKeyHandle> ofLkc(LkcSync sync, String account, {bool create = true}) {
    if (_accountKeySealedFor != null && _accountKeySealedFor != account) {
      _accountKeySealedFor = null;
    }
    return _said(() => _ring.ofLkc(lkc: sync, account: account, create: create));
  }

  /// The key beside a folder's segments.
  static Future<SyncKeyHandle> ofFiles(SyncKeyFile file, {bool create = true}) =>
      _said(() => _ring.ofFiles(id: file.id, create: create, file: (method, args, bytes) => _file(file, method, args, bytes)));

  /// One at a time: storing a secret key, and making one for LK Cloud's
  /// account key until it is kept, so neither replaces the other halfway.
  static Future<void> _secretKeyLock = Future.value();

  static Future<T> withSecretKeyLock<T>(Future<T> Function() f) {
    final run = _secretKeyLock.then((_) => f());
    _secretKeyLock = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// [key] as this device's secret key, entered or imported by the person;
  /// validated and normalized before either import path modifies secure
  /// storage; [recheck] after. Coordinates with Rust key-file writes across
  /// the full remote-write lifecycle and rejects conflicting imports when a
  /// staged secret key has already committed to a remote.
  static Future<void> storeSecretKey(String key) async {
    final canonical = normalizeSecretKey(key);
    if (canonical == null) {
      throw ArgumentError('Invalid sync secret key', 'key');
    }
    final beforeRaw = await SecureStoreProps.syncSecretKey.read(limited: false);
    final expectEmptyBefore = beforeRaw == null || beforeRaw.trim().isEmpty;
    return withSecretKeyLock(() async {
      final currentRaw = await SecureStoreProps.syncSecretKey.read(limited: false);
      final current = currentRaw == null || currentRaw.trim().isEmpty
          ? null
          : (normalizeSecretKey(currentRaw) ?? currentRaw.trim());
      if (expectEmptyBefore && current != null && current != canonical) {
        throw StateError('A staged secret key already committed while importing');
      }
      if (ready) {
        await _said(() => _ring.storeSecretKey(key: canonical, expectEmptyBefore: expectEmptyBefore));
        return;
      }
      final stagedRaw = await _pendingSecretKeyProp.read(limited: false);
      final staged = stagedRaw == null || stagedRaw.trim().isEmpty
          ? null
          : (normalizeSecretKey(stagedRaw) ?? stagedRaw.trim());
      if (staged != null && staged != canonical) {
        final epochs = _decoded(_epochsProp.get());
        final pending = _decoded(await _pendingProp.storage.read(key: _pendingProp.key));
        final hasDurableCommit =
            current == null &&
            (epochs.keys.any((k) => k.startsWith('2fa:')) ||
                pending.keys.any((k) => k.startsWith('intent:')));
        if (hasDurableCommit) {
          throw StateError('A staged secret key has a committed remote write; refusing conflicting import');
        }
      }
      await SecureStoreProps.syncSecretKey.write(canonical, limited: false);
      await _pendingSecretKeyProp.write(null, limited: false);
    });
  }

  /// Whether [account]'s key file on LK Cloud ([sync]'s `identity.age`) is
  /// sealed with a secret key, read only: one to import here. Said through
  /// [secretKeyMissing].
  static Future<bool> lkcSealedWithSecretKey(LkcSync sync, String account) {
    if (_accountKeySealedFor != null && _accountKeySealedFor != account) {
      _accountKeySealedFor = null;
    }
    return _said(() => _ring.lkcSealedWithSecretKey(lkc: sync, account: account));
  }

  /// [account]'s LK Cloud account key is sealed with a secret key this device
  /// does not hold: said through [secretKeyMissing] until [recheck] or an
  /// account change / sign-out.
  static void accountKeySealed(String account) {
    _accountKeySealedFor = account;
    _syncNotifiers();
  }

  /// Clears [_accountKeySealedFor] when signed out (`account == null`) or when
  /// it was recorded for [account].
  static void clearAccountKeySealed([String? account]) {
    if (_accountKeySealedFor == null) return;
    if (account == null || _accountKeySealedFor == account) {
      _accountKeySealedFor = null;
      _syncNotifiers();
    }
  }

  /// Updates the active LK Cloud account, clearing any stale account-key
  /// sealed flag left by a different account before notifying listeners.
  static void syncLkcAccount(String? account) {
    if (_accountKeySealedFor != null && _accountKeySealedFor != account) {
      _accountKeySealedFor = null;
      _syncNotifiers();
    }
  }

  /// The secret key currently staged in the pending slot, if any (read only).
  static Future<String?> pendingSecretKey() async {
    if (ready) {
      return _said(() => _ring.pendingSecretKey());
    }
    final staged = await _pendingSecretKeyProp.read(limited: false);
    return staged == null || staged.isEmpty ? null : staged;
  }

  /// The secret key LK Cloud's account key is first sealed with: the one
  /// held, else one staged for it, made now where [allowAutoGenerateSecretKey]
  /// lets; null when none may be made, also in an app that syncs no keys
  /// ([init] not called). [commitSecretKey] once the account key holds it.
  static Future<String?> secretKeyCandidate() async {
    if (!ready) return null;
    return _said(() => _ring.secretKeyCandidate());
  }

  /// Whether the app syncs keys here ([init] called).
  static bool get ready => _keys != null || _label != null;

  /// [candidate] ([secretKeyCandidate]) as this device's secret key.
  static Future<void> commitSecretKey(String candidate) => _said(() => _ring.commitSecretKey(candidate: candidate));

  /// Marks [candidate] as having an in-flight external remote commit so a
  /// conflicting import cannot erase it if a post-write step fails.
  static Future<void> stageExternalSecretKeyCommit(String candidate) =>
      _said(() => _ring.stageExternalSecretKeyCommit(candidate: candidate));

  /// Clears the external commit marker for [candidate] when the remote write
  /// is confirmed not to have committed.
  static Future<void> clearExternalSecretKeyCommit(String candidate) =>
      _said(() => _ring.clearExternalSecretKeyCommit(candidate: candidate));

  /// [id]'s remote is not synced here any more: read again next time.
  static void release(String id) {
    if (_accountKeySealedFor == id) _accountKeySealedFor = null;
    // None opened yet: nothing to release.
    _keys?.release(id: id);
    _syncNotifiers();
    if (_keys == null) {
      passwordMismatch.value = {...passwordMismatch.value}..remove(id);
    }
  }

  /// [id]'s remote is gone from this device: what it knew of its file goes.
  static Future<void> forget(String id) {
    if (_accountKeySealedFor == id) _accountKeySealedFor = null;
    return _said(() => _ring.forget(id: id));
  }

  /// Before the backup password here changes from [previous].
  static Future<void> passwordChanged(String? previous) => _said(() => _ring.passwordChanged(previous: previous));

  /// Every key in use checked again now: the password or the secret key here
  /// changed.
  static Future<void> recheck() {
    _accountKeySealedFor = null;
    return _said(() => _ring.recheck());
  }

  /// [sealed] opened with a key of a sync on here.
  static Future<Uint8List> openAny(Uint8List sealed) => _said(() => _ring.openAny(sealed: sealed));

  /// [sealed] opened with any key this device keeps: a synced backup picked
  /// to restore.
  static Future<Uint8List> openKept(Uint8List sealed) => _said(() => _ring.openKept(sealed: sealed));

  /// Whether [data] is sealed to a key; one sealed with a password otherwise,
  /// or not at all.
  static bool sealedToKey(List<int> data) {
    if (data.length < _keySealed.length) return false;
    for (var i = 0; i < _keySealed.length; i++) {
      if (data[i] != _keySealed[i]) return false;
    }
    return true;
  }

  static final _keySealed = utf8.encode('age-encryption.org/v1\n-> X25519 ');

  static Future<SyncReply> _file(SyncKeyFile file, String method, String args, Uint8List? bytes) => switch (method) {
    'keyFile.read' => syncReply(file.read, bytes: (r) => r?.body, json: (r) => r?.version),
    'keyFile.write' => syncReply(() => file.write(bytes ?? Uint8List(0), ifVersion: jsonDecode(args) as String?)),
    'keyFile.canCreate' => syncReply(file.canCreate),
    _ => Future.value(SyncReply(json: '', error: 'no such call: $method', errorKind: 'host')),
  };

  /// The keys of [id], one per line, the newest first: beside the backup
  /// password, so another Apple device of the person's has them.
  static SecureProp _kept(String id) => SecureProp('syncIdentity.$id', storage: SecureStore.synced, legacy: SecureStore.storage);

  /// Each key file's epoch as this device last opened it (JSON). Device
  /// local. Key is permanent.
  static const _epochsProp = PrefProp<String>('sync_key_epochs');

  /// The password each key file is still sealed with after a change here
  /// (JSON). On this device only, until the file is sealed again. Key is
  /// permanent.
  static const _pendingProp = SecureProp('syncKeyPending');

  /// Device-local staging slot for a candidate secret key generated before
  /// committing a remote key file.
  static const _pendingSecretKeyProp = SecureProp('syncSecretKeyPending');

  static Future<SyncReply> _secrets(String method, String args, Uint8List? _) {
    final a = args.isEmpty ? null : jsonDecode(args);
    return switch (method) {
      // Unlimited: a sync is not a user asking.
      'secrets.password' => syncReply(() async {
        final pwd = await SecureStoreProps.bakPwd.read(limited: false);
        return pwd == null || pwd.isEmpty ? null : pwd;
      }),
      'secrets.secretKey' => syncReply(() async {
        final key = await SecureStoreProps.syncSecretKey.read(limited: false);
        return key == null || key.isEmpty ? null : key;
      }),
      'secrets.setSecretKey' => syncReply(() async {
        final key = a as String;
        await SecureStoreProps.syncSecretKey.write(key, limited: false);
        secretKeyGenerated.value = key;
      }),
      'secrets.importSecretKey' => syncReply(() async {
        final key = a as String;
        await SecureStoreProps.syncSecretKey.write(key, limited: false);
      }),
      'secrets.pendingSecretKey' => syncReply(() async {
        final key = await _pendingSecretKeyProp.read(limited: false);
        return key == null || key.isEmpty ? null : key;
      }),
      'secrets.setPendingSecretKey' => syncReply(() async {
        final key = a as String?;
        await _pendingSecretKeyProp.write(key == null || key.isEmpty ? null : key, limited: false);
      }),
      'secrets.allowAutoGenerate' => syncReply(() async => allowAutoGenerateSecretKey?.call() ?? true),
      'secrets.kept' => syncReply(() => _kept(a as String).read(limited: false)),
      'secrets.setKept' => syncReply(() => _kept((a as Map)['id'] as String).write(a['identities'] as String, limited: false)),
      'secrets.epochs' => syncReply(() => _decoded(_epochsProp.get())),
      'secrets.setEpochs' => syncReply(() async {
        final all = a as Map;
        all.isEmpty ? await _epochsProp.remove() : await _epochsProp.set(jsonEncode(all));
      }),
      'secrets.pending' => syncReply(() async => _decoded(await _pendingProp.storage.read(key: _pendingProp.key))),
      'secrets.setPending' => syncReply(() {
        final all = a as Map;
        return _pendingProp.storage.write(key: _pendingProp.key, value: all.isEmpty ? null : jsonEncode(all));
      }),
      _ => Future.value(SyncReply(json: '', error: 'no such call: $method', errorKind: 'host')),
    };
  }

  static Map<String, Object?> _decoded(String? raw) {
    if (raw == null) return const {};
    try {
      return switch (jsonDecode(raw)) {
        final Map<String, Object?> m => m,
        _ => const {},
      };
    } on FormatException {
      return const {};
    }
  }

  @visibleForTesting
  static void resetForTest() {
    _keys = null;
    _label = null;
    passwordMismatch.value = const {};
    secretKeyMissing.value = false;
    secretKeyGenerated.value = null;
    allowAutoGenerateSecretKey = null;
    _accountKeySealedFor = null;
    _secretKeyLock = Future.value();
  }
}
