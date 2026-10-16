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
      ctx.showPickDialog<String>(items: const ['a'], actions: list);
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
      expect(find.text(libL10n.ok), findsOneWidget);
      Navigator.of(ctx, rootNavigator: true).pop();
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(actions, hasLength(1));
  });
}
