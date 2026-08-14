import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:fl_lib/src/core/dio.dart';
import 'package:fl_lib/src/core/utils/platform/arch.dart';
import 'package:fl_lib/src/core/utils/platform/base.dart';
import 'package:logging/logging.dart';

/// Parse and provide app update metadata from a JSON manifest.
///
/// The manifest supports per-channel (stable/beta), per-OS, and per-arch
/// overrides for build numbers, changelog, and download URLs.
abstract final class AppUpdate {
  static final _logger = Logger('AppUpdate');

  static String get _arch => CpuArch.current.name;
  static String get _os => Pfs.type.name;
  static String get _osArch => '$_os-$_arch';
  static String get _resKey => '${chan.name}-$_osArch';
  static String get _chanOs => '${chan.name}-$_os';

  static var _chan = AppUpdateChan.stable;
  /// Current update channel.
  static AppUpdateChan get chan => _chan;
  static set chan(AppUpdateChan value) {
    if (value == _chan) return;
    _chan = value;
    _getAll();
  }

  static void _updateChanRelated(AppUpdateChan value) {
    if (value == _chan) return;
    _chan = value;
  }

  static var _build = 0;
  static var _data = <String, dynamic>{};
  static var _locale = '';
  static var _source = _AppUpdateSource.manifest;
  static var _githubReleases = <_GitHubRelease>[];
  static String? _githubStoreUrl;
  static Pfs? _githubPlatform;
  static CpuArch? _githubArch;

  /// Reset mutable state between tests.
  static void resetForTest() {
    _chan = AppUpdateChan.stable;
    _build = 0;
    _data = <String, dynamic>{};
    _locale = '';
    _source = _AppUpdateSource.manifest;
    _githubReleases = <_GitHubRelease>[];
    _githubStoreUrl = null;
    _githubPlatform = null;
    _githubArch = null;
    _changelog = null;
    _releaseNotes = const [];
    _versionName = null;
    _url = null;
    _version = null;
  }

  static String _rmComment(String raw) {
    return (raw.split('\n')..removeWhere((e) => e.trimLeft().startsWith('//')))
        .join('\n');
  }

  /// Load and parse the manifest from a remote [url].
  static Future<void> fromUrl({
    required String url,
    required String locale,
    required int build,
  }) async {
    final resp = await myDio.get(url,
        options: Options(responseType: ResponseType.plain));
    final text = _rmComment(resp.data);
    final data = json.decode(text) as Map<String, dynamic>;
    _data = data;
    _locale = locale;
    _build = build;
    _source = _AppUpdateSource.manifest;
    _getAll();
  }

  /// Load and parse the manifest from a raw JSON [raw] string.
  static void fromStr({
    required String raw,
    required String locale,
    required int build,
  }) {
    final text = _rmComment(raw);
    final data = json.decode(text) as Map<String, dynamic>;
    _data = data;
    _locale = locale;
    _build = build;
    _source = _AppUpdateSource.manifest;
    _getAll();
  }

  /// Load and parse releases from the GitHub Releases API.
  static Future<void> fromGitHubReleasesUrl({
    required String url,
    required int build,
    String? storeUrl,
  }) async {
    final resp = await myDio.get(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    fromGitHubReleasesStr(
      raw: resp.data.toString(),
      build: build,
      storeUrl: storeUrl,
    );
  }

  /// Load and parse a raw GitHub Releases API response.
  static void fromGitHubReleasesStr({
    required String raw,
    required int build,
    String? storeUrl,
    Pfs? platform,
    CpuArch? arch,
  }) {
    final decoded = json.decode(raw);
    if (decoded is! List) {
      throw FormatException('Expected GitHub releases list, got $decoded');
    }
    _githubReleases = decoded
        .whereType<Map<String, dynamic>>()
        // Drafts are not published to anyone, so they are dropped before
        // parsing: an unfinished tag must not log as a malformed release.
        .where((release) => release['draft'] != true)
        .map((release) => _GitHubRelease.fromJson(Map.from(release)))
        .nonNulls
        .toList();
    _build = build;
    _source = _AppUpdateSource.github;
    _githubStoreUrl = storeUrl;
    _githubPlatform = platform;
    _githubArch = arch;
    _getAll();
  }

  static void _getAll() {
    _changelog = _url = _version = _versionName = null;
    _releaseNotes = const [];
    if (_source == _AppUpdateSource.github) {
      _getGitHubAll();
      return;
    }
    // Keep this order
    _getChangelog();
    _getVersion();
    _getUrl();
  }

  static void _getGitHubAll() {
    final release = _getGitHubRelease();
    if (release == null) return;
    final url = _getGitHubUrl(release);
    if (url == null) return;
    _url = url;
    _version = AppUpdateVer(latest: release.build).parse(_build);
    _versionName = release.tag;
    _releaseNotes = _getGitHubReleaseNotes(release.build);
    _changelog = switch (_releaseNotes.length) {
      0 => null,
      1 => _releaseNotes.first.body,
      _ => _releaseNotes.map((e) => '## ${e.title}\n\n${e.body}').join('\n\n'),
    };
  }

  /// The notes of every release between the installed build and [newest],
  /// newest first.
  ///
  /// A user several versions behind gets every version's notes, not only the
  /// one GitHub calls latest. Releases without a body are left out: they would
  /// only add an entry with nothing under it.
  static List<AppUpdateReleaseNote> _getGitHubReleaseNotes(int newest) {
    final notes = <AppUpdateReleaseNote>[];
    for (final release in _githubReleases) {
      if (release.build <= _build || release.build > newest) continue;
      // A beta user passes through the stable releases as well; a stable user
      // never sees a prerelease.
      if (chan == AppUpdateChan.stable && release.prerelease) continue;
      final body = release.body?.trim();
      if (body == null || body.isEmpty) continue;
      notes.add(AppUpdateReleaseNote(
        build: release.build,
        title: release.tag,
        date: release.publishedAt,
        body: body,
      ));
    }
    notes.sort((a, b) => b.build.compareTo(a.build));
    return notes;
  }

  static String? _versionName;
  /// What the source calls the newest version, e.g. the GitHub tag `v1.0.1024`.
  ///
  /// Null for the JSON manifest, which only carries build numbers.
  static String? get versionName => _versionName;

  static var _releaseNotes = const <AppUpdateReleaseNote>[];
  /// Per-version release notes for every build newer than the installed one,
  /// newest first. Empty for the JSON manifest, which has [changelog] instead.
  static List<AppUpdateReleaseNote> get releaseNotes => _releaseNotes;

  static String? _changelog;
  /// Combined changelog lines for builds newer than [build] in the selected locale.
  static String? get changelog => _changelog;
  static String? _getChangelog() {
    if (_changelog != null) return _changelog;

    final changelogMap = _data['changelog'] as Map<String, dynamic>? ?? {};
    final val = (changelogMap[_locale] ?? changelogMap['default'])
        as Map<String, dynamic>?;
    if (val == null) return null;
    final biggerKeys = val.keys.where((e) {
      final v = int.tryParse(e);
      if (v == null) return false;
      return v > _build;
    });
    final sb = StringBuffer();
    final reversed = biggerKeys.toList().reversed.toList();
    final len = reversed.length;
    for (var idx = 0; idx < len; idx++) {
      sb.write('${idx + 1}. ');
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
  /// Resolved download URL for the current platform/channel.
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
  /// The latest build number with update level for this platform/channel.
  static AppUpdateCheckResult? get version => _version;
  static AppUpdateCheckResult? _getVersion() {
    if (_version != null) return _version;

    final buildMap = _data['build'] as Map<String, dynamic>?;
    if (buildMap == null) return null;

    AppUpdateCheckResult? parse(AppUpdateChan chan) {
      final chanMap = buildMap[chan.name] as Map<String, dynamic>?;
      if (chanMap == null) return null;

      final map = _byOsArch<Map<String, dynamic>>(chanMap);
      if (map == null) return null;

      try {
        return AppUpdateVer.fromJson(map).parse(_build);
      } catch (e) {
        _logger.warning('AppUpdateVer.fromJson failed', e);
      }
      return null;
    }

    AppUpdateCheckResult? parseBeta() {
      final betaResult = parse(AppUpdateChan.beta);
      final stableResult = parse(AppUpdateChan.stable);
      if (betaResult == null) {
        _updateChanRelated(AppUpdateChan.stable);
        return stableResult;
      }
      if (stableResult == null) return betaResult;
      if (betaResult.$1 >= stableResult.$1) return betaResult;
      _updateChanRelated(AppUpdateChan.stable);
      return stableResult;
    }

    _version = switch (chan) {
      AppUpdateChan.beta => parseBeta(),
      AppUpdateChan.stable => parse(AppUpdateChan.stable),
    };

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

  static _GitHubRelease? _getGitHubRelease() {
    final stable = _latestGitHubRelease(prerelease: false);
    if (chan == AppUpdateChan.stable) return stable;

    final beta = _latestGitHubRelease(prerelease: true);
    if (beta == null) {
      _updateChanRelated(AppUpdateChan.stable);
      return stable;
    }
    if (stable == null) return beta;
    if (beta.build >= stable.build) return beta;
    _updateChanRelated(AppUpdateChan.stable);
    return stable;
  }

  static _GitHubRelease? _latestGitHubRelease({required bool prerelease}) {
    _GitHubRelease? latest;
    for (final release in _githubReleases) {
      if (release.prerelease != prerelease) continue;
      if (latest == null || release.build > latest.build) {
        latest = release;
      }
    }
    return latest;
  }

  static String? _getGitHubUrl(_GitHubRelease release) {
    final platform = _githubPlatform ?? Pfs.type;
    final arch = _githubArch ?? CpuArch.current;
    final assets = release.assets;

    switch (platform) {
      case Pfs.android:
        return _findGitHubAsset(
          assets,
          (asset) => asset.name.endsWith('.apk') && asset.hasArch(arch),
        )?.url;
      case Pfs.linux:
        final appImages = assets.where(
          (asset) => asset.name.endsWith('.AppImage') && asset.hasArch(arch),
        );
        return _preferNonLegacy(appImages)?.url;
      case Pfs.windows:
        return _findGitHubAsset(
          assets,
          (asset) =>
              asset.name.endsWith('.zip') &&
              asset.name.contains('windows') &&
              asset.hasArch(arch),
        )?.url;
      case Pfs.macos:
        final dmgs = assets.where((asset) => asset.name.endsWith('.dmg'));
        return _findGitHubAsset(dmgs, (asset) => asset.hasArch(arch))?.url ??
            _findGitHubAsset(dmgs, (asset) => !asset.hasAnyArch)?.url ??
            _githubStoreUrl;
      case Pfs.ios:
        return _githubStoreUrl;
      case Pfs.web || Pfs.fuchsia || Pfs.unknown:
        return null;
    }
  }

  static _GitHubAsset? _findGitHubAsset(
    Iterable<_GitHubAsset> assets,
    bool Function(_GitHubAsset asset) test,
  ) {
    for (final asset in assets) {
      if (test(asset)) return asset;
    }
    return null;
  }

  static _GitHubAsset? _preferNonLegacy(Iterable<_GitHubAsset> assets) {
    _GitHubAsset? legacy;
    for (final asset in assets) {
      if (!asset.name.contains('legacy')) return asset;
      legacy ??= asset;
    }
    return legacy;
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

enum _AppUpdateSource {
  manifest,
  github,
}

/// One version's release notes.
final class AppUpdateReleaseNote {
  /// Build number these notes belong to.
  final int build;

  /// What the source calls this version, e.g. the GitHub tag `v1.0.1024`.
  final String title;

  /// Publish time, if the source states one.
  final DateTime? date;

  /// The notes themselves, in markdown.
  final String body;

  const AppUpdateReleaseNote({
    required this.build,
    required this.title,
    required this.date,
    required this.body,
  });
}

final class _GitHubRelease {
  final int build;

  /// The tag the build number was read from, e.g. `v1.0.1024`.
  final String tag;
  final bool prerelease;
  final DateTime? publishedAt;
  final String? body;
  final List<_GitHubAsset> assets;

  const _GitHubRelease({
    required this.build,
    required this.tag,
    required this.prerelease,
    required this.publishedAt,
    required this.body,
    required this.assets,
  });

  factory _GitHubRelease._fromJson(Map<String, dynamic> data) {
    // The tag names the version everywhere the user sees it, so the build has
    // to come from the same string that ends up on screen.
    var tag = _nonEmptyStr(data['tag_name']);
    var build = _parseBuild(tag);
    if (build == null) {
      tag = _nonEmptyStr(data['name']);
      build = _parseBuild(tag);
    }
    if (build == null || tag == null) {
      throw FormatException('GitHub release build not found: $data');
    }

    final assets = (data['assets'] as List? ?? [])
        .whereType<Map<String, dynamic>>()
        .map((asset) => _GitHubAsset.fromJson(Map<String, dynamic>.from(asset)))
        .nonNulls
        .toList();

    return _GitHubRelease(
      build: build,
      tag: tag,
      prerelease: data['prerelease'] == true,
      publishedAt: DateTime.tryParse(
        _nonEmptyStr(data['published_at']) ?? _nonEmptyStr(data['created_at']) ?? '',
      ),
      body: data['body'] as String?,
      assets: assets,
    );
  }

  static String? _nonEmptyStr(Object? raw) {
    if (raw is! String) return null;
    final trimmed = raw.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  static _GitHubRelease? fromJson(Map<String, dynamic> data) {
    try {
      return _GitHubRelease._fromJson(data);
    } catch (e) {
      AppUpdate._logger.warning('GitHub release parse failed', e);
      return null;
    }
  }

  static int? _parseBuild(Object? raw) {
    if (raw == null) return null;
    final matches = RegExp(r'\d+').allMatches(raw.toString()).toList();
    if (matches.isEmpty) return null;
    return int.tryParse(matches.last.group(0)!);
  }
}

final class _GitHubAsset {
  final String name;
  final String url;

  const _GitHubAsset({
    required this.name,
    required this.url,
  });

  static _GitHubAsset? fromJson(Map<String, dynamic> data) {
    final name = data['name'];
    final url = data['browser_download_url'];
    if (name is! String || url is! String) return null;
    return _GitHubAsset(name: name, url: url);
  }

  bool hasArch(CpuArch arch) {
    final lower = name.toLowerCase();
    return switch (arch) {
      CpuArch.amd64 => lower.contains('amd64') || lower.contains('x86_64'),
      CpuArch.arm64 => lower.contains('arm64') || lower.contains('aarch64'),
      CpuArch.arm => lower.contains('_arm.') ||
          lower.contains('_arm_') ||
          lower.contains('-arm.') ||
          lower.contains('-arm_'),
    };
  }

  bool get hasAnyArch => CpuArch.values.any(hasArch);
}

/// Update channels supported by the app.
enum AppUpdateChan {
  beta,
  stable,
  ;
}

/// Result of an update check: latest build and its [AppUpdateLevel].
typedef AppUpdateCheckResult = (int latest, AppUpdateLevel level);

/// Version thresholds used to compute update level.
final class AppUpdateVer {
  final int latest;
  final int? min;
  final int? urgent;

  AppUpdateVer({
    required this.latest,
    this.min,
    this.urgent,
  });

  /// Parse from a JSON object: `{ latest, min?, urgent? }`.
  factory AppUpdateVer.fromJson(Map<String, dynamic> data) {
    return AppUpdateVer(
      latest: data['latest'] as int,
      min: data['min'] as int?,
      urgent: data['urgent'] as int?,
    );
  }

  /// Compute the required [AppUpdateLevel] given current [build].
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
