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
  static int? _storeBuild;

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
    _storeBuild = null;
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
    // Both requests go out at once: the store lookup only says anything on
    // iOS, and must not add a round trip to the check on every other platform.
    final releasesReq = myDio.get(
      url,
      options: Options(responseType: ResponseType.plain),
    );
    final storeReq = _fetchAppStoreBuild(storeUrl);
    final resp = await releasesReq;
    fromGitHubReleasesStr(
      raw: resp.data.toString(),
      build: build,
      storeUrl: storeUrl,
      storeBuild: await storeReq,
    );
  }

  /// The iTunes lookup URL for an App Store page [storeUrl], or null when it
  /// carries no app id.
  static String? appStoreLookupUrl(String? storeUrl) {
    if (storeUrl == null) return null;
    final id = RegExp(r'/id(\d+)').firstMatch(storeUrl)?.group(1);
    if (id == null) return null;
    return 'https://itunes.apple.com/lookup?id=$id';
  }

  /// The build number in an iTunes lookup response, or null when the response
  /// names no version — an app id that matches nothing answers with an empty
  /// `results` list rather than an error.
  static int? parseAppStoreBuild(String raw) {
    try {
      final data = json.decode(raw);
      if (data is! Map) return null;
      final results = data['results'];
      if (results is! List || results.isEmpty) return null;
      final first = results.first;
      if (first is! Map) return null;
      return _parseBuild(first['version']);
    } catch (e) {
      _logger.warning('App Store lookup parse failed', e);
      return null;
    }
  }

  /// What the App Store currently serves, or null when it could not be read.
  ///
  /// Only asked on iOS: everywhere else the release assets say what is
  /// installable, and macOS only reaches the store URL when a release carries
  /// no dmg at all.
  static Future<int?> _fetchAppStoreBuild(String? storeUrl) async {
    if (Pfs.type != Pfs.ios) return null;
    final url = appStoreLookupUrl(storeUrl);
    if (url == null) return null;
    // [myDio] sets no timeout and treats every status as success, so this has
    // to bound itself: a store that does not answer must delay the update
    // check by seconds, not hold it open. Timing out reads as "unknown",
    // which trusts the tag.
    final cancel = CancelToken();
    try {
      final resp = await myDio
          .get(
            url,
            options: Options(responseType: ResponseType.plain),
            cancelToken: cancel,
          )
          .timeout(const Duration(seconds: 5));
      return parseAppStoreBuild(resp.data.toString());
    } catch (e) {
      // [Future.timeout] only stops the waiting. Without this the request
      // itself stays open, holding a socket for a result nobody reads.
      cancel.cancel('App Store lookup abandoned');
      _logger.warning('App Store lookup failed', e);
      return null;
    }
  }

  /// Load and parse a raw GitHub Releases API response.
  ///
  /// [storeBuild] is what the App Store serves, when known; see
  /// [_fetchAppStoreBuild].
  static void fromGitHubReleasesStr({
    required String raw,
    required int build,
    String? storeUrl,
    int? storeBuild,
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
    _storeBuild = storeBuild;
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
    // The newest release this platform can install, which is not always the
    // newest release: a version published for some platforms only, or an iOS
    // build still in review, leaves the rest on an earlier one. Offering that
    // earlier one beats offering nothing — the alternative is that one
    // partial release mutes the update check until the next full one.
    //
    // The channel downgrade in [_getGitHubRelease] is meant to be decided by
    // what the user can install, so the installable pass is allowed to make
    // it. It must not stick when that pass comes back empty: the fallback
    // below and the release notes both read [chan], and a beta user with no
    // installable asset anywhere would otherwise be reported the newest
    // stable and left on a channel they never chose.
    final chanBefore = _chan;
    final installable = _getGitHubRelease(installable: true);
    if (installable == null) _chan = chanBefore;

    // Nothing installable anywhere: still report the newest release, so the
    // settings page names the real version instead of "unknown". [url] stays
    // null and no update is offered, since there is nothing to offer.
    final target = installable ?? _getGitHubRelease();
    if (target == null) return;

    final newest = _newestBuild(target);
    if (newest == null) return;

    _url = installable == null ? null : _getGitHubUrl(installable);
    _version = AppUpdateVer(latest: newest).parse(_build);
    // A store build the tags never caught up to has no name to give it; the
    // caller falls back to `v1.0.<build>`.
    _versionName = newest == target.build ? target.tag : null;
    _releaseNotes = _getGitHubReleaseNotes(newest);
    _changelog = switch (_releaseNotes.length) {
      0 => null,
      1 => _releaseNotes.first.body,
      _ => _releaseNotes.map((e) => '## ${e.title}\n\n${e.body}').join('\n\n'),
    };
  }

  /// What "newest" means here, or null when it cannot be said.
  ///
  /// Everywhere but iOS that is the newest tag: the release assets are what
  /// gets installed, so the tag is the thing being offered. An iOS build comes
  /// from the App Store and updates through it, and the store sits on either
  /// side of the tag at different times — behind it while a pushed tag is in
  /// review, ahead of it when a version ships to the store and is never
  /// tagged. Both name a version the user cannot act on, so the store decides.
  ///
  /// Null when the lookup did not answer, or answered something that is not a
  /// build number in the tags' space. iOS has no second source to fall back
  /// to, so nothing is reported rather than a tag the store may not serve.
  static int? _newestBuild(_GitHubRelease target) {
    if ((_githubPlatform ?? Pfs.type) != Pfs.ios) return target.build;
    return _comparableStoreBuild;
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

  /// The release to offer, or with [installable] the newest one that resolves
  /// to a download for this platform.
  ///
  /// [_getGitHubAll] asks for the installable one first, so the channel
  /// downgrade below is decided by what the user can actually get: a beta user
  /// whose newest prerelease is the only one carrying their platform's asset
  /// stays on beta rather than being dropped to an older stable.
  static _GitHubRelease? _getGitHubRelease({bool installable = false}) {
    final stable =
        _latestGitHubRelease(prerelease: false, installable: installable);
    if (chan == AppUpdateChan.stable) return stable;

    final beta =
        _latestGitHubRelease(prerelease: true, installable: installable);
    if (beta == null) {
      _updateChanRelated(AppUpdateChan.stable);
      return stable;
    }
    if (stable == null) return beta;
    if (beta.build >= stable.build) return beta;
    _updateChanRelated(AppUpdateChan.stable);
    return stable;
  }

  /// [_storeBuild], but only when it is a build number in the same space as
  /// the release tags.
  ///
  /// [_parseBuild] reads the last run of digits, which is the build under this
  /// project's `v1.0.<build>` tags but not under marketing versioning: an App
  /// Store version of `1.4.0` reads as build 0 and `1.4.1` as build 1, and
  /// either would reject every release and mute iOS updates permanently.
  ///
  /// An iOS build can only have been installed from the store, so the store
  /// does not serve something older than what is running. A value below the
  /// installed build means the two are not the same numbering, and answering
  /// null then keeps a misread version out of the comparison entirely —
  /// obeying it would report a version far below every release and reject
  /// them all.
  static int? get _comparableStoreBuild {
    final storeBuild = _storeBuild;
    if (storeBuild == null) return null;
    if (storeBuild <= 0 || storeBuild < _build) return null;
    return storeBuild;
  }

  static _GitHubRelease? _latestGitHubRelease({
    required bool prerelease,
    bool installable = false,
  }) {
    _GitHubRelease? latest;
    for (final release in _githubReleases) {
      if (release.prerelease != prerelease) continue;
      if (latest != null && release.build <= latest.build) continue;
      if (installable && _getGitHubUrl(release) == null) continue;
      latest = release;
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
        // A tag exists the moment it is pushed; the App Store build behind it
        // can still be in review for days. Offering it would send the user to
        // a store page that serves the build they are already running, on
        // every launch, with no way to act on it.
        //
        // An unknown store build offers nothing either: the store is the only
        // place an iOS build can update from, so without knowing what it
        // serves there is nothing to point at. That silences the check while
        // the lookup is failing, which is the trade [_newestBuild] describes.
        final storeBuild = _comparableStoreBuild;
        if (storeBuild == null || release.build > storeBuild) return null;
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
}

/// The build number in a version string: the last run of digits, so a GitHub
/// tag `v1.0.1491` and an App Store version `1.0.1491` both yield 1491.
int? _parseBuild(Object? raw) {
  if (raw == null) return null;
  final matches = RegExp(r'\d+').allMatches(raw.toString()).toList();
  if (matches.isEmpty) return null;
  return int.tryParse(matches.last.group(0)!);
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
