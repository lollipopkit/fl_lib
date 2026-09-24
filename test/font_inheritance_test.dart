import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';

const _fallback = ['Test CJK'];

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

Widget _app(Widget child, {double? letterSpacing}) => MaterialApp(
  theme: _theme(letterSpacing: letterSpacing),
  localizationsDelegates: LibLocalizations.localizationsDelegates,
  supportedLocales: LibLocalizations.supportedLocales,
  builder: (_, child) => ToastHost(child: child!),
  home: Builder(builder: (context) {
    context.setLibL10n();
    return Scaffold(body: child);
  }),
);

void main() {
  tearDown(Toast.dismissAll);

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

  for (final font in [null, 'Custom Mono']) {
    testWidgets('editor keeps UI fallbacks with font $font', (tester) async {
      await tester.pumpWidget(_app(EditorPage(args: EditorPageArgs(
        text: 'echo hello',
        fontFamily: font,
        onSave: (_) {},
      ))));
      await tester.pumpAndSettle();
      final style = tester.widget<CodeEditor>(find.byType(CodeEditor)).style!;
      expect(style.fontFamily, font);
      expect(style.fontFamilyFallback, _fallback);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('toast measures the same typography it renders', (tester) async {
    await tester.pumpWidget(_app(const SizedBox(), letterSpacing: 100));
    Toast.show('ABCDEF', duration: Duration.zero);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);

    // With ordinary spacing the same title fits, so the disclosure disappears.
    await tester.pumpWidget(_app(const SizedBox(), letterSpacing: 0));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
  });
}
