import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// An [Input] whose parent changes [Input.obscureText] follows it.
///
/// The state read it once, so a field that stopped being a password went on
/// masking what was typed into it.
void main() {
  Future<void> pump(WidgetTester tester, {required bool obscure}) =>
      tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Input(
              controller: TextEditingController(text: 'secret'),
              obscureText: obscure,
            ),
          ),
        ),
      );

  bool masked(WidgetTester tester) =>
      tester.widget<TextField>(find.byType(TextField)).obscureText;

  testWidgets('obscureText is followed after the first build', (tester) async {
    await pump(tester, obscure: true);
    expect(masked(tester), isTrue);

    await pump(tester, obscure: false);
    expect(masked(tester), isFalse);

    await pump(tester, obscure: true);
    expect(masked(tester), isTrue);
  });

  group('onReveal', () {
    Future<void> pumpGuarded(
      WidgetTester tester,
      Future<bool> Function() onReveal,
    ) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Input(
            controller: TextEditingController(text: 'secret'),
            obscureText: true,
            onReveal: onReveal,
          ),
        ),
      ),
    );

    Future<void> tapEye(WidgetTester tester) async {
      await tester.tap(find.byType(IconButton));
      await tester.pump();
    }

    testWidgets('a refusal keeps the value hidden', (tester) async {
      var asked = 0;
      await pumpGuarded(tester, () async {
        asked++;
        return false;
      });
      await tapEye(tester);
      expect(asked, 1);
      expect(masked(tester), isTrue);
    });

    testWidgets('a pass shows it; hiding it again is not asked', (
      tester,
    ) async {
      var asked = 0;
      await pumpGuarded(tester, () async {
        asked++;
        return true;
      });
      await tapEye(tester);
      expect(masked(tester), isFalse);
      await tapEye(tester);
      expect(masked(tester), isTrue);
      expect(asked, 1);
    });
  });
}
