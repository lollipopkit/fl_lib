import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart';

/// Markdown opens rendered; the source is one tap away.
void main() {
  Future<void> pumpEditor(WidgetTester tester, EditorPageArgs args) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: const [
        LibLocalizations.delegate,
        ...GlobalMaterialLocalizations.delegates,
      ],
      supportedLocales: LibLocalizations.supportedLocales,
      home: EditorPage(args: args),
    ));
    await pumpFrames(tester);
    addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  }

  testWidgets('markdown text opens rendered, images not loaded', (tester) async {
    await pumpEditor(
      tester,
      EditorPageArgs(
        lang: ProgLang.markdown,
        text: '# Hello\n\nA paragraph.\n\n![logo](https://example.com/logo.png)',
        onSave: (_) {},
      ),
    );

    expect(find.byType(CodeEditor), findsNothing);
    expect(find.text('Hello'), findsOneWidget);
    expect(find.text('A paragraph.'), findsOneWidget);
    expect(find.text('logo'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
    expect(find.byTooltip(libL10n.edit), findsOneWidget);
    expect(find.byTooltip(libL10n.search), findsNothing);
  });

  testWidgets('edit and preview swap the source and the rendered view', (tester) async {
    await pumpEditor(
      tester,
      EditorPageArgs(lang: ProgLang.markdown, text: '# Hello', onSave: (_) {}),
    );

    await tester.tap(find.byTooltip(libL10n.edit));
    await pumpFrames(tester);
    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.byTooltip(libL10n.search), findsOneWidget);

    await tester.tap(find.byTooltip(libL10n.preview));
    await pumpFrames(tester);
    expect(find.byType(CodeEditor), findsNothing);
    expect(find.text('Hello'), findsOneWidget);
  });

  testWidgets('other languages stay a source editor', (tester) async {
    await pumpEditor(
      tester,
      EditorPageArgs(lang: ProgLang.json, text: '{"name":"x"}', onSave: (_) {}),
    );

    expect(find.byType(CodeEditor), findsOneWidget);
    expect(find.byTooltip(libL10n.preview), findsNothing);
    expect(find.byTooltip(libL10n.edit), findsNothing);
  });
}

/// Counted out rather than settled: the editor keeps a frame scheduled.
Future<void> pumpFrames(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}
