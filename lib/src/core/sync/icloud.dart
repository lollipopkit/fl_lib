part of 'base.dart';

final class ICloud implements RemoteStorage<ICloudFile> {
  final String containerId;

  ICloud({required this.containerId});

  @override
  Future<void> upload({
    required String relativePath,
    String? localPath,
  }) async {
    final completer = Completer<void>();
    await ICloudStorage.uploadFile(
      containerId: containerId,
      localPath: localPath ?? Paths.doc.joinPath(relativePath),
      relativePath: relativePath,
      onProgress: (stream) {
        stream.listen(
          null,
          onDone: () => completer.complete(null),
          onError: (Object e) => completer.completeError(e),
        );
      },
    );
    return completer.future;
  }

  @override
  Future<List<ICloudFile>> list() async {
    final result = await ICloudStorage.gather(containerId: containerId);
    return result.files;
  }

  @override
  Future<void> delete(String relativePath) {
    return ICloudStorage.delete(
      containerId: containerId,
      relativePath: relativePath,
    );
  }

  @override
  Future<void> download({
    required String relativePath,
    String? localPath,
  }) async {
    final completer = Completer<void>();
    await ICloudStorage.downloadFile(
      containerId: containerId,
      relativePath: relativePath,
      localPath: localPath ?? Paths.doc.joinPath(relativePath),
      onProgress: (stream) {
        stream.listen(
          null,
          onDone: () => completer.complete(null),
          onError: (Object e) => completer.completeError(e),
        );
      },
    );
    return completer.future;
  }

  @override
  Future<bool> exists(String relativePath) async {
    try {
      final files = await list();
      return files.any((file) => file.relativePath == relativePath);
    } catch (e) {
      Loggers.app.warning('Check if file exists in iCloud', e);
      return false;
    }
  }

  @override
  String get identity => containerId;

  /// Kept on `contentChangeDate` and size, unlike WebDAV and Gist.
  ///
  /// There is no revision token to move to — `ICloudFile` carries no version,
  /// generation or etag — so the choice is this or nothing, and nothing means
  /// no device on the platform where iCloud is the default ever takes the
  /// shortcut. It is also the strongest of the three timestamps: an `NSDate`
  /// with sub-second precision, against WebDAV's one-second HTTP date, so the
  /// collision that made the WebDAV fallback unsafe needs two writes inside
  /// the same millisecond at the same length.
  @override
  Future<String?> versionTag(String relativePath) async {
    try {
      ICloudFile? newest;
      for (final file in await list()) {
        if (file.relativePath != relativePath) continue;
        // Answers null mid-transfer, deliberately. `contentChangeDate` is
        // already the new one while the bytes are still arriving, so a tag
        // taken now would describe a file this device cannot yet read — and
        // recording it would skip the download that was about to bring it.
        if (file.isDownloading || file.isUploading) return null;

        final date = file.contentChangeDate;
        if (date == null) continue;
        // The container can hold more than one record for a path while a
        // conflict is unresolved. Newest wins, matching what a reader gets.
        final best = newest?.contentChangeDate;
        if (best == null || date.isAfter(best)) newest = file;
      }

      final changed = newest?.contentChangeDate;
      if (changed == null) return null;
      // Size joins the date because the date's resolution is a second on some
      // filesystems, and two writes inside one are not that rare during a
      // restore.
      return '${changed.millisecondsSinceEpoch}/${newest?.sizeInBytes ?? -1}';
    } catch (e) {
      Loggers.app.warning('iCloud version tag', e);
      return null;
    }
  }
}
