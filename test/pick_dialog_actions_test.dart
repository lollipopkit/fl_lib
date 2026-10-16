import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// [showPickDialog] adds its OK to a list of its own.
///
/// It appended to the caller's: a list kept for the next call grew an OK each
/// time, and a const one threw before the dialog opened.
void main() {
  testWidgets('the caller\'s actions are left as they were', (tester) async {
    final actions = <Widget>[const Text('extra')];
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            ctx = context;
            return const SizedBox();
          },
        ),
      ),
    );

    for (final list in [actions, const <Widget>[]]) {
      final picked = ctx.showPickDialog<String>(
        items: const ['a'],
        initial: const ['a'],
        actions: list,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      // The one OK there is, and it is the one that answers and closes.
      await tester.tap(find.text(libL10n.ok));
      await tester.pumpAndSettle();
      expect(await picked, ['a']);
      expect(find.text(libL10n.ok), findsNothing);
    }
    expect(actions, hasLength(1));
  });
}
