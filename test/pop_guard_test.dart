import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/generated/l10n/lib_l10n.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Pages are removed for the user — a pane switched, a pane closed — as well as
/// by back. Both have to ask a page with unsaved work first.
void main() {
  final navKey = GlobalKey<NavigatorState>();
  late List<String> asked;

  Widget guarded(String name, {required bool answer, bool enabled = true}) {
    return PopGuard(
      enabled: enabled,
      confirm: () async {
        asked.add(name);
        return answer;
      },
      child: Scaffold(body: Text(name)),
    );
  }

  Future<void> pumpApp(WidgetTester tester) async {
    asked = [];
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: Text('root')),
      ),
    );
  }

  Future<void> push(WidgetTester tester, Widget page, String name) async {
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => page,
        settings: RouteSettings(name: name),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('back asks, and a refusal stays', (tester) async {
    await pumpApp(tester);
    await push(tester, guarded('a', answer: false), 'a');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(asked, ['a']);
    expect(find.text('a'), findsOneWidget);
  });

  testWidgets('back leaves once agreed', (tester) async {
    await pumpApp(tester);
    await push(tester, guarded('a', answer: true), 'a');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(find.text('root'), findsOneWidget);
  });

  testWidgets('nothing to lose is not asked about', (tester) async {
    await pumpApp(tester);
    await push(tester, guarded('a', answer: false, enabled: false), 'a');

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(asked, isEmpty);
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets('popUntilGuarded asks the top first and keeps what it keeps', (
    tester,
  ) async {
    await pumpApp(tester);
    await push(tester, guarded('kept', answer: false), 'kept');
    await push(tester, guarded('lower', answer: true), 'lower');
    await push(tester, guarded('top', answer: true), 'top');

    final left = await navKey.currentState!.popUntilGuarded(
      (route) => route.isFirst || route.settings.name == 'kept',
    );
    await tester.pumpAndSettle();

    expect(left, isTrue);
    expect(asked, ['top', 'lower']);
    expect(find.text('kept'), findsOneWidget);
  });

  testWidgets('one refusal removes nothing', (tester) async {
    await pumpApp(tester);
    await push(tester, guarded('lower', answer: false), 'lower');
    await push(tester, guarded('top', answer: true), 'top');

    final left = await navKey.currentState!.popUntilGuarded(
      (route) => route.isFirst,
    );
    await tester.pumpAndSettle();

    expect(left, isFalse);
    expect(asked, ['top', 'lower']);
    expect(find.text('top'), findsOneWidget);
  });

  testWidgets('a page in a nested navigator goes with the route holding it', (
    tester,
  ) async {
    await pumpApp(tester);
    final inner = GlobalKey<NavigatorState>();
    await push(
      tester,
      Navigator(
        key: inner,
        onGenerateRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('pane')),
        ),
      ),
      'holder',
    );
    inner.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => guarded('inner', answer: false)),
    );
    await tester.pumpAndSettle();

    expect(await PopGuard.confirmLeave(navKey.currentState!), isFalse);
    expect(asked, ['inner']);

    // Its holder stays, and so does it: what is put away over the holder
    // does not ask a page it is not taking.
    asked.clear();
    expect(
      await PopGuard.confirmLeave(
        navKey.currentState!,
        stays: ModalRoute.withName('holder'),
      ),
      isTrue,
    );
    expect(asked, isEmpty);
  });

  Future<GlobalKey<NavigatorState>> pumpPane(
    WidgetTester tester, {
    required bool answer,
    required VoidCallback onClose,
  }) async {
    asked = [];
    final pane = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        home: PaneScope(
          navigatorKey: pane,
          split: true,
          closeDetail: onClose,
          child: Navigator(
            key: pane,
            onGenerateRoute: (_) => MaterialPageRoute<void>(
              builder: (_) => PopGuard(
                enabled: true,
                confirm: () async {
                  asked.add('detail');
                  return answer;
                },
                child: const Scaffold(appBar: CustomAppBar()),
              ),
            ),
          ),
        ),
      ),
    );
    return pane;
  }

  testWidgets('closing a pane asks what is in it', (tester) async {
    var closed = 0;
    await pumpPane(tester, answer: false, onClose: () => closed++);
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    expect(asked, ['detail']);
    expect(closed, 0);

    await pumpPane(tester, answer: true, onClose: () => closed++);
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    expect(closed, 1);
  });

  testWidgets('back at the root of a pane closes it rather than emptying it', (
    tester,
  ) async {
    var closed = 0;
    final pane = await pumpPane(tester, answer: true, onClose: () => closed++);
    // What `NestedNavigator` hands a back to.
    await pane.currentState!.maybePop();
    await tester.pump();
    expect(asked, ['detail']);
    expect(closed, 1);
    expect(pane.currentState!.canPop(), isFalse);
    expect(find.byType(CustomAppBar), findsOneWidget);
  });

  testWidgets('leave removes the pages that agreed and keeps the rest', (
    tester,
  ) async {
    await pumpApp(tester);
    await push(tester, guarded('dirty', answer: true), 'dirty');
    await push(tester, const Scaffold(body: Text('clean')), 'clean');

    expect(await PopGuard.leave(navKey.currentState!), isTrue);
    await tester.pumpAndSettle();

    expect(asked, ['dirty']);
    expect(find.text('dirty', skipOffstage: false), findsNothing);
    expect(find.text('clean'), findsOneWidget);
  });

  testWidgets('the plain editor asks only once something changed', (
    tester,
  ) async {
    await pumpApp(tester);
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        localizationsDelegates: const [LibLocalizations.delegate],
        home: const Scaffold(body: Text('root')),
      ),
    );
    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const PlainEditPage(
          args: PlainEditPageArgs(initialText: 'x'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('root'), findsOneWidget, reason: 'unchanged');

    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const PlainEditPage(
          args: PlainEditPageArgs(initialText: 'x'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'y');
    await tester.pump();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(PlainEditPage), findsOneWidget, reason: 'changed');
  });
}
