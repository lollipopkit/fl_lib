/// [LkcRemoteStorage] through fl_lkc, against a homebase on loopback.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'rust_lib.dart';

/// Homebase's sync for one app, its files kept in memory.
final class _Homebase {
  late final HttpServer _server;
  final files = <String, (String, List<int>)>{};
  var _version = 0;

  /// Answered once to the next write: another device's 412, or a 403 reason.
  String? refuseNext;
  int skewMs = 0;

  Uri get base => Uri.parse('http://127.0.0.1:${_server.port}');

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen(_answer);
  }

  Future<void> close() => _server.close(force: true);

  Future<void> _answer(HttpRequest r) async {
    final res = r.response
      ..headers.set(
        'X-Server-Time',
        DateTime.now().millisecondsSinceEpoch + skewMs,
      );
    final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
    final name = r.uri.pathSegments.length == 4 ? r.uri.pathSegments[3] : null;
    final file = files[name];
    String quoted(String etag) => '"$etag"';

    switch ((r.method, name)) {
      case ('GET', null):
        res.headers.contentType = ContentType.json;
        res.write(jsonEncode({
          'data': [
            for (final MapEntry(:key, :value) in files.entries)
              {'name': key, 'etag': value.$1, 'size': value.$2.length, 'updated_at': ''},
          ],
        }));
      case ('HEAD' || 'GET', _) when file == null:
        res.statusCode = 404;
      case ('HEAD', _):
        res.headers.set('ETag', quoted(file!.$1));
      case ('GET', _):
        res.headers.set('ETag', quoted(file!.$1));
        res.add(file.$2);
      case ('PUT', final name?):
        final refused = refuseNext;
        refuseNext = null;
        final ifMatch = r.headers.value('if-match');
        final absent = r.headers.value('if-none-match') == '*';
        if (refused == 'changed' ||
            (absent && file != null) ||
            (ifMatch != null && ifMatch != quoted(file?.$1 ?? ''))) {
          res.statusCode = 412;
        } else if (refused != null) {
          res.statusCode = 403;
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'code': 2, 'msg': 'No', 'reason': refused, 'data': ''}));
        } else {
          final etag = 'v${++_version}';
          files[name] = (etag, body);
          res
            ..statusCode = 204
            ..headers.set('ETag', quoted(etag));
        }
      default:
        res.statusCode = 404;
    }
    await res.close();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  setUpAll(() async {
    await loadFlRustForTest();
    dir = await Directory.systemTemp.createTemp('fl-lkc-sync-');
    Paths.doc = dir.path;
  });
  tearDownAll(() => dir.delete(recursive: true));

  late _Homebase homebase;
  late LkcRemoteStorage storage;

  setUp(() async {
    homebase = _Homebase();
    await homebase.start();
    await for (final f in dir.list()) {
      await f.delete();
    }
    SyncClock.offsetMs = 0;
    FlutterSecureStorage.setMockInitialValues({
      'lkcToken': jsonEncode({
        'access': 'a1',
        'refresh': 'r1',
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }),
    });
    SecureProp.resetRateLimits();
    final client = LkcClient(
      oidc: LkcOidc(
        clientId: 'test',
        redirectUrl: 'test://auth/callback',
        issuer: homebase.base.resolve('/auth/v1/'),
      ),
      baseUrl: homebase.base,
      cache: LkcMemoryCache(),
    );
    storage = LkcRemoteStorage(client, 'test');
  });

  tearDown(() => homebase.close());

  Future<void> write(String text) =>
      File('${dir.path}/bak.age').writeAsString(text);

  test('writes on the version it read, and says which it made', () async {
    await write('one');
    await storage.upload(relativePath: 'bak.age');
    expect(storage.writtenTag('bak.age'), 'v1');

    await write('two');
    await storage.upload(relativePath: 'bak.age');
    expect(storage.writtenTag('bak.age'), 'v2');
    expect(utf8.decode(homebase.files['bak.age']!.$2), 'two');
    expect(await storage.list(), ['bak.age']);
  });

  test('a write another device beat is a RemoteChangedException', () async {
    await write('mine');
    expect(await storage.exists('bak.age'), isFalse);
    homebase.files['bak.age'] = ('theirs', utf8.encode('theirs'));

    await expectLater(
      storage.upload(relativePath: 'bak.age'),
      throwsA(isA<RemoteChangedException>()),
    );
    expect(utf8.decode(homebase.files['bak.age']!.$2), 'theirs');

    // Read again, the write goes through on what was read.
    await storage.download(relativePath: 'bak.age', localPath: '${dir.path}/got');
    await storage.upload(relativePath: 'bak.age');
    expect(utf8.decode(homebase.files['bak.age']!.$2), 'mine');
  });

  test('a plan without sync is its reason', () async {
    await write('x');
    homebase.refuseNext = 'sync_unavailable';
    await expectLater(
      storage.upload(relativePath: 'bak.age'),
      throwsA(isA<LkcException>().having((e) => e.reason, 'reason', 'sync_unavailable')),
    );
  });

  test('downloads, and a missing file throws', () async {
    homebase.files['bak.age'] = ('v9', utf8.encode('remote'));
    await storage.download(relativePath: 'bak.age');
    expect(await File('${dir.path}/bak.age').readAsString(), 'remote');
    expect(await storage.versionTag('bak.age'), 'v9');

    await expectLater(
      storage.download(relativePath: 'none.age'),
      throwsA(isA<LkcException>()),
    );
  });

  test("the sync clock follows homebase's", () async {
    homebase.skewMs = 60000;
    await storage.versionTag('bak.age');
    expect(SyncClock.offsetMs, closeTo(60000, 2000));
  });

  test('signed app refuses unsigned access when credentials are missing', () async {
    SecureProp.legacyApart = false;
    addTearDown(() => SecureProp.legacyApart = null);
    FlutterSecureStorage.setMockInitialValues({
      'lkcToken': jsonEncode({
        'access': 'a1',
        'refresh': 'r1',
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }),
      'lkcPersonalVersions.u1': jsonEncode({
        'v': 1,
        'files': {'test/bak.age': 2},
        'signed_apps': ['test'],
      }),
    });
    SecureProp.resetRateLimits();
    final signedClient = LkcClient(
      oidc: LkcOidc(
        clientId: 'test',
        redirectUrl: 'test://auth/callback',
        issuer: homebase.base.resolve('/auth/v1/'),
      ),
      baseUrl: homebase.base,
      cache: LkcMemoryCache(),
    );
    final now = DateTime.fromMillisecondsSinceEpoch(0);
    signedClient.user.value = LkcUser(id: 'u1', name: 'u1', group: 'user', createdAt: now, updatedAt: now);
    final signedStorage = LkcRemoteStorage(signedClient, 'test');

    // Missing backup password -> SyncPasswordMissing instead of unsigned access.
    await expectLater(
      signedStorage.list(),
      throwsA(isA<SyncPasswordMissing>()),
    );

    // With password present but secret key missing -> SyncSecretKeyMissing.
    await SecureStoreProps.bakPwd.write('pw', limited: false);
    await expectLater(
      signedStorage.list(),
      throwsA(isA<SyncSecretKeyMissing>()),
    );
  });

  test('corrupt personal versions JSON maps to FormatException', () async {
    FlutterSecureStorage.setMockInitialValues({
      'lkcToken': jsonEncode({
        'access': 'a1',
        'refresh': 'r1',
        'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
      }),
      'lkcPersonalVersions.u1': '{not-valid-json',
    });
    SecureProp.resetRateLimits();
    final badClient = LkcClient(
      oidc: LkcOidc(
        clientId: 'test',
        redirectUrl: 'test://auth/callback',
        issuer: homebase.base.resolve('/auth/v1/'),
      ),
      baseUrl: homebase.base,
      cache: LkcMemoryCache(),
    );
    final now = DateTime.fromMillisecondsSinceEpoch(0);
    badClient.user.value = LkcUser(id: 'u1', name: 'u1', group: 'user', createdAt: now, updatedAt: now);
    final badStorage = LkcRemoteStorage(badClient, 'test');

    await expectLater(
      badStorage.list(),
      throwsA(isA<FormatException>()),
    );
  });

  test('bootstrap recovers staged secret key from sealed account key and rejects unconfirmed 2FA upgrade', () async {
    SharedPreferences.setMockInitialValues({});
    await PrefStore.shared.init();
    SecureProp.legacyApart = false;
    addTearDown(() => SecureProp.legacyApart = null);

    // Server separating sync files per app and serving /v2/keys.
    final files = <String, (String, List<int>)>{};
    Map<String, dynamic> userKey = {'next_seq': 1};
    var version = 0;
    var failNextLkcPut = false;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      final res = r.response;
      final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
      final path = r.uri.path;
      if (path == '/v2/keys') {
        if (r.method == 'GET') {
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'data': userKey}));
        } else if (r.method == 'PUT') {
          final parsed = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
          userKey = {
            'recipient': parsed['recipient'],
            'signing_key': parsed['signing_key'],
            'prev_signing_key': parsed['signing_key'],
            'next_seq': (parsed['seq'] as int) + 1,
          };
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'data': null}));
        }
        await res.close();
        return;
      }
      if (r.uri.pathSegments.length == 4 && r.uri.pathSegments[0] == 'v2' && r.uri.pathSegments[1] == 'sync') {
        final key = '${r.uri.pathSegments[2]}/${r.uri.pathSegments[3]}';
        final entry = files[key];
        switch (r.method) {
          case 'GET':
            if (entry == null) {
              res.statusCode = 404;
            } else {
              res.headers.set('ETag', '"${entry.$1}"');
              res.add(entry.$2);
            }
          case 'PUT':
            if (failNextLkcPut && key == 'lkc/identity.age') {
              failNextLkcPut = false;
              res.statusCode = 500;
            } else {
              final ifMatch = r.headers.value('if-match');
              final absent = r.headers.value('if-none-match') == '*';
              if ((absent && entry != null) || (ifMatch != null && ifMatch != '"${entry?.$1 ?? ''}"')) {
                res.statusCode = 412;
              } else {
                final etag = 'e${++version}';
                files[key] = (etag, body);
                res
                  ..statusCode = 204
                  ..headers.set('ETag', '"$etag"');
              }
            }
          default:
            res.statusCode = 404;
        }
        await res.close();
        return;
      }
      res.statusCode = 404;
      await res.close();
    });

    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final tokenJson = jsonEncode({
      'access': 'a1',
      'refresh': 'r1',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    });
    final now = DateTime.fromMillisecondsSinceEpoch(0);
    LkcClient newClient() {
      final c = LkcClient(
        oidc: LkcOidc(clientId: 'test', redirectUrl: 'test://auth/callback', issuer: base.resolve('/auth/v1/')),
        baseUrl: base,
        cache: LkcMemoryCache(),
      );
      c.user.value = LkcUser(id: 'u1', name: 'u1', group: 'user', createdAt: now, updatedAt: now);
      return c;
    }

    // 1. Seed a legacy passphrase-only account key on the server.
    FlutterSecureStorage.setMockInitialValues({'lkcToken': tokenJson, 'bakPwd': 'pw'});
    SecureProp.resetRateLimits();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');
    final seedClient = newClient();
    final seedTeams = await seedClient.teams();
    await seedTeams.accountKey(passphrase: 'pw', allowLegacy: true);
    expect(files.containsKey('lkc/identity.age'), isTrue);

    // 2. When 2FA upgrade PUT fails, accountKey throws (unconfirmed 2FA),
    //    candidate stays pending (NOT committed), and account key is NOT cached;
    //    best-effort fetchAccountKey still returns the legacy key.
    failNextLkcPut = true;
    final upgrading = newClient();
    await expectLater(upgrading.ensurePersonalAuth('test'), throwsA(isA<LkcException>()));
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), isNull);
    final staged = await SyncKeyring.pendingSecretKey();
    expect(staged, isNotNull);
    expect(await const SecureProp('lkcAccountKey.u1', storage: SecureStore.synced, legacy: SecureStore.storage).read(limited: false), isNull);

    // While `staged` has an unconfirmed external commit, a conflicting import
    // must be rejected so `staged` remains recoverable.
    final conflicting = SyncKeyring.generateSecretKey();
    await expectLater(SyncKeyring.storeSecretKey(conflicting), throwsA(anything));
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), isNull);
    expect(await SyncKeyring.pendingSecretKey(), staged);

    // Best-effort fetchAccountKey can still open the legacy key even if upgrade PUT fails.
    failNextLkcPut = true;
    final legacyOpened = await (await upgrading.teams()).fetchAccountKey(
      passphrase: 'pw',
      secretKey: staged,
      allowLegacy: true,
    );
    expect(legacyOpened, isNotNull);
    expect(legacyOpened!.twoFactor(), isFalse);

    // 3. Upgrade succeeds on server with `staged`, then simulate crash before
    //    commitSecretKey: `syncSecretKey` is still null while `syncSecretKeyPending`
    //    holds `staged`. Next bootstrap recovers `staged` instead of prompting import.
    final committed = await (await upgrading.teams()).accountKey(
      passphrase: 'pw',
      secretKey: staged,
      allowLegacy: true,
    );
    expect(committed.twoFactor(), isTrue);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), isNull);

    final recovering = newClient();
    expect(await recovering.ensurePersonalAuth('test'), isTrue);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), staged);
    expect(await SyncKeyring.pendingSecretKey(), isNull);
    expect(SyncKeyring.secretKeyMissing.value, isFalse);

    // 4. On a fresh device without staged candidate, a sealed account key returns
    //    false and sets secretKeyMissing (scoped to u1).
    FlutterSecureStorage.setMockInitialValues({'lkcToken': tokenJson, 'bakPwd': 'pw'});
    SecureProp.resetRateLimits();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');
    final otherDevice = newClient();
    expect(await otherDevice.ensurePersonalAuth('test'), isFalse);
    expect(SyncKeyring.secretKeyMissing.value, isTrue);
  });

  test('LkcLogSync suppresses stale opening failures and publishes current opening failures', () async {
    SharedPreferences.setMockInitialValues({});
    await PrefStore.shared.init();
    SecureProp.legacyApart = false;
    addTearDown(() => SecureProp.legacyApart = null);

    final firstReqArrived = Completer<void>();
    final releaseFirstReq = Completer<void>();
    var reqCount = 0;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      await r.drain<void>();
      final n = ++reqCount;
      if (n == 1) {
        if (!firstReqArrived.isCompleted) firstReqArrived.complete();
        await releaseFirstReq.future;
      }
      r.response.statusCode = 500;
      await r.response.close();
    });

    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final tokenJson = jsonEncode({
      'access': 'a1',
      'refresh': 'r1',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    });
    FlutterSecureStorage.setMockInitialValues({
      'lkcToken': tokenJson,
      'bakPwd': 'pw',
    });
    SecureProp.resetRateLimits();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');

    final client = LkcClient(
      oidc: LkcOidc(
        clientId: 'test',
        redirectUrl: 'test://auth/callback',
        issuer: base.resolve('/auth/v1/'),
      ),
      baseUrl: base,
      cache: LkcMemoryCache(),
    );
    final now = DateTime.fromMillisecondsSinceEpoch(0);
    client.user.value = LkcUser(id: 'u1', name: 'u1', group: 'user', createdAt: now, updatedAt: now);
    // Initialize the session so client.signedIn is true.
    await client.sync('test');
    expect(client.signedIn, isTrue);

    final enabled = ValueNotifier(true);
    addTearDown(enabled.dispose);
    final logSync = LkcLogSync(client: client, app: 'test', enabled: enabled);

    // 1. Start opening #1, wait until it reaches the server, then reset() so
    //    opening #1 is no longer the current opening.
    final staleRun = logSync.sync();
    await firstReqArrived.future;
    logSync.reset();
    releaseFirstReq.complete();
    await staleRun;

    // Stale opening failure must NOT be published to lastFailure.
    expect(logSync.lastFailure.value, isNull);

    // 2. Start opening #2 as the current opening: its failure MUST be published.
    await logSync.sync();
    expect(logSync.lastFailure.value, isNotNull);
  });

  test('aborting or failing a later external stage on the same client preserves an earlier unresolved stage', () async {
    SharedPreferences.setMockInitialValues({});
    await PrefStore.shared.init();
    SecureProp.legacyApart = false;
    addTearDown(() => SecureProp.legacyApart = null);

    final files = <String, (String, List<int>)>{};
    Map<String, dynamic> userKey = {'next_seq': 1};
    var version = 0;
    var mode = 'seed'; // 'seed' | 'fail500' | 'raceWrongPwd' | 'abortBeforeCall'
    var raceGets = 0;
    (String, List<int>)? otherSealed;
    LkcClient? targetClient;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      final res = r.response;
      final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
      final path = r.uri.path;
      if (path == '/v2/keys') {
        if (r.method == 'GET') {
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'data': userKey}));
        } else if (r.method == 'PUT') {
          final parsed = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
          userKey = {
            'recipient': parsed['recipient'],
            'signing_key': parsed['signing_key'],
            'prev_signing_key': parsed['signing_key'],
            'next_seq': (parsed['seq'] as int) + 1,
          };
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'data': null}));
        }
        await res.close();
        return;
      }
      if (r.uri.pathSegments.length == 4 && r.uri.pathSegments[0] == 'v2' && r.uri.pathSegments[1] == 'sync') {
        final key = '${r.uri.pathSegments[2]}/${r.uri.pathSegments[3]}';
        switch (r.method) {
          case 'GET':
            if (key == 'lkc/identity.age' && mode == 'raceWrongPwd') {
              raceGets++;
              if (raceGets == 1) {
                res.statusCode = 404;
              } else {
                res.headers.set('ETag', '"${otherSealed!.$1}"');
                res.add(otherSealed.$2);
              }
            } else {
              final entry = files[key];
              if (entry == null) {
                res.statusCode = 404;
              } else {
                res.headers.set('ETag', '"${entry.$1}"');
                res.add(entry.$2);
              }
            }
          case 'PUT':
            if (key == 'lkc/identity.age' && mode == 'fail500') {
              res.statusCode = 500;
            } else {
              final etag = 'e${++version}';
              files[key] = (etag, body);
              res
                ..statusCode = 204
                ..headers.set('ETag', '"$etag"');
            }
          default:
            res.statusCode = 404;
        }
        await res.close();
        return;
      }
      res.statusCode = 404;
      await res.close();
    });

    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final tokenJson = jsonEncode({
      'access': 'a1',
      'refresh': 'r1',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    });
    FlutterSecureStorage.setMockInitialValues({'lkcToken': tokenJson, 'bakPwd': 'pw'});
    SecureProp.resetRateLimits();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');

    final now = DateTime.fromMillisecondsSinceEpoch(0);
    final userU1 = LkcUser(id: 'u1', name: 'u1', group: 'user', createdAt: now, updatedAt: now);

    // Pre-build a 2FA account key sealed with `otherKey` for the race simulation, then clear server files.
    final otherKey = SyncKeyring.generateSecretKey();
    final seedClient = LkcClient(
      oidc: LkcOidc(clientId: 'test', redirectUrl: 'test://auth/callback', issuer: base.resolve('/auth/v1/')),
      baseUrl: base,
      cache: LkcMemoryCache(),
    )..user.value = userU1;
    await (await seedClient.teams()).accountKey(passphrase: 'pw', secretKey: otherKey, allowLegacy: false);
    otherSealed = files.remove('lkc/identity.age');
    userKey = {'next_seq': 1};
    expect(otherSealed, isNotNull);

    final client = LkcClient(
      oidc: LkcOidc(clientId: 'test', redirectUrl: 'test://auth/callback', issuer: base.resolve('/auth/v1/')),
      baseUrl: base,
      cache: LkcMemoryCache(),
    )..user.value = userU1;
    targetClient = client;

    final stagedIds = <String>[];
    SyncKeyring.debugOnExternalStage = (id) {
      stagedIds.add(id);
      if (mode == 'abortAfterStage') {
        targetClient?.user.value = null;
      }
    };

    // 1. Attempt #1 on `client` fails with HTTP 500 -> leaves stage #1 unresolved in `client` and keyring.
    mode = 'fail500';
    await expectLater(client.ensurePersonalAuth('test'), throwsA(isA<LkcException>()));
    final staged = await SyncKeyring.pendingSecretKey();
    expect(staged, isNotNull);
    expect(stagedIds, hasLength(1));

    // 2. Attempt #2 on the SAME `client` hits `wrongPassphrase` on `t.accountKey`:
    //    must clear ONLY stage #2, keeping stage #1 protected against conflicting imports.
    mode = 'raceWrongPwd';
    raceGets = 0;
    expect(await client.ensurePersonalAuth('test'), isFalse);
    expect(stagedIds, hasLength(2));
    await expectLater(SyncKeyring.storeSecretKey(otherKey), throwsA(anything));

    // 3. Attempt #3 on the SAME `client` invalidates `stillValid()` right after
    //    `stageExternalSecretKeyCommit` returns (deterministically hitting line 596):
    //    must clear ONLY stage #3, keeping stage #1 protected.
    mode = 'abortAfterStage';
    expect(await client.ensurePersonalAuth('test'), isFalse);
    expect(stagedIds, hasLength(3));
    await expectLater(SyncKeyring.storeSecretKey(otherKey), throwsA(anything));

    // 4. Restoring `client.user` and completing `ensurePersonalAuth` settles stage #1
    //    and promotes `staged`, after which replacing with `otherKey` succeeds.
    mode = 'ok';
    client.user.value = userU1;
    expect(await client.ensurePersonalAuth('test'), isTrue);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), staged);
    await SyncKeyring.storeSecretKey(otherKey);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), otherKey);
  });

  test('recovered external intent after restart is bound to its creating account', () async {
    SharedPreferences.setMockInitialValues({});
    await PrefStore.shared.init();
    SecureProp.legacyApart = false;
    addTearDown(() => SecureProp.legacyApart = null);

    final files = <String, (String, List<int>)>{};
    final userKeys = <String, Map<String, dynamic>>{};
    var currentUid = 'u1';
    var failPut = true;
    var version = 0;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((r) async {
      final res = r.response;
      final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
      if (r.uri.path == '/v2/keys') {
        if (r.method == 'GET') {
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'data': userKeys[currentUid] ?? {'next_seq': 1}}));
        } else if (r.method == 'PUT') {
          final parsed = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
          userKeys[currentUid] = {
            'recipient': parsed['recipient'],
            'signing_key': parsed['signing_key'],
            'prev_signing_key': parsed['signing_key'],
            'next_seq': (parsed['seq'] as int) + 1,
          };
          res.headers.contentType = ContentType.json;
          res.write(jsonEncode({'data': null}));
        }
        await res.close();
        return;
      }
      if (r.uri.pathSegments.length == 4 && r.uri.pathSegments[0] == 'v2' && r.uri.pathSegments[1] == 'sync') {
        final key = '$currentUid:${r.uri.pathSegments[2]}/${r.uri.pathSegments[3]}';
        final entry = files[key];
        switch (r.method) {
          case 'GET':
            if (entry == null) {
              res.statusCode = 404;
            } else {
              res.headers.set('ETag', '"${entry.$1}"');
              res.add(entry.$2);
            }
          case 'PUT':
            if (failPut) {
              res.statusCode = 500;
            } else {
              final etag = 'e${++version}';
              files[key] = (etag, body);
              res
                ..statusCode = 204
                ..headers.set('ETag', '"$etag"');
            }
          default:
            res.statusCode = 404;
        }
        await res.close();
        return;
      }
      res.statusCode = 404;
      await res.close();
    });

    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final tokenJson = jsonEncode({
      'access': 'a1',
      'refresh': 'r1',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    });
    final conflictingKey = SyncKeyring.generateSecretKey();
    FlutterSecureStorage.setMockInitialValues({'lkcToken': tokenJson, 'bakPwd': 'pw'});
    SecureProp.resetRateLimits();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');

    final now = DateTime.fromMillisecondsSinceEpoch(0);
    LkcClient clientFor(String uid) => LkcClient(
      oidc: LkcOidc(clientId: 'test', redirectUrl: 'test://auth/callback', issuer: base.resolve('/auth/v1/')),
      baseUrl: base,
      cache: LkcMemoryCache(),
    )..user.value = LkcUser(id: uid, name: uid, group: 'user', createdAt: now, updatedAt: now);

    // 1. Account u1 stages an external commit and fails with 500 before restart.
    currentUid = 'u1';
    failPut = true;
    final c1 = clientFor('u1');
    await expectLater(c1.ensurePersonalAuth('test'), throwsA(isA<LkcException>()));
    final staged = await SyncKeyring.pendingSecretKey();
    expect(staged, isNotNull);

    // Promote `staged` to active `syncSecretKey` (simulating internal sync promotion before crash)
    // and simulate process restart (`SyncKeyring.resetForTest` + fresh LkcClient with empty stage list).
    await SecureStoreProps.syncSecretKey.write(staged, limited: false);
    final persistedPending = await const SecureProp('syncKeyPending').storage.read(key: 'syncKeyPending');
    expect(persistedPending, isNotNull);
    final pendingMap = jsonDecode(persistedPending!) as Map<String, dynamic>;
    final intent = jsonDecode(pendingMap['intent:lkc-account-key'] as String) as Map<String, dynamic>;
    expect(intent['owners'], ['u1']);

    FlutterSecureStorage.setMockInitialValues({
      'lkcToken': tokenJson,
      'bakPwd': 'pw',
      'syncSecretKey': staged!,
      'syncKeyPending': persistedPending,
    });
    SecureProp.resetRateLimits();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');

    // 2. After restart, account u2 opens its 2FA account key with the same `staged` key
    //    (stage-less `_settleExternalCommit` for u2): u1's unresolved intent MUST remain intact!
    currentUid = 'u2';
    failPut = false;
    final c2AfterRestart = clientFor('u2');
    expect(await c2AfterRestart.ensurePersonalAuth('test'), isTrue);
    await expectLater(SyncKeyring.storeSecretKey(conflictingKey), throwsA(anything));

    // 3. If u1's remote `lkc/identity.age` was meanwhile sealed by another device with
    //    `conflictingKey`, u1 enters `_accountKeyWith` (since `staged` is already in `syncSecretKey`),
    //    receives `wrongPassphrase`, clears u1's unresolved external intent, and unblocks importing
    //    `conflictingKey`!
    currentUid = 'u1';
    final u1OtherDeviceClient = clientFor('u1');
    await SecureStoreProps.syncSecretKey.write(conflictingKey, limited: false);
    expect(await u1OtherDeviceClient.ensurePersonalAuth('test'), isTrue);
    await SecureStoreProps.syncSecretKey.write(staged, limited: false);
    await const SecureProp('lkcAccountKey.u1').write(null, limited: false);

    final c1AfterRestart = clientFor('u1');
    await expectLater(c1AfterRestart.ensurePersonalAuth('test'), throwsA(isA<SyncPasswordMismatch>()));
    await SyncKeyring.storeSecretKey(conflictingKey);
    expect(await SecureStoreProps.syncSecretKey.read(limited: false), conflictingKey);
    expect(await c1AfterRestart.ensurePersonalAuth('test'), isTrue);
  });

  test('pending passphrase record is retained across secret-key mismatch and syncLkcAccount isolates probes', () async {
    SharedPreferences.setMockInitialValues({});
    SecureProp.legacyApart = false;
    const currentUid = 'u1';
    final files = <String, (String etag, List<int> body, ({String signer, String pk, String sig, String? ver})? signed)>{};
    final userKeys = <String, Map<String, Object?>>{};
    var version = 0;
    Completer<void>? probeStarted;
    Completer<void>? releaseProbe;

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() {
      SecureProp.legacyApart = null;
      LkcClient.debugOnAccountKeyHeldRead = null;
      return server.close(force: true);
    });
    server.listen((r) async {
      final body = await r.fold<List<int>>([], (a, b) => a..addAll(b));
      final res = r.response;
      final path = r.uri.path;
      if (path == '/v2/keys') {
        res.headers.contentType = ContentType.json;
        if (r.method == 'GET') {
          final existing = userKeys[currentUid] ?? {'recipient': null, 'signing_key': null, 'next_seq': 1, 'prev_signing_key': null};
          res.write(jsonEncode({'data': existing}));
        } else if (r.method == 'PUT') {
          final parsed = jsonDecode(utf8.decode(body)) as Map<String, dynamic>;
          final prev = userKeys[currentUid]?['signing_key'] ?? parsed['signing_key'];
          userKeys[currentUid] = {
            'recipient': parsed['recipient'],
            'signing_key': parsed['signing_key'],
            'prev_signing_key': prev,
            'next_seq': (parsed['seq'] as int) + 1,
          };
          res.write(jsonEncode({'data': null}));
        } else {
          res.write(jsonEncode({'code': 0}));
        }
        await res.close();
        return;
      }
      const prefix = '/v2/sync/';
      if (path.startsWith(prefix)) {
        final rest = path.substring(prefix.length);
        final key = '$currentUid:$rest';
        final entry = files[key];
        switch (r.method) {
          case 'HEAD':
            if (entry == null) {
              res.statusCode = 404;
            } else {
              res
                ..statusCode = 200
                ..headers.set('ETag', '"${entry.$1}"');
            }
          case 'GET':
            final started = probeStarted;
            final release = releaseProbe;
            if (rest == 'test/identity.age' && started != null && release != null && !started.isCompleted) {
              started.complete();
              await release.future;
            }
            if (entry == null) {
              res.statusCode = 404;
            } else {
              res.headers.set('ETag', '"${entry.$1}"');
              if (entry.$3 case final s?) {
                res.headers
                  ..set('X-Signer', s.signer)
                  ..set('X-Signing-Key', s.pk)
                  ..set('X-Signature', s.sig);
                if (s.ver != null) res.headers.set('X-Sync-Version', s.ver!);
              }
              res.add(entry.$2);
            }
          case 'PUT':
            final etag = 'e${++version}';
            final sigHdr = r.headers.value('x-signature');
            final pk = userKeys[currentUid]?['signing_key'] as String?;
            final signed = (sigHdr != null && pk != null)
                ? (signer: currentUid, pk: pk, sig: sigHdr, ver: r.headers.value('x-sync-version'))
                : null;
            files[key] = (etag, body, signed);
            res
              ..statusCode = 204
              ..headers.set('ETag', '"$etag"');
          default:
            res.statusCode = 404;
        }
        await res.close();
        return;
      }
      res.statusCode = 404;
      await res.close();
    });

    final base = Uri.parse('http://127.0.0.1:${server.port}');
    final tokenJson = jsonEncode({
      'access': 'a1',
      'refresh': 'r1',
      'expires_at': DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch,
    });
    final realKey = SyncKeyring.generateSecretKey();
    final wrongKey = SyncKeyring.generateSecretKey();
    FlutterSecureStorage.setMockInitialValues({
      'lkcToken': tokenJson,
      'bakPwd': 'oldPw',
      'syncSecretKey': realKey,
    });
    SecureProp.resetRateLimits();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');

    final now = DateTime.fromMillisecondsSinceEpoch(0);
    LkcClient clientFor(String uid) => LkcClient(
      oidc: LkcOidc(clientId: 'test', redirectUrl: 'test://auth/callback', issuer: base.resolve('/auth/v1/')),
      baseUrl: base,
      cache: LkcMemoryCache(),
    )..user.value = LkcUser(id: uid, name: uid, group: 'user', createdAt: now, updatedAt: now);

    // 1. Seed u1's remote `lkc/identity.age` under `(oldPw, realKey)`.
    final seedClient = clientFor('u1');
    expect(await seedClient.ensurePersonalAuth('test'), isTrue);

    // 2. Device currently holds `wrongKey`, password changed `oldPw -> newPw` offline:
    //    flush sees `wrongPassphrase` on both `oldPw` and `newPw` due to `wrongKey`,
    //    and MUST retain `lkcAccountKeyPendingPwd.u1` rather than clearing it!
    await const SecureProp('lkcAccountKey.u1').write(null, limited: false);
    await SecureStoreProps.bakPwd.write('newPw', limited: false);
    await SecureStoreProps.syncSecretKey.write(wrongKey, limited: false);
    final c1 = clientFor('u1');
    await c1.changePersonalAuthPassphrase(old: 'oldPw', newPassphrase: 'newPw');
    final retainedPending = await const SecureProp('lkcAccountKeyPendingPwd.u1').read(limited: false);
    expect(retainedPending, isNotNull, reason: 'ambiguous wrongPassphrase must not drop pending passphrase record');

    // Once the user imports `realKey`, `ensurePersonalAuth` flushes `oldPw -> newPw` and clears `lkcAccountKeyPendingPwd.u1`!
    await SyncKeyring.storeSecretKey(realKey);
    expect(await c1.ensurePersonalAuth('test'), isTrue);
    expect(await const SecureProp('lkcAccountKeyPendingPwd.u1').read(limited: false), isNull);

    // 2b. Key-refetch invalidation check (`_refetchAccountKey`):
    //     Another device rotates u1's account key and uploads a signed file.
    //     If `stillValid()` turns false after reading `held`, `_accountKeyProp('u1')`
    //     must NOT be overwritten; a valid refetch then caches the rotated key.
    final initialCachedKey = await const SecureProp('lkcAccountKey.u1').read(limited: false);
    expect(initialCachedKey, isNotNull);
    final rotator = clientFor('u1');
    final rotatedKey = await (await rotator.teams()).rotateAccountKey(
      passphrase: 'newPw',
      secretKey: realKey,
      allowLegacy: false,
    );
    expect(rotatedKey.toText(), isNot(initialCachedKey));
    final rotatorSync = await rotator.sync('test');
    rotatorSync.setPersonalAuth(
      auth: LkcPersonalAuth.open(
        key: rotatedKey,
        versions: '',
        save: (_) async => true,
        fetchKey: () async => null,
      ),
    );
    final srcFile = File('${dir.path}/rot-src.age')..writeAsStringSync('age-encryption.org/v1\n---\npayload\n');
    final dstFile = File('${dir.path}/rot-dst.age');
    await rotatorSync.upload(name: 'rotated.age', from: srcFile.path);

    final syncU1 = await c1.sync('test');
    LkcClient.debugOnAccountKeyHeldRead = (_) {
      c1.user.value = null;
    };
    await expectLater(syncU1.download(name: 'rotated.age', to: dstFile.path), throwsA(anything));
    expect(
      await const SecureProp('lkcAccountKey.u1').read(limited: false),
      initialCachedKey,
      reason: 'invalidated refetch must not write rotated key into cache',
    );

    // Re-open personal auth validly: valid refetch caches `rotatedKey` and verifies download!
    LkcClient.debugOnAccountKeyHeldRead = null;
    final c1Valid = clientFor('u1');
    expect(await c1Valid.ensurePersonalAuth('test'), isTrue);
    final syncU1Valid = await c1Valid.sync('test');
    await syncU1Valid.download(name: 'rotated.age', to: dstFile.path);
    expect(await const SecureProp('lkcAccountKey.u1').read(limited: false), rotatedKey.toText());

    // 3. `syncLkcAccount`: invalidates in-flight probe & clears Rust missing-key status for u1
    //    while preserving missing-key status for folder remotes!
    await SyncKeyring.ofLkc(syncU1Valid, 'u1'); // Creates 2FA `test/identity.age` for u1
    final folderSealedBytes = files['u1:test/identity.age']!.$2;

    FlutterSecureStorage.setMockInitialValues({'lkcToken': tokenJson, 'bakPwd': 'newPw'});
    SharedPreferences.setMockInitialValues({});
    SecureProp.resetRateLimits();
    SyncKeyring.resetForTest();
    SyncKeyring.init(label: 'Test sync key');
    SyncKeyring.allowAutoGenerateSecretKey = () => false;

    // Seed a folder remote that reports `secretKeyMissing` in Rust.
    final folder = _ReadOnlyKeyFile('folder-1', Uint8List.fromList(folderSealedBytes));
    await expectLater(SyncKeyring.ofFiles(folder, create: false), throwsA(isA<SyncSecretKeyMissing>()));
    expect(SyncKeyring.secretKeyMissing.value, isTrue);

    // Start an in-flight probe for u1, then switch to u2 before the probe completes.
    probeStarted = Completer<void>();
    releaseProbe = Completer<void>();
    final probeFuture = SyncKeyring.lkcSealedWithSecretKey(syncU1Valid, 'u1');
    await probeStarted.future;
    SyncKeyring.syncLkcAccount('u2');
    // Folder remote's missing-key status MUST remain preserved!
    expect(SyncKeyring.secretKeyMissing.value, isTrue);

    releaseProbe.complete();
    expect(await probeFuture, isTrue);

    // Release folder remote: if u1's stale probe had NOT been invalidated, `secretKeyMissing`
    // would stay true! With invalidation, it drops to false.
    SyncKeyring.release('folder-1');
    expect(SyncKeyring.secretKeyMissing.value, isFalse);
  });
}

final class _ReadOnlyKeyFile implements SyncKeyFile {
  final String _id;
  final Uint8List _body;
  _ReadOnlyKeyFile(this._id, this._body);

  @override
  String get id => _id;

  @override
  Future<({Uint8List body, String version})?> read() async => (body: _body, version: 'v1');

  @override
  Future<String?> write(Uint8List body, {required String? ifVersion}) async => null;

  @override
  Future<bool> canCreate() async => false;
}
