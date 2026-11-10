import 'dart:async';
import 'dart:math';

import 'package:fl_lib/src/core/rust.dart';
import 'package:fl_lib/src/core/store/iface.dart';
import 'package:fl_lib/src/core/sync/base.dart';
import 'package:fl_lib/src/rust/api/sync.dart';
import 'package:flutter/foundation.dart' show Listenable, visibleForTesting;
import 'package:sqlite3/sqlite3.dart';

/// Records every change a sync carries as its record's newest stamp in
/// `sync_record` (`fl_sync`'s hybrid logical clock).
///
/// A record is `(c, id)`: `kv:<store>` and the key for a key of a synced kv
/// store ([KvStore.onEdit], set by [install]), or what the app's own records
/// are ([record], [stampChanged]).
///
/// What this device still has to send is its own stamps after the last one
/// sent ([pending]); the value goes with it as the store holds it then.
abstract final class SyncRecorder {
  /// The kv stores that sync, by name ([install]).
  static final syncedStores = <String, SqliteStore>{};

  /// This install's id, in `sync_state`.
  static const _deviceKey = 'device';

  static Database get _db => SqliteDb.instance;

  static int _applying = 0;
  static String? _receiving;
  static BigInt? _device;
  static String? _last;

  /// Notified of each record stamped by this device (not while [applying] or
  /// [receiving]): what makes the syncs send.
  static final onLocal = <void Function()>[];

  /// The collection of [store]'s keys.
  static String kvOf(SqliteStore store) => 'kv:${store.name}';

  /// Writes an op another device made, stamped [h]: every record [write]
  /// stamps gets [h] as it is, and the clock moves past it.
  static T receiving<T>(String h, T Function() write) {
    final previous = _receiving;
    _receiving = h;
    try {
      return write();
    } finally {
      _receiving = previous;
    }
  }

  /// Sets [key] of [store] to what an older build kept outside the stores,
  /// as no device's edit at no time: an edit made on any device wins over
  /// it, and two devices that adopted different ones each keep theirs until
  /// one is edited. A record already here is newer: nothing is written then.
  /// TODO: remove with the keychain adoptions.
  static void adopt(SqliteStore store, String key, Object value) {
    final synced = _ready && syncedStores.containsKey(store.name) && !store.isDeviceLocalKey(key) && !store.isInternalKey(key);
    final c = kvOf(store);
    if (synced && stampsOf([(c, key)]).isNotEmpty) return;
    store.set(key, value, updateLastUpdateTsOnSet: false);
    if (!synced) return;
    receiving(syncStampOf(ms: BigInt.zero, device: legacy), () => record(c, key));
  }

  /// A stamp's wall-clock part.
  static int msOf(String h) => int.parse(h.substring(0, 12), radix: 16);

  /// A stamp's device, as [pending] compares it.
  static String deviceHexOf(BigInt device) => device.toRadixString(16).padLeft(16, '0');

  /// Writes changes that came from elsewhere through [write]: their stamps
  /// are no device's ([legacy]) and never [pending].
  static T applying<T>(T Function() write) {
    _applying++;
    try {
      return write();
    } finally {
      _applying--;
    }
  }

  /// The device id a stamp of something not made here carries: the whole
  /// backup's changes, whose maker it does not record.
  static final legacy = BigInt.zero;

  /// This install's device id, made once: a random 63-bit number, never
  /// [legacy].
  static BigInt get device {
    if (_device case final device?) return device;
    final rows = _db.select('SELECT v FROM sync_state WHERE k = ?;', [_deviceKey]);
    if (rows.isNotEmpty) return _device = BigInt.parse(rows.first['v'] as String);
    final random = Random.secure();
    var id = BigInt.zero;
    while (id == BigInt.zero) {
      id = (BigInt.from(random.nextInt(1 << 31)) << 32) | BigInt.from(random.nextInt(1 << 32));
    }
    _db.execute('INSERT OR IGNORE INTO sync_state (k, v) VALUES (?, ?);', [_deviceKey, '$id']);
    final kept = BigInt.parse(_db.select('SELECT v FROM sync_state WHERE k = ?;', [_deviceKey]).first['v'] as String);
    // Inside a transaction the row may yet be rolled back: kept in memory only
    // once committed, or the next launch makes another id and what was
    // stamped under this one is never sent. [install] makes it at launch,
    // outside any.
    if (_db.autocommit) _device = kept;
    return kept;
  }

  /// Whether stamps can be made: fl_lib's Rust is loaded. Without it nothing
  /// is recorded, and the app still runs.
  static bool get _ready => FlRust.ready;

  /// The newest stamp held, made here or not: the clock resumes after it.
  static String get _newest =>
      _last ??= _db.select('SELECT MAX(hlc) AS h FROM sync_record;').first['h'] as String? ?? '';

  /// Takes the edits of [stores] from now on. At launch, outside any
  /// transaction, so this install's [device] id is made and committed first.
  static void install(Iterable<SqliteStore> stores) {
    syncedStores
      ..clear()
      ..addEntries(stores.map((s) => MapEntry(s.name, s)));
    if (_ready) device;
    KvStore.onEdit = (store, key, _) {
      if (!syncedStores.containsKey(store.name)) return;
      record('kv:${store.name}', key);
    };
  }

  /// [c]/[id] changed: here at the clock's next stamp; while [receiving], at
  /// its stamp; while [applying], at [at] (milliseconds) as no device's.
  ///
  /// Answers the stamp made, null when none can be. A record keeps the
  /// greater of its stamp and this one: a stamp never moves back.
  /// [notify] false leaves out [onLocal]: for a stamp made by the send itself.
  static String? record(String c, String id, {int? at, bool notify = true}) {
    if (!_ready) return null;
    final String h;
    if (_receiving case final received?) {
      h = received;
      _last = syncLater(last: _newest, seen: h);
    } else if (_applying > 0) {
      h = syncStampOf(ms: BigInt.from(at ?? SyncClock.now()), device: legacy);
      // What came from elsewhere moves the clock too.
      _last = syncLater(last: _newest, seen: h);
    } else {
      h = syncTick(device: device, last: _newest, nowMs: BigInt.from(SyncClock.now()));
      _last = h;
    }
    _db.execute(
      'INSERT INTO sync_record (c, id, hlc) VALUES (?, ?, ?) '
      'ON CONFLICT (c, id) DO UPDATE SET hlc = excluded.hlc WHERE excluded.hlc > sync_record.hlc;',
      [c, id, h],
    );
    if (notify && _receiving == null && _applying == 0) {
      for (final f in onLocal) {
        f();
      }
    }
    return h;
  }

  /// Each record's stamp, for the ones [ids] names: what an incoming op is
  /// compared against.
  static Map<(String, String), String> stampsOf(Iterable<(String, String)> ids) {
    final out = <(String, String), String>{};
    for (final (c, id) in ids) {
      final rows = _db.select('SELECT hlc FROM sync_record WHERE c = ? AND id = ?;', [c, id]);
      if (rows.isNotEmpty) out[(c, id)] = rows.first['hlc'] as String;
    }
    return out;
  }

  /// Every record and its stamp, the oldest first: what a snapshot holds.
  static List<({String c, String id, String hlc})> all() => [
    for (final row in _db.select('SELECT c, id, hlc FROM sync_record ORDER BY hlc;'))
      (c: row['c'] as String, id: row['id'] as String, hlc: row['hlc'] as String),
  ];

  /// Records made here and stamped after [after] (empty: all of them), the
  /// oldest first: what the next sync sends.
  static List<({String c, String id, String hlc})> pending(String after) {
    final mine = deviceHexOf(device);
    return [
      for (final row in _db.select(
        'SELECT c, id, hlc FROM sync_record WHERE hlc > ? AND substr(hlc, 17) = ? ORDER BY hlc;',
        [after, mine],
      ))
        (c: row['c'] as String, id: row['id'] as String, hlc: row['hlc'] as String),
    ];
  }

  /// Fills `sync_record` with each synced kv store's keys, stamped as no
  /// device's at their last update. A record already there keeps its stamp.
  static void seedStores() {
    for (final store in syncedStores.values) {
      seedRecords(kvOf(store), [
        for (final MapEntry(:key, :value) in (store.lastUpdateTs ?? const <String, int>{}).entries) (key, value),
      ]);
    }
  }

  /// Records [rows] (each an id and when it was last changed, ms) of [c] as
  /// [legacy] stamps, keeping a record already there: what existed before
  /// [c] synced.
  static void seedRecords(String c, Iterable<(String, int)> rows) {
    if (!_ready) return;
    SqliteStore.transact(() {
      for (final (id, ms) in rows) {
        _db.execute(
          'INSERT OR IGNORE INTO sync_record (c, id, hlc) VALUES (?, ?, ?);',
          [c, id, syncStampOf(ms: BigInt.from(ms), device: legacy)],
        );
      }
    });
    _last = null;
  }

  /// Stamps each record of [c] whose fingerprint in [now] differs from the
  /// one last seen ([see]), and each seen one gone since: for records kept
  /// outside the stores (files), which no write stamps. [unknown] ones cannot
  /// be told now: left as last seen, so nothing is sent as gone that may only
  /// be missing for a while. [notify] as [record]'s.
  static void stampChanged(String c, Map<String, String> now, {Set<String> unknown = const {}, bool notify = false}) {
    final prefix = 'seen:$c:';
    final seen = {
      for (final row in _db.select('SELECT k, v FROM sync_state WHERE substr(k, 1, ?) = ?;', [prefix.length, prefix]))
        (row['k'] as String).substring(prefix.length): row['v'] as String,
    };
    // Lost meanwhile ([loseSeen]): one seen then and not here now went with
    // what was lost, and is not sent as removed.
    final lost = _db.select('SELECT 1 FROM sync_state WHERE k = ?;', ['lost:$c']).isNotEmpty;
    for (final id in {...seen.keys, ...now.keys}) {
      if (now[id] == seen[id] || unknown.contains(id)) continue;
      if (lost && !now.containsKey(id)) {
        see(c, id, null);
        _db.execute('INSERT INTO sync_state (k, v) VALUES (?, ?) ON CONFLICT (k) DO NOTHING;', ['lost:$c:$id', '1']);
        continue;
      }
      record(c, id, notify: notify);
      see(c, id, now[id]);
    }
    if (lost) _db.execute('DELETE FROM sync_state WHERE k = ?;', ['lost:$c']);
  }

  /// Runs [stamp] after each change [changes] tells of, once for changes
  /// close together, for records kept outside the stores.
  static void follow(Listenable changes, void Function() stamp) {
    var pending = false;
    changes.addListener(() {
      if (pending) return;
      pending = true;
      scheduleMicrotask(() {
        pending = false;
        if (SqliteDb.isOpen) stamp();
      });
    });
  }

  /// What [stampChanged] saw of [c] may be lost here now: the next one that
  /// reads it sends no removal of what is not there then.
  static void loseSeen(String c) => _db.execute(
    'INSERT INTO sync_state (k, v) VALUES (?, ?) ON CONFLICT (k) DO NOTHING;',
    ['lost:$c', '1'],
  );

  /// Whether [c]/[id] went with what [loseSeen] lost and has not been seen
  /// since.
  static bool wasLost(String c, String id) =>
      _db.select('SELECT 1 FROM sync_state WHERE k = ?;', ['lost:$c:$id']).isNotEmpty;

  /// [c]/[id] is said for again: another device's op says what it is now.
  static void forgetLost(String c, String id) =>
      _db.execute('DELETE FROM sync_state WHERE k = ?;', ['lost:$c:$id']);

  /// Notes [c]/[id] as [fingerprint] (null: not here) for [stampChanged]:
  /// what came from another device, which is not sent back.
  static void see(String c, String id, String? fingerprint) {
    if (fingerprint != null) forgetLost(c, id);
    if (fingerprint == null) {
      _db.execute('DELETE FROM sync_state WHERE k = ?;', ['seen:$c:$id']);
    } else {
      _db.execute(
        'INSERT INTO sync_state (k, v) VALUES (?, ?) ON CONFLICT (k) DO UPDATE SET v = excluded.v;',
        ['seen:$c:$id', fingerprint],
      );
    }
  }

  /// Empties [store] on this device as though it never held anything: its
  /// stamps and records go too, so no delete is sent and another device's
  /// values are taken again.
  static void forgetStore(SqliteStore store) => SqliteStore.transact(() {
    for (final key in store.keys()) {
      store.remove(key, updateLastUpdateTsOnRemove: false);
    }
    _db.execute('DELETE FROM kv WHERE store = ? AND key = ?;', [store.name, store.lastUpdateTsKey]);
    _db.execute('DELETE FROM sync_record WHERE c = ?;', [kvOf(store)]);
  });

  /// Forgets what was read, for a test's fresh database.
  @visibleForTesting
  static void resetForTest() {
    _device = null;
    _last = null;
    onLocal.clear();
  }
}
