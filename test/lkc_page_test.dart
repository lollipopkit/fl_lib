import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n_en.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

final _l10n = LibLocalizationsEn();

const _plans = [
  {
    'id': 'storage.plus',
    'line': 'storage',
    'period': 'year',
    'web': [
      {'source': 'stripe', 'amount': 1200, 'currency': 'usd'},
    ],
    'apple': [],
    'google': [],
  },
];

const _benefits = [
  {'tier': 'basic', 'benefit': 'backup.count', 'value': 10},
  {'tier': 'basic', 'benefit': 'backup.app_bytes', 'value': 100000000},
  {'tier': 'free', 'benefit': 'file.bytes', 'value': 100000000},
  {'tier': 'free', 'benefit': 'file.max_bytes', 'value': 5000000000},
  {'tier': 'storage.plus', 'benefit': 'file.bytes', 'value': 50000000000},
  {'tier': 'storage.plus', 'benefit': 'file.max_bytes', 'value': 5000000000},
];

const _user = {
  'id': 'u1',
  'name': 'lollipopkit',
  'group': 'user',
  'created_at': '2026-01-01T00:00:00Z',
  'updated_at': '2026-01-02T00:00:00Z',
};

const _entitlements = [
  {
    'plan': 'basic',
    'line': 'basic',
    'source': 'manual',
    'status': 'active',
    'period_end': '2027-10-28T06:39:00Z',
    'cancel_scheduled': true,
  },
];

LkcClient _client({required bool webCheckout}) => LkcClient(
  oidc: LkcOidc(clientId: 'test', redirectUrl: 'test://cb'),
  webCheckout: webCheckout,
  api: Dio()
    ..httpClientAdapter = _Adapter({
      '/v2/billing/plans': _plans,
      '/v2/billing/benefits': _benefits,
      '/auth/user': _user,
      '/v2/entitlements': _entitlements,
      '/file/usage': {
        'files': 3,
        'bytes': 12000000,
        'quota': {'bytes': 100000000, 'files': null, 'max_file_bytes': null},
      },
    }),
);

Future<void> _pump(
  WidgetTester tester,
  LkcClient client, {
  bool signedIn = false,
}) async {
  FlutterSecureStorage.setMockInitialValues({
    if (signedIn)
      'lkcToken': jsonEncode(
        LkcTokens(
          access: 'a',
          refresh: 'r',
          expiresAt: DateTime.now().add(const Duration(hours: 1)),
        ).toJson(),
      ),
  });
  unawaited(client.init());
  await tester.binding.setSurfaceSize(const Size(400, 1600));
  await tester.pumpWidget(
    MaterialApp(home: LkcAccountPage(args: LkcPageArgs(client))),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('signed out: a way in, and nothing else', (tester) async {
    await _pump(tester, _client(webCheckout: true));
    expect(find.text(_l10n.lkcNotSignedIn), findsOneWidget);
    expect(find.text(_l10n.login), findsOneWidget);
    expect(find.text('BASIC'), findsNothing);
  });

  testWidgets('signed in: each line by what it grants', (tester) async {
    await _pump(tester, _client(webCheckout: true), signedIn: true);
    expect(find.text('lollipopkit'), findsOneWidget);
    expect(find.text('BASIC'), findsOneWidget);
    expect(find.text(_l10n.lkcEndsOn('Oct 28, 2027')), findsOneWidget);
    expect(find.text(_l10n.lkcBenefitBackups), findsOneWidget);
    expect(find.text('12 MB / 100 MB'), findsOneWidget);
    expect(find.text(_l10n.lkcBenefitStorageDetail('5 GB')), findsOneWidget);
    // On sale where web checkout is on.
    expect(find.text('Storage Plus'), findsOneWidget);
    expect(find.text(_l10n.lkcPerYear(r'$12.00')), findsOneWidget);
    expect(find.text(_l10n.lkcDeleteAccount), findsOneWidget);
  });

  testWidgets('no plans or prices where web checkout is off', (tester) async {
    await _pump(tester, _client(webCheckout: false), signedIn: true);
    expect(find.text('BASIC'), findsOneWidget);
    expect(find.text('Storage Plus'), findsNothing);
    expect(find.text(_l10n.lkcSubscribe), findsNothing);
  });
}

final class _Adapter implements HttpClientAdapter {
  final Map<String, Object> data;

  _Adapter(this.data);

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final d = data[options.uri.path];
    return ResponseBody.fromString(
      jsonEncode(d == null ? {'code': 3, 'msg': 'Not found'} : {'data': d}),
      200,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}
