import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:mime/mime.dart';

extension FutureUint8ListX on Future<Uint8List> {
  Future<String> get string async => utf8.decode(await this);
  Future<ByteData> get byteData async => (await this).buffer.asByteData();
}

extension Uint8ListX on Uint8List {
  String get string => utf8.decode(this);

  Future<String> get md5Sum =>
      compute((data) => md5.convert(data).toString(), this);

  Future<ByteData> get byteData async => buffer.asByteData();

  /// Save the data to a file with `auto`:
  /// - md5 as name
  /// - mimeType as ext
  ///
  /// - [compress] only valid for image.
  ///
  /// Returns the path of the file.
  Future<String> save({bool compress = true}) async {
    final fileName = await md5Sum;
    // [Paths.file] is not created at startup on desktop — see [Paths.ensureFile].
    await Paths.ensureFile();
    final path = '${Paths.file}/$fileName';
    final file = File(path);
    await file.writeAsBytes(this);
    final headerBytes = sublist(0, math.min(100, length));
    final mime = lookupMimeType(path, headerBytes: headerBytes);
    if (mime != null) {
      var ext = extensionFromMime(mime);
      // The result of `extensionFromMime` if mime is jpeg is `jpe`
      if (ext == 'jpe') ext = 'jpg';
      final newPath = '$path.$ext';
      if (compress && ImageUtil.isImage(mime)) {
        final img = await ImageUtil.compress(this, mime: mime);
        await file.writeAsBytes(img);
      }
      await file.rename(newPath);
      return newPath;
    }
    return path;
  }
}
