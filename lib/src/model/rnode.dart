import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// [RNode] is RebuildNode.
///
/// [ChangeNotifier.notifyListeners] works not properly in some cases.
class RNode implements ChangeNotifier {
  final List<VoidCallback> _listeners = [];

  RNode();

  @override
  String toString() => 'RNode($hashCode)';

  @override
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  /// Trigger all listeners.
  /// - [delay] if true, rebuild will be delayed.
  Future<void> notify({bool delay = false}) async {
    if (delay) await Future.delayed(const Duration(milliseconds: 277));
    for (final listener in _listeners) {
      try {
        listener();
      } catch (e, s) {
        Loggers.app.warning('RNode.notify', e, s);
      }
    }
  }

  /// Add this node's listeners to another node.
  void chain(RNode node) {
    node.addListener(notify);
  }

  @override
  void dispose() {
    _listeners.clear();
  }

  @override
  bool get hasListeners => _listeners.isNotEmpty;

  @override
  void notifyListeners() {
    notify();
  }
}

/// As a ext, or [VNode] can't override [RNodeX.listen].
extension RNodeX on RNode {
  ListenBuilder listen(Widget Function() builder) {
    return ListenBuilder(listenable: this, builder: builder);
  }
}

class VNode<T> extends RNode implements ValueNotifier<T> {
  T _value;

  VNode(T value) : _value = value;

  @override
  T get value => _value;

  @override
  set value(T newVal) {
    _value = newVal;
    notify();
  }

  @override
  String toString() => 'VNode($value)';
}

extension ValueListenableX<T> on ValueListenable<T> {
  ValBuilder<T> listenVal(Widget Function(T) builder) {
    return ValBuilder<T>(listenable: this, builder: builder);
  }
}

/// Used for constrcuting a const [ValueListenable].
final class EmptyListenable<T> implements ValueListenable<T?> {
  @override
  void addListener(VoidCallback listener) {}

  @override
  void removeListener(VoidCallback listener) {}

  @override
  T? get value => null;

  const EmptyListenable();
}

/// [RNode]s for common use.
abstract final class RNodes {
  /// Root node for all [RNode]s.
  static final app = RNode();

  /// Listen on [Brightness] changes.
  static final dark = false.vn;
}
