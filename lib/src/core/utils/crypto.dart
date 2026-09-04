import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:pointycastle/export.dart';

/// Secure backup encryption utility class
/// Uses AES-GCM authenticated encryption and PBKDF2 key derivation
abstract final class Cryptor {
  static const _saltLength = 32;
  static const _nonceLength = 12;
  static const _tagLength = 16;

  /// What a payload gets when the caller says nothing, and what every V01
  /// envelope is fixed at.
  static const defaultIterations = 100000;

  static const _magicHeader = 'LKFL_ENC_V01';

  /// Same construction as [_magicHeader], with the PBKDF2 iteration count
  /// written into the envelope instead of assumed.
  ///
  /// A V01 payload cannot say how it was derived, so raising the cost for one
  /// caller would have silently broken every reader of the others. Written
  /// only when [encrypt] is asked for something other than
  /// [defaultIterations] — a backup still produces byte-identical V01 output,
  /// which an older build can still read.
  static const _magicHeaderV2 = 'LKFL_ENC_V02';

  /// Big-endian `uint32`, so an envelope is self-describing and a future
  /// change of cost does not need a third magic.
  static const _iterationsLength = 4;

  /// The largest cost a *reader* will act on.
  ///
  /// The count is the one field of a V02 envelope that is read before the tag
  /// can be checked — deriving the key is what produces the tag — so a
  /// tampered payload cannot forge plaintext but can ask for `0xffffffff`
  /// rounds and hang the app on a file someone was handed. Roughly two seconds
  /// on a phone, and three times what anything here writes.
  static const maxIterations = 2000000;

  /// Derives a key from password and salt using PBKDF2
  static Uint8List _deriveKey(String password, List<int> salt, int iterations) {
    final pbkdf2 = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64));
    pbkdf2.init(Pbkdf2Parameters(Uint8List.fromList(salt), iterations, 32));
    return pbkdf2.process(Uint8List.fromList(utf8.encode(password)));
  }

  /// Encrypts data using AES-GCM
  /// [data] Plaintext data to encrypt
  /// [password] Encryption password
  /// [iterations] PBKDF2 cost. Raise it when the password is short enough to
  /// enumerate — a six-digit code is twenty bits, and the only thing standing
  /// between that and the plaintext is how long one guess takes.
  /// Returns Base64 encoded encrypted result
  static String encrypt(
    String data,
    String password, {
    int iterations = defaultIterations,
  }) {
    if (data.isEmpty) {
      throw ArgumentError('Data cannot be empty');
    }
    return encryptBytes(utf8.encode(data), password, iterations: iterations);
  }

  /// [encrypt] for data that is not text.
  ///
  /// Its own entry point rather than "base64 it and call [encrypt]": the
  /// envelope base64s once already, and going through the text form would
  /// expand the payload by a third before that. Which matters exactly where
  /// this is used — compressed data, where the point was to make it smaller.
  static String encryptBytes(
    List<int> data,
    String password, {
    int iterations = defaultIterations,
  }) {
    if (password.isEmpty) {
      throw ArgumentError('Password cannot be empty');
    }
    if (data.isEmpty) {
      throw ArgumentError('Data cannot be empty');
    }
    if (iterations <= 0 || iterations > maxIterations) {
      throw ArgumentError('Iterations must be in 1..$maxIterations');
    }

    final random = Random.secure();

    // Generate random salt and nonce
    final salt = List.generate(_saltLength, (_) => random.nextInt(256));
    final nonce = List.generate(_nonceLength, (_) => random.nextInt(256));

    // Derive key from password and salt
    final key = _deriveKey(password, salt, iterations);

    // Initialize AES-GCM cipher
    final cipher = GCMBlockCipher(AESEngine());
    cipher.init(true, AEADParameters(
      KeyParameter(key),
      _tagLength * 8,
      Uint8List.fromList(nonce),
      Uint8List(0)
    ));

    // Encrypt data (includes authentication tag)
    final encrypted = cipher.process(Uint8List.fromList(data));

    // The default cost keeps producing exactly what it always did, so a
    // backup written by this build stays readable by one that predates V02.
    final result = iterations == defaultIterations
        ? <int>[...utf8.encode(_magicHeader), ...salt, ...nonce, ...encrypted]
        : <int>[
            ...utf8.encode(_magicHeaderV2),
            ..._encodeIterations(iterations),
            ...salt,
            ...nonce,
            ...encrypted,
          ];

    return base64.encode(result);
  }

  static List<int> _encodeIterations(int iterations) => [
    (iterations >> 24) & 0xff,
    (iterations >> 16) & 0xff,
    (iterations >> 8) & 0xff,
    iterations & 0xff,
  ];

  static int _decodeIterations(List<int> bytes) =>
      (bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3];

  /// Decrypts data using AES-GCM 
  /// [encryptedData] Base64 encoded encrypted data
  /// [password] Decryption password
  static String decrypt(String encryptedData, String password) {
    // Not wrapped in the try below: a payload that decrypted correctly and is
    // simply not text is a different failure from a wrong password, and
    // reporting it as one sends the user to change something that was right.
    final bytes = decryptBytes(encryptedData, password);
    try {
      return utf8.decode(bytes);
    } on FormatException {
      throw Exception('Failed to decrypt: the payload is not text');
    }
  }

  /// [decrypt] for data that is not text. See [encryptBytes].
  static Uint8List decryptBytes(String encryptedData, String password) {
    if (password.isEmpty) {
      throw ArgumentError('Password cannot be empty');
    }
    if (encryptedData.isEmpty) {
      throw ArgumentError('Encrypted data cannot be empty');
    }

    try {
      final envelope = _parse(base64.decode(encryptedData));
      if (envelope == null) {
        throw Exception('Invalid encrypted data format');
      }

      // Derive key from password and salt
      final key = _deriveKey(password, envelope.salt, envelope.iterations);

      // Initialize AES-GCM cipher for decryption
      final cipher = GCMBlockCipher(AESEngine());
      cipher.init(false, AEADParameters(
        KeyParameter(key),
        _tagLength * 8,
        Uint8List.fromList(envelope.nonce),
        Uint8List(0)
      ));

      // Decrypt data (automatically verifies authentication tag)
      return cipher.process(Uint8List.fromList(envelope.ciphertext));
    } on InvalidCipherTextException {
      throw Exception('Failed to decrypt: incorrect password or corrupted data');
    } on FormatException {
      throw Exception('Failed to decrypt: invalid Base64 format');
    } catch (e) {
      throw Exception('Failed to decrypt: $e');
    }
  }

  /// Checks if the data is encrypted
  /// [data] Data string to check
  /// Returns true if the data is encrypted by this class
  static bool isEncrypted(String data) {
    if (data.isEmpty) return false;

    try {
      return _parse(base64.decode(data)) != null;
    } catch (e) {
      return false;
    }
  }

  /// Splits an envelope of either version, or answers null when [data] is not
  /// one.
  ///
  /// The iteration count is read from the envelope rather than assumed, which
  /// is the whole difference between the two versions.
  static _Envelope? _parse(List<int> data) {
    final v1 = utf8.encode(_magicHeader);
    final v2 = utf8.encode(_magicHeaderV2);

    int offset;
    int iterations;
    if (_startsWith(data, v2)) {
      offset = v2.length;
      if (data.length < offset + _iterationsLength) return null;
      iterations = _decodeIterations(
        data.sublist(offset, offset + _iterationsLength),
      );
      offset += _iterationsLength;
      // Refused rather than clamped: a count outside the range is not a
      // payload this wrote, and clamping would spend the budget deriving a key
      // that cannot match the tag anyway.
      if (iterations <= 0 || iterations > maxIterations) return null;
    } else if (_startsWith(data, v1)) {
      offset = v1.length;
      iterations = defaultIterations;
    } else {
      return null;
    }

    if (data.length < offset + _saltLength + _nonceLength + _tagLength) {
      return null;
    }
    final salt = data.sublist(offset, offset + _saltLength);
    offset += _saltLength;
    final nonce = data.sublist(offset, offset + _nonceLength);
    offset += _nonceLength;
    return _Envelope(
      iterations: iterations,
      salt: salt,
      nonce: nonce,
      ciphertext: data.sublist(offset),
    );
  }

  static bool _startsWith(List<int> data, List<int> prefix) {
    if (data.length < prefix.length) return false;
    return _listEquals(data.sublist(0, prefix.length), prefix);
  }

  /// Compares two lists for equality using constant-time comparison
  /// to prevent timing attacks
  static bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) {
      final lengthResult = a.length ^ b.length;
      int result = lengthResult;
      final count = a.length > b.length ? a.length : b.length;
      for (int i = 0; i < count; i++) {
        final aByte = i < a.length ? a[i] : 0;
        final bByte = i < b.length ? b[i] : 0;
        result |= aByte ^ bByte;
      }
      return result == 0;
    }

    int result = 0;
    for (int i = 0; i < a.length; i++) {
      result |= a[i] ^ b[i];
    }
    return result == 0;
  }

  /// Generates a random password for testing
  /// [length] Password length, default is 32
  /// Returns a random alphanumeric password
  static String generatePassword([int length = 32]) {
    const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = Random.secure();
    return List.generate(length, (_) => chars[random.nextInt(chars.length)]).join();
  }
}

/// One parsed envelope, of either version.
final class _Envelope {
  const _Envelope({
    required this.iterations,
    required this.salt,
    required this.nonce,
    required this.ciphertext,
  });

  final int iterations;
  final List<int> salt;
  final List<int> nonce;

  /// Still carrying the GCM tag, which `process` checks as it decrypts.
  final List<int> ciphertext;
}