import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Paste from a Flutter-drawn menu reads the clipboard itself, which iOS
/// answers with a permission prompt; the system menu's paste does not.
void main() {
  Future<Widget> menuOf(WidgetTester tester, {required bool system}) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(supportsShowingSystemContextMenu: system),
          child: const Scaffold(body: Input(autoFocus: true)),
        ),
      ),
    );
    await tester.pump();
    final field = tester.widget<TextField>(find.byType(TextField));
    final state = tester.state<EditableTextState>(find.byType(EditableText));
    return field.contextMenuBuilder!(state.context, state);
  }

  testWidgets('iOS uses the system menu', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      expect(await menuOf(tester, system: true), isA<SystemContextMenu>());
      expect(
        await menuOf(tester, system: false),
        isA<AdaptiveTextSelectionToolbar>(),
      );
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('other platforms keep the Flutter menu', (tester) async {
    expect(
      await menuOf(tester, system: true),
      isA<AdaptiveTextSelectionToolbar>(),
    );
  });
}
