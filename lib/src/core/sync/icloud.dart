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
      cloudRelativePath: relativePath,
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
      cloudRelativePath: relativePath,
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
}
