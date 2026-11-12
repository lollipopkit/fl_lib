import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// `SheetScaffold.rows`, what `showRowsSheet` raises.
void main() {
  Future<BuildContext> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late BuildContext ctx;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    return ctx;
  }

  Future<void> step(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  const keys = ['tile', 'choice', 'switch', 'plain', 'divider'];

  List<Widget> rows(BuildContext ctx) => [
    ListTile(key: const Key('tile'), title: const Text('tile'), onTap: () {}),
    SheetChoiceTile(
      key: const Key('choice'),
      title: 'choice',
      subtitle: 'detail',
      icon: Icons.star,
      selected: true,
      onTap: () {},
    ),
    SwitchListTile(
      key: const Key('switch'),
      title: const Text('switch'),
      value: true,
      onChanged: (_) {},
    ),
    const Text('plain', key: Key('plain')),
    const Divider(key: Key('divider')),
  ];

  /// Every row's rect, every text's style, and where the arrows go.
  Future<List<Object?>> measure(WidgetTester tester) async {
    final out = <Object?>[];
    for (final key in keys) {
      out.add(tester.getRect(find.byKey(Key(key))));
    }
    for (final text in ['tile', 'choice', 'detail', 'switch', 'plain']) {
      final found = find.text(text);
      out.add(DefaultTextStyle.of(tester.element(found)).style);
      out.add(tester.renderObject<RenderParagraph>(found).text.style);
      out.add(tester.getRect(found));
    }
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      final focused = FocusManager.instance.primaryFocus!.context!;
      out.add((focused.findRenderObject()! as RenderBox).localToGlobal(Offset.zero));
    }
    return out;
  }

  testWidgets('with no title or actions, rows lay out as a bare rows sheet did', (
    tester,
  ) async {
    final ctx = await pump(tester);
    showResizableSheet<void>(ctx, builder: (c) => _BareRowsSheet(children: rows(c)));
    await step(tester);
    final before = await measure(tester);
    ctx.popSheet();
    await step(tester);

    showRowsSheet<void>(ctx, rows: rows);
    await step(tester);
    expect(find.byType(SheetScaffold), findsOneWidget);
    final after = await measure(tester);
    expect(after, before);
  });

  testWidgets('a title above the rows at the start, actions under them at the end', (
    tester,
  ) async {
    final ctx = await pump(tester);
    showRowsSheet<void>(
      ctx,
      title: 'servers',
      rows: (c) => [
        for (var i = 0; i < 3; i++) ListTile(title: Text('row $i'), onTap: () {}),
      ],
      actions: (c) => [TextButton(onPressed: () {}, child: Text(libL10n.ok))],
    );
    await step(tester);

    final sheet = tester.getRect(find.byType(SheetScaffold));
    final title = tester.getRect(find.text('servers'));
    final first = tester.getRect(find.widgetWithText(ListTile, 'row 0'));
    final last = tester.getRect(find.widgetWithText(ListTile, 'row 2'));
    final ok = tester.getRect(find.widgetWithText(TextButton, libL10n.ok));
    expect(title.bottom, lessThanOrEqualTo(first.top));
    expect(title.left, sheet.left + SheetScaffold.defaultTitlePadding.left);
    expect(ok.top, greaterThanOrEqualTo(last.bottom));
    expect(ok.left, greaterThan(sheet.center.dx));
    expect(
      find.descendant(of: find.byType(SingleChildScrollView), matching: find.text('servers')),
      findsNothing,
    );

    // The arrows step from the last row on to the actions.
    for (var i = 0; i < 4; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
    }
    expect(
      FocusManager.instance.primaryFocus!.context!.findAncestorWidgetOfExactType<TextButton>(),
      isNotNull,
    );
  });
}

/// The rows sheet as it was before [SheetScaffold.rows], kept to hold the
/// layout to.
class _BareRowsSheet extends StatelessWidget {
  const _BareRowsSheet({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        _RowTraversalActivator(LogicalKeyboardKey.arrowDown): NextFocusIntent(),
        _RowTraversalActivator(LogicalKeyboardKey.arrowUp): PreviousFocusIntent(),
      },
      child: FocusTraversalGroup(
        policy: WidgetOrderTraversalPolicy(),
        child: FocusScope(
          autofocus: true,
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ListTileTheme.merge(
                    visualDensity: VisualDensity.compact,
                    minVerticalPadding: 4,
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Column(mainAxisSize: MainAxisSize.min, children: children),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _RowTraversalActivator extends SingleActivator {
  const _RowTraversalActivator(super.trigger);

  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    final editor = FocusManager.instance.primaryFocus?.context
        ?.findAncestorWidgetOfExactType<EditableText>();
    return editor == null && super.accepts(event, state);
  }
}
