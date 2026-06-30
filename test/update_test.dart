import 'dart:convert';

import 'package:fl_lib/src/core/utils/platform/arch.dart';
import 'package:fl_lib/src/core/utils/platform/base.dart';
import 'package:fl_lib/src/model/update.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  setUp(() {
    AppUpdate.chan = AppUpdateChan.stable;
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

  test('github missing platform asset keeps version but has no update url', () {
    AppUpdate.fromGitHubReleasesStr(
      raw: _githubRaw([
        _release(tag: 'v1.0.3', assets: [_asset('ServerBox.zip')]),
      ]),
      build: 1,
      platform: Pfs.windows,
      arch: CpuArch.amd64,
    );
    expect(AppUpdate.version, (3, AppUpdateLevel.normal));
    expect(AppUpdate.url, isNull);
  });
}

String _githubRaw(List<Map<String, dynamic>> releases) => json.encode(releases);

Map<String, dynamic> _release({
  required String tag,
  bool prerelease = false,
  bool draft = false,
  String? body,
  List<Map<String, dynamic>> assets = const [],
}) {
  return {
    'tag_name': tag,
    'name': tag,
    'draft': draft,
    'prerelease': prerelease,
    'body': body,
    'assets': assets,
  };
}

Map<String, dynamic> _asset(String name) {
  return {
    'name': name,
    'browser_download_url': 'https://download/$name',
  };
}
