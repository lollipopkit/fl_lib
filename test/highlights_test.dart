import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all highlight themes resolve to flutter_highlight theme maps', () {
    for (final theme in HighlightTheme.values) {
      expect(theme.theme, isNotNull, reason: theme.name);
    }
  });

  test('parses flutter_highlight theme map keys', () {
    expect(
      HighlightTheme.fromThemeMapKey('a11y-light'),
      HighlightTheme.a11y_light,
    );
    expect(HighlightTheme.fromThemeMapKey('monokai'), HighlightTheme.monokai);
    expect(
      HighlightTheme.fromThemeMapKey('default'),
      HighlightTheme.defaultTheme,
    );
    expect(
      HighlightTheme.fromThemeMapKey('kimbie.dark'),
      HighlightTheme.kimbie_dark,
    );
    expect(
      HighlightTheme.fromThemeMapKey('qtcreator_dark'),
      HighlightTheme.qtcreator_dark,
    );
    expect(HighlightTheme.fromThemeMapKey('unknown-theme'), isNull);
    expect(HighlightTheme.fromThemeMapKey(null), isNull);
  });

  test('suffixes match in any case, on either path separator', () {
    expect(ProgLang.parseFileName('README.md'), ProgLang.markdown);
    expect(ProgLang.parseFileName('notes.MD'), ProgLang.markdown);
    expect(ProgLang.parseFileName('doc.mdown'), ProgLang.markdown);
    expect(ProgLang.parseFileName('doc.mkd'), ProgLang.markdown);
    expect(ProgLang.parseFileName('doc.mdwn'), ProgLang.markdown);
    expect(ProgLang.parseFileName('main.RS'), ProgLang.rust);
    expect(ProgLang.parseFileName(r'C:\Users\a\script.py'), ProgLang.python);
    expect(ProgLang.parseFileName('/srv/Makefile'), ProgLang.makefile);
    expect(ProgLang.parseFileName('ViewController.m'), ProgLang.objectivec);
    expect(ProgLang.parseFileName('query.sql'), ProgLang.sql);
    expect(ProgLang.parseFileName('README'), isNull);
    expect(ProgLang.parseFileName('file.unknownext'), isNull);
  });
}
