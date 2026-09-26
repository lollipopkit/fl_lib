import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  test('sync drains a dirty change after an in-flight upload fails', () async {
    final error = StateError('first upload failed');
    final uploadGate = Completer<void>();
    final firstUploadStarted = Completer<void>();
    final remote = _TestRemoteStorage(
      uploadGate: uploadGate,
      firstUploadStarted: firstUploadStarted,
      uploadError: error,
      uploadFailureCount: 1,
    );
    final sync = _TestSync(remote);

    final first = sync.sync(throttleMilli: 0);
    await firstUploadStarted.future;
    final second = sync.sync(throttleMilli: 0);
    uploadGate.complete();

    await expectLater(first, throwsA(same(error)));
    await expectLater(second, throwsA(same(error)));
    expect(remote.uploadCount, 2);
    expect(sync.saveCount, 2);
  });

  test('sync preserves the first error when a queued retry also fails', () async {
    final firstError = StateError('first upload failed');
    final secondError = StateError('second upload failed');
    final uploadGate = Completer<void>();
    final firstUploadStarted = Completer<void>();
    final remote = _TestRemoteStorage(
      uploadGate: uploadGate,
      firstUploadStarted: firstUploadStarted,
      uploadErrors: [firstError, secondError],
    );
    final sync = _TestSync(remote);

    final first = sync.sync(throttleMilli: 0);
    await firstUploadStarted.future;
    final second = sync.sync(throttleMilli: 0);
    uploadGate.complete();

    await expectLater(first, throwsA(same(firstError)));
    await expectLater(second, throwsA(same(firstError)));
    expect(remote.uploadCount, 2);
  });

  test('sync never uploads after a remote merge failure', () async {
    final remote = _TestRemoteStorage(remoteExists: true);
    final sync = _TestSync(remote, failToReadRemote: true);

    await sync.sync(throttleMilli: 0);

    expect(remote.downloadCount, 1);
    expect(remote.uploadCount, 0);
    expect(sync.saveCount, 0);
  });

  // #1562 in server_box: `fromFile` ran inside `compute`, where `PrefStore`
  // is uninitialized and answers the default, so a pref deciding what to
  // merge was read as its default on every sync, with no error anywhere.
  test('fromFile reads prefs set on the syncing isolate', () async {
    SharedPreferences.setMockInitialValues({});
    await PrefStore.shared.init();
    const prop = PrefPropDefault<bool>('sync_test_flag', false);
    await prop.set(true);
    final remote = _TestRemoteStorage(remoteExists: true);
    final sync = _TestSync(remote, reader: prop.get);

    await sync.sync(throttleMilli: 0);

    expect(sync.readValue, isTrue);
    expect(remote.uploadCount, 1);
  });

  test('sync uploads to the explicitly selected storage', () async {
    final defaultStorage = _TestRemoteStorage();
    final selectedStorage = _TestRemoteStorage();
    final sync = _TestSync(defaultStorage);

    await sync.sync(throttleMilli: 0, rs: selectedStorage);

    expect(defaultStorage.uploadCount, 0);
    expect(selectedStorage.uploadCount, 1);
  });

  for (final throttleMilli in [0, 20]) {
    test('sync propagates upload failures with throttle $throttleMilli', () async {
      final error = StateError('upload failed');
      final remote = _TestRemoteStorage(uploadError: error);
      final sync = _TestSync(remote);

      await expectLater(
        sync.sync(throttleMilli: throttleMilli),
        throwsA(same(error)),
      );
    });
  }
}

final class _TestSync extends SyncIface<_TestMergeable, String> {
  _TestSync(this.storage, {this.failToReadRemote = false, this.reader});

  final _TestRemoteStorage storage;
  final bool failToReadRemote;
  final bool Function()? reader;
  int saveCount = 0;

  /// What [reader] answered inside [fromFile], on the isolate that
  /// ran the sync. A copy of this object in another isolate would leave it
  /// unset here.
  bool? readValue;

  @override
  Future<_TestMergeable> fromFile(String path) async {
    if (failToReadRemote) throw const FormatException('broken remote backup');
    readValue = reader?.call();
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
    this.uploadError,
    this.uploadFailureCount,
    this.uploadErrors,
  });

  final bool remoteExists;
  final Completer<void>? uploadGate;
  final Completer<void>? firstUploadStarted;
  final Object? uploadError;
  final int? uploadFailureCount;
  final List<Object>? uploadErrors;
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
    final error = uploadError;
    if (error != null &&
        (uploadFailureCount == null || uploadCount <= uploadFailureCount!)) {
      throw error;
    }
    final errors = uploadErrors;
    if (errors != null && uploadCount <= errors.length) {
      throw errors[uploadCount - 1];
    }
  }
}
