import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _show(WidgetTester tester, String title, {ToastAction? action}) async {
  await tester.pumpWidget(
    MaterialApp(builder: (_, child) => ToastHost(child: child!), home: const SizedBox()),
  );
  Toast.show(title, action: action, duration: Duration.zero);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  tearDown(Toast.dismissAll);

  final long = 'A title far too long for one line of a toast, ' * 3;
  final action = ToastAction(label: 'Configure', onTap: () {});

  testWidgets('a title too long for one line can be opened', (tester) async {
    await _show(tester, long);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
  });

  testWidgets('and still can with an action button beside it', (tester) async {
    await _show(tester, long, action: action);
    expect(find.text('Configure'), findsOneWidget);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
  });

  testWidgets('a short one has nothing to open, action or not', (tester) async {
    await _show(tester, 'Saved', action: action);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);
  });
}
