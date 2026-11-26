/// [LkcRemoteStorage] through fl_lkc, against a homebase on loopback.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
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
}
