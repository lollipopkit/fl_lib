import 'dart:convert';
import 'dart:io';

import 'package:fl_lib/fl_lib.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

/// The Windows and Linux plugins: a JSON file, decoded without a guard.
final class _FilePrefs extends SharedPreferencesStorePlatform {
  _FilePrefs(this.file);

  final File file;

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters parameters) async {
    if (!file.existsSync()) return {};
    return (json.decode(file.readAsStringSync()) as Map).cast<String, Object>();
  }

  @override
  Future<bool> clear() async => true;
  @override
  Future<Map<String, Object>> getAll() => getAllWithParameters(GetAllParameters(filter: PreferencesFilter(prefix: '')));
  @override
  Future<bool> remove(String key) async => true;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async => true;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('prefs');
    file = File('${dir.path}/shared_preferences.json');
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = _FilePrefs(file);
    PrefStore.prefsFileForTest = () async => file;
  });

  tearDown(() {
    PrefStore.prefsFileForTest = null;
    dir.deleteSync(recursive: true);
  });

  test('a zero-filled file, left by a shutdown mid-write, is set aside', () async {
    file.writeAsBytesSync(List.filled(299, 0));

    final store = PrefStore();
    await store.init();

    expect(store.get<String>('k'), isNull);
    expect(file.existsSync(), isFalse);
    final aside = dir.listSync().whereType<File>().single;
    expect(aside.path, startsWith('${file.path}.corrupt-'));
    expect(aside.lengthSync(), 299);
  });

  test('a readable file is left alone', () async {
    file.writeAsStringSync(json.encode({'k': 'v'}));

    final store = PrefStore();
    await store.init();

    expect(store.get<String>('k'), 'v');
    expect(file.existsSync(), isTrue);
  });
}
