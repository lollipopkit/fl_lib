part of 'base.dart';

/// LK Cloud's sync (homebase's `/v2/sync/{app}`) as a backup destination.
///
/// Every write is conditional, on the version this device last read of the
/// file or on there being none, so a write another device beat is refused
/// with [RemoteChangedException], and [writtenTag] is the version a write
/// made. Answers carry homebase's clock, which [SyncClock] follows.
final class LkcRemoteStorage
    implements RemoteStorage<String>, ConditionalStorage {
  LkcRemoteStorage(this.client, this.app);

  final LkcClient client;

  /// Homebase's name of the app: `serverbox`, `gptbox`, …
  final String app;

  LkcSync? _sync;

  /// The version last read or written of each file, null when there is none.
  final _known = <String, String?>{};
  final _written = <String, String>{};

  /// The account and the app: another account's files are another remote.
  @override
  String get identity => 'lkc|${client.user.value?.id ?? ''}|$app';

  Future<T> _call<T>(
    String relativePath,
    Future<T> Function(LkcSync sync) f,
  ) async {
    final sync = _sync ??= await client.sync(app);
    try {
      return await f(sync);
    } on LkcSyncError catch (e) {
      if (e.kind == LkcSyncErrorKind.changed) {
        _known.remove(relativePath);
        throw RemoteChangedException(relativePath);
      }
      if (e.kind == LkcSyncErrorKind.signedOut) await client.forget();
      throw e.exception;
    } finally {
      final offset = sync.offsetMs();
      if (offset != 0) SyncClock.offsetMs = offset;
    }
  }

  String _local(String relativePath, String? localPath) =>
      localPath ?? Paths.doc.joinPath(relativePath);

  /// Conditional on the version last read; one never read is asked for first.
  @override
  Future<void> upload({required String relativePath, String? localPath}) async {
    if (!_known.containsKey(relativePath)) await _head(relativePath);
    final etag = await _call(
      relativePath,
      (s) => s.upload(
        name: relativePath,
        from: _local(relativePath, localPath),
        ifMatch: _known[relativePath],
      ),
    );
    _known[relativePath] = etag;
    _written[relativePath] = etag;
  }

  @override
  Future<void> download({
    required String relativePath,
    String? localPath,
  }) async {
    final fetched = await _call(
      relativePath,
      (s) => s.download(name: relativePath, to: _local(relativePath, localPath)),
    );
    _known[relativePath] = fetched.etag;
    if (fetched.missing) {
      throw const LkcException(code: LkcCode.notFound, status: 404);
    }
  }

  @override
  Future<void> delete(String relativePath) async {
    await _call(
      relativePath,
      (s) => s.delete(name: relativePath, ifMatch: _known[relativePath]),
    );
    _known[relativePath] = null;
    _written.remove(relativePath);
  }

  /// Throws when homebase cannot say: a sync must not take that for absent
  /// and write as though nothing were there.
  @override
  Future<bool> exists(String relativePath) async =>
      await _head(relativePath) != null;

  @override
  Future<List<String>> list() async {
    final files = await _call('', (s) => s.list());
    return [for (final f in files) f.name];
  }

  @override
  Future<String?> versionTag(String relativePath) async {
    try {
      return await _head(relativePath);
    } catch (e) {
      Loggers.app.warning('LK Cloud version tag', e);
      return null;
    }
  }

  @override
  String? writtenTag(String relativePath) => _written[relativePath];

  Future<String?> _head(String relativePath) async {
    final etag = await _call(relativePath, (s) => s.head(name: relativePath));
    _known[relativePath] = etag;
    return etag;
  }
}

extension LkcSyncErrorX on LkcSyncError {
  /// As the rest of LK Cloud's refusals: [LkcException.reason] says what the
  /// user can do. An answer this build cannot read is a [FormatException].
  Exception get exception => switch (kind) {
    LkcSyncErrorKind.signedOut => const LkcException(code: LkcCode.perm),
    LkcSyncErrorKind.refused => LkcException(
      code: LkcCode.perm,
      reason: reason,
      message: detail,
      status: 403,
    ),
    LkcSyncErrorKind.tooLarge => LkcException(
      code: LkcCode.quota,
      reason: 'file_too_large',
      message: detail,
      status: 413,
    ),
    // Not homebase's answer as this build knows it: a defect to report.
    LkcSyncErrorKind.invalid => FormatException(detail),
    _ => LkcException(message: detail),
  };
}
