/// [LkcRemoteStorage] through fl_lkc, against a homebase on loopback.
library;

import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
