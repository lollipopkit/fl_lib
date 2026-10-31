import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
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
}

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
