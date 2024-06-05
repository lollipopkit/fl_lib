import 'dart:convert';

import 'package:fl_lib/fl_lib.dart';

abstract final class AppUpdate {
  static final _arch = CpuArch.current.name;
  static final _os = Pfs.type.name;
  static final _osArch = '$_os-$_arch';
  static var _resKey = '${chan.name}-$_osArch';
  static var _chanOs = '${chan.name}-$_os';

  static var _chan = AppUpdateChan.stable;
  static AppUpdateChan get chan => _chan;
  static set chan(AppUpdateChan value) {
    if (value == _chan) return;
    _chan = value;
    _resKey = '${chan.name}-$_osArch';
    _chanOs = '${chan.name}-$_os';
    _getAll();
  }

  static var _build = 0;
  static var _data = <String, dynamic>{};
  static var _locale = '';

  static Future<void> fromUrl({
    required String url,
    required String locale,
    required int build,
  }) async {
    final resp = await myDio.get(url);
    final data = resp.data as Map<String, dynamic>;
    _data = data;
    _build = build;
    _locale = locale;
    _getAll();
  }

  static void fromStr({
    required String raw,
    required int build,
    required String locale,
  }) {
    final data = json.decode(raw) as Map<String, dynamic>;
    _data = data;
    _build = build;
    _locale = locale;
    _getAll();
  }

  static void _getAll() {
    _changelog = _url = _version = null;
    // Keep this order
    _getChangelog();
    _getVersion();
    _getUrl();
  }

  static String? _changelog;
  static String? get changelog => _changelog;
  static String? _getChangelog() {
    if (_changelog != null) return _changelog;

    final changelogMap = _data['changelog'] as Map<String, dynamic>? ?? {};
    final val = (changelogMap[_locale] ?? changelogMap['default'])
        as Map<String, dynamic>?;
    if (val == null) return null;
    final buildStr = _build.toString();
    final biggerKeys = val.keys.where((e) => e.compareTo(buildStr) > 0);
    final sb = StringBuffer();
    final reversed = biggerKeys.toList().reversed.toList();
    final len = reversed.length;
    for (var idx = 0; idx < len; idx++) {
      sb.write('$idx. ');
      final key = reversed[idx];
      if (idx != len - 1) {
        sb.writeln(val[key]);
      } else {
        sb.write(val[key]);
      }
    }
    _changelog = sb.toString();
    return _changelog;
  }

  static String? _url;
  static String? get url => _url;
  static String? _getUrl() {
    if (_url != null) return _url;

    final urlMap = _data['urls'] as Map<String, dynamic>?;
    if (urlMap == null) return null;

    final overrideMap = urlMap['overrides'] as Map<String, dynamic>?;
    if (overrideMap != null) {
      final overrideUrl = _byResKey<String>(overrideMap);
      if (overrideUrl != null) return overrideUrl;
    }

    final baseUrls = urlMap['base'] as Map<String, dynamic>?;
    if (baseUrls == null) return null;
    final baseUrl = _byResKey<String>(baseUrls);
    if (baseUrl == null) return null;

    final suffixUrls = urlMap['suffix'] as Map<String, dynamic>?;
    final suffixUrl = _byResKey<String>(suffixUrls);
    if (suffixUrl == null) {
      _url = baseUrl;
      return _url;
    }
    
    final suffixUrlFmted = _fmt(suffixUrl, _version!.$1);
    _url = '$baseUrl$suffixUrlFmted';
    return _url;
  }

  static AppUpdateCheckResult? _version;
  static AppUpdateCheckResult? get version => _version;
  static AppUpdateCheckResult? _getVersion() {
    if (_version != null) return _version;

    final buildMap = _data['build'] as Map<String, dynamic>?;
    if (buildMap == null) return null;

    final chanMap = buildMap[chan.name] as Map<String, dynamic>?;
    if (chanMap == null) return null;

    final map = _byOsArch<Map<String, dynamic>>(chanMap);
    if (map == null) return null;

    try {
      _version = AppUpdateVer.fromJson(map).parse(_build);
    } catch (e) {
      Loggers.app.warning('AppUpdateVer.fromJson failed', e);
    }
    return _version;
  }

  static T? _byResKey<T extends Object>(Map<String, dynamic>? data) {
    if (data == null) return null;
    // Keep this order
    final resKeys = [_resKey, _osArch, _chanOs, _os, chan.name, 'default'];
    for (final key in resKeys) {
      final val = data[key];
      if (val != null && val is T) return val;
    }
    return null;
  }

  static T? _byOsArch<T extends Object>(Map<String, dynamic>? data) {
    if (data == null) return null;
    // Keep this order
    final resKeys = [_osArch, _os, 'default'];
    for (final key in resKeys) {
      final val = data[key];
      if (val != null && val is T) return val;
    }
    return null;
  }

  static String _fmt(String s, int build) {
    return s
        .replaceAll('{VERSION}', '$build')
        .replaceAll('{ARCH}', _arch)
        .replaceAll('{CHAN}', chan.name);
  }

  // static Map<String, String> _asStrMap(Map<String, dynamic> data) {
  //   final ret = <String, String>{};
  //   for (final key in data.keys) {
  //     final val = data[key];
  //     if (val is String) {
  //       ret[key] = val;
  //     }
  //   }
  //   return ret;
  // }
}

enum AppUpdateChan {
  beta,
  stable,
  ;
}

typedef AppUpdateCheckResult = (int latest, AppUpdateLevel level);

final class AppUpdateVer {
  final int latest;
  final int? min;
  final int? urgent;

  AppUpdateVer({
    required this.latest,
    this.min,
    this.urgent,
  });

  factory AppUpdateVer.fromJson(Map<String, dynamic> data) {
    return AppUpdateVer(
      latest: data['latest'] as int,
      min: data['min'] as int?,
      urgent: data['urgent'] as int?,
    );
  }

  AppUpdateCheckResult parse(int build) {
    if (latest <= build) return (latest, AppUpdateLevel.nil);
    if (urgent != null && urgent! > build) {
      return (latest, AppUpdateLevel.forced);
    }
    if (min != null && min! > build) {
      return (latest, AppUpdateLevel.recommended);
    }
    return (latest, AppUpdateLevel.normal);
  }
}

enum AppUpdateLevel {
  /// No update
  nil,

  /// Show snackbar
  normal,

  /// Show dialog
  recommended,

  /// Forced to update
  forced,
  ;
}
