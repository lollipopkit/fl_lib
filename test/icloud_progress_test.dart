import 'dart:async';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a failed transfer fails once, with nothing left uncaught', () async {
    // A progress stream that errors and is then closed, which is what the
    // iCloud plugin does. Completing on `onDone` as well threw
    // `Bad state: Future already completed` into the zone.
    final uncaught = <Object>[];
    await runZonedGuarded(() async {
      final progress = StreamController<double>();
      final done = Completer<void>();
      ICloud.settleOnProgress(progress.stream, done);
      progress.addError(StateError('not signed in'));
      await progress.close();

      await expectLater(done.future, throwsA(isA<StateError>()));
      await Future<void>.delayed(Duration.zero);
    }, (e, _) => uncaught.add(e));

    expect(uncaught, isEmpty);
  });

  test('a finished transfer completes', () async {
    final progress = StreamController<double>();
    final done = Completer<void>();
    ICloud.settleOnProgress(progress.stream, done);
    progress.add(1);
    await progress.close();

    await expectLater(done.future, completes);
  });
}
