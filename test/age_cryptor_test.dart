import 'dart:convert';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rage/rage.dart';

/// What a backup's envelope has to hold: age as `age -p` writes it, in either
/// form; the `LKFL_ENC` envelope every backup before it was written in; and
/// one error type for a wrong password across all of them.
void main() {
  final plain = utf8.encode('{"version":4,"spis":{}}');

  test('what is written is armored age, and reads back', () async {
    final text = await AgeCryptor.encrypt(plain, 'pwd');
    expect(text, startsWith(AgeCryptor.armorHeader));
    expect(AgeCryptor.isEncrypted(utf8.encode(text)), isTrue);
    expect(await AgeCryptor.decrypt(utf8.encode(text), 'pwd'), plain);
    // Pasted with whitespace around it.
    expect(await AgeCryptor.decrypt(utf8.encode('\n $text \n'), 'pwd'), plain);
  });

  test('binary age reads too', () async {
    final binary = await Rage.encryptWithPassphrase(
      plain,
      'pwd',
      workFactor: 10,
    );
    expect(AgeCryptor.isEncrypted(binary), isTrue);
    expect(await AgeCryptor.decrypt(binary, 'pwd'), plain);
  });

  test('the LKFL_ENC envelope still opens, V01 and V02', () async {
    for (final text in [
      Cryptor.encryptBytes(plain, 'pwd'),
      Cryptor.encryptBytes(plain, 'pwd', iterations: 1000),
    ]) {
      expect(AgeCryptor.isEncrypted(utf8.encode(text)), isTrue);
      expect(await AgeCryptor.decrypt(utf8.encode(text), 'pwd'), plain);
    }
  });

  test('a wrong password is one error type, for every envelope', () async {
    final age = utf8.encode(await AgeCryptor.encrypt(plain, 'pwd'));
    await expectLater(
      AgeCryptor.decrypt(age, 'wrong'),
      throwsA(isA<WrongPasswordException>()),
    );
    final lkfl = Cryptor.encryptBytes(plain, 'pwd');
    await expectLater(
      AgeCryptor.decrypt(utf8.encode(lkfl), 'wrong'),
      throwsA(isA<WrongPasswordException>()),
    );
    // Said as it always was, for a caller still matching the message.
    expect(
      () => Cryptor.decryptBytes(lkfl, 'wrong'),
      throwsA(
        isA<WrongPasswordException>().having(
          (e) => e.toString(),
          'message',
          contains('incorrect password'),
        ),
      ),
    );
  });

  test('text is decided from its head, without being encoded', () async {
    final age = await AgeCryptor.encrypt(plain, 'pwd');
    expect(AgeCryptor.isEncryptedText(age), isTrue);
    expect(AgeCryptor.isEncryptedText('\n  $age'), isTrue);
    expect(AgeCryptor.isEncryptedText(Cryptor.encryptBytes(plain, 'pwd')), isTrue);
    expect(AgeCryptor.isEncryptedText(utf8.decode(plain)), isFalse);
    expect(AgeCryptor.isEncryptedText('TEtGTF9FTkM='), isFalse, reason: 'too short');
    expect(AgeCryptor.isEncryptedText(''), isFalse);
  });

  test('what is not encrypted is said so', () async {
    expect(AgeCryptor.isEncrypted(plain), isFalse);
    expect(AgeCryptor.isEncrypted([0xff, 0xfe, 0x00]), isFalse);
    await expectLater(
      AgeCryptor.decrypt(plain, 'pwd'),
      throwsA(isA<FormatException>()),
    );
    await expectLater(
      AgeCryptor.decrypt(plain, ''),
      throwsA(isA<ArgumentError>()),
    );
  });
}
