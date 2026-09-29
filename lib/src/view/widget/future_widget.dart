import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

final class FutureWidget<T> extends StatelessWidget {
  final Future<T> future;
  final Widget loading;
  final Widget Function(AsyncSnapshot<T>? snapshot)? loadingBuilder;
  final Widget Function(Object? error, StackTrace? trace)? error;
  final Widget Function(T? data) success;
  final bool cacheWidget;
  final T? initialData;

  const FutureWidget({
    super.key,
    required this.future,
    this.loading = SizedLoading.medium,
    this.error,
    required this.success,
    this.cacheWidget = true,
    this.initialData,
    this.loadingBuilder,
  });

  @override
  Widget build(BuildContext context) {
    Widget? cachedWidget;
    return FutureBuilder<T>(
      future: future,
      initialData: initialData,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return error?.call(snapshot.error, snapshot.stackTrace) ?? ErrorView.es(snapshot.error, snapshot.stackTrace);
        }
        switch (snapshot.connectionState) {
          case ConnectionState.none:
          case ConnectionState.waiting:
          case ConnectionState.active:
            if (cacheWidget && cachedWidget != null) return cachedWidget!;
            return loadingBuilder?.call(snapshot) ?? loading;
          case ConnectionState.done:
            final suc = success(snapshot.data);
            if (cacheWidget) cachedWidget = suc;
            return suc;
        }
      },
    );
  }
}
