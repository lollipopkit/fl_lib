import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:fl_lib/src/core/utils/crypto.dart';
import 'package:rage/rage.dart';

/// A backup's envelope: age (age-encryption.org/v1) in passphrase mode, as
/// `age -p` writes it, so a backup opens with `age -d` and the password.
///
/// Written armored, so it travels as text (the clipboard, a gist); read in
/// either form, and in the `LKFL_ENC` envelope of [Cryptor], which every
/// backup before this was written in.
/// TODO: stop reading `LKFL_ENC` once old backups are no longer expected.
///
/// The work is scrypt's (or PBKDF2's), never on the caller's isolate.
abstract final class AgeCryptor {
  /// scrypt's `log2(N)` written: 128 MiB, well under a second on a phone.
  ///
  /// Fixed rather than rage's "a second on this device": a reader refuses a
  /// file more than four above what takes a second on *it*, so what a
  /// desktop wrote could be refused by a phone.
  static const workFactor = 17;

  /// The highest `log2(N)` opened: what `age -p` writes by default (18) and
  /// some, on any device.
  static const maxWorkFactor = 20;

  static const armorHeader = '-----BEGIN AGE ENCRYPTED FILE-----';
  static const binaryHeader = 'age-encryption.org/v1\n';

  /// How much of an `LKFL_ENC` envelope says what it is: base64 of the
  /// 12-byte magic.
  static const _lkflHead = 16;

  /// [plain] encrypted with [passphrase], armored.
  static Future<String> encrypt(List<int> plain, String passphrase) async {
    if (passphrase.isEmpty) {
      throw ArgumentError('Passphrase cannot be empty');
    }
    if (plain.isEmpty) {
      throw ArgumentError('Data cannot be empty');
    }
    final out = await Rage.encryptWithPassphrase(
      plain,
      passphrase,
      workFactor: workFactor,
      armor: true,
    );
    return ascii.decode(out);
  }

  /// [data] opened with [passphrase]: armored or binary age, or `LKFL_ENC`.
  ///
  /// Throws [WrongPasswordException] when [passphrase] does not open it, and
  /// a [FormatException] when it is not an encrypted file this reads.
  static Future<Uint8List> decrypt(List<int> data, String passphrase) async {
    if (passphrase.isEmpty) {
      throw ArgumentError('Passphrase cannot be empty');
    }
    final form = _form(data);
    switch (form) {
      case _Form.armored || _Form.binary:
        try {
          return await Rage.decryptWithPassphrase(
            _trimmed(data, end: form == _Form.armored),
            passphrase,
            maxWorkFactor: maxWorkFactor,
          );
        } on RageError catch (e) {
          throw switch (e.kind) {
            RageErrorKind.wrongPassphrase => const WrongPasswordException(),
            RageErrorKind.excessiveWork => FormatException(
              'The file asks for more work than this device does '
              '(scrypt 2^${e.requiredWorkFactor}, at most 2^$maxWorkFactor)',
            ),
            _ => FormatException('Not a readable age file: ${e.message}'),
          };
        }
      case _Form.lkfl:
        // PBKDF2 in Dart: off this isolate, as scrypt is off it in rage's.
        final text = utf8.decode(data).trim();
        return Isolate.run(() => Cryptor.decryptBytes(text, passphrase));
      case null:
        throw const FormatException('Not an encrypted file');
    }
  }

  /// Whether [data] is something [decrypt] opens, decided from its head.
  static bool isEncrypted(List<int> data) => _form(data) != null;

  /// [isEncrypted] for text, without encoding it: every head is ASCII, and
  /// `codeUnits` is a view.
  static bool isEncryptedText(String text) => _form(text.codeUnits) != null;

  static _Form? _form(List<int> data) {
    var start = 0;
    while (start < data.length && _isSpace(data[start])) {
      start++;
    }
    if (_startsAt(data, start, armorHeader)) return _Form.armored;
    if (_startsAt(data, start, binaryHeader)) return _Form.binary;
    if (data.length - start < _lkflHead) return null;
    final head = data.sublist(start, start + _lkflHead);
    if (!head.every(_isBase64)) return null;
    try {
      final magic = base64.decode(String.fromCharCodes(head));
      return _startsAt(magic, 0, Cryptor.envelopePrefix) ? _Form.lkfl : null;
    } on FormatException {
      return null;
    }
  }

  static bool _startsAt(List<int> data, int at, String header) {
    if (data.length - at < header.length) return false;
    for (var i = 0; i < header.length; i++) {
      if (data[at + i] != header.codeUnitAt(i)) return false;
    }
    return true;
  }

  /// [data] without the whitespace before it, and with [end] after it too (a
  /// pasted armor, a file ending in a newline). Binary age keeps its end: its
  /// last bytes are ciphertext, which may be whitespace.
  static Uint8List _trimmed(List<int> data, {required bool end}) {
    var start = 0;
    var stop = data.length;
    while (start < stop && _isSpace(data[start])) {
      start++;
    }
    while (end && stop > start && _isSpace(data[stop - 1])) {
      stop--;
    }
    return Uint8List.fromList(data.sublist(start, stop));
  }

  static bool _isSpace(int b) => b == 0x20 || b == 0x0a || b == 0x0d || b == 0x09;

  static bool _isBase64(int b) =>
      (b >= 0x30 && b <= 0x39) ||
      (b >= 0x41 && b <= 0x5a) ||
      (b >= 0x61 && b <= 0x7a) ||
      b == 0x2b ||
      b == 0x2f ||
      b == 0x3d;
}

enum _Form { armored, binary, lkfl }
