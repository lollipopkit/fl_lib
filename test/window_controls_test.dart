import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  // What a 430pt-wide iPad window reported: the controls at the top left,
  // and the rounded corner at the top right.
  const zones = [
    Rect.fromLTRB(0, 0, 66, 53),
    Rect.fromLTRB(420.5, 0, 430, 53),
  ];

  setUp(() => WindowControls.zones.value = const []);
  tearDown(() => WindowControls.zones.value = const []);

  Future<void> pump(WidgetTester tester, Widget home) async {
    tester.view.physicalSize = const Size(430, 614);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: home));
    // One frame to be laid out and measured, one to take the padding.
    await tester.pump();
  }

  double leftOf(WidgetTester tester, Finder f) => tester.getTopLeft(f).dx;

  testWidgets('a bar under the controls moves its leading past them', (
    tester,
  ) async {
    WindowControls.zones.value = zones;
    await pump(
      tester,
      const Scaffold(
        appBar: CustomAppBar(leading: BackButton(), title: Text('t')),
      ),
    );
    expect(leftOf(tester, find.byType(BackButton)), greaterThanOrEqualTo(66));
  });

  testWidgets('nothing moves without zones', (tester) async {
    await pump(
      tester,
      const Scaffold(
        appBar: CustomAppBar(leading: BackButton(), title: Text('t')),
      ),
    );
    expect(leftOf(tester, find.byType(BackButton)), lessThan(66));
  });

  testWidgets('zones arriving later move a bar already on screen', (
    tester,
  ) async {
    await pump(
      tester,
      const Scaffold(
        appBar: CustomAppBar(leading: BackButton(), title: Text('t')),
      ),
    );
    WindowControls.zones.value = zones;
    await tester.pump();
    await tester.pump();
    expect(leftOf(tester, find.byType(BackButton)), greaterThanOrEqualTo(66));
  });

  testWidgets('a bar beside the controls is left where it is', (tester) async {
    WindowControls.zones.value = zones;
    await pump(
      tester,
      const Row(
        children: [
          SizedBox(width: 200),
          Expanded(
            child: Scaffold(
              appBar: CustomAppBar(leading: BackButton(), title: Text('t')),
            ),
          ),
        ],
      ),
    );
    // Only the button's own inset from the bar's edge, nothing for the zone.
    expect(leftOf(tester, find.byType(BackButton)), lessThan(200 + 66));
  });

  testWidgets('a bar below the status bar padding has nothing to clear', (
    tester,
  ) async {
    WindowControls.zones.value = zones;
    await pump(
      tester,
      const MediaQuery(
        data: MediaQueryData(
          size: Size(430, 614),
          padding: EdgeInsets.only(top: 60),
        ),
        child: Scaffold(
          appBar: CustomAppBar(leading: BackButton(), title: Text('t')),
        ),
      ),
    );
    expect(leftOf(tester, find.byType(BackButton)), lessThan(66));
  });

  testWidgets('vertically, a column under the controls starts below them', (
    tester,
  ) async {
    WindowControls.zones.value = zones;
    await pump(
      tester,
      const Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 80,
          height: 400,
          child: WindowControlsInset(
            axis: Axis.vertical,
            child: SafeArea(child: Text('first', key: Key('first'))),
          ),
        ),
      ),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('first'))).dy,
      greaterThanOrEqualTo(53),
    );
  });
}
