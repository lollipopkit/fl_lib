import 'package:fl_lib/theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// No platform moves a page with Cupertino's transition: iOS and macOS, whose
/// Flutter default it is, get the predictive back driven by an edge swipe.
void main() {
  bool isCupertino(Widget w) => w.runtimeType.toString().startsWith('CupertinoPage');

  for (final platform in TargetPlatform.values) {
    testWidgets('no Cupertino transition on ${platform.name}', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          theme: ThemeData(platform: platform, pageTransitionsTheme: AppPageTransitions.plain),
          home: const Text('below'),
        ),
      );
      nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('arriving')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byWidgetPredicate(isCupertino), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byWidgetPredicate(isCupertino), findsNothing);
    });
  }

  for (final platform in [TargetPlatform.iOS, TargetPlatform.macOS]) {
    testWidgets('a swipe from the left edge goes back on ${platform.name}', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          theme: ThemeData(platform: platform, pageTransitionsTheme: AppPageTransitions.plain),
          home: const Scaffold(body: Text('below')),
        ),
      );
      nav.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Center(child: Text('arriving')))),
      );
      await tester.pumpAndSettle();

      final g = await tester.startGesture(const Offset(5, 300));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(40, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await g.up();
      await tester.pumpAndSettle();
      expect(find.text('arriving'), findsNothing);
      expect(find.text('below'), findsOneWidget);
    });
  }

  testWidgets(
    "a page's copy of the background is not built again as Android's back gesture starts and ends",
    (tester) async {
      ThemePackages.preview.value = _gradient;
      addTearDown(() => ThemePackages.preview.value = null);
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          theme: ThemeData(
            platform: TargetPlatform.android,
            pageTransitionsTheme: AppPageTransitions.backgrounded,
          ),
          home: const Text('below'),
        ),
      );
      nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('arriving')));
      await tester.pumpAndSettle();

      final copy = find.ancestor(of: find.text('arriving'), matching: find.byType(AppBackground));
      final before = tester.element(copy);

      Future<void> send(String method, [Map<String, Object?>? args]) =>
          tester.binding.defaultBinaryMessenger.handlePlatformMessage(
            SystemChannels.backGesture.name,
            SystemChannels.backGesture.codec.encodeMethodCall(MethodCall(method, args)),
            (_) {},
          );
      Map<String, Object?> at(double progress) => {
        'touchOffset': [5.0, 300.0],
        'progress': progress,
        'swipeEdge': 0,
      };
      await send('startBackGesture', at(0));
      await send('updateBackGestureProgress', at(0.3));
      await tester.pump();
      expect(tester.element(copy), same(before));

      await send('cancelBackGesture');
      await tester.pumpAndSettle();
      expect(tester.element(copy), same(before));
    },
  );

  testWidgets("a page in a pane has the window's background, not one fitted to the pane", (tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    ThemePackages.preview.value = _gradient;
    addTearDown(() => ThemePackages.preview.value = null);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(pageTransitionsTheme: AppPageTransitions.backgrounded),
        builder: (_, child) => AppBackground(child: child!),
        home: Row(
          children: [
            const SizedBox(width: 300),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 50),
                child: Navigator(
                  key: nav,
                  onGenerateRoute: (_) => MaterialPageRoute<void>(builder: (_) => const Text('pane')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('arriving')));
    await tester.pumpAndSettle();

    final page = find.ancestor(of: find.text('arriving'), matching: find.byType(AppBackground));
    final copy = find.descendant(of: page.first, matching: find.byType(BackgroundLayer));
    expect(tester.getRect(page.first), const Rect.fromLTWH(300, 50, 500, 550));
    expect(tester.getRect(copy.first), const Rect.fromLTWH(0, 0, 800, 600));
  });

  testWidgets("a page keeps its copy of the background on the frame a back gesture commits", (tester) async {
    ThemePackages.preview.value = _gradient;
    addTearDown(() => ThemePackages.preview.value = null);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: nav,
        theme: ThemeData(
          platform: TargetPlatform.android,
          pageTransitionsTheme: AppPageTransitions.backgrounded,
        ),
        home: const Text('below'),
      ),
    );
    nav.currentState!.push(MaterialPageRoute<void>(builder: (_) => const Text('arriving')));
    await tester.pumpAndSettle();

    final copy = find.descendant(
      of: find.ancestor(of: find.text('arriving'), matching: find.byType(AppBackground)).first,
      matching: find.byType(Opacity),
    );
    double shown() => tester.widget<Opacity>(copy.first).opacity;
    expect(shown(), 0, reason: 'at rest');

    Future<void> send(String method, [Map<String, Object?>? args]) =>
        tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          SystemChannels.backGesture.name,
          SystemChannels.backGesture.codec.encodeMethodCall(MethodCall(method, args)),
          (_) {},
        );
    Map<String, Object?> at(double progress) => {
      'touchOffset': [5.0, 300.0],
      'progress': progress,
      'swipeEdge': 0,
    };
    await send('startBackGesture', at(0));
    await send('updateBackGestureProgress', at(0.4));
    await tester.pump();
    expect(shown(), 1);

    // The route restarts its pop from fully shown: a value of 1 again, for a
    // frame, on a page that is leaving.
    await send('commitBackGesture');
    await tester.pump();
    expect(shown(), 1);
    await tester.pump(const Duration(milliseconds: 16));
    expect(shown(), 1);
    await tester.pumpAndSettle();
  });
}

const _gradient = ThemePackage(
  installationId: '',
  id: 'test.gradient',
  name: 'Gradient',
  schemaMin: 3,
  schemaMax: 3,
  mode: 0,
  modes: {ThemeMode.light},
  seed: 0xFFFF80AB,
  systemColor: false,
  paletteLight: {},
  paletteDark: {},
  iconStyle: IconStyle.classic,
  iconFiles: {},
  backgroundStyle: BackgroundStyle.gradient,
  backgroundFile: null,
  backgroundTile: 0,
  opacity: 0.3,
  blur: 0,
  cardRadius: 12,
  tileRadius: 8,
  buttonRadius: 10,
  directory: '',
);
