import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const supported = [
    Locale('de'),
    Locale('en'),
    Locale('pt'),
    Locale('zh'),
    Locale('zh', 'TW'),
  ];

  Locale? resolve(List<Locale> locales) =>
      LocaleUtil.resolve(locales, supported);

  test('a region or script the app does not list still finds the language',
      () {
    expect(resolve([const Locale('de', 'AT')]), const Locale('de'));
    expect(resolve([const Locale('en', 'US')]), const Locale('en'));
    expect(
      resolve([
        const Locale.fromSubtags(
            languageCode: 'zh', scriptCode: 'Hans', countryCode: 'SG'),
      ]),
      const Locale('zh'),
    );
    expect(resolve([const Locale('zh', 'CN')]), const Locale('zh'));
  });

  test('Traditional Chinese by script or by region', () {
    expect(
      resolve([
        const Locale.fromSubtags(
            languageCode: 'zh', scriptCode: 'Hant', countryCode: 'HK'),
      ]),
      const Locale('zh', 'TW'),
    );
    expect(resolve([const Locale('zh', 'MO')]), const Locale('zh', 'TW'));
    expect(resolve([const Locale('zh', 'TW')]), const Locale('zh', 'TW'));
  });

  test('Traditional falls back to Chinese when only Simplified is listed', () {
    expect(
      LocaleUtil.resolve([const Locale('zh', 'HK')], const [Locale('zh')]),
      const Locale('zh'),
    );
  });

  test('later preferences are tried before English', () {
    expect(resolve([const Locale('fi'), const Locale('pt', 'BR')]),
        const Locale('pt'));
    expect(resolve([const Locale('fi')]), const Locale('en'));
    expect(resolve([]), const Locale('en'));
    expect(LocaleUtil.resolve(null, supported), const Locale('en'));
  });

  test('a listed region wins over the bare language', () {
    expect(
      LocaleUtil.resolve(
          [const Locale('pt', 'BR')], const [Locale('pt'), Locale('pt', 'BR')]),
      const Locale('pt', 'BR'),
    );
    expect(
      LocaleUtil.resolve(
          [const Locale('pt', 'PT')], const [Locale('pt', 'BR'), Locale('pt')]),
      const Locale('pt'),
    );
  });
}
