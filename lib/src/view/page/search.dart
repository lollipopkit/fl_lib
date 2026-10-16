import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

final class SearchPage<T> extends SearchDelegate<T> {
  final Future<List<T>> Function(String) future;
  final Widget Function(BuildContext, T) builder;
  final EdgeInsetsGeometry? padding;
  final Duration throttleInterval;

  String? _query;
  Future<List<T>>? _results;

  SearchPage({
    required this.future,
    required this.builder,
    this.padding,
    this.throttleInterval = const Duration(milliseconds: 200),
  });

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        tooltip: libL10n.clear,
        onPressed: () {
          query = '';
        },
      ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      onPressed: context.pop,
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: const Icon(Icons.arrow_back),
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    return _buildList(context);
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    return _buildList(context);
  }

  Widget _buildList(BuildContext context) {
    return FutureWidget(
      future: _search(query),
      loading: const Center(child: SizedLoading.medium),
      error: (error, trace) {
        return Center(
          child: Text('$error\n$trace'),
        );
      },
      success: (list) {
        if (list == null || list.isEmpty) {
          return const Center(child: Text('~'));
        }

        return ListView.builder(
          padding: padding,
          itemCount: list.length,
          itemBuilder: (_, index) => builder(context, list[index]),
        );
      },
    );
  }

  /// One search per query: a rebuild for the same text gets the same future
  /// back rather than asking again, and a different text never gets the
  /// previous one's results.
  Future<List<T>> _search(String query) {
    final results = _results;
    if (results != null && query == _query) return results;
    _query = query;
    return _results = _afterPause(query);
  }

  /// Typing changes the query once a key, so it is asked for only once it has
  /// held for [throttleInterval]; one typed over in the meantime is dropped.
  Future<List<T>> _afterPause(String query) async {
    await Future<void>.delayed(throttleInterval);
    if (query != _query) return _results!;
    return future(query);
  }
}
