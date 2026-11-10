import 'dart:typed_data';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'rust_lib.dart';

/// A folder in memory, as WebDAV keeps one.
final class _Folder implements SyncFiles {
  final files = <String, (Uint8List, DateTime)>{};

  @override
  Future<void> write(String name, Uint8List body) async {
    files[name] = (body, DateTime.now());
  }

  @override
  Future<Uint8List?> read(String name) async => files[name]?.$1;

  @override
  Future<List<({String name, DateTime? at})>> list(String prefix) async => [
    for (final MapEntry(key: name, value: (_, at)) in files.entries)
      if (name.startsWith(prefix)) (name: name, at: at),
  ];

  @override
  Future<void> delete(String name) async {
    files.remove(name);
  }
}

/// This install as another device: a fresh database, another device id.
Future<SqliteStore> _freshDevice() async {
  await SqliteDb.close();
  SqliteDb.openInMemory();
  SyncTables.ensure();
  SyncRecorder.resetForTest();
  final store = SqliteStore('settings');
  SyncRecorder.install([store]);
  return store;
}

Future<SyncSegmentEngine> _engine(_Folder folder) async {
  final key = await SyncKeyring.ofFiles(FilesKeyFile(folder, 'folder'));
  final host = SyncHost(files: folder);
  await syncCall(() => SyncSegmentEngine.bind(store: 'folder', host: host.call));
  return SyncSegmentEngine(key: key, host: host.call);
}

void main() {
  setUpAll(loadFlRustForTest);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PrefStore.shared.init();
    FlutterSecureStorage.setMockInitialValues({'bakPwd': 'pw'});
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');
  });

  tearDown(SqliteDb.close);

  test('what one device edits, another reads from the folder', () async {
    final folder = _Folder();
    var store = await _freshDevice();
    store.set('theme', 'dark');
    store.set('font', {'size': 14});
    await syncCall((await _engine(folder)).run);
    expect(folder.files.keys.where((n) => n.startsWith('seg-')), isNotEmpty);
    expect(folder.files.keys, contains('identity.age'));

    // Another device, the same password: its keychain brought the keys.
    store = await _freshDevice();
    expect(store.get<String>('theme'), isNull);
    await syncCall((await _engine(folder)).run);
    expect(store.get<String>('theme'), 'dark');
    expect(store.get<Map<String, dynamic>>('font'), {'size': 14});
    // Taken as the other device's: nothing of it waits to be sent back.
    expect(SyncRecorder.pending(''), isEmpty);
  });

  test('a delete reaches the other device, and a later edit there wins', () async {
    final folder = _Folder();
    var store = await _freshDevice();
    store.set('theme', 'dark');
    await syncCall((await _engine(folder)).run);
    store.remove('theme');
    await syncCall((await _engine(folder)).run);
    // A value no edit here stamped (an old backup's): the delete wins.
    store = await _freshDevice();
    store.set('theme', 'stale', updateLastUpdateTsOnSet: false);
    final engine = await _engine(folder);
    await syncCall(engine.run);
    expect(store.get<String>('theme'), isNull);
    // Edited here after it: this one stays.
    store.set('theme', 'light');
    await syncCall(engine.run);
    expect(store.get<String>('theme'), 'light');
  });

  test('another password syncs nothing, and says so', () async {
    final folder = _Folder();
    final store = await _freshDevice();
    store.set('theme', 'dark');
    await syncCall((await _engine(folder)).run);
    await _freshDevice();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');
    FlutterSecureStorage.setMockInitialValues({'bakPwd': 'other'});
    await expectLater(_engine(folder), throwsA(isA<SyncPasswordMismatch>()));
    expect(SyncKeyring.passwordMismatch.value, {'folder'});
  });

  test('a key seals and opens what the whole backup is', () async {
    final folder = _Folder();
    await _freshDevice();
    final key = await SyncKeyring.ofFiles(FilesKeyFile(folder, 'folder'));
    final sealed = key.seal(plain: Uint8List.fromList([1, 2, 3]));
    expect(SyncKeyring.sealedToKey(sealed), isTrue);
    expect(await SyncKeyring.openAny(sealed), [1, 2, 3]);
  });
}
