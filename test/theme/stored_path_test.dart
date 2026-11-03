import 'package:fl_lib/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const oldDoc = '/var/mobile/Containers/Data/Application/OLD/Documents';
  const doc = '/var/mobile/Containers/Data/Application/NEW/Documents';
  const rel = 'themes/serverbox.piggy/background.png';

  String? rebase(String path, Set<String> files) =>
      StoredPaths.rebase(path, doc: doc, exists: files.contains);

  test('a path into an old container moves onto the current one', () {
    expect(rebase('$oldDoc/$rel', {'$doc/$rel'}), '$doc/$rel');
  });

  test('a path that still resolves is left alone', () {
    expect(rebase('$oldDoc/$rel', {'$oldDoc/$rel', '$doc/$rel'}), isNull);
    expect(rebase('$doc/$rel', {'$doc/$rel'}), isNull);
  });

  test('nothing moves when the file is not under the current one either', () {
    expect(rebase('$oldDoc/$rel', {}), isNull);
  });

  test('an empty path, or one outside any documents directory, is kept', () {
    expect(rebase('', {'$doc/'}), isNull);
    expect(rebase('/Users/me/font.ttf', {'$doc/font.ttf'}), isNull);
  });

  test('a path into Documents follows the data out of it', () {
    const support =
        '/var/mobile/Containers/Data/Application/NEW/Library/Application Support/ServerBox';
    String? moved(String path, Set<String> files) => StoredPaths.rebase(
      path,
      doc: support,
      formerly: 'Documents',
      exists: files.contains,
    );

    expect(moved('$oldDoc/$rel', {'$support/$rel'}), '$support/$rel');
    // The user's files stay in Documents, so none of theirs is found here.
    expect(moved('$oldDoc/file/a.ttf', {'$doc/a.ttf'}), isNull);
    expect(moved('$support/$rel', {'$support/$rel'}), isNull);
  });
}
