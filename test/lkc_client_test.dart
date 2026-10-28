import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'package:dio/dio.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n_en.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

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

/// Saved tokens whose access token ends in [left].
String _saved(Duration left, {String access = 'a1', String refresh = 'r1'}) =>
    jsonEncode(
      LkcTokens(
        access: access,
        refresh: refresh,
        expiresAt: DateTime.now().add(left),
      ).toJson(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Adapter api;
  late _Adapter store;
  late _Adapter idp;
  late LkcClient client;
  late LkcMemoryCache cache;
  Future<bool> Function(Uri url) browser = (_) async => false;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    api = _Adapter()
      ..on('GET /auth/user', {'data': _user})
      ..on('GET /v2/entitlements', {'data': []});
    store = _Adapter();
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

  group('benefits', () {
    final l10n = LibLocalizationsEn();
    final benefits = LkcBenefits.fromJson([
      {'tier': 'free', 'benefit': 'backup.count', 'value': 1},
      {'tier': 'free', 'benefit': 'backup.app_bytes', 'value': 10000000},
      {'tier': 'free', 'benefit': 'file.bytes', 'value': 0},
      {'tier': 'basic', 'benefit': 'backup.count', 'value': null},
      {'tier': 'basic', 'benefit': 'backup.total_bytes', 'value': 1000000000},
      {'tier': 'basic', 'benefit': 'relay.bytes_per_sec', 'value': 2500000},
      {'tier': 'basic', 'benefit': 'uptime.targets', 'value': 10},
      {'tier': 'basic', 'benefit': 'uptime.interval_secs', 'value': 60},
      {'tier': 'basic', 'benefit': 'sync', 'value': 1},
      {'tier': 'basic', 'benefit': 'future.thing', 'value': 3},
      {'tier': 'storage.plus', 'benefit': 'file.bytes', 'value': 50000000000},
      {
        'tier': 'storage.plus',
        'benefit': 'file.max_bytes',
        'value': 2000000000,
      },
      {'tier': 'storage.pro', 'benefit': 'file.bytes', 'value': null},
      {'tier': 'storage.pro', 'benefit': 'file.max_bytes', 'value': null},
    ]);

    test('a missing row grants nothing, null is unlimited', () {
      expect(benefits.amount('free', LkcBenefit.backupCount), 1);
      expect(benefits.amount('free', LkcBenefit.sync), 0);
      expect(benefits.amount('basic', LkcBenefit.backupCount), isNull);
      expect(benefits.amount('conduit.pro', LkcBenefit.sync), 0);
    });

    test('items from the amounts', () {
      List<String> items(String tier, LkcLine line) => [
        for (final i in benefits.items(l10n, tier, line)) '$i',
      ];
      expect(items(LkcBenefits.free, LkcLine.basic), [
        'Backups: Latest one per app, up to 10 MB per app',
      ]);
      expect(items(LkcBenefits.free, LkcLine.storage), isEmpty);
      expect(items('basic', LkcLine.basic), [
        'Backups: Unlimited rolling per app, 1 GB shared by all apps',
        'Relay, tailnet and push: Unlimited traffic, 2.5 MB/s, no availability guarantee',
        'Downtime checks: Every minute, up to 10 targets',
        'Sync: Real-time, end-to-end encrypted',
      ]);
      expect(items('storage.plus', LkcLine.storage), [
        'WebDAV: Files up to 2 GB each',
        'Share links: With expiry',
      ]);
      expect(
        items('storage.pro', LkcLine.storage).first,
        'WebDAV: Files up to 5 GB each',
      );
    });

    test('a Conduit plan by its limits', () {
      expect(
        [
          for (final i in lkcConduitItems(
            l10n,
            const LkcConduitLimits(
              period: 'monthly',
              creditNanoUsd: 5000000000,
              concurrency: 4,
            ),
          ))
            '$i',
        ],
        ['Credit: \$5.00 per month', 'Concurrency: 4 requests in flight'],
      );
    });

    test('sizes in powers of 1000', () {
      expect(lkcBytes(999), '999 B');
      expect(lkcBytes(9500000), '9.5 MB');
      expect(lkcBytes(12300000), '12 MB');
      expect(lkcBytes(5000000000), '5 GB');
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

    test('a due one is refreshed once, however many ask', () async {
      var refreshes = 0;
      idp.onFn('POST /auth/v1/oidc/token', (_) {
        refreshes++;
        return (200, {'access_token': 'a2', 'expires_in': 300});
      });
      await signedIn(const Duration(seconds: 30));
      await Future.wait([
        for (var i = 0; i < 3; i++) client.refreshEntitlements(),
      ]);
      expect(refreshes, 1);
      expect(
        Uri.splitQueryString(idp.bodyOf('/auth/v1/oidc/token'))['grant_type'],
        'refresh_token',
      );
      expect(api.requests.last.headers['Authorization'], 'Bearer a2');
      // A refresh token not rotated is kept.
      final saved =
          jsonDecode((await SecureStoreProps.lkcToken.read())!) as Map;
      expect((saved['access'], saved['refresh']), ('a2', 'r1'));
    });

    test('a refused refresh token signs out', () async {
      idp.onFn(
        'POST /auth/v1/oidc/token',
        (_) => (400, {'error': 'invalid_grant'}),
      );
      FlutterSecureStorage.setMockInitialValues({
        'lkcToken': _saved(Duration.zero),
      });
      await expectLater(client.init(), throwsA(isA<LkcException>()));
      expect(client.signedIn, isFalse);
      expect(await SecureStoreProps.lkcToken.read(), isNull);
    });

    test('a proxy in front of the IdP is no word on the grant', () async {
      // Cloudflare's challenge: a page, not the IdP's `invalid_grant`.
      idp.onFn(
        'POST /auth/v1/oidc/token',
        (_) => (403, '<html>challenge</html>'),
      );
      await expectLater(
        signedIn(const Duration(seconds: 30)),
        throwsA(isA<LkcException>()),
      );
      expect(client.signedIn, isTrue);
      expect(await SecureStoreProps.lkcToken.read(), isNotNull);
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
      expect(api.requests, isEmpty);
    });

    test('signing out revokes the refresh token', () async {
      await signedIn();
      await client.signOut();
      expect(client.signedIn, isFalse);
      final revoke = Uri.splitQueryString(
        idp.bodyOf('/auth/v1/oidc/token/revoke'),
      );
      expect(
        (revoke['token'], revoke['token_type_hint']),
        ('r1', 'refresh_token'),
      );
    });

    test('a deleted account takes the tokens with it', () async {
      api.on('DELETE /auth/user', {'code': 0, 'msg': 'Ok'});
      await signedIn();
      await client.deleteAccount();
      expect(client.signedIn, isFalse);
      expect(client.user.value, isNull);
      expect(await SecureStoreProps.lkcToken.read(), isNull);
      expect(idp.requests.any((r) => r.uri.path.endsWith('/revoke')), isTrue);
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
    api.on('GET /v2/billing/benefits', {
      'data': [
        {'tier': 'free', 'benefit': 'sync', 'value': 1},
      ],
    });
    await client.refreshBenefits();
    await signedIn();
    final next = LkcClient(
      cache: cache,
      oidc: LkcOidc(clientId: 'test', redirectUrl: 'test://cb'),
    );
    expect(next.benefits.value?.amount('free', LkcBenefit.sync), 1);

    // The account's own replies go with it.
    await client.signOut();
    expect(cache.read('user'), isNull);
    expect(cache.read('entitlements'), isNull);
    expect(cache.read('benefits'), isNotNull);
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
          'limits': {
            'period': 'monthly',
            'credit_nano_usd': 5000000000,
            'concurrency': null,
          },
        },
      ],
    });
    final plan = (await client.refreshPlans()).single;
    expect(plan.line, LkcLine.conduit);
    expect(plan.stripe?.amount, 500);
    expect(plan.limits?.concurrency, isNull);
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
        },
      );
    }
    final reply = _replies[route];
    return ResponseBody.fromString(
      reply == null ? '' : jsonEncode(reply),
      reply == null && status == 200 ? 200 : status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

final class _RealHttp extends HttpOverrides {}
