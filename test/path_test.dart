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

  group('adoptIosDocuments', () {
    late String documents;
    late String doc;

    Future<void> write(String path, [String content = 'x']) async {
      await File(path).parent.create(recursive: true);
      await File(path).writeAsString(content);
    }

    Future<Set<String>> names(String dir) =>
        Directory(dir).list().map((e) => e.path.split('/').last).toSet();

    Future<bool> adopt() =>
        Paths.adoptIosDocuments(documents: documents, doc: doc);

    /// What a released build left in Documents.
    Future<void> released() async {
      await write('$documents/store.db', 'db');
      await write('$documents/store.db-wal', 'wal');
      await write('$documents/img/ssh_bg_1.png');
      await write('$documents/logs/app.log');
      await write('$documents/file/srv-1/note.txt', 'note');
      await write('$documents/file/a.txt', 'a');
      await write('$documents/Inbox/shared.txt', 'shared');
    }

    setUp(() async {
      documents = at('Documents');
      doc = at('Library/Application Support/App');
      await Directory(documents).create(recursive: true);
    });

    test('the app\'s data leaves, the user\'s files come up', () async {
      await released();

      expect(await adopt(), true);

      expect(await File('$doc/store.db').readAsString(), 'db');
      expect(await File('$doc/store.db-wal').readAsString(), 'wal');
      expect(await File('$doc/img/ssh_bg_1.png').exists(), true);
      expect(await File('$doc/logs/app.log').exists(), true);
      expect(await File('$documents/a.txt').readAsString(), 'a');
      expect(await File('$documents/srv-1/note.txt').readAsString(), 'note');
      expect(await File('$documents/Inbox/shared.txt').readAsString(), 'shared');
      expect(await names(documents), {'a.txt', 'srv-1', 'Inbox'});
      expect(await Directory('$doc.incoming').exists(), false);
    });

    test('a finished move does not run again', () async {
      await released();
      await adopt();
      // The user's own, put there through the Files app.
      await write('$documents/logs/mine.txt');
      await write('$documents/file/mine.txt');

      expect(await adopt(), true);

      expect(await File('$documents/logs/mine.txt').exists(), true);
      expect(await File('$documents/file/mine.txt').exists(), true);
    });

    test('a launch that died moving the app\'s data finishes it', () async {
      await released();
      await Directory('$doc.incoming').create(recursive: true);
      await File('$documents/store.db').rename('$doc.incoming/store.db');

      expect(await adopt(), true);

      expect(await File('$doc/store.db').readAsString(), 'db');
      expect(await File('$doc/store.db-wal').readAsString(), 'wal');
      expect(await File('$documents/a.txt').exists(), true);
    });

    test('a launch that died moving the user\'s files takes none of them',
        () async {
      await released();
      await adopt();
      await write('$doc/.moved-from-documents', '');
      await Directory('$documents/.file-moving').create();
      await File('$documents/a.txt').rename('$documents/.file-moving/a.txt');

      expect(await adopt(), true);

      expect(await File('$documents/a.txt').readAsString(), 'a');
      expect(await File('$documents/srv-1/note.txt').readAsString(), 'note');
      expect(await Directory('$documents/.file-moving').exists(), false);
      expect(await File('$doc/srv-1/note.txt').exists(), false);
    });

    test('a user file whose name is taken stays in `file`', () async {
      await write('$documents/file/Inbox/mine.txt', 'mine');
      await write('$documents/file/b.txt', 'b');
      await write('$documents/Inbox/shared.txt');

      await adopt();

      expect(await File('$documents/b.txt').readAsString(), 'b');
      expect(await File('$documents/file/Inbox/mine.txt').readAsString(), 'mine');
    });

    test('a fresh install ends with the marker and an empty Documents', () async {
      expect(await adopt(), true);

      expect(await File('$doc/.moved-from-documents').readAsString(), 'done');
      expect(await Directory(documents).list().isEmpty, true);
    });

    test('a failure puts the data back and stays on Documents', () async {
      await released();
      // Something already in `doc`: the staging directory cannot take its
      // place.
      await write('$doc/other');

      expect(await adopt(), false);

      expect(await File('$documents/store.db').readAsString(), 'db');
      expect(await File('$documents/img/ssh_bg_1.png').exists(), true);
      expect(await File('$documents/file/a.txt').exists(), true);
      expect(await Directory('$doc.incoming').exists(), false);
      expect(await File('$doc/.moved-from-documents').exists(), false);
    });
  });
}
