/// The check that lets a sync do nothing.
///
/// A sync runs on every launch and most launches changed nothing, so the cost
/// that matters is the one paid when there is no work: it used to be a full
/// download, decrypt, merge, re-encrypt and full upload, and it is now one
/// request. What has to hold is the other direction — every way of *not* being
/// sure has to fall through to the full cycle, because a needless sync costs a
/// round trip and a skipped one costs the user an edit.
library;

import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

/// Answers whatever the test tells it to, and counts what it was asked.
final class _FakeRemote extends RemoteStorage<String> {
  String? tag;
  var versionTagCalls = 0;
  var existsCalls = 0;
  var uploadCalls = 0;

  @override
  Future<String?> versionTag(String relativePath) async {
    versionTagCalls++;
    return tag;
  }

  /// Reached only when the skip did not happen, which is what the tests below
  /// actually assert on: everything past this point is the full cycle.
  @override
  Future<bool> exists(String relativePath) async {
    existsCalls++;
    return false;
  }

  @override
  Future<void> upload({required String relativePath, String? localPath}) async {
    uploadCalls++;
  }

  @override
  Future<void> download({
    required String relativePath,
    String? localPath,
  }) async {}

  @override
  Future<void> delete(String relativePath) async {}

  @override
  Future<List<String>> list() async => const [];
}

final class _NoopMergeable implements Mergeable {
  @override
  Future<void> merge({bool force = false}) async {}
}

final class _FakeSyncer extends SyncIface<_NoopMergeable, String> {
  _FakeSyncer(this.remote);

  final _FakeRemote remote;

  String? localTag = 'local-1';
  (String, String)? checkpoint;
  var saveToFileCalls = 0;

  @override
  RemoteStorage<String> get remoteStorage => remote;

  @override
  String? get localVersionTag => localTag;

  @override
  (String, String)? get syncCheckpoint => checkpoint;

  @override
  void saveSyncCheckpoint(String remote, String local) {
    checkpoint = (remote, local);
  }

  @override
  _NoopMergeable fromFile(String path) => _NoopMergeable();

  @override
  void saveToFile() => saveToFileCalls++;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeRemote remote;
  late _FakeSyncer syncer;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('fl-sync-skip-');
    Paths.doc = tempDir.path;
    Paths.bakName = 'bak.json';
  });

  tearDownAll(() async => tempDir.delete(recursive: true));

  setUp(() {
    remote = _FakeRemote();
    syncer = _FakeSyncer(remote);
  });

  // `throttleMilli: 0` runs the cycle now instead of behind the debounce.
  Future<void> runSync() => syncer.sync(throttleMilli: 0);

  test('the first sync has no checkpoint and does the full cycle', () async {
    remote.tag = 'etag-1';
    await runSync();

    expect(remote.existsCalls, 1, reason: 'it got past the skip');
    expect(remote.uploadCalls, 1);
    expect(syncer.checkpoint, isNotNull);
  });

  test('a second sync with nothing changed does nothing', () async {
    remote.tag = 'etag-1';
    await runSync();
    final after = syncer.checkpoint;

    await runSync();

    expect(remote.existsCalls, 1, reason: 'the second one skipped');
    expect(remote.uploadCalls, 1);
    expect(syncer.checkpoint, after, reason: 'and left the checkpoint alone');
  });

  test('a local edit ends the skip', () async {
    remote.tag = 'etag-1';
    await runSync();

    syncer.localTag = 'local-2';
    await runSync();

    expect(remote.existsCalls, 2);
    expect(remote.uploadCalls, 2);
  });

  test('a remote change ends the skip', () async {
    remote.tag = 'etag-1';
    await runSync();

    remote.tag = 'etag-2';
    await runSync();

    expect(remote.existsCalls, 2);
    expect(remote.uploadCalls, 2);
  });

  /// Every way of not being sure takes the same branch. A backend with no
  /// answer is the common one — `versionTag` defaults to null on the base
  /// class, so anything that has not implemented it lands here.
  test('a backend that cannot answer never skips', () async {
    remote.tag = null;
    await runSync();
    await runSync();
    await runSync();

    expect(remote.existsCalls, 3);
    expect(remote.uploadCalls, 3);
  });

  test('a device that has never edited anything never skips', () async {
    remote.tag = 'etag-1';
    syncer.localTag = null;
    await runSync();
    await runSync();

    expect(remote.existsCalls, 2);
    // Nothing to record either: a checkpoint with no local half could never
    // match, and writing one would only make the next read look meaningful.
    expect(syncer.checkpoint, isNull);
  });

  /// The tag carries the backend's identity, so moving a user from one remote
  /// to another cannot match a checkpoint describing a file on the old one.
  test('the checkpoint names the backend it came from', () async {
    remote.tag = 'etag-1';
    await runSync();

    expect(syncer.checkpoint?.$1, contains('_FakeRemote'));
    expect(syncer.checkpoint?.$1, contains('etag-1'));
    expect(syncer.checkpoint?.$2, 'local-1');
  });
}
