import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// An edit the editor refuses changes nothing.
///
/// It showed the error and then saved anyway — an empty key or value went in
/// — and renaming one key onto another replaced the other's value, so the
/// entry under that key was gone without a word.
void main() {
  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: KvEditor(args: KvEditorArgs(data: {'a': '1', 'b': '2'})),
      ),
    );
    await tester.pump();
  }

  Future<void> edit(WidgetTester tester, {required String key}) async {
    await tester.tap(find.byTooltip(libL10n.edit).first);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField).first, key);
    await tester.tap(find.text(libL10n.ok));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('renaming onto a key that is there is refused', (tester) async {
    await pump(tester);
    await edit(tester, key: 'b');

    expect(find.text(libL10n.existsFmt('b')), findsOneWidget);
    // The error has no button; it goes as a tap outside it.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('a'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
  });

  testWidgets('an empty key is refused, not saved', (tester) async {
    await pump(tester);
    await edit(tester, key: '');

    expect(find.text(libL10n.empty), findsOneWidget);
    // The error has no button; it goes as a tap outside it.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('a'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
  });
}
