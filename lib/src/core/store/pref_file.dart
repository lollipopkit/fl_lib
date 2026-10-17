part of 'iface.dart';

/// `shared_preferences` where it is one JSON file (Windows, Linux): the same
/// file and format as the plugins, so nothing moves, but written atomically.
///
/// The plugins overwrite the file in place, and a shutdown mid-write could
/// leave it zero-filled; every launch then failed reading it (ServerBox
/// #1633). Here a write goes to a sibling, is flushed, and replaces the file
/// by rename. A file that cannot be read all the same is set aside for a look
/// and started again empty, rather than thrown on.
@visibleForTesting
final class AtomicFilePrefs extends SharedPreferencesStorePlatform {
  AtomicFilePrefs(this.file);

  final File file;

  Map<String, Object>? _cache;

  Map<String, Object> get _prefs => _cache ??= _load();

  Map<String, Object> _load() {
    if (!file.existsSync()) return {};
    try {
      final text = file.readAsStringSync();
      if (text.isEmpty) return {};
      if (json.decode(text) case final Map<String, dynamic> map) {
        return map.cast<String, Object>();
      }
      throw const FormatException('Not a JSON object');
    } on FormatException catch (e) {
      final aside = '${file.path}.corrupt-${DateTime.now().millisecondsSinceEpoch}';
      Loggers.app.warning('Unreadable ${file.path}, moved to $aside', e);
      file.renameSync(aside);
      return {};
    }
  }

  bool _save() {
    final tmp = File('${file.path}.tmp');
    try {
      file.parent.createSync(recursive: true);
      tmp.writeAsStringSync(json.encode(_prefs), flush: true);
      tmp.renameSync(file.path);
      return true;
    } catch (e, s) {
      Loggers.app.warning('Writing ${file.path}', e, s);
      return false;
    }
  }

  static bool _matches(String key, PreferencesFilter filter) =>
      key.startsWith(filter.prefix) && (filter.allowList?.contains(key) ?? true);

  @override
  Future<Map<String, Object>> getAllWithParameters(GetAllParameters parameters) async =>
      Map.of(_prefs)..removeWhere((key, _) => !_matches(key, parameters.filter));

  @override
  Future<Map<String, Object>> getAll() =>
      getAllWithParameters(GetAllParameters(filter: PreferencesFilter(prefix: 'flutter.')));

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    _prefs[key] = value;
    return _save();
  }

  @override
  Future<bool> remove(String key) async {
    _prefs.remove(key);
    return _save();
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    _prefs.removeWhere((key, _) => _matches(key, parameters.filter));
    return _save();
  }

  @override
  Future<bool> clear() => clearWithParameters(ClearParameters(filter: PreferencesFilter(prefix: 'flutter.')));
}
