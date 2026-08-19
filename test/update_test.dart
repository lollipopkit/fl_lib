import 'dart:convert';

import 'package:fl_lib/src/core/utils/platform/arch.dart';
import 'package:fl_lib/src/core/utils/platform/base.dart';
import 'package:fl_lib/src/model/update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    AppUpdate.resetForTest();
  });

  tearDown(() {
    AppUpdate.resetForTest();
  });

  test('github stable release uses release body and platform asset', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.3',
          body: 'stable body',
          assets: [
            _asset('ServerBox_v1.0.3_arm64.apk'),
          ],
        ),
      ]),
      build: 1,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(AppUpdate.version, (3, AppUpdateLevel.normal));
    expect(AppUpdate.changelog, 'stable body');
    expect(AppUpdate.url, 'https://download/ServerBox_v1.0.3_arm64.apk');
  });

  test('github release notes cover every version newer than current', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.5',
          body: 'five',
          publishedAt: '2026-08-14T10:00:00Z',
          assets: [_asset('ServerBox_v1.0.5_arm64.apk')],
        ),
        _release(tag: 'v1.0.3', body: 'three'),
        _release(tag: 'v1.0.4', body: 'four'),
        // Already installed, and older than that: not news.
        _release(tag: 'v1.0.2', body: 'two'),
        _release(tag: 'v1.0.1', body: 'one'),
      ]),
      build: 2,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(AppUpdate.versionName, 'v1.0.5');
    expect(
      AppUpdate.releaseNotes.map((e) => e.title).toList(),
      ['v1.0.5', 'v1.0.4', 'v1.0.3'],
    );
    expect(AppUpdate.releaseNotes.map((e) => e.body).toList(),
        ['five', 'four', 'three']);
    expect(AppUpdate.releaseNotes.first.date, DateTime.utc(2026, 8, 14, 10));
    expect(AppUpdate.releaseNotes.last.date, isNull);
    expect(
      AppUpdate.changelog,
      '## v1.0.5\n\nfive\n\n## v1.0.4\n\nfour\n\n## v1.0.3\n\nthree',
    );
  });

  test('github release notes skip drafts and empty bodies', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.5',
          body: 'five',
          assets: [_asset('ServerBox_v1.0.5_arm64.apk')],
        ),
        _release(tag: 'v1.0.4', body: '  '),
        _release(tag: 'v1.0.3'),
        _release(tag: 'v1.0.6', body: 'six', draft: true),
      ]),
      build: 2,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(AppUpdate.version, (5, AppUpdateLevel.normal));
    expect(AppUpdate.releaseNotes.map((e) => e.title).toList(), ['v1.0.5']);
    expect(AppUpdate.changelog, 'five');
  });

  test('github release notes exclude prereleases on stable channel', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.5',
          body: 'five',
          assets: [_asset('ServerBox_v1.0.5_arm64.apk')],
        ),
        _release(tag: 'v1.0.4', body: 'four beta', prerelease: true),
        _release(tag: 'v1.0.3', body: 'three'),
      ]),
      build: 2,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(
      AppUpdate.releaseNotes.map((e) => e.title).toList(),
      ['v1.0.5', 'v1.0.3'],
    );
  });

  test('github beta channel keeps prereleases in release notes', () {
    AppUpdate.chan = AppUpdateChan.beta;
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.5',
          body: 'five beta',
          prerelease: true,
          assets: [_asset('ServerBox_v1.0.5_arm64.apk')],
        ),
        _release(tag: 'v1.0.4', body: 'four'),
        _release(tag: 'v1.0.3', body: 'three'),
      ]),
      build: 3,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(
      AppUpdate.releaseNotes.map((e) => e.title).toList(),
      ['v1.0.5', 'v1.0.4'],
    );
  });

  test('github release notes stop at the release being offered', () {
    // The newest stable is 4; a newer prerelease exists but this channel is
    // not being offered it, so its notes have no place in the dialog.
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(tag: 'v1.0.5', body: 'five beta', prerelease: true),
        _release(
          tag: 'v1.0.4',
          body: 'four',
          assets: [_asset('ServerBox_v1.0.4_arm64.apk')],
        ),
      ]),
      build: 3,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(AppUpdate.version, (4, AppUpdateLevel.normal));
    expect(AppUpdate.releaseNotes.map((e) => e.title).toList(), ['v1.0.4']);
  });

  test('github release notes are empty when up to date', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.3',
          body: 'three',
          assets: [_asset('ServerBox_v1.0.3_arm64.apk')],
        ),
      ]),
      build: 3,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(AppUpdate.version, (3, AppUpdateLevel.nil));
    expect(AppUpdate.releaseNotes, isEmpty);
    expect(AppUpdate.changelog, isNull);
  });

  test('github version name falls back to release name', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: '',
          name: 'ServerBox 1.0.3',
          body: 'three',
          assets: [_asset('ServerBox_v1.0.3_arm64.apk')],
        ),
      ]),
      build: 1,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(AppUpdate.version, (3, AppUpdateLevel.normal));
    expect(AppUpdate.versionName, 'ServerBox 1.0.3');
  });

  test('github stable release ignores drafts and older releases', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.4',
          draft: true,
          assets: [_asset('ServerBox_v1.0.4_arm64.apk')],
        ),
        _release(
          tag: 'v1.0.3',
          assets: [_asset('ServerBox_v1.0.3_arm64.apk')],
        ),
        _release(
          tag: 'v1.0.2',
          assets: [_asset('ServerBox_v1.0.2_arm64.apk')],
        ),
      ]),
      build: 1,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(AppUpdate.version, (3, AppUpdateLevel.normal));
    expect(AppUpdate.url, 'https://download/ServerBox_v1.0.3_arm64.apk');
  });

  test('github beta channel uses newer prerelease', () {
    AppUpdate.chan = AppUpdateChan.beta;
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.3',
          prerelease: true,
          assets: [_asset('ServerBox_v1.0.3_amd64.AppImage')],
        ),
        _release(
          tag: 'v1.0.2',
          assets: [_asset('ServerBox_v1.0.2_amd64.AppImage')],
        ),
      ]),
      build: 1,
      platform: Pfs.linux,
      arch: CpuArch.amd64,
    );

    expect(AppUpdate.version, (3, AppUpdateLevel.normal));
    expect(AppUpdate.url, 'https://download/ServerBox_v1.0.3_amd64.AppImage');
  });

  test('github current build is up to date', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.3',
          assets: [_asset('ServerBox_v1.0.3_arm64.apk')],
        ),
      ]),
      build: 3,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(AppUpdate.version, (3, AppUpdateLevel.nil));
    expect(AppUpdate.url, 'https://download/ServerBox_v1.0.3_arm64.apk');
  });

  test('github beta channel falls back to newer stable', () {
    AppUpdate.chan = AppUpdateChan.beta;
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.4',
          prerelease: true,
          assets: [_asset('ServerBox_v1.0.4_windows_amd64.zip')],
        ),
        _release(
          tag: 'v1.0.5',
          assets: [_asset('ServerBox_v1.0.5_windows_amd64.zip')],
        ),
      ]),
      build: 1,
      platform: Pfs.windows,
      arch: CpuArch.amd64,
    );

    expect(AppUpdate.chan, AppUpdateChan.stable);
    expect(AppUpdate.version, (5, AppUpdateLevel.normal));
    expect(
      AppUpdate.url,
      'https://download/ServerBox_v1.0.5_windows_amd64.zip',
    );
  });

  test('github linux prefers non legacy AppImage', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.3',
          assets: [
            _asset('ServerBox_v1.0.3_legacy_amd64.AppImage'),
            _asset('ServerBox_v1.0.3_amd64.AppImage'),
          ],
        ),
      ]),
      build: 1,
      platform: Pfs.linux,
      arch: CpuArch.amd64,
    );

    expect(AppUpdate.url, 'https://download/ServerBox_v1.0.3_amd64.AppImage');
  });

  test('github macos uses dmg and falls back to store url', () {
    final raw = _githubRaw([
      _release(
        tag: 'v1.0.3',
        assets: [_asset('ServerBox-1.0.3.dmg')],
      ),
    ]);

    AppUpdate.fromGitHubReleasesStr(
      raw: raw,
      build: 1,
      storeUrl: 'https://apps.apple.com/app/id1586449703',
      platform: Pfs.macos,
      arch: CpuArch.arm64,
    );
    expect(AppUpdate.url, 'https://download/ServerBox-1.0.3.dmg');

    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(tag: 'v1.0.3', assets: const []),
      ]),
      build: 1,
      storeUrl: 'https://apps.apple.com/app/id1586449703',
      platform: Pfs.macos,
      arch: CpuArch.arm64,
    );
    expect(AppUpdate.url, 'https://apps.apple.com/app/id1586449703');
  });

  test('github macos prefers current architecture dmg over generic dmg', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(
          tag: 'v1.0.3',
          assets: [
            _asset('App-1.0.3-x86_64.dmg'),
            _asset('App-1.0.3.dmg'),
            _asset('App-1.0.3-arm64.dmg'),
          ],
        ),
      ]),
      build: 1,
      storeUrl: 'https://apps.apple.com/app/id1586449703',
      platform: Pfs.macos,
      arch: CpuArch.arm64,
    );

    expect(AppUpdate.url, 'https://download/App-1.0.3-arm64.dmg');
  });

  test('github ios always uses store url', () {
    final raw = _githubRaw([
      _release(
        tag: 'v1.0.3',
        assets: [_asset('ServerBox-1.0.3.dmg')],
      ),
    ]);

    AppUpdate.fromGitHubReleasesStr(
      raw: raw,
      build: 1,
      storeUrl: 'https://apps.apple.com/app/id1586449703',
      platform: Pfs.ios,
      arch: CpuArch.arm64,
    );
    expect(AppUpdate.url, 'https://apps.apple.com/app/id1586449703');
  });

  test('github invalid tag yields no update', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(tag: 'invalid', assets: [_asset('ServerBox.zip')]),
      ]),
      build: 1,
      platform: Pfs.windows,
      arch: CpuArch.amd64,
    );
    expect(AppUpdate.version, isNull);
    expect(AppUpdate.url, isNull);
  });

  test('github missing platform asset still names the newest version', () {
    // No release has a Windows asset, so there is nothing to install — but the
    // version is known and the settings page should say so rather than
    // "unknown".
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(tag: 'v1.0.3', assets: [_asset('ServerBox.zip')]),
      ]),
      build: 1,
      platform: Pfs.windows,
      arch: CpuArch.amd64,
    );
    expect(AppUpdate.version, (3, AppUpdateLevel.normal));
    expect(AppUpdate.versionName, 'v1.0.3');
    expect(AppUpdate.url, isNull);
  });

  group('release published for some platforms only', () {
    // The shape this was written for: v1.0.1491 shipped a dmg, an AppImage, a
    // Windows zip and an ipa, and no apk at all.
    String raw() => _githubRaw([
          _release(
            tag: 'v1.0.1491',
            body: 'ninety one',
            assets: [
              _asset('ServerBox-1.0.1491.dmg'),
              _asset('ServerBox_v1.0.1491_amd64.AppImage'),
              _asset('ServerBox_v1.0.1491_windows_amd64.zip'),
            ],
          ),
          _release(
            tag: 'v1.0.1480',
            body: 'eighty',
            assets: [
              _asset('ServerBox-1.0.1480.dmg'),
              _asset('ServerBox_v1.0.1480_amd64.apk'),
              _asset('ServerBox_v1.0.1480_arm64.apk'),
              _asset('ServerBox_v1.0.1480_arm.apk'),
              _asset('ServerBox_v1.0.1480_windows_amd64.zip'),
            ],
          ),
        ]);

    test('offers the newest release that has an asset for this platform', () {
      AppUpdate.fromGitHubReleasesStr(
        raw: raw(),
        build: 1466,
        platform: Pfs.android,
        arch: CpuArch.arm64,
      );

      expect(AppUpdate.version, (1480, AppUpdateLevel.normal));
      expect(AppUpdate.versionName, 'v1.0.1480');
      expect(AppUpdate.url, 'https://download/ServerBox_v1.0.1480_arm64.apk');
      // The notes stop at what is being offered: 1491 is not on the way in.
      expect(AppUpdate.releaseNotes.map((e) => e.title).toList(), ['v1.0.1480']);
    });

    test('is up to date on the newest release carrying its asset', () {
      AppUpdate.fromGitHubReleasesStr(
        raw: raw(),
        build: 1480,
        platform: Pfs.android,
        arch: CpuArch.arm64,
      );

      expect(AppUpdate.version, (1480, AppUpdateLevel.nil));
      expect(AppUpdate.releaseNotes, isEmpty);
    });

    test('platforms in that release are unaffected', () {
      AppUpdate.fromGitHubReleasesStr(
        raw: raw(),
        build: 1466,
        platform: Pfs.windows,
        arch: CpuArch.amd64,
      );

      expect(AppUpdate.version, (1491, AppUpdateLevel.normal));
      expect(
        AppUpdate.url,
        'https://download/ServerBox_v1.0.1491_windows_amd64.zip',
      );
      expect(
        AppUpdate.releaseNotes.map((e) => e.title).toList(),
        ['v1.0.1491', 'v1.0.1480'],
      );
    });

    test('an arch with no asset in any release falls back to the newest', () {
      // Linux arm64: every AppImage is amd64, so nothing is installable.
      AppUpdate.fromGitHubReleasesStr(
        raw: raw(),
        build: 1466,
        platform: Pfs.linux,
        arch: CpuArch.arm64,
      );

      expect(AppUpdate.version, (1491, AppUpdateLevel.normal));
      expect(AppUpdate.url, isNull);
    });
  });

  group('ios store build', () {
    String raw() => _githubRaw([
          _release(tag: 'v1.0.1491', body: 'ninety one'),
          _release(tag: 'v1.0.1480', body: 'eighty'),
        ]);

    const storeUrl = 'https://apps.apple.com/app/id1586449703';

    test('a tag still in review is not offered', () {
      AppUpdate.fromGitHubReleasesStr(
        raw: raw(),
        build: 1480,
        storeUrl: storeUrl,
        storeBuild: 1480,
        platform: Pfs.ios,
        arch: CpuArch.arm64,
      );

      // 1491 exists on GitHub but the store still serves 1480, which is what
      // is running: no update, rather than a prompt that cannot be acted on.
      expect(AppUpdate.version, (1480, AppUpdateLevel.nil));
      expect(AppUpdate.versionName, 'v1.0.1480');
      expect(AppUpdate.url, storeUrl);
    });

    test('a released build is offered once the store serves it', () {
      AppUpdate.fromGitHubReleasesStr(
        raw: raw(),
        build: 1480,
        storeUrl: storeUrl,
        storeBuild: 1491,
        platform: Pfs.ios,
        arch: CpuArch.arm64,
      );

      expect(AppUpdate.version, (1491, AppUpdateLevel.normal));
      expect(AppUpdate.url, storeUrl);
      expect(AppUpdate.releaseNotes.map((e) => e.title).toList(), ['v1.0.1491']);
    });

    test('a store ahead of the tag still offers the newest tag', () {
      AppUpdate.fromGitHubReleasesStr(
        raw: raw(),
        build: 1466,
        storeUrl: storeUrl,
        storeBuild: 1500,
        platform: Pfs.ios,
        arch: CpuArch.arm64,
      );

      expect(AppUpdate.version, (1491, AppUpdateLevel.normal));
    });

    test('an unknown store build trusts the tag', () {
      AppUpdate.fromGitHubReleasesStr(
        raw: raw(),
        build: 1480,
        storeUrl: storeUrl,
        platform: Pfs.ios,
        arch: CpuArch.arm64,
      );

      expect(AppUpdate.version, (1491, AppUpdateLevel.normal));
      expect(AppUpdate.url, storeUrl);
    });

    test('a store behind every tag reports the newest and offers nothing', () {
      AppUpdate.fromGitHubReleasesStr(
        raw: raw(),
        build: 1466,
        storeUrl: storeUrl,
        storeBuild: 1466,
        platform: Pfs.ios,
        arch: CpuArch.arm64,
      );

      expect(AppUpdate.version, (1491, AppUpdateLevel.normal));
      expect(AppUpdate.url, isNull);
    });

    test('the store build does not constrain macos', () {
      AppUpdate.fromGitHubReleasesStr(
        raw: _githubRaw([
          _release(tag: 'v1.0.1491', assets: [_asset('ServerBox-1.0.1491.dmg')]),
        ]),
        build: 1480,
        storeUrl: storeUrl,
        storeBuild: 1480,
        platform: Pfs.macos,
        arch: CpuArch.arm64,
      );

      expect(AppUpdate.version, (1491, AppUpdateLevel.normal));
      expect(AppUpdate.url, 'https://download/ServerBox-1.0.1491.dmg');
    });
  });

  group('app store lookup', () {
    test('lookup url is derived from the store page url', () {
      expect(
        AppUpdate.appStoreLookupUrl('https://apps.apple.com/app/id1586449703'),
        'https://itunes.apple.com/lookup?id=1586449703',
      );
      expect(
        AppUpdate.appStoreLookupUrl(
          'https://apps.apple.com/us/app/serverbox/id1586449703?mt=8',
        ),
        'https://itunes.apple.com/lookup?id=1586449703',
      );
      expect(AppUpdate.appStoreLookupUrl(null), isNull);
      expect(AppUpdate.appStoreLookupUrl('https://example.com/app'), isNull);
    });

    test('build is read from the version string', () {
      expect(
        AppUpdate.parseAppStoreBuild('{"resultCount":1,'
            '"results":[{"version":"1.0.1480"}]}'),
        1480,
      );
    });

    test('a response naming no app yields null', () {
      expect(
        AppUpdate.parseAppStoreBuild('{"resultCount":0,"results":[]}'),
        isNull,
      );
      expect(AppUpdate.parseAppStoreBuild('{"results":[{}]}'), isNull);
      expect(AppUpdate.parseAppStoreBuild('not json'), isNull);
      expect(AppUpdate.parseAppStoreBuild('[]'), isNull);
    });
  });

  test('github beta stays on a prerelease that has this platform asset', () {
    // The stable is newer but shipped no apk; downgrading the channel here
    // would hand the beta user an older build than the one waiting for them.
    AppUpdate.chan = AppUpdateChan.beta;
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(tag: 'v1.0.6', assets: [_asset('ServerBox-1.0.6.dmg')]),
        _release(
          tag: 'v1.0.5',
          prerelease: true,
          assets: [_asset('ServerBox_v1.0.5_arm64.apk')],
        ),
        _release(
          tag: 'v1.0.4',
          assets: [_asset('ServerBox_v1.0.4_arm64.apk')],
        ),
      ]),
      build: 1,
      platform: Pfs.android,
      arch: CpuArch.arm64,
    );

    expect(AppUpdate.chan, AppUpdateChan.beta);
    expect(AppUpdate.version, (5, AppUpdateLevel.normal));
    expect(AppUpdate.url, 'https://download/ServerBox_v1.0.5_arm64.apk');
  });
}

String _githubRaw(List<Map<String, dynamic>> releases) => json.encode(releases);

Map<String, dynamic> _release({
  required String tag,
  String? name,
  bool prerelease = false,
  bool draft = false,
  String? body,
  String? publishedAt,
  List<Map<String, dynamic>> assets = const [],
}) {
  return {
    'tag_name': tag,
    'name': name ?? tag,
    'draft': draft,
    'prerelease': prerelease,
    'body': body,
    'published_at': publishedAt,
    'assets': assets,
  };
}

Map<String, dynamic> _asset(String name) {
  return {
    'name': name,
    'browser_download_url': 'https://download/$name',
  };
}
