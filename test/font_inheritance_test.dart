import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

const _fallback = ['Test CJK'];
const _chinese = ['system-font', 'sans-serif', 'Microsoft YaHei'];
const _title = 'ABCD EF';

ThemeData _theme({double? letterSpacing}) {
  final theme = ThemeData(
    fontFamily: 'Test UI',
    fontFamilyFallback: _fallback,
  );
  return theme.copyWith(
    textTheme: theme.textTheme.copyWith(
      bodyMedium: theme.textTheme.bodyMedium!.copyWith(letterSpacing: letterSpacing),
    ),
  );
}

Widget _app(
  Widget child, {
  double? letterSpacing,
  double? letterSpacingOverride,
  double? wordSpacingOverride,
}) => MaterialApp(
  theme: _theme(letterSpacing: letterSpacing),
  localizationsDelegates: LibLocalizations.localizationsDelegates,
  supportedLocales: LibLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    // The platform's text overrides, which only `Text` reads, and only when it
    // paints. `Toast` has to measure with them too.
    data: MediaQuery.of(context).applyTextStyleOverrides(
      lineHeightScaleFactorOverride: null,
      letterSpacingOverride: letterSpacingOverride,
      wordSpacingOverride: wordSpacingOverride,
      paragraphSpacingOverride: null,
    ),
    child: ToastHost(child: child!),
  ),
  home: Builder(builder: (context) {
    context.setLibL10n();
    return Scaffold(body: child);
  }),
);

void main() {
  tearDown(Toast.dismissAll);

  group('withChineseFontFallback', () {
    test('extends the list a slot already carried', () {
      final theme = ThemeData(fontFamilyFallback: _fallback).textTheme.withChineseFontFallback;

      expect(theme.bodyMedium!.fontFamilyFallback, [..._fallback, ..._chinese]);
      // And nothing else about the slot moves.
      expect(theme.bodyMedium!.fontSize, ThemeData().textTheme.bodyMedium!.fontSize);
      expect(theme.bodyMedium!.fontFamily, 'Roboto');
    });

    test('does not name a family twice', () {
      final theme = ThemeData(fontFamilyFallback: ['Microsoft YaHei']).textTheme.withChineseFontFallback;

      expect(theme.bodyMedium!.fontFamilyFallback, ['Microsoft YaHei', 'system-font', 'sans-serif']);
    });

    // A family from a package is written `packages/<package>/…`, and the getter
    // that reports it prefixes again for whoever reads it next.
    test('names a package-scoped family once, and the platform families plainly', () {
      final theme = const TextTheme(
        bodyMedium: TextStyle(
          fontSize: 12,
          color: Colors.red,
          fontFamily: 'Foo',
          package: 'pkg',
          fontFamilyFallback: ['Bar'],
        ),
      ).withChineseFontFallback;

      expect(theme.bodyMedium!.fontFamily, 'packages/pkg/Foo');
      expect(theme.bodyMedium!.fontFamilyFallback, ['packages/pkg/Bar', ..._chinese]);
      // Rebuilt field by field, so everything else survives the rebuild.
      expect(theme.bodyMedium!.fontSize, 12);
      expect(theme.bodyMedium!.color, Colors.red);
    });

    test('leaves a slot that names no package unprefixed', () {
      final theme = const TextTheme(
        bodyMedium: TextStyle(fontFamilyFallback: ['Bar']),
      ).withChineseFontFallback;

      expect(theme.bodyMedium!.fontFamily, isNull);
      expect(theme.bodyMedium!.fontFamilyFallback, ['Bar', ..._chinese]);
    });
  });

  testWidgets('segments keep theme fonts while selection changes', (tester) async {
    final selected = ValueNotifier('one');
    addTearDown(selected.dispose);
    await tester.pumpWidget(_app(
      ValueListenableBuilder<String>(
        valueListenable: selected,
        builder: (_, value, _) => SegmentedTabs<String>(
          segments: const [
            SegmentedTab(value: 'one', label: 'First'),
            SegmentedTab(value: 'two', label: 'Second'),
          ],
          selected: value,
          onSelected: (value) => selected.value = value,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    void expectFonts() {
      for (final label in ['First', 'Second']) {
        final paragraph = tester.renderObject<RenderParagraph>(find.descendant(
          of: find.text(label), matching: find.byType(RichText),
        ));
        expect(paragraph.text.style!.fontFamily, 'Test UI');
        expect(paragraph.text.style!.fontFamilyFallback, _fallback);
        expect(paragraph.text.style!.fontSize, 12);
        // ...and only the font: a 12pt label is not the 14pt body `bodyMedium`
        // describes, whose line height and tracking would size the bar.
        expect(paragraph.text.style!.height, isNull);
        expect(paragraph.text.style!.letterSpacing, isNull);
      }
    }

    expectFonts();
    await tester.tap(find.text('Second'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expectFonts();
    await tester.pumpAndSettle();
    expectFonts();
  });

  // `re_editor` takes a null family as "start at the fallback list", which
  // would make the first entry the editor's font rather than its last resort.
  for (final font in [null, 'Custom Mono']) {
    testWidgets('editor keeps the UI fallbacks with font $font', (tester) async {
      await tester.pumpWidget(_app(EditorPage(args: EditorPageArgs(
        text: 'echo hello',
        fontFamily: font,
        onSave: (_) {},
      ))));
      await tester.pumpAndSettle();
      final style = tester.widget<CodeEditor>(find.byType(CodeEditor)).style!;
      expect(style.fontFamily, font ?? 'Test UI');
      expect(style.fontFamilyFallback, _fallback);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  /// The disclosure is offered exactly when the title it is offered for is
  /// painted cut off — which is the whole of what the measurement decides.
  void expectDisclosureAgrees(WidgetTester tester, {required bool cutOff}) {
    final paragraph = tester.renderObject<RenderParagraph>(find.descendant(
      of: find.text(_title), matching: find.byType(RichText),
    ));
    expect(paragraph.didExceedMaxLines, cutOff);
    expect(find.byIcon(Icons.keyboard_arrow_down), cutOff ? findsOneWidget : findsNothing);
  }

  testWidgets('toast measures the typography it renders', (tester) async {
    await tester.pumpWidget(_app(const SizedBox(), letterSpacing: 100));
    Toast.show(_title, duration: Duration.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expectDisclosureAgrees(tester, cutOff: true);

    // With ordinary spacing the same title fits, so the disclosure disappears.
    // Settled, not merely rebuilt: the card's own text style is animated, so a
    // single pump shows the new title in the old tracking on its way down.
    await tester.pumpWidget(_app(const SizedBox(), letterSpacing: 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expectDisclosureAgrees(tester, cutOff: false);
  });

  // Widen the title past the width it is drawn in, in a way a painter that
  // only reads the theme cannot see. One of these was measured as fitting
  // while the screen showed it cut off.
  for (final (name, spacing, word) in [
    ('letter spacing', 60.0, null),
    ('word spacing', null, 400.0),
  ]) {
    testWidgets('toast measures with the platform $name override', (tester) async {
      await tester.pumpWidget(_app(
        const SizedBox(),
        letterSpacingOverride: spacing,
        wordSpacingOverride: word,
      ));
      Toast.show(_title, duration: Duration.zero);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expectDisclosureAgrees(tester, cutOff: true);
    });
  }
}
