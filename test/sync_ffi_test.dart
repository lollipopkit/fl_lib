import 'dart:convert';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

import 'rust_lib.dart';

void main() {
  setUpAll(loadFlRustForTest);

  test('stamps go forward and the newest op per record wins', () {
    final device = BigInt.from(7);
    final a = syncTick(device: device, last: '', nowMs: BigInt.from(1000));
    final b = syncTick(device: device, last: a, nowMs: BigInt.from(900));
    expect(b.compareTo(a), greaterThan(0));
    expect(syncLater(last: a, seen: b), b);
    expect(syncStampOf(ms: BigInt.from(1000), device: device), a);

    final ops = [
      {'c': 'spi', 'id': 'x', 'h': a, 'd': {'name': 'old'}},
      {'c': 'spi', 'id': 'x', 'h': b, 'd': null},
    ];
    final won = jsonDecode(syncWinners(opsJson: jsonEncode(ops), currentJson: '{}')) as List;
    expect(won.single['d'], isNull);
    final held = jsonEncode({'spi\u0000x': b});
    expect(jsonDecode(syncWinners(opsJson: jsonEncode(ops), currentJson: held)), isEmpty);
    expect(() => syncLater(last: 'nope', seen: a), throwsA(isA<SyncFailure>()));
    expect(() => syncLater(last: 'nope', seen: ''), throwsA(isA<SyncFailure>()));
    expect(() => syncLater(last: '', seen: 'nope'), throwsA(isA<SyncFailure>()));
    expect(syncLater(last: '', seen: ''), '');
    expect(
      () => syncWinners(opsJson: jsonEncode(ops), currentJson: jsonEncode({'spi\u0000x': 'nope'})),
      throwsA(isA<SyncFailure>()),
    );
  });

  test('a blob name is keyed: the same data under another key is another name', () {
    final a = syncBlobName(secret: 'k1', data: [1, 2, 3]);
    expect(a, hasLength(64));
    expect(syncBlobName(secret: 'k1', data: [1, 2, 3]), a);
    expect(syncBlobName(secret: 'k2', data: [1, 2, 3]), isNot(a));
  });
}
