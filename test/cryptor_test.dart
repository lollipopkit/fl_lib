import 'dart:convert';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

/// The V02 envelope exists so a short password can be given a cost the reader
/// does not have to be told about out of band. What has to hold is that saying
/// nothing still produces exactly what every existing backup is, and that the
/// one field a reader acts on before it can check the tag cannot be used to
/// hang it.
void main() {
  // 1000 rather than the real 600k: this asserts the envelope, and a test
  // that spends a second per case gets run less often than one that does not.
  const cheap = 1000;

  group('Cryptor V01 compatibility', () {
    test('the default cost still writes a V01 envelope', () {
      final encrypted = Cryptor.encrypt('hello', 'pwd');
      final magic = utf8.decode(base64.decode(encrypted).sublist(0, 12));
      expect(magic, 'LKFL_ENC_V01');
    });

    test('a V01 payload decrypts without being told the cost', () {
      // Written the way every build before V02 wrote one: no iteration field,
      // the reader assumes 100k. Produced here through the same default path.
      final encrypted = Cryptor.encrypt('hello', 'pwd');
      expect(Cryptor.decrypt(encrypted, 'pwd'), 'hello');
    });

    test('passing the default explicitly is the same envelope', () {
      final encrypted = Cryptor.encrypt(
        'hello',
        'pwd',
        iterations: Cryptor.defaultIterations,
      );
      final magic = utf8.decode(base64.decode(encrypted).sublist(0, 12));
      expect(magic, 'LKFL_ENC_V01');
    });
  });

  group('Cryptor V02', () {
    test('a non-default cost writes a V02 envelope and round-trips', () {
      final encrypted = Cryptor.encrypt('hello', '123456', iterations: cheap);
      final magic = utf8.decode(base64.decode(encrypted).sublist(0, 12));
      expect(magic, 'LKFL_ENC_V02');
      expect(Cryptor.decrypt(encrypted, '123456'), 'hello');
    });

    test('the cost is read from the envelope, not from the reader', () {
      // The point of the version. Two payloads with different costs are both
      // readable by the same call, which is only possible if the count came
      // out of the bytes.
      final cheapOne = Cryptor.encrypt('a', 'pwd', iterations: cheap);
      final dearOne = Cryptor.encrypt('b', 'pwd', iterations: cheap * 2);
      expect(Cryptor.decrypt(cheapOne, 'pwd'), 'a');
      expect(Cryptor.decrypt(dearOne, 'pwd'), 'b');
    });

    test('isEncrypted recognises both versions', () {
      expect(Cryptor.isEncrypted(Cryptor.encrypt('a', 'pwd')), isTrue);
      expect(
        Cryptor.isEncrypted(Cryptor.encrypt('a', 'pwd', iterations: cheap)),
        isTrue,
      );
      expect(Cryptor.isEncrypted('not base64 at all !!'), isFalse);
      expect(Cryptor.isEncrypted(base64.encode(utf8.encode('short'))), isFalse);
    });

    test('a wrong password is refused', () {
      final encrypted = Cryptor.encrypt('hello', '123456', iterations: cheap);
      expect(() => Cryptor.decrypt(encrypted, '123457'), throwsException);
    });
  });

  group('Cryptor iteration bounds', () {
    test('writing past the cap is refused', () {
      expect(
        () => Cryptor.encrypt(
          'a',
          'pwd',
          iterations: Cryptor.maxIterations + 1,
        ),
        throwsArgumentError,
      );
      expect(
        () => Cryptor.encrypt('a', 'pwd', iterations: 0),
        throwsArgumentError,
      );
    });

    /// The case the cap is for. Nothing in the envelope is authenticated
    /// before the key is derived, so a hand-edited count is what the reader
    /// spends its time on — and `0xffffffff` rounds of PBKDF2 is not a wrong
    /// answer, it is no answer at all.
    test('a payload claiming an absurd cost is rejected, not attempted', () {
      final bytes = base64.decode(
        Cryptor.encrypt('hello', 'pwd', iterations: cheap),
      );
      // The four bytes right after the magic.
      bytes[12] = 0xff;
      bytes[13] = 0xff;
      bytes[14] = 0xff;
      bytes[15] = 0xff;
      final tampered = base64.encode(bytes);

      expect(Cryptor.isEncrypted(tampered), isFalse);
      // Returns rather than running for minutes; the timeout is what makes the
      // assertion mean anything.
      expect(() => Cryptor.decrypt(tampered, 'pwd'), throwsException);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('a payload claiming a zero cost is rejected', () {
      final bytes = base64.decode(
        Cryptor.encrypt('hello', 'pwd', iterations: cheap),
      );
      bytes.setRange(12, 16, const [0, 0, 0, 0]);
      expect(Cryptor.isEncrypted(base64.encode(bytes)), isFalse);
    });
  });
}
