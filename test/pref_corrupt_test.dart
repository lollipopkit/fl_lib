import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// `PrefStore` on Windows and Linux, where the preferences are one JSON file
/// [AtomicFilePrefs] reads and writes in place of the plugin.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('prefs');
    file = File('${dir.path}/shared_preferences.json');
    SharedPreferences.resetStatic();
    PrefStore.prefsFileForTest = () async => file;
  });

  tearDown(() {
    PrefStore.prefsFileForTest = null;
    SharedPreferences.setMockInitialValues({});
    dir.deleteSync(recursive: true);
  });

  List<String> names() => dir.listSync().map((e) => e.uri.pathSegments.last).toList()..sort();

  test('it takes over the file', () async {
    await PrefStore().init();
    expect(SharedPreferencesStorePlatform.instance, isA<AtomicFilePrefs>());
  });

  test('what the plugin wrote is read as it was', () async {
    file.writeAsStringSync(json.encode({'flutter.k': 'v'}));

    final store = PrefStore();
    await store.init(prefix: 'flutter.');

    expect(store.get<String>('k'), 'v');
  });

  test('a null in the file is dropped, not thrown on later', () async {
    file.writeAsStringSync(json.encode({'flutter.k': null, 'flutter.j': 'v'}));

    final store = PrefStore();
    await store.init(prefix: 'flutter.');

    expect(store.get<String>('k'), isNull);
    expect(store.get<String>('j'), 'v');
  });

  test('a write replaces the file whole, and leaves nothing beside it', () async {
    final store = PrefStore();
    await store.init(prefix: 'flutter.');

    store.set('k', 'v');
    await Future<void>.delayed(Duration.zero);

    expect(json.decode(file.readAsStringSync()), containsPair('flutter.k', 'v'));
    expect(names(), ['shared_preferences.json']);
  });

  test('a zero-filled file, left by a shutdown mid-write, is set aside', () async {
    file.writeAsBytesSync(List.filled(299, 0));

    final store = PrefStore();
    await store.init(prefix: 'flutter.');

    expect(store.get<String>('k'), isNull);
    expect(file.existsSync(), isFalse);
    final aside = names().single;
    expect(aside, startsWith('shared_preferences.json.corrupt-'));
    expect(File('${dir.path}/$aside').lengthSync(), 299);

    // And it is written again from there.
    store.set('k', 'v');
    await Future<void>.delayed(Duration.zero);
    expect(json.decode(file.readAsStringSync()), containsPair('flutter.k', 'v'));
  });
}
