import 'dart:ui' show Tristate;

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// What a screen reader is told about the buttons this library draws itself.
///
/// A [Btn] other than text or elevated is an [InkWell], which gives a reader a
/// tap action and nothing else: an icon-only one was read as its tooltip with
/// no word that it is a button, and one without a tooltip as nothing at all.
void main() {
  Future<void> pump(WidgetTester tester, Widget child) => tester.pumpWidget(
    MaterialApp(home: Scaffold(body: Center(child: child))),
  );

  testWidgets('an icon button is a button named by its text', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      Btn.icon(text: 'Delete', icon: const Icon(Icons.delete), onTap: () {}),
    );

    final node = tester.getSemantics(find.byType(Btn));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isEnabled, Tristate.isTrue);
    expect(node.tooltip, 'Delete');
    handle.dispose();
  });

  testWidgets('a row button is a button', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      Btn.row(text: 'Open', icon: const Icon(Icons.open_in_new), onTap: () {}),
    );

    final node = tester.getSemantics(find.byType(Btn));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.label, 'Open');
    handle.dispose();
  });

  testWidgets('a disabled one says so', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      const Btn.icon(text: 'Delete', icon: Icon(Icons.delete), onTap: null),
    );

    final node = tester.getSemantics(find.byType(Btn));
    expect(node.flagsCollection.isButton, isTrue);
    expect(node.flagsCollection.isEnabled, Tristate.isFalse);
    handle.dispose();
  });

  testWidgets('a password field\'s eye says what it does and whether it is on', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(
      tester,
      Input(controller: TextEditingController(), obscureText: true),
    );

    final eye = find.byType(IconButton);
    expect(tester.widget<IconButton>(eye).tooltip, libL10n.showPwd);
    expect(tester.widget<IconButton>(eye).isSelected, isFalse);

    await tester.tap(eye);
    await tester.pump();
    expect(tester.widget<IconButton>(eye).isSelected, isTrue);
    handle.dispose();
  });
}
