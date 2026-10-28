import 'dart:convert';
import 'dart:typed_data';

import 'dart:io';

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

/// A JWT whose payload expires at [exp]; the signature isn't checked here.
String _jwt(DateTime exp) {
  String part(Object o) =>
      base64Url.encode(utf8.encode(jsonEncode(o))).replaceAll('=', '');
  return '${part({'alg': 'HS256'})}.${part({'sub': 'u1', 'exp': exp.millisecondsSinceEpoch ~/ 1000})}.sig';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Adapter api;
  late _Adapter store;
  late LkcClient client;

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    api = _Adapter();
    store = _Adapter();
    client = LkcClient(
      appId: 'com.lollipopkit.Test',
      api: Dio()..httpClientAdapter = api,
      store: Dio()..httpClientAdapter = store,
    );
  });

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

  test('only this app\'s callback gives a token', () {
    Uri link(String s) => Uri.parse(s);
    expect(
      client.tokenOf(
        link('lpkt.cn://com.lollipopkit.Test/oauth-callback?token=t'),
      ),
      't',
    );
    for (final s in [
      'lpkt.cn://com.lollipopkit.other/oauth-callback?token=t',
      'lpkt.cn://com.lollipopkit.Test/other?token=t',
      'https://com.lollipopkit.Test/oauth-callback?token=t',
      'lpkt.cn://com.lollipopkit.Test/oauth-callback?token=',
      'lpkt.cn://com.lollipopkit.Test/oauth-callback',
    ]) {
      expect(client.tokenOf(link(s)), isNull, reason: s);
    }
  });

  test('the login page names the app', () {
    expect(
      client.loginUrl.toString(),
      'https://api.lollipopkit.com/auth/oauth?app_id=com.lollipopkit.Test',
    );
  });

  group('sign-in', () {
    final token = _jwt(DateTime.now().add(const Duration(days: 365)));

    test('saves a token the server accepts', () async {
      api.on('GET /auth/user', {'data': _user});
      api.on('GET /v2/entitlements', {
        'data': [
          {
            'plan': 'storage.plus',
            'source': 'stripe',
            'status': 'past_due',
            'cancel_scheduled': false,
          },
        ],
      });
      final user = await client.signIn(' $token\n');
      expect(user.id, 'u1');
      expect(api.requests.first.headers['Authorization'], 'Bearer $token');
      expect(await SecureStoreProps.lkcToken.read(), token);
      final storage = client.entitlementOf(LkcLine.storage)!;
      expect(storage.status, LkcStatus.pastDue);
      expect(storage.status.grants, isTrue);
    });

    test('keeps no token the server refuses', () async {
      api.on('GET /auth/user', {'code': 2, 'msg': 'No perm'});
      await expectLater(client.signIn(token), throwsA(isA<LkcException>()));
      expect(client.signedIn, isFalse);
      expect(await SecureStoreProps.lkcToken.read(), isNull);
    });

    test('an expired token is not sent', () async {
      final old = _jwt(DateTime.now().subtract(const Duration(days: 1)));
      await expectLater(client.signIn(old), throwsA(isA<LkcException>()));
      FlutterSecureStorage.setMockInitialValues({'lkcToken': old});
      await client.init();
      expect(api.requests, isEmpty);
      expect(await SecureStoreProps.lkcToken.read(), isNull);
    });

    test('a deleted account takes the token with it', () async {
      api.on('GET /auth/user', {'data': _user});
      api.on('GET /v2/entitlements', {'data': []});
      api.on('DELETE /auth/user', {'code': 0, 'msg': 'Ok'});
      await client.signIn(token);
      await client.deleteAccount();
      expect(client.signedIn, isFalse);
      expect(client.user.value, isNull);
      expect(await SecureStoreProps.lkcToken.read(), isNull);
    });
  });

  test('uploads straight to the store, without the token', () async {
    final token = _jwt(DateTime.now().add(const Duration(days: 1)));
    api.on('GET /auth/user', {'data': _user});
    api.on('GET /v2/entitlements', {'data': []});
    api.on('POST /file/uploads', {
      'data': {
        'id': 'up1',
        'name': 'abc.txt',
        'url': 'https://bucket.example.com/files/u1/abc.txt?X-Amz-Signature=s',
        'expires_at': '2026-01-01T00:20:00Z',
      },
    });
    api.on('POST /file/uploads/up1/complete', {'data': 'abc.txt'});
    await client.signIn(token);

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
    final token = _jwt(DateTime.now().add(const Duration(days: 1)));
    api.on('GET /auth/user', {'data': _user});
    api.on('GET /v2/entitlements', {'data': []});
    api.on('POST /file/uploads', {
      'data': {
        'id': 'up1',
        'name': 'abc',
        'url': 'https://bucket.example.com/files/u1/abc',
        'expires_at': '2026-01-01T00:20:00Z',
      },
    });
    store.status = 403;
    await client.signIn(token);

    final e = await client
        .upload(data: Stream.value([1]), size: 1, originalName: 'a')
        .then<Object?>((_) => null, onError: (Object e) => e);
    expect(e, isA<LkcException>().having((e) => e.status, 'status', 403));
    expect(api.requests.where((r) => r.path.endsWith('/complete')), isEmpty);
  });

  test('no web checkout where it is off', () async {
    final ios = LkcClient(
      appId: 'a',
      webCheckout: false,
      api: Dio()..httpClientAdapter = api,
    );
    expect(() => ios.openCheckout('storage.plus'), throwsStateError);
    expect(() => ios.openPortal(), throwsStateError);
    expect(api.requests, isEmpty);
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
    final plan = (await client.plans()).single;
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

  void on(String route, Object reply) => _replies[route] = reply;

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
    final reply = _replies['${options.method} ${options.uri.path}'];
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
