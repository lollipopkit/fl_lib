import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// [SessionTabBar.sessionMenu]: rows behind the last button while a session
/// is open, and none on the leading tab.
void main() {
  Future<void> pump(WidgetTester tester, {required int index}) =>
      tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const [LibLocalizations.delegate],
          supportedLocales: LibLocalizations.supportedLocales,
          home: Scaffold(
            appBar: SessionTabBar(
              names: const ['+', 'pve'],
              index: index,
              onTap: (_) {},
              onClose: (_) {},
              sessionActions: [
                BarAction(icon: Icons.code, label: 'Snippet', onTap: () {}),
              ],
              leadingActions: const [],
              sessionMenu: () => [
                ContextMenuAction(text: 'As text', onTap: () {}),
              ],
            ),
          ),
        ),
      );

  testWidgets('a session puts its menu rows behind the last button', (
    tester,
  ) async {
    await pump(tester, index: 1);
    expect(find.byTooltip('Snippet'), findsOneWidget);
    expect(find.text('As text'), findsNothing);

    await tester.tap(find.byIcon(Icons.more_vert));
    await tester.pumpAndSettle();
    expect(find.text('As text'), findsOneWidget);
  });

  testWidgets('the leading tab has no session menu', (tester) async {
    await pump(tester, index: 0);
    expect(find.byIcon(Icons.more_vert), findsNothing);
  });
}
