import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:fl_lib/src/core/logger.dart';
import 'package:fl_lib/src/core/store/iface.dart';
import 'package:fl_lib/src/core/sync/log/categories.dart';
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
      SyncRefused() => 'refused',
      _ => 'host',
    };
    if (kind == 'host') Loggers.app.warning('Sync host call', e, s);
    return SyncReply(json: '', error: '$e', errorKind: kind);
  }
}

/// The host the engine reads and writes through: [SyncRecorder]'s records,
/// [SyncRecords]' values, the `sync_state` and `sync_passed` tables, and
/// [files] for a segment engine.
final class SyncHost {
  SyncHost({this.files, this.stamp});

  final SyncFiles? files;

  /// Stamps what changed without a write that stamps it (files), before what
  /// is pending is read.
  final void Function()? stamp;

  Future<SyncReply> call(String method, String args, Uint8List? bytes) {
    final a = args.isEmpty ? null : jsonDecode(args);
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
      'apply' => syncReply(() => SyncRecords.apply(_ops(a as List))),
      'notCarried' => syncReply(() => SyncCategories.notCarried().toList()),
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
      _ => Future.value(SyncReply(json: '', error: 'no such call: $method', errorKind: 'host')),
    };
  }

  SyncFiles get _files => files ?? (throw StateError('Not a segment sync'));

  static List<List<String>> _rows(List<({String c, String id, String hlc})> rows) => [
    for (final r in rows) [r.c, r.id, r.hlc],
  ];

  static Future<List<Map<String, Object?>>> _read(List<Object?> ids) async {
    final read = SyncRecords.reader();
    final out = <Map<String, Object?>>[];
    for (final pair in ids.cast<List<Object?>>()) {
      final d = await read(pair[0] as String, pair[1] as String);
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
