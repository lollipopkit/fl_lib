import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

final class _Args {
  const _Args(this.id);
  final String id;
}

Widget _page({Key? key, required _Args args}) => Text(args.id, key: key);

const _route = AppRouteArg<void, _Args>(page: _page, path: '/thing');

void main() {
  testWidgets('a pushed route carries its arguments for observers', (tester) async {
    final seen = <RouteSettings>[];
    final observer = _Observer(seen.add);
    final nav = GlobalKey<NavigatorState>();
    await tester.pumpWidget(MaterialApp(navigatorKey: nav, navigatorObservers: [observer], home: const SizedBox()));
    _route.go(nav.currentContext!, const _Args('a'));
    await tester.pumpAndSettle();
    expect(seen.last.name, '/thing');
    expect((seen.last.arguments as _Args).id, 'a');
  });
}

final class _Observer extends NavigatorObserver {
  _Observer(this.onPush);
  final void Function(RouteSettings) onPush;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) => onPush(route.settings);
}
