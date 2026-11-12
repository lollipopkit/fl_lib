import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:window_manager/window_manager.dart';

part 'window_state.g.dart';

@JsonSerializable()
class WindowState {
  const WindowState(this.size, this.position);

  factory WindowState.fromJson(Map<String, dynamic> json) => _$WindowStateFromJson(json);

  @_SizeJsonConverter()
  final Size size;

  @_OffsetJsonConverter()
  final Offset position;

  Map<String, dynamic> toJson() => _$WindowStateToJson(this);
}

final class WindowStateListener extends WindowListener {
  final StoreProp<WindowState> windowSize;
  Future<void> _updateTail = Future.value();
  Timer? _pending;

  WindowStateListener(this.windowSize);

  Future<void> _updateState() {
    final update = _updateTail.then((_) async {
      // Only the normal bounds are restored: a minimized window on Windows is
      // at (-32000, -32000), a maximized one overhangs its display.
      if (await windowManager.isMinimized() ||
          await windowManager.isMaximized() ||
          await windowManager.isFullScreen()) {
        return;
      }
      final state = WindowState(
        await windowManager.getSize(),
        await windowManager.getPosition(),
      );
      await windowSize.set(state);
    });
    _updateTail = update.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return update;
  }

  // Saved once a drag has paused: Linux reports no end of one.
  void _updateLater() {
    _pending?.cancel();
    _pending = Timer(const Duration(milliseconds: 100), _updateState);
  }

  void _updateNow() {
    _pending?.cancel();
    _updateState();
  }

  @override
  void onWindowMove() => _updateLater();

  @override
  void onWindowResize() => _updateLater();

  // The end of a drag (Windows and macOS).
  @override
  void onWindowMoved() => _updateNow();

  @override
  void onWindowResized() => _updateNow();
}

class _SizeJsonConverter implements JsonConverter<Size, Map<String, dynamic>> {
  const _SizeJsonConverter();

  @override
  Size fromJson(Map<String, dynamic> json) {
    return Size(json['width'] as double, json['height'] as double);
  }

  @override
  Map<String, dynamic> toJson(Size object) {
    return {
      'width': object.width,
      'height': object.height,
    };
  }
}

class _OffsetJsonConverter implements JsonConverter<Offset, Map<String, dynamic>> {
  const _OffsetJsonConverter();

  @override
  Offset fromJson(Map<String, dynamic> json) {
    return Offset(json['dx'] as double, json['dy'] as double);
  }

  @override
  Map<String, dynamic> toJson(Offset object) {
    return {
      'dx': object.dx,
      'dy': object.dy,
    };
  }
}
