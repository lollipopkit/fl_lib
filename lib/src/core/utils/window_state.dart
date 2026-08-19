import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
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

  WindowStateListener(this.windowSize);

  Future<void> _updateState() {
    final update = _updateTail.then((_) async {
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

  @override
  void onWindowMove() {
    Fns.throttle(
      _updateState,
      id: 'WindowStateListener.onWindowMove',
      duration: 100,
    );
  }

  @override
  void onWindowResize() {
    Fns.throttle(
      _updateState,
      id: 'WindowStateListener.onWindowResize',
      duration: 100,
    );
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
