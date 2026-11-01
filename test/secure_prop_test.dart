import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late _Vault synced;
  late _Vault local;
  late SecureProp prop;

  setUp(() {
    SecureProp.resetRateLimits();
    SecureProp.legacyApart = true;
    synced = _Vault();
    local = _Vault();
    prop = SecureProp('pwd', storage: synced, legacy: local);
  });

  tearDown(() => SecureProp.legacyApart = null);

  test('a device-only value is read, not copied to the synced store', () async {
    local.values['pwd'] = 'old';
    expect(await prop.read(), 'old');
    expect(synced.values, isEmpty, reason: 'another device may have a newer one on its way');
  });

  test('the synced value wins', () async {
    synced.values['pwd'] = 'new';
    local.values['pwd'] = 'old';
    expect(await prop.read(), 'new');
  });

  test('a write moves it, and clearing does not bring the old one back', () async {
    local.values['pwd'] = 'old';
    await prop.write('new');
    expect(synced.values, {'pwd': 'new'});
    expect(local.values, isEmpty);

    await prop.write(null);
    expect(await prop.read(), isNull);
  });

  test('a value the synced store refuses is kept on this device', () async {
    synced.values['pwd'] = 'old';
    synced.failWrites = true;
    await prop.write('new');
    expect(local.values, {'pwd': 'new'});
    expect(await prop.read(), 'new', reason: 'not the one it replaced');
  });

  test('a refused write whose old value cannot go changes nothing, and says so', () async {
    synced.values['pwd'] = 'old';
    synced.failWrites = synced.failDeletes = true;
    await expectLater(prop.write('new'), throwsStateError);
    expect(local.values, isEmpty);
    expect(await prop.read(), 'old');
  });

  test('in the synced store only when it is there', () async {
    expect(await prop.inSyncedStore(), isFalse);
    local.values['pwd'] = 'old';
    expect(await prop.inSyncedStore(), isFalse, reason: 'this device only');
    await prop.write('new');
    expect(await prop.inSyncedStore(), isTrue);
    SecureProp.legacyApart = false;
    expect(await prop.inSyncedStore(), isFalse, reason: 'one store underneath');
  });

  test('in the device-only store only when only there', () async {
    expect(await prop.inLegacyOnly(), isFalse);
    local.values['pwd'] = 'old';
    expect(await prop.inLegacyOnly(), isTrue);
    await prop.write('new');
    expect(await prop.inLegacyOnly(), isFalse);
    SecureProp.legacyApart = false;
    local.values['pwd'] = 'x';
    expect(await prop.inLegacyOnly(), isFalse, reason: 'one store underneath');
  });

  test('a synced store that cannot be read falls back to this device', () async {
    synced.failWrites = synced.failReads = true;
    await prop.write('new');
    expect(await prop.read(), 'new');
  });

  test('a device-only copy that cannot be removed does not fail the write', () async {
    local.values['pwd'] = 'old';
    local.failDeletes = true;
    await prop.write('new');
    expect(await prop.read(), 'new');
  });

  test('one store underneath: a write is not deleted after it', () async {
    SecureProp.legacyApart = false;
    final same = _Vault();
    prop = SecureProp('pwd', storage: same, legacy: same);
    await prop.write('new');
    expect(await prop.read(), 'new');
  });
}

final class _Vault implements FlutterSecureStorage {
  final values = <String, String>{};
  var failReads = false;
  var failWrites = false;
  var failDeletes = false;

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failReads) throw StateError('keychain');
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failWrites) throw StateError('keychain');
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (failDeletes) throw StateError('keychain');
    values.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
