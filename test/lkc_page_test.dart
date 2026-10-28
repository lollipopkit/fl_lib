import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n_en.dart';
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
  {'tier': 'storage.plus', 'benefit': 'file.bytes', 'value': 50000000000},
  {'tier': 'storage.plus', 'benefit': 'file.max_bytes', 'value': 5000000000},
];

LkcClient _client({required bool webCheckout}) => LkcClient(
  oidc: LkcOidc(clientId: 'test', redirectUrl: 'test://cb'),
  webCheckout: webCheckout,
  api: Dio()
    ..httpClientAdapter = _Adapter({
      '/v2/billing/plans': _plans,
      '/v2/billing/benefits': _benefits,
    }),
);

Future<void> _pump(WidgetTester tester, LkcClient client) async {
  await tester.pumpWidget(
    MaterialApp(home: LkcAccountPage(args: LkcPageArgs(client))),
  );
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  testWidgets('signed out: sign-in, and the plans on sale', (tester) async {
    await _pump(tester, _client(webCheckout: true));
    expect(find.text(_l10n.lkcSignInBrowser), findsOneWidget);
    expect(find.text('Storage Plus'), findsOneWidget);
    expect(find.text(_l10n.lkcPerYear(r'$12.00')), findsOneWidget);
    expect(find.text('WebDAV 50 GB, files up to 5 GB each'), findsOneWidget);
    // Subscribing needs an account.
    expect(find.text(_l10n.lkcSubscribe), findsNothing);
  });

  testWidgets('no plans or prices where web checkout is off', (tester) async {
    await _pump(tester, _client(webCheckout: false));
    expect(find.text(_l10n.lkcSignInBrowser), findsOneWidget);
    expect(find.text('Storage Plus'), findsNothing);
    expect(find.textContaining(r'$'), findsNothing);
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
