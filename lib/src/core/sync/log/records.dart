import 'dart:async';
import 'dart:convert';

import 'package:fl_lib/src/core/store/iface.dart';
import 'package:fl_lib/src/core/sync/log/recorder.dart';

/// A record's change as the log carries it: `fl_sync::Op`. [d] null: deleted.
typedef SyncOp = ({String c, String id, String h, Object? d});

/// A record kind kept outside the kv stores: read to send, stamped where it
/// changed ([SyncRecorder.stampChanged]), and installed by its owner after the
/// stores are written.
typedef SyncKind = ({
  FutureOr<Object?> Function(String id) read,
  void Function()? stamp,
  FutureOr<void> Function(List<SyncOp> ops) install,
});

/// Records an app keeps in tables of its own (ServerBox's servers, keys,
/// snippets), written in the stores' transaction.
abstract interface class SyncTableRecords {
  /// Whether records of [c] are these.
  bool claims(String c);

  /// [read] for many records: what they read is read once.
  FutureOr<Object?> Function(String c, String id) reader();

  /// Writes [ops] (already decided to win), each stamped with its op's
  /// stamp, inside the transaction the stores' ops are written in. Answers
  /// the collections written.
  Set<String> write(List<SyncOp> ops);
}

/// The synced records as ops carry them: read from the stores to send, and
/// written back when another device's op wins.
abstract final class SyncRecords {
  static const _kvPrefix = 'kv:';

  /// The records kept outside the stores, by collection.
  static final kinds = <String, SyncKind>{};

  /// The app's own tables, if it has records in any.
  static SyncTableRecords? tables;

  /// After a read went past where it stopped before: what could not be
  /// written then is tried again (by the app). [carries] as the run asked.
  static FutureOr<void> Function(bool Function(String c) carries)? afterRead;

  /// Tells the app what other devices' ops changed: [won] all of them,
  /// [written] the collections the stores and [tables] wrote.
  static FutureOr<void> Function(List<SyncOp> won, Set<String> written)? announce;

  /// What [read] answers for a record it could not read now, as against null
  /// for one that is not here.
  static const unread = Object();

  /// What [read] answers for a record with nothing to say now: not sent, and
  /// nothing after it held back. It is stamped again once there is.
  static const silent = Object();

  /// [read] for many records.
  static FutureOr<Object?> Function(String c, String id) reader() {
    final table = tables?.reader();
    return (c, id) {
      if (kinds[c] case final kind?) return kind.read(id);
      if (c.startsWith(_kvPrefix)) {
        final store = _kvStore(c);
        if (store == null || !_syncedKey(store, id)) return null;
        return store.get<Object>(id);
      }
      if (table != null && tables!.claims(c)) return table(c, id);
      return null;
    };
  }

  /// The winners of [ops] against the stamps here, written: the stores and
  /// [tables] in one transaction, decided in it, so an edit made meanwhile is
  /// not overwritten; then [kinds]; then [announce].
  static Future<void> apply(List<SyncOp> ops) async {
    final current = SyncRecorder.stampsOf({for (final op in ops) (op.c, op.id)});
    final won = winners(ops, current);
    if (won.isEmpty) return;
    final written = write([for (final op in won) if (!kinds.containsKey(op.c)) op]);
    for (final MapEntry(key: c, value: kind) in kinds.entries) {
      final of = [for (final op in won) if (op.c == c) op];
      if (of.isNotEmpty) await kind.install(of);
    }
    await announce?.call(won, written);
  }

  /// Of [ops], per record the one with the greatest stamp, when greater than
  /// [current]'s (`fl_sync::winners`), in the order each record first came.
  static List<SyncOp> winners(List<SyncOp> ops, Map<(String, String), String> current) {
    final best = <(String, String), SyncOp>{};
    for (final op in ops) {
      final had = best[(op.c, op.id)];
      if (had == null || op.h.compareTo(had.h) > 0) best[(op.c, op.id)] = op;
    }
    return [
      for (final op in best.values)
        if (current[(op.c, op.id)] case final h when h == null || op.h.compareTo(h) > 0) op,
    ];
  }

  /// Writes [ops] (already decided to win) as other devices' changes: each
  /// record stamped with its op's [SyncOp.h]. One transaction. Answers the
  /// collections written.
  static Set<String> write(List<SyncOp> ops) {
    final kv = <({SqliteStore store, String key, String h, Object? d})>[];
    final table = <SyncOp>[];
    for (final op in ops) {
      if (op.c.startsWith(_kvPrefix)) {
        final store = _kvStore(op.c);
        if (store != null && _syncedKey(store, op.id)) kv.add((store: store, key: op.id, h: op.h, d: op.d));
      } else if (tables?.claims(op.c) ?? false) {
        table.add(op);
      }
    }
    final written = <String>{};
    SqliteStore.transact(() {
      if (table.isNotEmpty) written.addAll(tables!.write(table));
      for (final op in kv) {
        SyncRecorder.receiving(op.h, () {
          final done = op.d == null
              ? op.store.remove(op.key, updateLastUpdateTsOnRemove: false)
              : op.store.set(op.key, op.d!, updateLastUpdateTsOnSet: false);
          if (!done) throw StateError('failed to write ${op.store.name}/${op.key}');
          SyncRecorder.record(SyncRecorder.kvOf(op.store), op.key);
        });
        written.add(SyncRecorder.kvOf(op.store));
      }
    });
    // The whole backup's stamps, at each op's time, so it agrees with what
    // was written.
    for (final op in kv) {
      unawaited(op.store.updateLastUpdateTs(ts: SyncRecorder.msOf(op.h), key: op.key));
    }
    return written;
  }

  static SqliteStore? _kvStore(String c) => SyncRecorder.syncedStores[c.substring(_kvPrefix.length)];

  static bool _syncedKey(SqliteStore store, String key) => !store.isInternalKey(key) && !store.isDeviceLocalKey(key);

  /// [value] as plain JSON (maps, lists, primitives), as another device
  /// decodes it.
  static Object? plain(Object? value) => json.decode(json.encode(value));
}
