import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:dio/dio.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n_en.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rust_lib.dart';

const _user = {
  'id': 'u1',
  'name': 'Lk',
  'group': 'user',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-02T00:00:00Z',
};

const _issuer = 'https://idp.example.com/auth/v1/';

const _discovery = {
  'authorization_endpoint': 'https://idp.example.com/auth/v1/oidc/authorize',
  'token_endpoint': 'https://idp.example.com/auth/v1/oidc/token',
  'revocation_endpoint': 'https://idp.example.com/auth/v1/oidc/token/revoke',
};

/// A saved session (`fl_lkc::Stored`) whose access token ends in [left].
String _saved(Duration left, {String access = 'a1', String refresh = 'r1'}) =>
    jsonEncode({
      'access': access,
      'refresh': refresh,
      'expires_at': DateTime.now().add(left).millisecondsSinceEpoch,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadFlRustForTest);

  late _Adapter api;
  late _Adapter store;
  late _Adapter idp;
  late _Adapter conduit;
  late LkcClient client;
  late LkcMemoryCache cache;
  Future<bool> Function(Uri url) browser = (_) async => false;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    SecureProp.resetRateLimits();
    api = _Adapter()
      ..on('GET /auth/user', {'data': _user})
      ..on('GET /v2/entitlements', {'data': []});
    store = _Adapter();
    conduit = _Adapter();
    idp = _Adapter()
      ..on('GET /auth/v1/.well-known/openid-configuration', _discovery);
    cache = LkcMemoryCache();
    client = LkcClient(
      cache: cache,
      oidc: LkcOidc(
        clientId: 'test',
        redirectUrl: 'test://auth/callback',
        issuer: Uri.parse(_issuer),
      ),
      api: Dio()..httpClientAdapter = api,
      store: Dio()..httpClientAdapter = store,
      conduit: Dio()..httpClientAdapter = conduit,
      idp: Dio()..httpClientAdapter = idp,
      openBrowser: (url) => browser(url),
      loopback: true,
    );
  });

  /// Signed in with saved tokens whose access token ends in [left].
  Future<void> signedIn([Duration left = const Duration(minutes: 5)]) async {
    FlutterSecureStorage.setMockInitialValues({'lkcToken': _saved(left)});
    await client.init();
  }

  group('unwrap', () {
    test('an Ok reply leaves the code out', () {
      expect(LkcClient.unwrap(200, '{"msg":"ok","data":[1]}'), [1]);
      expect(LkcClient.unwrap(200, '{"code":0,"msg":"Ok"}'), isNull);
    });

    test('a rejection carries its reason and text', () {
      final e = _thrown(
        () => LkcClient.unwrap(
          200,
          '{"code":5,"msg":"Quota over used","reason":"file_quota","data":"The files would exceed the storage quota"}',
        ),
      );
      expect(e.code, LkcCode.quota);
      expect(e.reason, 'file_quota');
      expect(e.message, 'The files would exceed the storage quota');
    });

    test('a refused token', () {
      final e = _thrown(
        () => LkcClient.unwrap(200, '{"code":2,"msg":"No perm"}'),
      );
      expect(e.isPerm, isTrue);
      expect(e.reason, isNull);
      expect(e.message, 'No perm');
    });

    test('a reply that is not the API\'s', () {
      final e = _thrown(
        () => LkcClient.unwrap(502, '<html>Bad gateway</html>'),
      );
      expect(e.code, isNull);
      expect(e.status, 502);
      expect(_thrown(() => LkcClient.unwrap(200, '[]')).code, isNull);
    });
  });

  group('reason text', () {
    final l10n = LibLocalizationsEn();

    test('every translated reason is looked up', () {
      final arb = jsonDecode(
        File('lib/generated/l10n/source/app_en.arb').readAsStringSync(),
      ) as Map;
      final keys = arb.keys
          .whereType<String>()
          .where((k) => k.startsWith('lkcReason'))
          .toList();
      expect(keys, isNotEmpty);
      for (final k in keys) {
        final reason = k
            .substring('lkcReason'.length)
            .replaceAllMapped(RegExp('[A-Z]'), (m) => '_${m[0]!.toLowerCase()}')
            .substring(1);
        final e = LkcException(reason: reason, message: 'server text');
        expect(e.text(l10n), arb[k], reason: reason);
      }
    });

    test('an unknown reason shows the server\'s text', () {
      expect(
        const LkcException(
          reason: 'new_reason',
          message: 'server text',
        ).text(l10n),
        'server text',
      );
      expect(const LkcException(code: LkcCode.internal).text(l10n), l10n.fail);
    });
  });

  group('paywall', () {
    final paywall = LkcPaywall.fromJson(_paywall);

    test('rows as homebase words them, in its order', () {
      expect(paywall.locale, 'en');
      expect(paywall.lines, ['basic', 'conduit', 'storage']);
      expect(
        [for (final i in paywall.items('basic', LkcPaywall.free)) '$i'],
        ['Sync: Real-time, end-to-end encrypted', 'Push notifications'],
      );
      expect(paywall.items('basic', 'basic').single.icon, 'monitor_heart');
    });

    test('a line or tier it does not list grants nothing shown', () {
      expect(paywall.items('conduit', LkcPaywall.free), isEmpty);
      expect(paywall.items('team', 'team.plus'), isEmpty);
    });

    test('sizes in powers of 1024, as homebase words the plans', () {
      expect(lkcBytes(1023), '1023 B');
      expect(lkcBytes(9961472), '9.5 MiB');
      expect(lkcBytes(12 << 20), '12 MiB');
      expect(lkcBytes(5 << 30), '5 GiB');
    });
  });

  test('usage and its quota', () {
    final u = LkcUsage.fromJson({
      'files': 3,
      'bytes': 1200,
      'quota': {
        'bytes': 5000000000,
        'files': null,
        'max_file_bytes': 8000000000,
      },
    });
    expect(u.maxFileBytes, lkcStoreMaxFileBytes);
    expect(
      (u.files, u.bytes, u.quotaBytes, u.quotaFiles),
      (3, 1200, 5000000000, null),
    );
  });

  test('the line of an entitlement is the server\'s', () {
    final e = LkcEntitlement.fromJson({
      'plan': 'storage.plus',
      'line': 'storage',
      'source': 'manual',
      'status': 'active',
      'cancel_scheduled': false,
    });
    expect(e.line, LkcLine.storage);
    final old = LkcEntitlement.fromJson({
      'plan': 'conduit.pro',
      'source': 'stripe',
      'status': 'active',
      'cancel_scheduled': false,
    });
    expect(old.line, LkcLine.conduit);
  });

  group('sign-in', () {
    test('a loopback redirect, with S256 PKCE', () async {
      late Uri asked;
      browser = (url) async {
        asked = url;
        // The browser, sent back by the IdP: an icon first, then the code.
        // The test binding answers every request 400; this is the browser's own.
        final http = HttpOverrides.runWithHttpOverrides(
          HttpClient.new,
          _RealHttp(),
        );
        final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
        await (await http.getUrl(redirect.replace(path: '/favicon.ico')))
            .close();
        final res = await (await http.getUrl(
          redirect.replace(
            queryParameters: {
              'code': 'c1',
              'state': url.queryParameters['state'],
            },
          ),
        )).close();
        expect(res.statusCode, 200);
        http.close();
        return true;
      };
      idp.onFn(
        'POST /auth/v1/oidc/token',
        (_) => (
          200,
          {
            'access_token': 'a1',
            'refresh_token': 'r1',
            'expires_in': 300,
            'id_token':
                'x.${base64Url.encode(utf8.encode(jsonEncode({'name': 'Lk'}))).replaceAll('=', '')}.y',
          },
        ),
      );

      final user = await client.signIn();

      expect(user?.id, 'u1');
      expect(asked.path, '/auth/v1/oidc/authorize');
      expect(asked.queryParameters['code_challenge_method'], 'S256');
      expect(asked.queryParameters['scope'], 'openid profile');
      expect(
        asked.queryParameters['redirect_uri'],
        startsWith('http://127.0.0.1:'),
      );
      expect(
        Uri.parse(asked.queryParameters['redirect_uri']!).path,
        '/oauth-callback',
      );
      final exchange = Uri.splitQueryString(idp.bodyOf('/auth/v1/oidc/token'));
      expect(exchange['grant_type'], 'authorization_code');
      expect(exchange['code'], 'c1');
      expect(exchange['redirect_uri'], asked.queryParameters['redirect_uri']);
      expect(
        base64Url
            .encode(
              sha256.convert(ascii.encode(exchange['code_verifier']!)).bytes,
            )
            .replaceAll('=', ''),
        asked.queryParameters['code_challenge'],
      );
      expect(api.requests.first.headers['Authorization'], 'Bearer a1');
      final saved =
          jsonDecode((await SecureStoreProps.lkcToken.read())!) as Map;
      expect(saved['refresh'], 'r1');
    });

    test('declined at the IdP', () async {
      browser = (url) async {
        // The test binding answers every request 400; this is the browser's own.
        final http = HttpOverrides.runWithHttpOverrides(
          HttpClient.new,
          _RealHttp(),
        );
        final redirect = Uri.parse(url.queryParameters['redirect_uri']!);
        await (await http.getUrl(
          redirect.replace(
            queryParameters: {
              'error': 'access_denied',
              'state': url.queryParameters['state'],
            },
          ),
        )).close();
        http.close();
        return true;
      };
      expect(await client.signIn(), isNull);
      expect(client.signedIn, isFalse);
      expect(await SecureStoreProps.lkcToken.read(), isNull);
    });

    test('a fresh access token is never refreshed', () async {
      await signedIn();
      await client.refreshEntitlements();
      expect(idp.requests.where((r) => r.uri.path.endsWith('/token')), isEmpty);
      expect(api.requests.last.headers['Authorization'], 'Bearer a1');
    });

    test('a token homebase refuses signs out', () async {
      api.on('GET /auth/user', {'code': 2, 'msg': 'No perm'});
      await expectLater(signedIn(), throwsA(isA<LkcException>()));
      expect(client.signedIn, isFalse);
    });

    test('a token saved by the hand-off sign-in is dropped', () async {
      FlutterSecureStorage.setMockInitialValues({'lkcToken': 'eyJ.old.jwt'});
      await client.init();
      expect(client.signedIn, isFalse);
      expect(await SecureStoreProps.lkcToken.read(), isNull);
      expect(api.requests.where((r) => r.path == '/auth/user'), isEmpty);
    });

    test('a session saved mid-refresh is dropped, the account with it, and the log says why', () async {
      FlutterSecureStorage.setMockInitialValues({
        'lkcToken': jsonEncode({'access': 'a1', 'refresh': 'r1', 'expires_at': 0, 'refreshing': true}),
      });
      final logged = <String>[];
      final sub = Loggers.app.onRecord.listen((r) => logged.add(r.message));
      addTearDown(sub.cancel);
      await client.init();
      expect(client.signedIn, isFalse);
      expect(client.user.value, isNull);
      expect(await SecureStoreProps.lkcToken.read(), isNull);
      expect(logged, contains(startsWith('LK Cloud signed out: a refresh was under way')));
    });

    // Revoking is the session's (`fl_lkc`'s tests).
    test('signing out drops the session', () async {
      await signedIn();
      await client.signOut();
      expect(client.signedIn, isFalse);
      expect(await SecureStoreProps.lkcToken.read(), isNull);
    });

    test('a deleted account takes the tokens with it', () async {
      api.on('DELETE /auth/user', {'code': 0, 'msg': 'Ok'});
      await signedIn();
      await client.deleteAccount();
      expect(client.signedIn, isFalse);
      expect(client.user.value, isNull);
      expect(await SecureStoreProps.lkcToken.read(), isNull);
    });
  });

  test('uploads straight to the store, without the token', () async {
    api.on('POST /file/uploads', {
      'data': {
        'id': 'up1',
        'name': 'abc.txt',
        'url': 'https://bucket.example.com/files/u1/abc.txt?X-Amz-Signature=s',
        'expires_at': '2026-01-01T00:20:00Z',
      },
    });
    api.on('POST /file/uploads/up1/complete', {'data': 'abc.txt'});
    await signedIn();

    final bytes = utf8.encode('hello');
    final name = await client.upload(
      data: Stream.value(bytes),
      size: bytes.length,
      originalName: 'a.txt',
    );

    expect(name, 'abc.txt');
    final create = api.requests.firstWhere((r) => r.path == '/file/uploads');
    expect(create.data, {'original_name': 'a.txt', 'size': 5});
    final put = store.requests.single;
    expect(put.method, 'PUT');
    expect(put.uri.host, 'bucket.example.com');
    expect(put.headers[Headers.contentLengthHeader], 5);
    expect(
      put.headers.keys.map((k) => k.toLowerCase()),
      isNot(contains('authorization')),
    );
    expect(store.bodies.single, bytes);
  });

  test('a failed PUT is not completed', () async {
    api.on('POST /file/uploads', {
      'data': {
        'id': 'up1',
        'name': 'abc',
        'url': 'https://bucket.example.com/files/u1/abc',
        'expires_at': '2026-01-01T00:20:00Z',
      },
    });
    store.status = 403;
    await signedIn();

    final e = await client
        .upload(data: Stream.value([1]), size: 1, originalName: 'a')
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<LkcException>().having((e) => e.status, 'status', 403));
    expect(api.requests.where((r) => r.path.endsWith('/complete')), isEmpty);
  });

  test('no web checkout where it is off', () async {
    final ios = LkcClient(
      oidc: LkcOidc(clientId: 'a', redirectUrl: 'a://cb'),
      cache: LkcMemoryCache(),
      webCheckout: false,
      api: Dio()..httpClientAdapter = api,
    );
    expect(() => ios.openCheckout('storage.plus'), throwsStateError);
    expect(() => ios.openPortal(), throwsStateError);
    expect(api.requests, isEmpty);
  });

  test('what was read shows before the network answers', () async {
    api.on('GET /v2/billing/paywall', {'data': _paywall});
    await client.refreshPaywall('zh_TW');
    expect(api.requests.last.uri.queryParameters, {'locale': 'zh-TW'});
    await signedIn();
    // Homebase not answering, a node mid-deploy's 404 included: the copy kept
    // stays.
    api.onFn('GET /v2/billing/paywall', (_) => (404, ''));
    final next = LkcClient(
      cache: cache,
      oidc: LkcOidc(clientId: 'test', redirectUrl: 'test://cb'),
      api: Dio()..httpClientAdapter = api,
    );
    await expectLater(next.refreshPaywall('zh_TW'), throwsA(anything));
    expect(next.paywall.value?.items('basic', 'basic').single.title, 'Uptime');
    // Another locale with nothing kept: these rows rather than none.
    await expectLater(next.refreshPaywall('de'), throwsA(anything));
    expect(next.paywall.value?.locale, 'en');

    // The account's own replies go with it.
    await client.signOut();
    expect(cache.read('user'), isNull);
    expect(cache.read('entitlements'), isNull);
    expect(cache.read('paywall.zh-TW'), isNotNull);
  });

  test('a reply that does not parse is not kept', () async {
    api
      ..etag = '"bad"'
      ..on('GET /v2/billing/paywall', {
        'data': {
          'lines': [
            {
              'line': 'basic',
              'tiers': [
                {
                  'tier': 'free',
                  'items': [
                    {'icon': 'sync'},
                  ],
                },
              ],
            },
          ],
        },
      });
    await expectLater(client.refreshPaywall('en'), throwsA(anything));
    expect(cache.read('paywall.en'), isNull);
  });

  test('a locale asked for later is not overwritten by an earlier', () async {
    final slow = Completer<void>();
    late RequestOptions served;
    api.gate = (o) async {
      if (o.uri.queryParameters['locale'] == 'de') await slow.future;
      served = o;
    };
    api.onFn(
      'GET /v2/billing/paywall',
      (_) => (
        200,
        {
          'data': {..._paywall, 'locale': served.uri.queryParameters['locale']},
        },
      ),
    );
    final de = client.refreshPaywall('de');
    await client.refreshPaywall('fr');
    slow.complete();
    await de;
    expect(client.paywall.value?.locale, 'fr');
    // Still kept for when German is asked for.
    expect(cache.read('paywall.de'), isNotNull);
  });

  test('amounts kept by an older build are dropped', () {
    final old = LkcMemoryCache()..write('benefits', const []);
    LkcClient(
      cache: old,
      oidc: LkcOidc(clientId: 'test', redirectUrl: 'test://cb'),
    );
    expect(old.read('benefits'), isNull);
  });

  test('a device registered for push is dropped on signing out', () async {
    api.on('POST /v2/devices', {
      'data': {
        'id': 'd1',
        'platform': 'ios',
        'app_id': 'com.lollipopkit.toolbox',
        'sandbox': true,
        'created_at': '2026-10-29T00:00:00Z',
        'last_seen_at': '2026-10-29T00:00:00Z',
      },
    });
    api.on('DELETE /v2/devices/d1', {'code': 0, 'msg': 'Ok'});
    await signedIn();
    final d = await client.registerDevice(
      token: 'ab12',
      appId: 'com.lollipopkit.toolbox',
      sandbox: true,
    );
    expect(d.id, 'd1');
    final sent = api.requests.lastWhere((r) => r.path == '/v2/devices');
    expect(sent.data, {
      'platform': 'ios',
      'app_id': 'com.lollipopkit.toolbox',
      'token': 'ab12',
      'sandbox': true,
    });

    await client.signOut();
    expect(
      api.requests.any(
        (r) => r.method == 'DELETE' && r.path == '/v2/devices/d1',
      ),
      isTrue,
    );
    expect(cache.read('device'), isNull);
  });

  group('Conduit key', () {
    test('asked with the access token, for this app and device', () async {
      conduit.onFn('POST /v0/user/app-keys', (_) => (201, {'item': {'id': 'ak1', 'key': 'sk-1'}}));
      await signedIn();
      expect(await client.conduitKey(device: 'dev1', deviceName: 'Mac'), 'sk-1');
      final sent = conduit.requests.single;
      expect(sent.headers[HttpHeaders.authorizationHeader], 'Bearer a1');
      expect(sent.data, {'app': 'test', 'device_id': 'dev1', 'device_name': 'Mac'});
    });

    test('a refusal carries Conduit\'s words', () async {
      conduit.onFn('POST /v0/user/app-keys', (_) => (404, {'error': 'app keys are not available'}));
      await signedIn();
      final e = await client.conduitKey(device: 'dev1').then<LkcException?>((_) => null, onError: (Object e) => e as LkcException);
      expect(e?.status, 404);
      expect(e?.message, 'app keys are not available');
    });

    test('one already gone is dropped', () async {
      conduit.onFn('DELETE /v0/user/app-keys/test/dev1', (_) => (404, {'error': 'api key not found'}));
      await signedIn();
      await client.dropConduitKey('dev1');
      expect(conduit.requests.single.method, 'DELETE');
    });

    test('told when known signed out: no session at launch', () async {
      var told = 0;
      client.onSignedOut.add(() => told++);
      await client.init();
      expect(told, 1);
    });

    test('told when known signed out: signing out', () async {
      var told = 0;
      client.onSignedOut.add(() => told++);
      await signedIn();
      expect(told, 0);
      await client.signOut();
      // Once for this side, again as the session ends: it may come twice.
      expect(told, isPositive);
    });

    test('a request Conduit never answers is an LkcException', () async {
      conduit.gate = (_) async => throw DioException.connectionError(
        requestOptions: RequestOptions(),
        reason: 'offline',
      );
      await signedIn();
      await expectLater(client.conduitKey(device: 'dev1'), throwsA(isA<LkcException>()));
    });

    test('what runs before signing out has the session still', () async {
      conduit.onFn('DELETE /v0/user/app-keys/test/dev1', (_) => (200, {'status': 'ok'}));
      await signedIn();
      var signedInThen = false;
      client.beforeSignOut.add(() async {
        signedInThen = client.signedIn;
        await client.dropConduitKey('dev1');
      });
      client.beforeSignOut.add(() async => throw StateError('passed'));
      await client.signOut();
      expect(signedInThen, isTrue);
      expect(conduit.requests.single.headers[HttpHeaders.authorizationHeader], 'Bearer a1');
      expect(client.signedIn, isFalse);
    });
  });

  test('the catalog is asked for by its ETag, and kept on a 304', () async {
    api
      ..etag = '"v1"'
      ..on('GET /v2/billing/plans', {
        'data': {
          'plans': [],
          'lines': [
            {'id': 'basic', 'name': 'Cloud Basic'},
          ],
          'free': {'name': 'Cloud Free'},
        },
      });
    await client.refreshCatalog();
    expect(
      api.requests.single.headers.keys,
      isNot(contains(HttpHeaders.ifNoneMatchHeader)),
    );
    api.onFn('GET /v2/billing/plans', (_) => (304, ''));
    final catalog = await client.refreshCatalog();
    expect(api.requests.last.headers[HttpHeaders.ifNoneMatchHeader], '"v1"');
    expect(catalog.lineName('basic'), 'Cloud Basic');
    expect(catalog.freeName, 'Cloud Free');
  });

  test('names are the ids until the catalog is read', () {
    const LkcCatalog? none = null;
    expect(none.lineName('basic'), 'basic');
    expect(none.planName('storage.plus'), 'storage.plus');
  });

  // TODO: rm with LkcCatalog's reading of a bare plan list.
  test('plans need no sign-in', () async {
    api.on('GET /v2/billing/plans', {
      'data': [
        {
          'id': 'conduit.plus',
          'line': 'conduit',
          'period': 'month',
          'web': [
            {'source': 'stripe', 'amount': 500, 'currency': 'usd'},
          ],
          'apple': [],
          'google': [],
        },
      ],
    });
    final plan = (await client.refreshCatalog()).plans.single;
    expect(plan.line, LkcLine.conduit);
    expect(plan.stripe?.amount, 500);
    expect(api.requests.single.headers.keys, isNot(contains('Authorization')));
  });
}

LkcException _thrown(void Function() f) {
  try {
    f();
  } on LkcException catch (e) {
    return e;
  }
  fail('nothing thrown');
}

/// Answers `METHOD /path` with JSON, and keeps what it was sent.
final class _Adapter implements HttpClientAdapter {
  final _replies = <String, Object>{};
  final requests = <RequestOptions>[];
  final bodies = <List<int>>[];
  int status = 200;

  /// Sent with every reply.
  String? etag;

  /// Holds a reply back until it completes.
  Future<void> Function(RequestOptions options)? gate;

  final _handlers = <String, (int, Object) Function(String body)>{};
  final _sent = <String, String>{};

  void on(String route, Object reply) => _replies[route] = reply;

  void onFn(String route, (int, Object) Function(String body) handler) =>
      _handlers[route] = handler;

  /// The last body sent to [path], as text.
  String bodyOf(String path) => _sent[path]!;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    await gate?.call(options);
    if (requestStream != null) {
      bodies.add([for (final chunk in await requestStream.toList()) ...chunk]);
    }
    final route = '${options.method} ${options.uri.path}';
    final data = options.data;
    if (data != null && requestStream == null) {
      _sent[options.uri.path] = data is Map
          ? Transformer.urlEncodeMap(data.cast<String, dynamic>())
          : '$data';
    } else if (requestStream != null) {
      _sent[options.uri.path] = utf8.decode(bodies.last, allowMalformed: true);
    }
    if (_handlers[route] case final handler?) {
      final (code, body) = handler(_sent[options.uri.path] ?? '');
      return ResponseBody.fromString(
        jsonEncode(body),
        code,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
          if (etag case final etag?) HttpHeaders.etagHeader: [etag],
        },
      );
    }
    final reply = _replies[route];
    return ResponseBody.fromString(
      reply == null ? '' : jsonEncode(reply),
      reply == null && status == 200 ? 200 : status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (etag case final etag?) HttpHeaders.etagHeader: [etag],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _RealHttp extends HttpOverrides {}

const _paywall = {
  'locale': 'en',
  'lines': [
    {
      'line': 'basic',
      'tiers': [
        {
          'tier': 'free',
          'items': [
            {
              'icon': 'sync',
              'title': 'Sync',
              'detail': 'Real-time, end-to-end encrypted',
            },
            {'icon': 'notifications', 'title': 'Push notifications'},
          ],
        },
        {
          'tier': 'basic',
          'items': [
            {
              'icon': 'monitor_heart',
              'title': 'Uptime',
              'detail': 'Every 5 minutes, up to 20 targets',
            },
          ],
        },
      ],
    },
    {
      'line': 'conduit',
      'tiers': [
        {
          'tier': 'conduit.plus',
          'items': [
            {'icon': 'toll', 'title': 'Credit', 'detail': r'$20 a month'},
          ],
        },
      ],
    },
    {'line': 'storage', 'tiers': []},
  ],
};
