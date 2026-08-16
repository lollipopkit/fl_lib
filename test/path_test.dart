import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

/// `Paths.adoptLegacyDoc` moves an install's whole database, on two platforms
/// that already shipped the old location. Every branch here is one where
/// getting it wrong looks to the user like the app forgot them.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('fl_lib_paths_');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  String at(String name) => '${root.path}/$name';

  Future<Directory> makeLegacy(String name, {String? content}) async {
    final dir = await Directory(at(name)).create(recursive: true);
    await File('${dir.path}/server_enc.hive').writeAsString(content ?? 'boxes');
    return dir;
  }

  test('a destination that is not there yet takes the whole directory', () async {
    await makeLegacy('config');
    final to = at('data/App');

    await Paths.adoptLegacyDoc(from: at('config'), to: to);

    expect(await File('$to/server_enc.hive').readAsString(), 'boxes');
    expect(await Directory(at('config')).exists(), false);
  });

  test('a destination with data in it is left alone', () async {
    await makeLegacy('config', content: 'old');
    final to = await Directory(at('data')).create(recursive: true);
    await File('${to.path}/server_enc.hive').writeAsString('current');

    await Paths.adoptLegacyDoc(from: at('config'), to: to.path);

    // Both survive: the newer one in place, the older one where it was, so a
    // wrong answer here is recoverable rather than a deletion.
    expect(await File('${to.path}/server_enc.hive').readAsString(), 'current');
    expect(await File(at('config/server_enc.hive')).readAsString(), 'old');
  });

  test('an empty destination is replaced, not refused', () async {
    await makeLegacy('config');
    final to = await Directory(at('data')).create(recursive: true);

    await Paths.adoptLegacyDoc(from: at('config'), to: to.path);

    expect(await File('${to.path}/server_enc.hive').readAsString(), 'boxes');
  });

  test('nothing to adopt leaves the destination as it found it', () async {
    final to = at('data');

    await Paths.adoptLegacyDoc(from: at('config'), to: to);

    // Not created here: `_getDoc` makes it right after, and a directory this
    // returned would say a move happened.
    expect(await Directory(to).exists(), false);
  });

  test('an empty destination survives having nothing to adopt', () async {
    final to = await Directory(at('data')).create(recursive: true);

    await Paths.adoptLegacyDoc(from: at('config'), to: to.path);

    expect(await Directory(to.path).exists(), true);
  });

  test('a destination on another filesystem is copied and swapped in', () async {
    final legacy = await makeLegacy('config');
    await Directory('${legacy.path}/file/srv-1').create(recursive: true);
    await File('${legacy.path}/file/srv-1/note.txt').writeAsString('kept');
    final to = at('data/App');

    await Paths.adoptLegacyDoc(
      from: legacy.path,
      to: to,
      move: (_, _) => throw const FileSystemException('EXDEV'),
    );

    expect(await File('$to/server_enc.hive').readAsString(), 'boxes');
    expect(await File('$to/file/srv-1/note.txt').readAsString(), 'kept');
    expect(await legacy.exists(), false);
    expect(await Directory('$to.incoming').exists(), false);
  });

  test('a copy that fails leaves the original and no half-written destination',
      () async {
    final legacy = await makeLegacy('config');
    final to = at('data/App');
    // A file where the staging directory has to go: the copy cannot start.
    await Directory(at('data')).create(recursive: true);
    await File('$to.incoming').writeAsString('in the way');

    await Paths.adoptLegacyDoc(
      from: legacy.path,
      to: to,
      move: (_, _) => throw const FileSystemException('EXDEV'),
    );

    expect(await File('${legacy.path}/server_enc.hive').readAsString(), 'boxes');
    expect(await Directory(to).exists(), false);
  });

  test('the same directory twice is not a move', () async {
    await makeLegacy('config');

    await Paths.adoptLegacyDoc(from: at('config'), to: at('config'));

    expect(await File(at('config/server_enc.hive')).readAsString(), 'boxes');
  });

  test('no legacy location on this platform is not a move', () async {
    await Paths.adoptLegacyDoc(from: null, to: at('data'));

    expect(await Directory(at('data')).exists(), false);
  });
}
