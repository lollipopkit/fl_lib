import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

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

/// A folder out of reach.
final class _Unreachable extends _Folder {
  var reachable = true;

  @override
  Future<List<({String name, DateTime? at})>> list(String prefix) {
    if (!reachable) throw const SocketException('no route');
    return super.list(prefix);
  }
}

/// A log that takes no batch: always full.
final class _FullLog extends _Log {
  @override
  Future<({String log, int seq, bool compact})> append(String key, Uint8List body) => throw const SyncLogFull();
}

/// A server-ordered log in memory, as LK Cloud keeps one.
final class _Log extends _Folder implements SyncLogStore {
  final batches = <(int, String, Uint8List)>[];
  (int, Uint8List)? snap;

  @override
  Future<({String log, int seq, bool compact})> append(String key, Uint8List body) async {
    for (final (seq, k, _) in batches) {
      if (k == key) return (log: 'l', seq: seq, compact: false);
    }
    final seq = (batches.lastOrNull?.$1 ?? 0) + 1;
    batches.add((seq, key, body));
    return (log: 'l', seq: seq, compact: batches.length % 3 == 0);
  }

  @override
  Future<SyncLogPage> readLog(int after, String? log) async => SyncLogPage(
    log: 'l',
    batches: [for (final (seq, _, body) in batches) if (seq > after) (seq, body)],
    more: false,
  );

  @override
  Future<bool> putSnapshot(int seq, Uint8List body) async {
    if ((snap?.$1 ?? 0) >= seq) return false;
    snap = (seq, body);
    return true;
  }

  @override
  Future<({String log, int seq, Uint8List body})?> snapshot() async =>
      snap == null ? null : (log: 'l', seq: snap!.$1, body: snap!.$2);
}

/// The key file on a log: writes ordered.
final class _LogKeyFile implements SyncKeyFile {
  ({Uint8List body, String version})? file;
  var _v = 0;

  @override
  String get id => 'account';

  @override
  Future<({Uint8List body, String version})?> read() async => file;

  @override
  Future<String?> write(Uint8List body, {required String? ifVersion}) async {
    if (file?.version != ifVersion) return null;
    file = (body: body, version: 'v${++_v}');
    return file!.version;
  }

  @override
  Future<bool> canCreate() async => true;
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
    SecureProp.legacyApart = false;
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');
  });

  tearDown(() async {
    SecureProp.legacyApart = null;
    await SqliteDb.close();
  });

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
    final secretKey = await SecureStoreProps.syncSecretKey.read(limited: false);
    expect(secretKey, isNotNull);
    expect(SyncKeyring.normalizeSecretKey(secretKey!), secretKey);

    // Without the client-side secret key, the second device gets SyncSecretKeyMissing.
    await _freshDevice();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');
    FlutterSecureStorage.setMockInitialValues({'bakPwd': 'pw'});
    await expectLater(_engine(folder), throwsA(isA<SyncSecretKeyMissing>()));
    expect(SyncKeyring.secretKeyMissing.value, isTrue);

    // With the secret key but another password, it gets SyncPasswordMismatch.
    await _freshDevice();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');
    FlutterSecureStorage.setMockInitialValues({'bakPwd': 'other', 'syncSecretKey': secretKey});
    await expectLater(_engine(folder), throwsA(isA<SyncPasswordMismatch>()));
    expect(SyncKeyring.passwordMismatch.value, {'folder'});
  });

  test('secret key generation and normalization validate checksums', () {
    final key = SyncKeyring.generateSecretKey();
    expect(key, startsWith('S1-'));
    expect(key.length, 38);
    expect(SyncKeyring.normalizeSecretKey('  ${key.toLowerCase().replaceAll('-', ' ')}  '), key);
    final bad = '${key.substring(0, key.length - 1)}${key.endsWith('0') ? '1' : '0'}';
    expect(SyncKeyring.normalizeSecretKey(bad), isNull);
  });

  test('a log Dart keeps carries the edits, and its snapshot covers them', () async {
    final log = _Log();
    final file = _LogKeyFile();
    Future<SyncLogEngine> engine() async {
      final key = await SyncKeyring.ofFiles(file);
      final host = SyncHost(log: log);
      await syncCall(() => SyncLogEngine.bind(account: 'account', host: host.call));
      return SyncLogEngine.onDart(key: key, host: host.call);
    }

    var store = await _freshDevice();
    final a = await engine();
    for (var i = 0; i < 4; i++) {
      store.set('k$i', i);
      await syncCall(a.run);
    }
    expect(log.batches, hasLength(4));
    expect(log.snap, isNotNull);
    store = await _freshDevice();
    await syncCall((await engine()).run);
    expect([for (var i = 0; i < 4; i++) store.get<int>('k$i')], [0, 1, 2, 3]);
  });

  test('a folder out of reach is the remote\'s failure', () async {
    final folder = _Unreachable();
    await _freshDevice();
    final engine = await _engine(folder);
    folder.reachable = false;
    await expectLater(syncCall(engine.run), throwsA(isA<SyncError>().having((e) => e.kind, 'kind', SyncEngineErrorKind.remote)));
  });

  test('a full log with no snapshot to make reaches the caller as such', () async {
    final log = _FullLog();
    final store = await _freshDevice();
    final key = await SyncKeyring.ofFiles(_LogKeyFile());
    final host = SyncHost(log: log);
    store.set('k', 1);
    // Nothing read yet: no snapshot can cover the log.
    await expectLater(
      syncCall(SyncLogEngine.onDart(key: key, host: host.call).run),
      throwsA(isA<SyncError>().having((e) => e.kind, 'kind', SyncEngineErrorKind.logFull)),
    );
  });

  test('a key seals and opens what the whole backup is', () async {
    final folder = _Folder();
    await _freshDevice();
    final key = await SyncKeyring.ofFiles(FilesKeyFile(folder, 'folder'));
    final sealed = await key.seal(plain: Uint8List.fromList([1, 2, 3]));
    expect(SyncKeyring.sealedToKey(sealed), isTrue);
    expect(await SyncKeyring.openAny(sealed), [1, 2, 3]);
  });

  test('accountKeySealed is scoped per account and clears on account switch or sign-out', () {
    SyncKeyring.accountKeySealed('account-a');
    expect(SyncKeyring.secretKeyMissing.value, isTrue);

    // Same account keeps the sealed flag.
    SyncKeyring.syncLkcAccount('account-a');
    expect(SyncKeyring.secretKeyMissing.value, isTrue);

    // Switching to another account clears it before listeners observe secretKeyMissing.
    SyncKeyring.syncLkcAccount('account-b');
    expect(SyncKeyring.secretKeyMissing.value, isFalse);

    // Releasing or signing out clears the sealed account as well.
    SyncKeyring.accountKeySealed('account-b');
    expect(SyncKeyring.secretKeyMissing.value, isTrue);
    SyncKeyring.release('account-b');
    expect(SyncKeyring.secretKeyMissing.value, isFalse);

    SyncKeyring.accountKeySealed('account-c');
    expect(SyncKeyring.secretKeyMissing.value, isTrue);
    SyncKeyring.syncLkcAccount(null);
    expect(SyncKeyring.secretKeyMissing.value, isFalse);
  });

  test('storeSecretKey rejects conflicting import when a staged key committed via ofFiles', () async {
    final folder = _Folder();
    await _freshDevice();
    final writeStarted = Completer<void>();
    final releaseWrite = Completer<void>();
    final inner = FilesKeyFile(folder, 'folder');
    final slowFile = _BlockingKeyFile(inner, writeStarted, releaseWrite);

    // Start ofFiles which generates staged key A and writes remotely.
    final opening = SyncKeyring.ofFiles(slowFile);
    await writeStarted.future;

    // Concurrently attempt to import conflicting secret key B while write is in flight.
    // Attach expectLater immediately so an early rejection is captured cleanly.
    final keyB = SyncKeyring.generateSecretKey();
    final importAssertion = expectLater(
      SyncKeyring.storeSecretKey(keyB),
      throwsA(anything),
    );

    // Allow the remote write with staged key A to commit and promote.
    releaseWrite.complete();
    final handle = await opening;
    final committedA = await SecureStoreProps.syncSecretKey.read(limited: false);
    expect(committedA, isNotNull);
    expect(committedA, isNot(keyB));

    // Conflicting import B must be rejected rather than overwriting committed key A.
    await importAssertion;
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), committedA);
    expect(await handle.open(sealed: await handle.seal(plain: Uint8List.fromList([7, 8]))), [7, 8]);
  });

  test('storeSecretKey validates and normalizes input consistently across both paths', () async {
    final canonical = SyncKeyring.generateSecretKey();
    final alternateSpelling = '  ${canonical.toLowerCase().replaceAll('-', ' ')}  ';
    const invalidReady = 'S1-NOT-A-VALID-READY-KEY-9999';
    const invalidNotReady = 'S1-NOT-A-VALID-UNREADY-KEY-8888';

    // Invalid secret key is rejected before modifying secure storage and never
    // retains or displays the supplied key value in ArgumentError.
    await expectLater(
      SyncKeyring.storeSecretKey(invalidReady),
      throwsA(
        isA<ArgumentError>()
            .having((e) => e.name, 'name', 'key')
            .having((e) => e.invalidValue, 'invalidValue', isNull)
            .having((e) => e.message, 'message', 'Invalid sync secret key')
            .having((e) => e.toString(), 'toString', isNot(contains(invalidReady))),
      ),
    );
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), isNull);

    // Ready path stores canonical spelling.
    await SyncKeyring.storeSecretKey(alternateSpelling);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), canonical);

    // Non-ready path also validates and stores canonical spelling without leaking input.
    SyncKeyring.resetForTest();
    FlutterSecureStorage.setMockInitialValues({});
    await expectLater(
      SyncKeyring.storeSecretKey(invalidNotReady),
      throwsA(
        isA<ArgumentError>()
            .having((e) => e.name, 'name', 'key')
            .having((e) => e.invalidValue, 'invalidValue', isNull)
            .having((e) => e.message, 'message', 'Invalid sync secret key')
            .having((e) => e.toString(), 'toString', isNot(contains(invalidNotReady))),
      ),
    );
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), isNull);
    await SyncKeyring.storeSecretKey(alternateSpelling);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), canonical);
  });

  test('storeSecretKey non-ready path enforces durable intent whether active or staged', () async {
    final keyA = SyncKeyring.generateSecretKey();
    final keyB = SyncKeyring.generateSecretKey();
    final intentJson = '{"ext-intent:lkc-account-key":"{\\"epoch\\":0,\\"pwd\\":\\"$keyA\\"}"}';
    final legacyIntentJson = '{"intent:lkc-account-key":"{\\"epoch\\":0,\\"pwd\\":\\"$keyA\\"}"}';

    // Case 1: keyA is already ACTIVE (no pending staged key), durable external intent exists.
    SyncKeyring.resetForTest();
    FlutterSecureStorage.setMockInitialValues({
      'syncSecretKey': keyA,
      'syncKeyPending': intentJson,
    });
    await expectLater(SyncKeyring.storeSecretKey(keyB), throwsStateError);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), keyA);

    // Same-key import is allowed and keeps the unresolved intent intact.
    await SyncKeyring.storeSecretKey(keyA);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), keyA);
    await expectLater(SyncKeyring.storeSecretKey(keyB), throwsStateError);

    // Case 2: keyA is STAGED (no active key), durable external intent exists.
    FlutterSecureStorage.setMockInitialValues({
      'syncSecretKeyPending': keyA,
      'syncKeyPending': intentJson,
    });
    await expectLater(SyncKeyring.storeSecretKey(keyB), throwsStateError);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), isNull);

    // Case 2b: legacy `intent:lkc-account-key` record is still enforced during migration.
    FlutterSecureStorage.setMockInitialValues({
      'syncSecretKey': keyA,
      'syncKeyPending': legacyIntentJson,
    });
    await expectLater(SyncKeyring.storeSecretKey(keyB), throwsStateError);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), keyA);
    await SyncKeyring.storeSecretKey(keyA);

    // Case 3: once no unresolved intent exists, replacing active keyA with keyB succeeds.
    FlutterSecureStorage.setMockInitialValues({
      'syncSecretKey': keyA,
    });
    await SyncKeyring.storeSecretKey(keyB);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), keyB);
  });

  group('FileLogSync WebDAV binding', () {
    late HttpServer server;
    final requests = <({String method, String path, String? auth})>[];

    setUp(() async {
      requests.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        requests.add((
          method: request.method,
          path: request.uri.path,
          auth: request.headers.value(HttpHeaders.authorizationHeader),
        ));
        await request.drain<void>();
        request.response.statusCode = HttpStatus.created;
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    Webdav makeWebdav({String path = '/dav/', String user = 'alice', String pwd = 'p1'}) => Webdav(
      client: WebdavClient.basicAuth(
        url: 'http://127.0.0.1:${server.port}$path',
        user: user,
        pwd: pwd,
      ),
    );

    String basicAuth(String user, String pwd) => 'Basic ${base64.encode(utf8.encode('$user:$pwd'))}';

    test('writes while active remote matches and follows credential updates', () async {
      RemoteStorage<Object?>? current = makeWebdav(pwd: 'p1');
      final sync = FileLogSync(
        remote: () => current,
        folder: 'srvbox_sync',
        on: () => true,
        webdavAccount: () => 'alice',
      );

      final files = sync.boundFilesForTest(current, requireActive: true)!;
      await files.write('seg-1.age', Uint8List.fromList([1, 2, 3]));
      expect(
        requests.where((r) => r.method == 'PUT' && r.path == '/dav/lpkt-apps/srvbox_sync/seg-1.age').single.auth,
        basicAuth('alice', 'p1'),
      );

      // Rotating password yields a new Webdav instance with the same store id and updated credentials.
      requests.clear();
      current = makeWebdav(pwd: 'p2');
      await files.write('seg-2.age', Uint8List.fromList([4, 5, 6]));
      expect(
        requests.where((r) => r.method == 'PUT' && r.path == '/dav/lpkt-apps/srvbox_sync/seg-2.age').single.auth,
        basicAuth('alice', 'p2'),
      );
    });

    test('aborts writes without hitting stale server when active remote is removed or disabled', () async {
      var active = true;
      RemoteStorage<Object?>? current = makeWebdav();
      final sync = FileLogSync(
        remote: () => current,
        folder: 'srvbox_sync',
        on: () => active,
        webdavAccount: () => 'alice',
      );

      final files = sync.boundFilesForTest(current, requireActive: true)!;
      // Warm _made with an initial write.
      await files.write('seg-1.age', Uint8List.fromList([1]));
      requests.clear();

      // Removing active remote (remote() == null) aborts writes instead of falling back.
      current = null;
      await expectLater(files.write('seg-2.age', Uint8List.fromList([2])), throwsStateError);
      expect(requests, isEmpty);

      // Clearing client (Webdav(client: null)) also aborts writes.
      current = Webdav(client: null);
      await expectLater(files.write('seg-3.age', Uint8List.fromList([3])), throwsStateError);
      expect(requests, isEmpty);

      // Switching active remote to iCloud also aborts WebDAV writes.
      current = ICloud(containerId: 'iCloud.test');
      await expectLater(files.write('seg-4.age', Uint8List.fromList([4])), throwsStateError);
      expect(requests, isEmpty);

      // Turning sync off (on() == false) while remote() still returns Webdav also aborts.
      current = makeWebdav();
      active = false;
      await expectLater(files.write('seg-5.age', Uint8List.fromList([5])), throwsStateError);
      expect(requests, isEmpty);
    });

    test('aborts writes when active remote switches to another endpoint or account', () async {
      RemoteStorage<Object?>? current = makeWebdav(path: '/dav/');
      var account = 'alice';
      final sync = FileLogSync(
        remote: () => current,
        folder: 'srvbox_sync',
        on: () => true,
        webdavAccount: () => account,
      );

      final files = sync.boundFilesForTest(current, requireActive: true)!;
      current = makeWebdav(path: '/other/');
      await expectLater(files.write('seg-1.age', Uint8List.fromList([1])), throwsStateError);
      expect(requests, isEmpty);

      current = makeWebdav(path: '/dav/');
      account = 'bob';
      await expectLater(files.write('seg-2.age', Uint8List.fromList([2])), throwsStateError);
      expect(requests, isEmpty);
    });

    test('non-active binding (pre-enable keyOf) still writes when sync is off', () async {
      final candidate = makeWebdav();
      final sync = FileLogSync(
        remote: () => null,
        folder: 'srvbox_sync',
        on: () => false,
        webdavAccount: () => 'alice',
      );

      final files = sync.boundFilesForTest(candidate, requireActive: false)!;
      await files.write('identity.age', Uint8List.fromList([9]));
      expect(
        requests.any((r) => r.method == 'PUT' && r.path == '/dav/lpkt-apps/srvbox_sync/identity.age'),
        isTrue,
      );
    });
  });
}

final class _BlockingKeyFile implements SyncKeyFile {
  final SyncKeyFile inner;
  final Completer<void> writeStarted;
  final Completer<void> releaseWrite;

  _BlockingKeyFile(this.inner, this.writeStarted, this.releaseWrite);

  @override
  String get id => inner.id;

  @override
  Future<({Uint8List body, String version})?> read() => inner.read();

  @override
  Future<String?> write(Uint8List body, {required String? ifVersion}) async {
    if (!writeStarted.isCompleted) writeStarted.complete();
    await releaseWrite.future;
    return inner.write(body, ifVersion: ifVersion);
  }

  @override
  Future<bool> canCreate() => inner.canCreate();
}
