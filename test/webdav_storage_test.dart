import 'dart:async';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/core/sync/log/host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webdav_client_plus/webdav_client_plus.dart';

/// [Webdav] against a server that answers as OpenList does: a name with a bare
/// `%` sent as is in its `href` (flutter_server_box#1825), which made the
/// listing throw and a restore impossible.
void main() {
  late HttpServer server;
  final requests = <String>[];

  setUp(() async {
    requests.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests.add('${request.method} ${request.uri.path}');
      await request.drain<void>();
      final response = request.response;
      switch (request.method) {
        case 'PROPFIND':
          response.statusCode = 207;
          response.headers.contentType = ContentType('application', 'xml');
          response.write(_listing);
        case 'GET':
          response.write('{}');
        default:
          response.statusCode = HttpStatus.created;
      }
      await response.close();
    });
  });

  tearDown(() => server.close(force: true));

  Webdav storage() => Webdav(
    client: WebdavClient.basicAuth(
      url: 'http://127.0.0.1:${server.port}/dav/',
      user: 'user',
      pwd: 'pwd',
    ),
  );

  test('a name with a bare % lists rather than failing the whole folder', () async {
    final names = await storage().list();

    expect(names, unorderedEquals(['srvbox_bak_1.json', '100%.txt']));
  });

  test('files stay where earlier versions put them', () async {
    final dir = await Directory.systemTemp.createTemp('webdav-storage-');
    addTearDown(() => dir.delete(recursive: true));
    final local = '${dir.path}/a.json';
    await File(local).writeAsString('{}');

    await storage().upload(relativePath: 'a.json', localPath: local);
    await storage().download(relativePath: 'a.json', localPath: local);

    expect(requests, containsAll(['PUT /dav/lpkt-apps/a.json', 'GET /dav/lpkt-apps/a.json']));
  });

  group('Webdav.test', () {
    test('rejects invalid URLs without issuing a request', () async {
      await expectLater(Webdav.test('', 'u', 'p'), throwsFormatException);
      await expectLater(Webdav.test('ftp://example.com/dav/', 'u', 'p'), throwsFormatException);
      await expectLater(Webdav.test('https://', 'u', 'p'), throwsFormatException);
    });

    test('rejects a plain HTTP root whose OPTIONS answers 200 but PROPFIND answers 405', () async {
      final nonDav = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => nonDav.close(force: true));
      nonDav.listen((request) async {
        await request.drain<void>();
        final res = request.response;
        if (request.method == 'OPTIONS') {
          res.statusCode = HttpStatus.ok;
        } else {
          res.statusCode = HttpStatus.methodNotAllowed;
        }
        await res.close();
      });

      await expectLater(
        Webdav.test('http://127.0.0.1:${nonDav.port}/', 'u', 'p'),
        throwsA(isA<WebdavException<Object?>>().having((e) => e.statusCode, 'statusCode', 405)),
      );
    });

    test('rejects 401 unauthorized responses', () async {
      final authed = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => authed.close(force: true));
      authed.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set(HttpHeaders.wwwAuthenticateHeader, 'Basic realm="dav"');
        await request.response.close();
      });

      await expectLater(
        Webdav.test('http://127.0.0.1:${authed.port}/dav/', 'u', 'wrong'),
        throwsA(isA<WebdavException<Object?>>().having((e) => e.statusCode, 'statusCode', 401)),
      );
    });

    test('rejects non-WebDAV HTML returned with 200 OK', () async {
      final htmlServer = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => htmlServer.close(force: true));
      htmlServer.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = HttpStatus.ok
          ..headers.contentType = ContentType.html
          ..write('<html><body>hello</body></html>');
        await request.response.close();
      });

      await expectLater(
        Webdav.test('http://127.0.0.1:${htmlServer.port}/', 'u', 'p'),
        throwsA(isA<WebdavException<Object?>>()),
      );
    });

    test('succeeds on an existing prefix collection', () async {
      await Webdav.test('http://127.0.0.1:${server.port}/dav/', 'user', 'pwd');
      expect(requests, ['PROPFIND /dav/lpkt-apps/']);
    });

    test('falls back to base collection when prefix returns 404 on a fresh server', () async {
      final seen = <String>[];
      final fresh = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => fresh.close(force: true));
      fresh.listen((request) async {
        seen.add('${request.method} ${request.uri.path}');
        await request.drain<void>();
        final res = request.response;
        if (request.uri.path == '/dav/lpkt-apps/') {
          res.statusCode = HttpStatus.notFound;
        } else if (request.method == 'PROPFIND' && request.uri.path == '/dav/') {
          res.statusCode = 207;
          res.headers.contentType = ContentType('application', 'xml');
          res.write(_rootProp);
        } else {
          res.statusCode = HttpStatus.methodNotAllowed;
        }
        await res.close();
      });

      await Webdav.test('http://127.0.0.1:${fresh.port}/dav/', 'user', 'pwd');
      expect(seen, ['PROPFIND /dav/lpkt-apps/', 'PROPFIND /dav/']);
    });

    test('still rejects when prefix returns 404 and base returns 405', () async {
      final partial = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => partial.close(force: true));
      partial.listen((request) async {
        await request.drain<void>();
        final res = request.response;
        res.statusCode = request.uri.path.contains('lpkt-apps')
            ? HttpStatus.notFound
            : HttpStatus.methodNotAllowed;
        await res.close();
      });

      await expectLater(
        Webdav.test('http://127.0.0.1:${partial.port}/', 'user', 'pwd'),
        throwsA(isA<WebdavException<Object?>>().having((e) => e.statusCode, 'statusCode', 405)),
      );
    });

    test('accepts URLs without trailing slash, with surrounding spaces, and empty credentials', () async {
      await Webdav.test('  http://127.0.0.1:${server.port}/dav  ', '', '');
      expect(requests, ['PROPFIND /dav/lpkt-apps/']);
    });

    test('rejects an empty multistatus XML response where readProps returns null', () async {
      final emptyDav = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => emptyDav.close(force: true));
      emptyDav.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write('<?xml version="1.0" encoding="utf-8"?><D:multistatus xmlns:D="DAV:"/>');
        await request.response.close();
      });

      await expectLater(
        Webdav.test('http://127.0.0.1:${emptyDav.port}/dav/', 'u', 'p'),
        throwsA(isA<WebdavException<Object?>>()),
      );
    });

    test('rejects a non-directory file endpoint even when PROPFIND returns 207', () async {
      final fileDav = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => fileDav.close(force: true));
      fileDav.listen((request) async {
        await request.drain<void>();
        request.response
          ..statusCode = 207
          ..headers.contentType = ContentType('application', 'xml')
          ..write(_fileProp);
        await request.response.close();
      });

      await expectLater(
        Webdav.test('http://127.0.0.1:${fileDav.port}/dav/srvbox_bak_v4.age', 'u', 'p'),
        throwsA(isA<WebdavException<Object?>>()),
      );
    });

    test('falls back to base collection when prefix returns 207 with embedded 404', () async {
      final seen = <String>[];
      final embedded404 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => embedded404.close(force: true));
      embedded404.listen((request) async {
        seen.add('${request.method} ${request.uri.path}');
        await request.drain<void>();
        final res = request.response;
        res.statusCode = 207;
        res.headers.contentType = ContentType('application', 'xml');
        res.write(request.uri.path == '/dav/lpkt-apps/' ? _embedded404Prop : _rootProp);
        await res.close();
      });

      await Webdav.test('http://127.0.0.1:${embedded404.port}/dav/', 'user', 'pwd');
      expect(seen, ['PROPFIND /dav/lpkt-apps/', 'PROPFIND /dav/']);
    });

    test('aborts in-flight probe when CancelToken is cancelled', () async {
      final hanging = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final hold = Completer<void>();
      addTearDown(() async {
        if (!hold.isCompleted) hold.complete();
        await hanging.close(force: true);
      });
      hanging.listen((request) async {
        await request.drain<void>();
        await hold.future;
        try {
          await request.response.close();
        } catch (_) {}
      });

      final cancel = CancelToken();
      final future = Webdav.test(
        'http://127.0.0.1:${hanging.port}/dav/',
        'user',
        'pwd',
        cancelToken: cancel,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      cancel.cancel('user cancelled');

      await expectLater(
        future,
        throwsA(isA<DioException>().having((e) => e.type, 'type', DioExceptionType.cancel)),
      );
    });

    test('isRemoteFailure treats WebdavException 4xx as remote rather than host defect', () {
      expect(
        isRemoteFailure(WebdavException<String>(message: 'Method not allowed', statusCode: 405)),
        isTrue,
      );
      expect(
        isRemoteFailure(WebdavException<String>(message: 'Unauthorized', statusCode: 401)),
        isTrue,
      );
    });

    test('formatError returns concise text without HTML and null when empty', () {
      expect(
        Webdav.formatError(
          WebdavException<String>(
            message: 'WebDAV operation failed',
            statusCode: 405,
            statusMessage: 'Method Not Allowed',
          ),
        ),
        '405 Method Not Allowed · WebDAV operation failed',
      );
      expect(Webdav.formatError(WebdavException<Object?>(message: '   ')), isNull);
    });
  });
}

const _rootProp = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';

const _fileProp = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/srvbox_bak_v4.age/lpkt-apps/</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>42</D:getcontentlength></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';

const _embedded404Prop = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/lpkt-apps/</D:href>
    <D:status>HTTP/1.1 404 Not Found</D:status>
  </D:response>
</D:multistatus>''';

const _listing = '''<?xml version="1.0" encoding="utf-8"?>
<D:multistatus xmlns:D="DAV:">
  <D:response>
    <D:href>/dav/lpkt-apps/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/lpkt-apps/srvbox_bak_1.json</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>2</D:getcontentlength></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/lpkt-apps/100%.txt</D:href>
    <D:propstat><D:prop><D:resourcetype/><D:getcontentlength>1</D:getcontentlength></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
  <D:response>
    <D:href>/dav/lpkt-apps/sub/</D:href>
    <D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop>
    <D:status>HTTP/1.1 200 OK</D:status></D:propstat>
  </D:response>
</D:multistatus>''';
