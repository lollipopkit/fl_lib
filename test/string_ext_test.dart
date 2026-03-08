import 'package:fl_lib/src/core/ext/string.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('RandomStr.generate', () {
    test('uses the provided charsSet', () {
      final value = RandomStr.generate(64, charsSet: 'ab');

      expect(value, hasLength(64));
      expect(value, matches(r'^[ab]+$'));
    });

    test(
      'normalizes alphabetic characters to uppercase when lowerCase is false',
      () {
        final value = RandomStr.generate(
          64,
          lowerCase: false,
          charsSet: 'ab12',
        );

        expect(value, hasLength(64));
        expect(value, matches(r'^[AB12]+$'));
      },
    );

    test(
      'normalizes alphabetic characters to lowercase when lowerCase is true',
      () {
        final value = RandomStr.generate(64, charsSet: 'AB12');

        expect(value, hasLength(64));
        expect(value, matches(r'^[ab12]+$'));
      },
    );
  });
}
