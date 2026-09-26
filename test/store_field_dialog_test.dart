import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const prop = PrefPropDefault<String>('store_field_dialog_test', 'old');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await PrefStore.shared.init();
  });

  testWidgets('the edit dialog still closes after its field is gone', (
    tester,
  ) async {
    // The settings page can close under the dialog. Its buttons read the
    // field's context when pressed, which by then failed a null check.
    final showField = ValueNotifier(true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ValueListenableBuilder(
            valueListenable: showField,
            builder: (_, show, _) => show
                ? const StoreField<String>(prop: prop, label: 'Name')
                : const SizedBox(),
          ),
        ),
      ),
    );

    await tester.tap(find.text('old'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);

    showField.value = false;
    await tester.pump();
    await tester.enterText(find.byType(TextField), 'new');
    await tester.tap(find.text(libL10n.ok));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(prop.get(), 'new', reason: 'what was typed is still saved');
    // The controller outlives the dialog by a few seconds on purpose.
    await tester.pump(const Duration(seconds: 3));
  });
}
