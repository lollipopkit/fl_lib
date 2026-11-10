import 'dart:async';
import 'dart:convert';

import 'package:fl_lib/src/core/store/iface.dart';
import 'package:fl_lib/src/core/store/secure.dart';
import 'package:fl_lib/src/core/sync/log/errors.dart';
import 'package:fl_lib/src/core/sync/log/host.dart';
import 'package:fl_lib/src/rust/api/lkc.dart';
import 'package:fl_lib/src/rust/api/sync_engine.dart';
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

  /// [label] begins the key file's comment line (`ServerBox sync key`). Once,
  /// at launch.
  static void init({required String label}) {
    _keys ??= SyncKeys(label: label, secrets: _secrets);
  }

  static SyncKeys get _ring => _keys ?? (throw StateError('SyncKeyring.init was not called'));

  static Future<T> _said<T>(Future<T> Function() run) async {
    try {
      return await syncCall(run);
    } finally {
      final now = _ring.mismatch().toSet();
      if (!setEquals(now, passwordMismatch.value)) passwordMismatch.value = now;
    }
  }

  /// The key of [account] on LK Cloud. Without [create] (a restore, nothing
  /// synced), none is made where there is none: [SyncKeyNotHere].
  static Future<SyncKeyHandle> ofLkc(LkcSync sync, String account, {bool create = true}) =>
      _said(() => _ring.ofLkc(lkc: sync, account: account, create: create));

  /// The key beside a folder's segments.
  static Future<SyncKeyHandle> ofFiles(SyncKeyFile file, {bool create = true}) =>
      _said(() => _ring.ofFiles(id: file.id, create: create, file: (method, args, bytes) => _file(file, method, args, bytes)));

  /// [id]'s remote is not synced here any more: read again next time.
  static void release(String id) {
    // None opened yet: nothing to release.
    _keys?.release(id: id);
    passwordMismatch.value = {...passwordMismatch.value}..remove(id);
  }

  /// [id]'s remote is gone from this device: what it knew of its file goes.
  static Future<void> forget(String id) => _said(() => _ring.forget(id: id));

  /// Before the backup password here changes from [previous].
  static Future<void> passwordChanged(String? previous) => _said(() => _ring.passwordChanged(previous: previous));

  /// Every key in use checked again now: the password here changed.
  static Future<void> recheck() => _said(() => _ring.recheck());

  /// [sealed] opened with a key of a sync on here.
  static Future<Uint8List> openAny(Uint8List sealed) => _said(() => _ring.openAny(sealed: sealed));

  /// [sealed] opened with any key this device keeps: a synced backup picked
  /// to restore.
  static Future<Uint8List> openKept(Uint8List sealed) => _said(() => _ring.openKept(sealed: sealed));

  /// Whether [data] is sealed to a key; one sealed with a password otherwise.
  static bool sealedToKey(Uint8List data) => syncSealedToKey(data: data);

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

  static Future<SyncReply> _secrets(String method, String args, Uint8List? _) {
    final a = args.isEmpty ? null : jsonDecode(args);
    return switch (method) {
      // Unlimited: a sync is not a user asking.
      'secrets.password' => syncReply(() async {
        final pwd = await SecureStoreProps.bakPwd.read(limited: false);
        return pwd == null || pwd.isEmpty ? null : pwd;
      }),
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
    passwordMismatch.value = const {};
  }
}
