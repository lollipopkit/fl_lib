import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

final class ValBuilder<T> extends ValueListenableBuilder<T> {
  final ValueListenable<T> listenable;

  ValBuilder({
    super.key,
    required this.listenable,
    required Widget Function(T) builder,
  }) : super(valueListenable: listenable, builder: (_, val, _) => builder(val));

  ValBuilder.child({
    super.key,
    required this.listenable,
    required Widget Function(T, Widget?) builder,
    super.child,
  }) : super(valueListenable: listenable, builder: (_, val, child) => builder(val, child));
}

final class ListenBuilder extends ListenableBuilder {
  ListenBuilder({
    super.key,
    required super.listenable,
    required Widget Function() builder,
  }) : super(builder: (_, _) => builder());

  ListenBuilder.child({
    super.key,
    required super.listenable,
    required Widget Function(Widget?) builder,
    super.child,
  }) : super(builder: (_, child) => builder(child));
}

final class PreferredSizeListenBuilder extends ListenBuilder implements PreferredSizeWidget {
  final Size preferSize;

  PreferredSizeListenBuilder({
    super.key,
    required super.listenable,
    required super.builder,
    this.preferSize = const Size.fromHeight(kToolbarHeight),
  });

  @override
  Size get preferredSize => preferSize;
}
