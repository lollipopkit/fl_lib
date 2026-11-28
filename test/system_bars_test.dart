import 'dart:ui';

import 'package:fl_lib/fl_lib.dart' show ScreenEdge, SystemBars;
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => SystemBars.debugBars = const {});

  test('SystemBars.debugBars notifies listeners', () {
    final listenable = SystemBars.watch(const {ScreenEdge.top: 44});
    var calls = 0;
    void listener() => calls++;
    listenable.addListener(listener);
    addTearDown(() => listenable.removeListener(listener));

    const rect = Rect.fromLTWH(10, 20, 300, 44);
    SystemBars.debugBars = const {ScreenEdge.top: rect};
    expect(listenable.value, const {ScreenEdge.top: rect});
    expect(calls, 1);
  });

  test('SystemBars.parseRaw filters non-finite and non-positive rects', () {
    final parsed = SystemBars.parseRaw({
      'top': [10, 20, 300, 44],
      'bottom': [0, 0, 0, 44],
      'left': [0, 0, -10, 200],
      'right': [double.infinity, 0, 44, 200],
    });
    expect(parsed, const {ScreenEdge.top: Rect.fromLTWH(10, 20, 300, 44)});
    expect(SystemBars.parseRaw(null), isEmpty);
  });
}
