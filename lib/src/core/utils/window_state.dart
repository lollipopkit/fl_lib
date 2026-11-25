import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';
import 'package:json_annotation/json_annotation.dart';
import 'package:window_manager/window_manager.dart';

part 'window_state.g.dart';

@JsonSerializable()
class WindowState {
  const WindowState(this.size, this.position);

  factory WindowState.fromJson(Map<String, dynamic> json) =>
      _$WindowStateFromJson(json);

  @_SizeJsonConverter()
  final Size size;

  @_OffsetJsonConverter()
  final Offset position;

  Map<String, dynamic> toJson() => _$WindowStateToJson(this);
}

final class WindowStateListener {
  final StoreProp<WindowState> windowSize;
  Future<void> _updateTail = Future.value();
  Timer? _pending;
  Window? _window;
  ListenerId? _listenerId;

  WindowStateListener(this.windowSize);

  /// Starts recording bounds changes on [window]. Detaches any previous one.
  void attach(Window window) {
    detach();
    final id = window.addListener(_onEvent);
    _window = window;
    _listenerId = id;
  }

  /// Stops recording bounds changes.
  void detach() {
    _pending?.cancel();
    _pending = null;
    final id = _listenerId;
    final window = _window;
    _listenerId = null;
    _window = null;
    if (id != null && window != null) {
      window.removeListener(id);
    }
  }

  void _onEvent(WindowEvent event) {
    switch (event) {
      case WindowMovedEvent():
      case WindowResizedEvent():
        _updateLater();
      case WindowCloseRequestedEvent():
        if (_pending?.isActive ?? false) {
          _pending?.cancel();
          _pending = null;
          _updateState();
        }
      case WindowClosedEvent():
        detach();
      default:
        break;
    }
  }

  Future<void> _updateState() {
    final update = _updateTail.then((_) async {
      final window = _window;
      if (window == null) return;
      // Only the normal bounds are restored: a minimized window on Windows is
      // at (-32000, -32000), a maximized one overhangs its display.
      if (window.isMinimized || window.isMaximized || window.isFullScreen) {
        return;
      }
      final bounds = window.bounds.toRect();
      if (bounds.isEmpty) return;
      final state = WindowState(bounds.size, bounds.topLeft);
      await windowSize.set(state);
    });
    _updateTail = update.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return update;
  }

  // Saved once a drag has paused: nativeapi emits one event per geometry step.
  void _updateLater() {
    _pending?.cancel();
    _pending = Timer(const Duration(milliseconds: 100), _updateState);
  }
}

class _SizeJsonConverter implements JsonConverter<Size, Map<String, dynamic>> {
  const _SizeJsonConverter();

  @override
  Size fromJson(Map<String, dynamic> json) {
    return Size(json['width'] as double, json['height'] as double);
  }

  @override
  Map<String, dynamic> toJson(Size object) {
    return {'width': object.width, 'height': object.height};
  }
}

class _OffsetJsonConverter
    implements JsonConverter<Offset, Map<String, dynamic>> {
  const _OffsetJsonConverter();

  @override
  Offset fromJson(Map<String, dynamic> json) {
    return Offset(json['dx'] as double, json['dy'] as double);
  }

  @override
  Map<String, dynamic> toJson(Offset object) {
    return {'dx': object.dx, 'dy': object.dy};
  }
}
