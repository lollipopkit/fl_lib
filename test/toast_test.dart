import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

Future<void> _show(WidgetTester tester, String title, {ToastAction? action, ThemeData? theme}) async {
  await tester.pumpWidget(
    MaterialApp(theme: theme, builder: (_, child) => ToastHost(child: child!), home: const SizedBox()),
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

  // Measured the way the button paints its label: a title that fits beside
  // the button with the default style does not beside a wider one, and has
  // to be openable there.
  testWidgets("the button's own text style decides where the title ends", (tester) async {
    const title = 'Twelve chars';
    await _show(tester, title, action: action);
    expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing, reason: 'fits beside the button');

    Toast.dismissAll();
    await _show(
      tester,
      title,
      action: action,
      theme: ThemeData(
        textButtonTheme: const TextButtonThemeData(
          style: ButtonStyle(textStyle: WidgetStatePropertyAll(TextStyle(letterSpacing: 20))),
        ),
      ),
    );
    expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget, reason: 'the spaced label leaves it no room');
  });
}
