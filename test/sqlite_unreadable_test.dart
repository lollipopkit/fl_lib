import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_secure_storage/test/test_flutter_secure_storage_platform.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A vault whose every read throws, as Android's does once its key pair no
/// longer unwraps the stored key (ServerBox #1784).
class _FailingVault extends TestFlutterSecureStoragePlatform {
  _FailingVault() : super({});

  final deleteAllOptions = <Map<String, String>>[];

  @override
  Future<String?> read({required String key, required Map<String, String> options}) =>
      throw PlatformException(code: 'Exception encountered', message: 'Failed to unwrap key');

  @override
  Future<void> deleteAll({required Map<String, String> options}) {
    deleteAllOptions.add(options);
    return super.deleteAll(options: options);
  }
}

/// `SqliteDb.open` on a file its key does not open (ServerBox #1780).
///
/// The SQLite under test has no cipher, so the "wrong key" is a file that is
/// not a database at all: SQLite answers both with `SQLITE_NOTADB`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File db;

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('sqlite_unreadable');
    db = File('${dir.path}/${SqliteDb.fileName}');
    SharedPreferences.setMockInitialValues({});
    await PrefStore.shared.init();
    FlutterSecureStorage.setMockInitialValues({});
  });

  tearDown(() async {
    await SqliteDb.close();
    dir.deleteSync(recursive: true);
  });

  void writeGarbage() => db.writeAsBytesSync(List.filled(4096, 0x5a));

  Future<StoreUnreadableException> openFails() async {
    try {
      await SqliteDb.open(dir.path);
    } on StoreUnreadableException catch (e) {
      return e;
    }
    fail('open succeeded');
  }

  test('a file with no key in the vault is keyLost, and no key is made', () async {
    writeGarbage();
    final e = await openFails();
    expect(e.reason, StoreUnreadableReason.keyLost);
    expect(e.path, db.path);
    expect(e.cause, isNull);
    expect(SqliteDb.isOpen, isFalse);
    expect(await SecureStoreProps.hivePwd.read(), isNull);
  });

  test('an empty file with no key opens as a first launch', () async {
    db.writeAsBytesSync([]);
    await SqliteDb.open(dir.path);
    expect(SqliteDb.isOpen, isTrue);
    expect(await SecureStoreProps.hivePwd.read(), isNotNull);
  });

  test('a file the stored key does not open is keyRejected', () async {
    await SecureStoreProps.hivePwd.write('A' * 43 + '=');
    writeGarbage();
    expect((await openFails()).reason, StoreUnreadableReason.keyRejected);
  });

  test('the exception describes the file', () async {
    await SecureStoreProps.hivePwd.write('A' * 43 + '=');
    writeGarbage();
    final e = await openFails();
    expect(e.file, contains('db=4096B@'));
    expect(e.file, contains('page1=opaque'));
    expect('$e', contains(e.file));
  });

  test('describe tells a zeroed file and a plaintext one apart', () {
    db.writeAsBytesSync(List.filled(8192, 0));
    expect(StoreUnreadableException.describe(db.path), contains('page1=zero'));
    db.writeAsBytesSync([...'SQLite format 3\x00'.codeUnits, ...List.filled(100, 1)]);
    File('${db.path}-wal').writeAsBytesSync([1, 2]);
    final s = StoreUnreadableException.describe(db.path);
    expect(s, contains('page1=plain'));
    expect(s, contains('-wal=2B@'));
    expect(s, contains('-shm=none'));
  });

  test('a first launch opens', () async {
    await SqliteDb.open(dir.path);
    expect(SqliteDb.isOpen, isTrue);
  });

  test('setAside keeps the file and its sidecars, and open starts empty', () async {
    await SecureStoreProps.hivePwd.write('A' * 43 + '=');
    writeGarbage();
    final e = await openFails();
    // After the failed open, which drops an invalid `-wal` as it closes.
    File('${db.path}-wal').writeAsStringSync('wal');

    final aside = SqliteDb.setAside(e.path);
    expect(db.existsSync(), isFalse);
    expect(File(aside).lengthSync(), 4096);
    expect(File('$aside-wal').readAsStringSync(), 'wal');

    await SqliteDb.open(dir.path);
    expect(SqliteDb.isOpen, isTrue);
  });

  test('setAside refuses an open database', () async {
    await SqliteDb.open(dir.path);
    expect(() => SqliteDb.setAside(db.path), throwsStateError);
  });

  test('a file whose key the vault cannot read is vaultFailed, and no key is made', () async {
    writeGarbage();
    final vault = _FailingVault();
    FlutterSecureStoragePlatform.instance = vault;
    final e = await openFails();
    expect(e.reason, StoreUnreadableReason.vaultFailed);
    expect(e.path, db.path);
    expect(e.cause, isA<PlatformException>());
    expect(SqliteDb.isOpen, isFalse);
    expect(db.readAsBytesSync(), List.filled(4096, 0x5a));
    expect(vault.data, isEmpty);
  });

  test('a first launch with a vault that throws rethrows the vault\'s error', () async {
    FlutterSecureStoragePlatform.instance = _FailingVault();
    await expectLater(SqliteDb.open(dir.path), throwsA(isA<PlatformException>()));
  });

  test('SecureStore.reset lets the Android plugin reset', () async {
    final vault = _FailingVault();
    FlutterSecureStoragePlatform.instance = vault;
    await SecureStore.reset();
    expect(vault.deleteAllOptions.single['resetOnError'], 'true');
  });
}
