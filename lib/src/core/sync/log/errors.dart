import 'package:fl_lib/src/rust/api/sync_engine.dart';

/// The backup password here does not open the sync key of [id]'s remote:
/// another device sealed it with another one. Nothing syncs there meanwhile.
final class SyncPasswordMismatch implements Exception {
  const SyncPasswordMismatch(this.id);

  /// The key file's ([SyncKeyFile.id]).
  final String id;

  @override
  String toString() => 'The backup password does not open the sync key of $id';
}

/// No key file is there yet beside what was synced with one: it may only not
/// have arrived. Tried again at the next sync.
final class SyncKeyNotHere implements Exception {
  const SyncKeyNotHere(this.id);

  final String id;

  @override
  String toString() => 'The sync key of $id is not here yet';
}

/// No backup password here: nothing is sealed or opened without one.
final class SyncPasswordMissing implements Exception {
  const SyncPasswordMissing();

  @override
  String toString() => 'No backup password';
}

/// A batch written by a newer build, in a format this one does not read: the
/// log is not read past it until this build is updated.
final class SyncLogTooNew implements Exception {
  const SyncLogTooNew(this.version);

  final String version;

  @override
  String toString() => 'SyncLogTooNew: batch version $version';
}

/// LK Cloud refused the request: [reason] is homebase's (`sync_quota`,
/// `sync_daily_limit`, `sync_unavailable`, …).
final class SyncRefused implements Exception {
  const SyncRefused(this.reason);

  final String reason;

  @override
  String toString() => 'LK Cloud refused the sync: $reason';
}

/// What the engine could not do otherwise: the store out of reach, a file no
/// key here opens, the host's own failure.
final class SyncError implements Exception {
  const SyncError(this.kind, this.detail);

  final SyncEngineErrorKind kind;
  final String detail;

  @override
  String toString() => 'Sync ${kind.name}: $detail';
}

/// [e], an engine error, as the exception it says.
Object syncException(SyncEngineError e) => switch (e.kind) {
  SyncEngineErrorKind.passwordMismatch => SyncPasswordMismatch(e.detail),
  SyncEngineErrorKind.keyNotHere => SyncKeyNotHere(e.detail),
  SyncEngineErrorKind.passwordMissing => const SyncPasswordMissing(),
  SyncEngineErrorKind.tooNew => SyncLogTooNew(e.detail),
  SyncEngineErrorKind.refused => SyncRefused(e.detail),
  _ => SyncError(e.kind, e.detail),
};

/// [run], its engine errors thrown as [syncException]s.
Future<T> syncCall<T>(Future<T> Function() run) async {
  try {
    return await run();
  } on SyncEngineError catch (e, s) {
    Error.throwWithStackTrace(syncException(e), s);
  }
}
