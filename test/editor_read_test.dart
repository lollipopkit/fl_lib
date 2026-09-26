import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('editor-read-'));
  tearDown(() => dir.delete(recursive: true));

  test('a binary file is not text, rather than an error', () {
    // A PNG's signature is not valid UTF-8. Opened in the editor, this used
    // to surface as an uncaught `FileSystemException` from the worker.
    final png = File('${dir.path}/image.png')
      ..writeAsBytesSync([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

    expect(editorReadUtf8(png.path), isNull);
  });

  test('text is read as it is', () {
    final text = File('${dir.path}/a.txt')..writeAsStringSync('héllo\n');

    expect(editorReadUtf8(text.path), 'héllo\n');
  });

  test('a missing file is still an error', () {
    expect(
      () => editorReadUtf8('${dir.path}/missing'),
      throwsA(isA<FileSystemException>()),
    );
  });
}
