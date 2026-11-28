import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'base.dart';

/// An edge of the app's view.
enum ScreenEdge { left, top, right, bottom }

/// Where the system puts a bar along each edge of the app's view, in logical
/// pixels: clear of rounded corners, camera housings and the status bar,
/// centred on the line the status bar icons and cameras sit on.
///
/// From iOS 27.1+ bar layout regions; empty elsewhere, where the safe area
/// is all there is. Holds a single app-wide watched edge-thickness map: a new
/// [watch] call with different extents replaces the previous configuration.
abstract final class SystemBars {
  static const _channel = MethodChannel('fl_lib/system_bars');
  static const _maxRetries = 10;
  static final _bars = ValueNotifier<Map<ScreenEdge, Rect>>(const {});
  static Map<String, double>? _extents;
  static int _token = 0;

  /// The area for a bar of each given thickness on those edges, updated on
  /// rotation, folding and the like.
  static ValueListenable<Map<ScreenEdge, Rect>> watch(
    Map<ScreenEdge, double> extents,
  ) {
    final named = {for (final e in extents.entries) e.key.name: e.value};
    if (isIOS && !mapEquals(named, _extents)) {
      _startWatch(named, 0);
    }
    return _bars;
  }

  static void _startWatch(Map<String, double> named, int attempt) {
    _extents = named;
    final token = ++_token;
    _channel.setMethodCallHandler((call) async {
      if (token == _token && call.method == 'changed') {
        _bars.value = _parse(call.arguments);
      }
    });
    _channel
        .invokeMethod<Object?>('watch', named)
        .then(
          (r) {
            if (token != _token) return;
            _bars.value = _parse(r);
          },
          onError: (Object e) {
            if (token != _token) return;
            debugPrint('SystemBars: $e');
            if (e is PlatformException &&
                e.code == 'no_view' &&
                attempt < _maxRetries) {
              _extents = null;
              SchedulerBinding.instance.addPostFrameCallback((_) {
                if (token == _token) _startWatch(named, attempt + 1);
              });
            }
          },
        );
  }

  /// Stands in for the system's bars, as on a device that reports them.
  @visibleForTesting
  static set debugBars(Map<ScreenEdge, Rect> bars) => _bars.value = bars;

  @visibleForTesting
  static Map<ScreenEdge, Rect> parseRaw(Object? raw) => _parse(raw);

  static Map<ScreenEdge, Rect> _parse(Object? raw) {
    if (raw is! Map) return const {};
    final out = <ScreenEdge, Rect>{};
    for (final e in ScreenEdge.values) {
      if (raw[e.name] case [
        final num l,
        final num t,
        final num w,
        final num h,
      ]) {
        final ld = l.toDouble();
        final td = t.toDouble();
        final wd = w.toDouble();
        final hd = h.toDouble();
        if (ld.isFinite &&
            td.isFinite &&
            wd.isFinite &&
            hd.isFinite &&
            wd > 0 &&
            hd > 0) {
          out[e] = Rect.fromLTWH(ld, td, wd, hd);
        }
      }
    }
    return out;
  }
}
