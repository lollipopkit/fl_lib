import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fl_lib/src/core/dio.dart';
import 'package:fl_lib/src/core/update.dart';
import 'package:fl_lib/src/model/update.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late HttpClientAdapter original;
  late _StubAdapter stub;

  setUp(() {
    original = myDio.httpClientAdapter;
    stub = _StubAdapter();
    myDio.httpClientAdapter = stub;
    AppUpdate.resetForTest();
    AppUpdateIface.newestBuild.value = null;
  });

  tearDown(() {
    myDio.httpClientAdapter = original;
    AppUpdate.resetForTest();
    AppUpdateIface.newestBuild.value = null;
  });

  /// Runs a check against [releases].
  ///
  /// Through [WidgetTester.runAsync] because the response arrives on the real
  /// event loop, which the fake-async zone a `testWidgets` body runs in never
  /// pumps. Every case here returns before [BuildContext] is read, so no
  /// overlay or toast host is needed.
  Future<void> check(
    WidgetTester tester,
    BuildContext ctx, {
    required List<Map<String, dynamic>> releases,
    required int build,
  }) async {
    stub.body = json.encode(releases);
    await tester.runAsync(() => AppUpdateIface.doUpdate(
          context: ctx,
          githubReleasesUrl: 'https://example.invalid/releases',
          build: build,
        ));
  }

  Future<BuildContext> pumpCtx(WidgetTester tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(home: Builder(builder: (c) {
      ctx = c;
      return const SizedBox();
    })));
    return ctx;
  }

  testWidgets('a check with no asset clears what an earlier one published',
      (tester) async {
    final ctx = await pumpCtx(tester);

    await check(
      tester,
      ctx,
      releases: [_release(tag: 'v1.0.200', assets: _hostAssets('1.0.200'))],
      build: 200,
    );
    expect(AppUpdateIface.newestBuild.value, 200,
        reason: 'an installable build is published');

    // Now no release carries an asset for this platform. Leaving 200 in place
    // would keep the settings page naming a build that is no longer on offer,
    // and its tap would do nothing.
    await check(
      tester,
      ctx,
      releases: [
        _release(tag: 'v1.0.300'),
        _release(tag: 'v1.0.200'),
      ],
      build: 200,
    );
    expect(AppUpdateIface.newestBuild.value, isNull);
  });

  testWidgets('the running build is published even with no asset',
      (tester) async {
    final ctx = await pumpCtx(tester);

    // Nothing to download, but the newest release is what is already running.
    // "Up to date" is the truth, and there is no tap to mislead.
    await check(
      tester,
      ctx,
      releases: [_release(tag: 'v1.0.100')],
      build: 100,
    );
    expect(AppUpdateIface.newestBuild.value, 100);
  });
}

/// Assets named so one release matches whichever host the suite runs on.
///
/// `arm64_amd64` satisfies [CpuArch.arm64] and [CpuArch.amd64] alike, and the
/// dmg carries no arch at all, which is what the macOS branch falls back to.
List<Map<String, dynamic>> _hostAssets(String version) => [
      _asset('App-$version.dmg'),
      _asset('App_v${version}_arm64_amd64.apk'),
      _asset('App_v${version}_arm64_amd64.AppImage'),
      _asset('App_v${version}_windows_arm64_amd64.zip'),
    ];

final class _StubAdapter implements HttpClientAdapter {
  String body = '[]';

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    return ResponseBody.fromString(body, 200, headers: {
      Headers.contentTypeHeader: [Headers.jsonContentType],
    });
  }

  @override
  void close({bool force = false}) {}
}

Map<String, dynamic> _release({
  required String tag,
  List<Map<String, dynamic>> assets = const [],
}) {
  return {
    'tag_name': tag,
    'name': tag,
    'draft': false,
    'prerelease': false,
    'body': 'notes',
    'assets': assets,
  };
}

Map<String, dynamic> _asset(String name) {
  return {
    'name': name,
    'browser_download_url': 'https://download/$name',
  };
}
