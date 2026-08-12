import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands for whatever the surface holds that cannot simply be rebuilt — a
/// terminal with a connection behind it. Counts its own lifetimes, so a test
/// can say whether it was torn down.
class _Session extends StatefulWidget {
  const _Session();

  static int inits = 0;
  static int disposals = 0;

  @override
  State<_Session> createState() => _SessionState();
}

class _SessionState extends State<_Session> {
  int _taps = 0;

  @override
  void initState() {
    super.initState();
    _Session.inits++;
  }

  @override
  void dispose() {
    _Session.disposals++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => setState(() => _taps++),
      child: Text('taps $_taps'),
    );
  }
}

const _sideKey = ValueKey('side');
const _mainKey = ValueKey('main');

/// The divider, found by the only thing that is uniquely true of it.
final _divider = find.byWidgetPredicate(
  (w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn,
);

void main() {
  setUp(() {
    _Session.inits = 0;
    _Session.disposals = 0;
  });

  /// Lays the widget out at a real window width.
  ///
  /// Not a `SizedBox` inside the default 800x600 surface: the point of most of
  /// these is what happens above and below a breakpoint, and a box wider than
  /// the surface is silently the surface's width.
  Future<void> pumpAt(
    WidgetTester tester, {
    required double width,
    bool enabled = true,
    double minWidthForSide = 800,
    double sideWidth = 320,
    ValueChanged<double>? onSideWidthChanged,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AdaptiveSideList(
            enabled: enabled,
            minWidthForSide: minWidthForSide,
            sideWidth: sideWidth,
            onSideWidthChanged: onSideWidthChanged,
            sideBuilder: (_) => const ColoredBox(
              key: _sideKey,
              color: Colors.transparent,
              child: Center(child: Text('list')),
            ),
            builder: (_, split) => ColoredBox(
              key: _mainKey,
              color: Colors.transparent,
              child: Column(
                children: [
                  Text(split ? 'folded out' : 'folded in'),
                  const _Session(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a narrow window folds the list away', (tester) async {
    await pumpAt(tester, width: 700);

    expect(find.text('list'), findsNothing);
    expect(
      find.text('folded in'),
      findsOneWidget,
      reason: 'the surface is told to find somewhere else for the list',
    );
    expect(tester.getSize(find.byKey(_mainKey)).width, 700);
  });

  testWidgets('a wide window gives the list a column', (tester) async {
    await pumpAt(tester, width: 1000);

    expect(find.text('list'), findsOneWidget);
    expect(find.text('folded out'), findsOneWidget);
    expect(tester.getSize(find.byKey(_sideKey)).width, 320);
  });

  testWidgets('disabled keeps one column at any width', (tester) async {
    await pumpAt(tester, width: 1400, enabled: false);

    expect(find.text('list'), findsNothing);
    expect(find.text('folded in'), findsOneWidget);
  });

  testWidgets('the surface survives the layout changing', (tester) async {
    await pumpAt(tester, width: 700);
    await tester.tap(find.text('taps 0'));
    await tester.pump();
    expect(find.text('taps 1'), findsOneWidget);

    await pumpAt(tester, width: 1000);
    await tester.pump();

    expect(
      find.text('taps 1'),
      findsOneWidget,
      reason: 'a column appearing beside it must not restart what it holds',
    );
    expect(_Session.disposals, 0);
    expect(_Session.inits, 1);

    await pumpAt(tester, width: 700);
    await tester.pump();

    expect(find.text('taps 1'), findsOneWidget);
    expect(_Session.disposals, 0, reason: 'nor must the column going away');
    expect(_Session.inits, 1);
  });

  testWidgets('dragging the divider resizes the list and reports once', (
    tester,
  ) async {
    final reported = <double>[];
    await pumpAt(tester, width: 1000, sideWidth: 300, onSideWidthChanged: reported.add);

    await tester.drag(_divider, const Offset(60, 0));
    await tester.pump();

    expect(tester.getSize(find.byKey(_sideKey)).width, closeTo(360, 0.01));
    expect(reported, hasLength(1), reason: 'at the end, not once per frame');
    expect(reported.single, closeTo(360, 0.01));
  });

  testWidgets('the list cannot take more than half the width', (tester) async {
    await pumpAt(tester, width: 900, sideWidth: 800);

    expect(tester.getSize(find.byKey(_sideKey)).width, 450);
  });

  testWidgets('a wider start than the range allows is clamped down', (
    tester,
  ) async {
    await pumpAt(tester, width: 2000, sideWidth: 900);

    expect(
      tester.getSize(find.byKey(_sideKey)).width,
      520,
      reason: 'maxSideWidth still applies when half the window is more',
    );
  });
}
