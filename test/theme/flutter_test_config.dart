import 'dart:async';

import 'helper.dart';

/// Runs before every test file under `test/theme/`: the theme code reads its
/// host from where an app sets it at launch, so this is the tests' launch.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  initTestThemeHost();
  await testMain();
}
