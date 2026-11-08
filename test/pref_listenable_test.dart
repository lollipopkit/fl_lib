import 'package:fl_lib/fl_lib.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await PrefStore.shared.init();
  });

  test('one listener on several keys hears each of them, and none once removed', () async {
    const a = PrefPropDefault('listenable_a', false, updateLastUpdateTsOnSetProp: false);
    const b = PrefPropDefault('listenable_b', false, updateLastUpdateTsOnSetProp: false);
    final both = Listenable.merge([a.listenable(), b.listenable()]);
    var heard = 0;
    void listener() => heard++;

    both.addListener(listener);
    await b.set(true);
    expect(heard, 1, reason: 'the second key');
    await a.set(true);
    expect(heard, 2);

    both.removeListener(listener);
    await a.set(false);
    await b.set(false);
    expect(heard, 2);
  });
}
