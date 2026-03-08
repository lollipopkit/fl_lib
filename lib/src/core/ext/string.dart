import 'dart:convert';
import 'dart:math';

import 'package:extended_image/extended_image.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher_string.dart';

extension StringX on String {
  /// [isEmpty] => [null]
  /// [isNotEmpty] => [this]
  String? get selfNotEmptyOrNull => isEmpty ? null : this;

  /// Uppercase the first character.
  String get capitalize {
    if (isEmpty) return this;
    // final firstRune = codeUnitAt(0);
    // if (firstRune < 0x61 || firstRune > 0x7A) return this;
    // final runes = List.of(this.runes);
    // runes[0] = firstRune - 0x20;
    // return String.fromCharCodes(runes);

    // A more efficient way.
    // Refer: [test/bench_test.dart]

    final first = codeUnitAt(0);
    if (first < 0x61 || first > 0x7A) return this;
    return String.fromCharCode(first - 0x20) + substring(1);
  }

  /// Decode the `u8` list to a string using `utf8`.
  Uint8List get uint8List => Uint8List.fromList(utf8.encode(this));
}

extension StringColorX on String? {
  /// Convert a hex string to a color.
  ///
  /// - The leading '#' is optional.
  /// - The alpha channel is optional.
  /// - Except the '#', the length of the string should be 3(RGB), 4(ARGB), 6(RRGGBB), or 8(AARRGGBB).
  ///
  /// eg.:
  /// - '#FF0000' => Color(0xFFFF0000)
  /// - '#123' => Color(0xFF112233)
  /// - '11223344' => Color(0xFF11223344)
  Color? get fromColorHex {
    if (this == null) return null;
    final hex = this!.replaceFirst('#', '');
    final hexLen = hex.length;
    if (hexLen != 3 && hexLen != 4 && hexLen != 6 && hexLen != 8) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return null;
    return switch (hexLen) {
      3 || 6 => fromColorHexRGB,
      4 || 8 => fromColorHexARGB,
      _ => null,
    };
  }

  /// Accepts (#)RGB / (#)RRGGBB hex strings.
  ///
  /// {@template string_color_hex_internal_tip}
  /// This method is used internally by [fromColorHex].
  /// {@endtemplate}
  Color? get fromColorHexRGB {
    if (this == null) return null;
    final hex = this!.replaceFirst('#', '');
    final hexLen = hex.length;
    if (hexLen != 3 && hexLen != 6) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return null;
    return switch (hexLen) {
      3 => () {
        final r = (value & 0xF00) >> 8;
        final g = (value & 0x0F0) >> 4;
        final b = value & 0x00F;
        final rgb = r << 20 | r << 16 | g << 12 | g << 8 | b << 4 | b;
        return Color(rgb | 0xFF000000);
      }(),
      6 => Color(value | 0xFF000000),
      _ => null,
    };
  }

  /// Accepts (#)ARGB / (#)AARRGGBB hex strings.
  ///
  /// {@macro string_color_hex_internal_tip}
  Color? get fromColorHexARGB {
    if (this == null) return null;
    final hex = this!.replaceFirst('#', '');
    final hexLen = hex.length;
    if (hexLen != 4 && hexLen != 8) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return null;
    return switch (hexLen) {
      4 => () {
        final a = (value & 0xF000) >> 12;
        final r = (value & 0x0F00) >> 8;
        final g = (value & 0x00F0) >> 4;
        final b = value & 0x000F;
        final argb = a << 28 | a << 24 | r << 20 | r << 16 | g << 12 | g << 8 | b << 4 | b;
        return Color(argb);
      }(),
      8 => Color(value),
      _ => null,
    };
  }
}

extension StringUrlX on String {
  /// Check if the string is a valid URL.
  bool get isUrl => Uri.tryParse(this) != null;

  /// Launch the URL.
  Future<bool> launchUrl({LaunchMode? mode}) async {
    if (!isUrl) return false;
    return await launchUrlString(this, mode: mode ?? LaunchMode.platformDefault);
  }
}

/// {@template string_path_separator}
/// During the design period, the target platform only can be `android` or `ios`.
/// So, the default [separator] is `/`.
/// {@endtemplate}
extension StringPathX on String {
  /// Join the path.
  ///
  /// - [separator] is the separator of the path.
  ///
  /// {@macro string_path_separator}
  String joinPath(String path, {String? separator}) {
    if (isEmpty) return path;
    if (path.isEmpty) return this;
    final sep = separator ?? Pfs.seperator;
    return this + sep + path;
  }

  /// Get the file name from the path.
  ///
  /// - [separator] is the separator of the path.
  /// - [withoutExtension] is whether to remove the extension
  ///
  /// {@macro string_path_separator}
  String? getFileName({String separator = '/', bool withoutExtension = false}) {
    final index = lastIndexOf(separator);
    if (index == -1) return null;
    final wholeName = substring(index + 1);
    if (!withoutExtension) return wholeName;
    final dotIdx = wholeName.lastIndexOf('.');
    // It means the file name doesn't have an extension.
    // So, return the whole name.
    if (dotIdx == -1) return wholeName;
    return wholeName.substring(0, dotIdx);
  }

  /// Getter of [getFileName] with [withoutExtension] is false.
  ///
  /// Name it as [fileNameGetter] to avoid the conflict with the common [fileName] attribute.
  String? get fileNameGetter => getFileName();
}

extension StringDateTimeX on String {
  /// Parse the string to [DateTime].
  ///
  /// Examples of accepted strings:
  /// - "2012-02-27"
  /// - "2012-02-27 13:27:00"
  /// - "2012-02-27 13:27:00.123456789z"
  /// - "2012-02-27 13:27:00,123456789z"
  /// - "20120227 13:27:00"
  /// - "20120227T132700"
  /// - "20120227"
  /// - "+20120227"
  /// - "2012-02-27T14Z"
  /// - "2012-02-27T14+00:00"
  /// - "-123450101 00:00:00 Z": in the year -12345.
  /// - "2002-02-27T14:00:00-0500": Same as "2002-02-27T19:00:00Z"
  DateTime? parseDateTime() {
    if (isEmpty) return null;
    try {
      return DateTime.parse(this);
    } catch (e) {
      return null;
    }
  }

  /// Parse the timestamp string to [DateTime].
  DateTime? parseTimestamp() {
    if (isEmpty) return null;
    try {
      final number = parseNum<int>();
      if (number == null) return null;
      return DateTime.fromMillisecondsSinceEpoch(number);
    } catch (e) {
      return null;
    }
  }
}

extension StringNumX on String {
  /// Try to parse the string to [num].
  ///
  /// If the string is empty, return null.
  /// If the string can't be parsed, return null.
  T? parseNum<T extends num>() {
    if (isEmpty) return null;
    try {
      return num.parse(this) as T;
    } catch (e) {
      return null;
    }
  }
}

/// Generate a random string.
abstract final class RandomStr {
  /// The default character set.
  static const chars = 'abcdefghijklmnopqrstuvwxyz0123456789';

  /// Generate a random string.
  ///
  /// - [length] is the length of the string.
  /// - [secure] is whether to use a secure random number generator.
  /// - [lowerCase] controls whether alphabetic characters are lowercase or uppercase.
  /// - [charsSet] is the character set used to generate the result.
  static String generate(int length, {bool secure = false, bool lowerCase = true, String charsSet = chars}) {
    final random = secure ? Random.secure() : Random();
    final effectiveCharsSet = lowerCase ? charsSet.toLowerCase() : charsSet.toUpperCase();
    return List.generate(length, (_) => effectiveCharsSet[random.nextInt(effectiveCharsSet.length)]).join();
  }
}

extension StringImgX on String {
  /// Matches http and https schemes.
  static final httpReg = RegExp(r'^https?://');

  static final _transparentImgBytes = const Base64Decoder().convert(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/wcAAgAB/ax5kAAAAABJRU5ErkJggg==',
  );

  /// Get the image provider from the string.
  ///
  /// - [catchErr] If true, returns a placeholder image when the image fails to load.
  /// - [headers] is the headers of the network image. It will override the default headers ([UserApi.authHeaders]).
  /// - [cache] / [headers] / [retries] / [cancelToken] only work for the network image.
  ImageProvider getImageProvider({
    bool cache = true,
    Map<String, String>? headers,
    int retries = 3,
    CancellationToken? cancelToken,
    String? imageCacheName,
    bool catchErr = false,
  }) {
    try {
      if (startsWith(httpReg)) {
        final isLpktApi = startsWith(ApiUrls.base);
        final headers_ = (isLpktApi ? UserApi.authHeaders : null) ?? <String, String>{};
        if (headers != null) headers_.addAll(headers);
        return ExtendedNetworkImageProvider(
          this,
          headers: headers_,
          cache: cache,
          retries: retries,
          cancelToken: cancelToken,
          imageCacheName: imageCacheName,
        );
      } else if (startsWith('assets')) {
        return ExtendedAssetImageProvider(this, imageCacheName: imageCacheName);
      }
      return PlatformImage.file(this, imageCacheName: imageCacheName);
    } catch (e, s) {
      dprint('getImageProvider', e, s);
      if (!catchErr) rethrow;
      return ExtendedMemoryImageProvider(_transparentImgBytes);
    }
  }

  /// Get the image provider from the string.
  ImageProvider get imageProvider => getImageProvider();
}
