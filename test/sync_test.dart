import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Paths.bakName = 'sync_test_backup.json';
  Paths.bak = 'sync_test_backup.json';

  test('sync coalesces rapid changes at the trailing edge', () async {
    final remote = _TestRemoteStorage();
    final sync = _TestSync(remote);

    await Future.wait([
      sync.sync(throttleMilli: 20),
      sync.sync(throttleMilli: 20),
      sync.sync(throttleMilli: 20),
    ]);

    expect(remote.uploadCount, 1);
    expect(sync.saveCount, 1);
  });

  test('sync drains a dirty change after an in-flight upload', () async {
    final uploadGate = Completer<void>();
    final firstUploadStarted = Completer<void>();
    final remote = _TestRemoteStorage(
      uploadGate: uploadGate,
      firstUploadStarted: firstUploadStarted,
    );
    final sync = _TestSync(remote);

    final first = sync.sync(throttleMilli: 0);
    await firstUploadStarted.future;
    final second = sync.sync(throttleMilli: 0);
    uploadGate.complete();
    await Future.wait([first, second]);

    expect(remote.uploadCount, 2);
    expect(sync.saveCount, 2);
  });

  test('sync never uploads after a remote merge failure', () async {
    final remote = _TestRemoteStorage(remoteExists: true);
    final sync = _TestSync(remote, failToReadRemote: true);

    await sync.sync(throttleMilli: 0);

    expect(remote.downloadCount, 1);
    expect(remote.uploadCount, 0);
    expect(sync.saveCount, 0);
  });

  test('sync uploads to the explicitly selected storage', () async {
    final defaultStorage = _TestRemoteStorage();
    final selectedStorage = _TestRemoteStorage();
    final sync = _TestSync(defaultStorage);

    await sync.sync(throttleMilli: 0, rs: selectedStorage);

    expect(defaultStorage.uploadCount, 0);
    expect(selectedStorage.uploadCount, 1);
  });
}

final class _TestSync extends SyncIface<_TestMergeable, String> {
  _TestSync(this.storage, {this.failToReadRemote = false});

  final _TestRemoteStorage storage;
  final bool failToReadRemote;
  int saveCount = 0;

  @override
  Future<_TestMergeable> fromFile(String path) async {
    if (failToReadRemote) throw const FormatException('broken remote backup');
    return const _TestMergeable();
  }

  @override
  Future<RemoteStorage<String>?> get remoteStorage async => storage;

  @override
  Future<void> saveToFile() async {
    saveCount++;
  }
}

final class _TestMergeable implements Mergeable {
  const _TestMergeable();

  @override
  Future<void> merge({bool force = false}) async {}
}

final class _TestRemoteStorage extends RemoteStorage<String> {
  _TestRemoteStorage({
    this.remoteExists = false,
    this.uploadGate,
    this.firstUploadStarted,
  });

  final bool remoteExists;
  final Completer<void>? uploadGate;
  final Completer<void>? firstUploadStarted;
  int downloadCount = 0;
  int uploadCount = 0;

  @override
  Future<void> delete(String relativePath) async {}

  @override
  Future<void> download({
    required String relativePath,
    String? localPath,
  }) async {
    downloadCount++;
  }

  @override
  Future<bool> exists(String relativePath) async => remoteExists;

  @override
  Future<List<String>> list() async => const [];

  @override
  Future<void> upload({
    required String relativePath,
    String? localPath,
  }) async {
    uploadCount++;
    if (uploadCount == 1) {
      if (firstUploadStarted?.isCompleted == false) {
        firstUploadStarted!.complete();
      }
      await uploadGate?.future;
    }
  }
}
