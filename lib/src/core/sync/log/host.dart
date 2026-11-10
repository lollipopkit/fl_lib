import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:icloud_storage_plus/icloud_storage.dart' show ICloudContainerAccessException, ICloudCoordinationException;
import 'package:webdav_client_plus/webdav_client_plus.dart' show WebdavException;

import 'package:fl_lib/src/core/lkc/client.dart';
import 'package:fl_lib/src/core/logger.dart';
import 'package:fl_lib/src/core/store/iface.dart';
import 'package:fl_lib/src/core/sync/log/groups.dart';
import 'package:fl_lib/src/core/sync/log/errors.dart';
import 'package:fl_lib/src/core/sync/log/recorder.dart';
import 'package:fl_lib/src/core/sync/log/records.dart';
import 'package:fl_lib/src/rust/api/sync_engine.dart';

/// A folder only this app writes to, on WebDAV or iCloud: where the segment
/// sync keeps its files. [write] writes over one there.
abstract interface class SyncFiles {
  Future<void> write(String name, Uint8List body);

  /// The file [name], null when it is gone.
  Future<Uint8List?> read(String name);

  /// The files whose name starts with [prefix], and when each was written.
  Future<List<({String name, DateTime? at})>> list(String prefix);

  Future<void> delete(String name);
}

/// Whether [e] is the store's or the network's, worth trying later: no
/// answer, a timeout, a server's error.
bool isRemoteFailure(Object e) => switch (e) {
  SocketException() || TimeoutException() || HttpException() || TlsException() => true,
  DioException(:final response) => (response?.statusCode ?? 500) >= 500,
  WebdavException(:final statusCode) => statusCode == null || statusCode >= 500,
  // Signed out of iCloud, or its container not reachable now.
  ICloudContainerAccessException() || ICloudCoordinationException() => true,
  _ => false,
};

/// A log the server orders, kept by Dart (LK Cloud's is reached in Rust):
/// a test's, or a store an app reaches itself. Its blobs are [SyncFiles].
abstract interface class SyncLogStore implements SyncFiles {
  /// Appends [body] once per [key]: the seq given, of which log, and whether
  /// a snapshot is due. [SyncLogFull] while a snapshot is due first.
  Future<({String log, int seq, bool compact})> append(String key, Uint8List body);

  /// The batches after [after] of [log], or [SyncLogPage.compacted].
  Future<SyncLogPage> readLog(int after, String? log);

  /// [body] as the snapshot up to [seq]; false when one at or past it is
  /// there already.
  Future<bool> putSnapshot(int seq, Uint8List body);

  /// The snapshot, null before there is one.
  Future<({String log, int seq, Uint8List body})?> snapshot();
}

final class SyncLogPage {
  const SyncLogPage({required this.log, required this.batches, required this.more}) : compacted = false;

  /// The batches after the cursor are gone, or it was of another log.
  const SyncLogPage.compacted({this.log}) : batches = const [], more = false, compacted = true;

  final String? log;
  final List<(int, Uint8List)> batches;
  final bool more;
  final bool compacted;
}

/// The log takes no more batches until a snapshot covers them.
final class SyncLogFull implements Exception {
  const SyncLogFull();
}

/// The calls the Rust engine makes of Dart, answered.
typedef SyncCall = Future<SyncReply> Function(String method, String json, Uint8List? bytes);

/// [answer]'s result as a reply: as JSON, or [json] of it, and [bytes] of it
/// beside; or the error it threw and its kind.
Future<SyncReply> syncReply<T>(
  FutureOr<T> Function() answer, {
  Uint8List? Function(T result)? bytes,
  Object? Function(T result)? json,
}) async {
  try {
    final result = await answer();
    final value = json != null ? json(result) : (bytes != null ? null : result);
    return SyncReply(json: jsonEncode(value), bytes: bytes?.call(result));
  } catch (e, s) {
    final kind = switch (e) {
      SyncPasswordMissing() => 'passwordMissing',
      SyncRefused() || SyncLogFull() => 'refused',
      LkcException(reason: 'signed_out') => 'signedOut',
      _ when isRemoteFailure(e) => 'remote',
      _ => 'host',
    };
    if (kind == 'host') Loggers.app.warning('Sync host call', e, s);
    return SyncReply(json: '', error: e is SyncLogFull ? 'sync_log_full' : '$e', errorKind: kind);
  }
}

/// The host the engine reads and writes through: [SyncRecorder]'s records,
/// [SyncRecords]' values, the `sync_state` and `sync_passed` tables, and
/// [files] for a segment engine.
final class SyncHost {
  SyncHost({SyncFiles? files, this.log, this.stamp}) : files = files ?? log;

  final SyncFiles? files;

  /// The log, when Dart keeps it ([SyncLogEngine.onDart]).
  final SyncLogStore? log;

  /// The bodies of the page [log] read last, by seq: fetched one by one.
  final _page = <int, Uint8List>{};

  /// Stamps what changed without a write that stamps it (files), before what
  /// is pending is read.
  final void Function()? stamp;

  Future<SyncReply> call(String method, String args, Uint8List? bytes) {
    final Object? a;
    try {
      a = args.isEmpty ? null : jsonDecode(args);
    } on FormatException catch (e) {
      return Future.value(SyncReply(json: '', error: '$method: $e', errorKind: 'host'));
    }
    return switch (method) {
      'device' => syncReply(() => SyncRecorder.device.toInt()),
      'stamp' => syncReply(() {
        stamp?.call();
        for (final kind in SyncRecords.kinds.values) {
          kind.stamp?.call();
        }
        return null;
      }),
      'all' => syncReply(() => _rows(SyncRecorder.all())),
      'pending' => syncReply(() => _rows(SyncRecorder.pending(a as String? ?? ''))),
      'read' => syncReply(() => _read(a as List)),
      'apply' => syncReply(() async => [
        for (final op in await SyncRecords.apply(_ops(a as List))) {'c': op.c, 'id': op.id, 'h': op.h, 'd': op.d},
      ]),
      'notCarried' => syncReply(() => SyncGroups.notCarried().toList()),
      'afterRead' => syncReply(() {
        final not = {for (final c in a as List) c as String};
        return SyncRecords.afterRead?.call((c) => !not.contains(c));
      }),
      'state' => syncReply(() => [for (final k in a as List) _state(k as String)]),
      'statePrefixed' => syncReply(() => [
        for (final row in SqliteDb.instance.select('SELECT k, v FROM sync_state WHERE substr(k, 1, ?) = ?;', [(a as String).length, a]))
          [row['k'], row['v']],
      ]),
      'setState' => syncReply(() => _setState([for (final e in a as List) (e[0] as String, e[1] as String?)])),
      'clearState' => syncReply(() {
        final m = a as Map;
        final prefix = m['prefix'] as String;
        final keep = [for (final k in m['keep'] as List) k as String];
        SqliteDb.instance.execute(
          'DELETE FROM sync_state WHERE substr(k, 1, ?) = ?${keep.isEmpty ? '' : ' AND k NOT IN (${List.filled(keep.length, '?').join(', ')})'};',
          [prefix.length, prefix, ...keep],
        );
        return null;
      }),
      'pass' => syncReply(() => _pass((a as Map)['engine'] as String, _ops(a['ops'] as List))),
      'passed' => syncReply(() => [
        for (final row in SqliteDb.instance.select('SELECT c, id, h, d FROM sync_passed WHERE e = ?;', [a as String]))
          {'c': row['c'], 'id': row['id'], 'h': row['h'], 'd': jsonDecode(row['d'] as String)},
      ]),
      'forgetPassed' => syncReply(() => SqliteDb.instance.execute('DELETE FROM sync_passed WHERE e = ?;', [a as String])),
      'warn' => syncReply(() => Loggers.app.warning(a)),
      'files.write' => syncReply(() => _files.write(a as String, bytes ?? Uint8List(0))),
      'files.read' => syncReply(() => _files.read(a as String), bytes: (r) => r),
      'files.list' => syncReply(() async => [
        for (final f in await _files.list(a as String)) [f.name, f.at?.millisecondsSinceEpoch],
      ]),
      'files.delete' => syncReply(() => _files.delete(a as String)),
      'log.append' => syncReply(() async {
        final r = await _log.append(a as String, bytes ?? Uint8List(0));
        return {'log': r.log, 'seq': r.seq, 'compact': r.compact};
      }),
      'log.read' => syncReply(() async {
        final m = a as Map;
        final page = await _log.readLog(m['after'] as int, m['log'] as String?);
        _page
          ..clear()
          ..addEntries(page.batches.map((b) => MapEntry(b.$1, b.$2)));
        return {
          'log': page.log,
          'compacted': page.compacted,
          'more': page.more,
          'batches': [for (final (seq, _) in page.batches) {'seq': seq}],
        };
      }),
      'log.batch' => syncReply(() => _page[a as int], bytes: (r) => r),
      'log.putSnapshot' => syncReply(() => _log.putSnapshot(a as int, bytes ?? Uint8List(0))),
      'log.snapshot' => syncReply(() => _log.snapshot(), bytes: (r) => r?.body, json: (r) => r == null ? null : {'log': r.log, 'seq': r.seq}),
      _ => Future.value(SyncReply(json: '', error: 'no such call: $method', errorKind: 'host')),
    };
  }

  SyncFiles get _files => files ?? (throw StateError('Not a segment sync'));

  SyncLogStore get _log => log ?? (throw StateError('No log kept in Dart'));

  static List<List<String>> _rows(List<({String c, String id, String hlc})> rows) => [
    for (final r in rows) [r.c, r.id, r.hlc],
  ];

  static Future<List<Map<String, Object?>>> _read(List<Object?> ids) async {
    final pairs = [for (final p in ids.cast<List<Object?>>()) (p[0] as String, p[1] as String)];
    // A kind that reads many at once, once per kind.
    final many = <(String, String), Object?>{};
    for (final MapEntry(key: c, value: kind) in SyncRecords.kinds.entries) {
      final readMany = kind.readMany;
      if (readMany == null) continue;
      final of = [for (final (pc, id) in pairs) if (pc == c) id];
      if (of.isEmpty) continue;
      final read = await readMany(of);
      for (var i = 0; i < of.length; i++) {
        many[(c, of[i])] = read[i];
      }
    }
    final read = SyncRecords.reader();
    final out = <Map<String, Object?>>[];
    for (final pair in pairs) {
      final d = many.containsKey(pair) ? many[pair] : await read(pair.$1, pair.$2);
      out.add(switch (d) {
        _ when identical(d, SyncRecords.unread) => const {'unread': true},
        _ when identical(d, SyncRecords.silent) => const {'silent': true},
        null => const {'gone': true},
        _ => {'v': SyncRecords.plain(d)},
      });
    }
    return out;
  }

  static List<SyncOp> _ops(List<Object?> ops) => [
    for (final op in ops.cast<Map<String, Object?>>()) (c: op['c'] as String, id: op['id'] as String, h: op['h'] as String, d: op['d']),
  ];

  static String? _state(String k) {
    final rows = SqliteDb.instance.select('SELECT v FROM sync_state WHERE k = ?;', [k]);
    return rows.isEmpty ? null : rows.first['v'] as String;
  }

  static void _setState(List<(String, String?)> values) => SqliteStore.transact(() {
    for (final (k, v) in values) {
      if (v == null) {
        SqliteDb.instance.execute('DELETE FROM sync_state WHERE k = ?;', [k]);
      } else {
        SqliteDb.instance.execute(
          'INSERT INTO sync_state (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v;',
          [k, v],
        );
      }
    }
  });

  static void _pass(String engine, List<SyncOp> ops) => SqliteStore.transact(() {
    for (final op in ops) {
      SqliteDb.instance.execute(
        'INSERT INTO sync_passed (e, c, id, h, d) VALUES (?, ?, ?, ?, ?) '
        'ON CONFLICT (e, c, id) DO UPDATE SET h = excluded.h, d = excluded.d WHERE excluded.h > sync_passed.h;',
        [engine, op.c, op.id, op.h, jsonEncode(op.d)],
      );
    }
  });
}
