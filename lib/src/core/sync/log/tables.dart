import 'package:fl_lib/src/core/store/iface.dart';

/// The operation-log sync's tables, in the stores' database. ServerBox makes
/// the same ones through Drift: these statements are what they are, so either
/// opens the other's.
abstract final class SyncTables {
  static const statements = [
    // Each synced record's newest stamp.
    'CREATE TABLE IF NOT EXISTS sync_record ("c" TEXT NOT NULL, "id" TEXT NOT NULL, "hlc" TEXT NOT NULL, PRIMARY KEY ("c", "id")) WITHOUT ROWID;',
    'CREATE INDEX IF NOT EXISTS idx_sync_record_hlc ON sync_record(hlc);',
    // The engines' state: cursors, what was sent, this install's device id.
    'CREATE TABLE IF NOT EXISTS sync_state ("k" TEXT NOT NULL, "v" TEXT NOT NULL, PRIMARY KEY ("k")) WITHOUT ROWID;',
    // Ops of what this device does not sync, kept for its snapshots.
    'CREATE TABLE IF NOT EXISTS sync_passed (e TEXT NOT NULL, c TEXT NOT NULL, id TEXT NOT NULL, h TEXT NOT NULL, d TEXT NOT NULL, PRIMARY KEY (e, c, id)) WITHOUT ROWID;',
  ];

  /// Makes the tables where they are not.
  static void ensure() {
    for (final s in statements) {
      SqliteDb.instance.execute(s);
    }
  }
}
