import 'dart:ui';

import 'package:fl_lib/src/core/utils/window_placement.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // A laptop at 1920x1032 usable (taskbar below).
  const laptop = WindowDisplay(Rect.fromLTWH(0, 0, 1920, 1032));
  const size = Size(1000, 700);

  WindowPlacement place(Offset? position, List<WindowDisplay> displays,
          {Size? saved = size, WindowDisplay? primary}) =>
      placeWindow(size: saved, position: position, displays: displays, primary: primary ?? laptop);

  const centered = WindowPlacement(size: size, position: Offset(460, 166));

  test('kept on the only display', () {
    expect(
      place(const Offset(100, 80), [laptop]),
      const WindowPlacement(size: size, position: Offset(100, 80)),
    );
  });

  group('second display still connected', () {
    test('to the right', () {
      const right = WindowDisplay(Rect.fromLTWH(1920, 0, 2560, 1400));
      expect(
        place(const Offset(2500, 200), [laptop, right]),
        const WindowPlacement(size: size, position: Offset(2500, 200)),
      );
    });

    test('to the left and above, negative coordinates', () {
      const leftAbove = WindowDisplay(Rect.fromLTWH(-2560, -1400, 2560, 1400));
      expect(
        place(const Offset(-2000, -1200), [laptop, leftAbove]),
        const WindowPlacement(size: size, position: Offset(-2000, -1200)),
      );
    });

    test('at another scale (Windows): converted to the window space', () {
      // A 100 % display right of a 150 % laptop (1920 physical pixels wide),
      // the window starting on the laptop.
      const external = WindowDisplay(Rect.fromLTWH(1920, 0, 1920, 1040), scale: 1 / 1.5);
      const hiDpiLaptop = WindowDisplay(Rect.fromLTWH(0, 0, 1280, 688));
      expect(
        place(const Offset(2220, 300), [hiDpiLaptop, external], primary: hiDpiLaptop),
        WindowPlacement(size: size, position: const Offset(2220, 300) / 1.5),
      );
    });
  });

  test('second display gone: centered on the primary', () {
    expect(place(const Offset(2500, 200), [laptop]), centered);
    expect(place(const Offset(-2000, -1200), [laptop]), centered);
  });

  test('saved while minimized (Windows)', () {
    expect(place(const Offset(-32000, -32000), [laptop]), centered);
  });

  group('title strip at an edge', () {
    test('too little width left on screen', () {
      expect(place(const Offset(1850, 100), [laptop]), centered);
      expect(place(const Offset(-930, 100), [laptop]), centered);
    });

    test('enough width left on screen', () {
      expect(
        place(const Offset(1700, 100), [laptop]),
        const WindowPlacement(size: size, position: Offset(1700, 100)),
      );
    });

    test('title above the top or under the taskbar', () {
      expect(place(const Offset(100, -20), [laptop]), centered);
      expect(place(const Offset(100, 1020), [laptop]), centered);
    });

    test('title partly above the top, still draggable', () {
      expect(
        place(const Offset(100, -8), [laptop]),
        const WindowPlacement(size: size, position: Offset(100, -8)),
      );
    });

    test('a window narrower than the minimum width', () {
      const narrow = Size(100, 400);
      expect(
        place(const Offset(1820, 100), [laptop], saved: narrow),
        const WindowPlacement(size: narrow, position: Offset(1820, 100)),
      );
    });
  });

  group('oversized saved size', () {
    test('clamped to the primary when centered', () {
      expect(
        place(const Offset(2500, 200), [laptop], saved: const Size(2560, 1400)),
        const WindowPlacement(size: Size(1920, 1032), position: Offset.zero),
      );
    });

    test('clamped to the display it stays on', () {
      expect(
        place(const Offset(100, 80), [laptop], saved: const Size(2560, 900)),
        const WindowPlacement(size: Size(1920, 900), position: Offset(100, 80)),
      );
    });
  });

  test('no displays: saved values as they are', () {
    expect(
      place(const Offset(-32000, -32000), []),
      const WindowPlacement(size: size, position: Offset(-32000, -32000)),
    );
  });

  group('partial saved state', () {
    test('no size: kept when on a display, else left to the system', () {
      expect(
        place(const Offset(100, 80), [laptop], saved: null),
        const WindowPlacement(position: Offset(100, 80)),
      );
      expect(place(const Offset(2500, 80), [laptop], saved: null), const WindowPlacement());
    });

    test('no position: centered and clamped', () {
      expect(place(null, [laptop]), centered);
    });

    test('without a primary, the first display', () {
      expect(
        placeWindow(size: size, position: const Offset(5000, 0), displays: const [laptop]),
        centered,
      );
    });
  });
}
