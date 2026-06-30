import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';

abstract final class AppUpdateIface {
  static final newestBuild = ValueNotifier<int?>(null);

  static Future<void> doUpdate({
    required BuildContext context,
    required String githubReleasesUrl,
    required int build,
    String? storeUrl,
    bool force = false,
    bool beta = false,
  }) async {
    if (isWeb) return;

    try {
      await AppUpdate.fromGitHubReleasesUrl(
        url: githubReleasesUrl,
        build: build,
        storeUrl: storeUrl,
      );
    } catch (e, s) {
      Loggers.app.warning('Check update failed', e, s);
      return;
    }

    final result = AppUpdate.version;
    if (result == null) {
      Loggers.app.warning('Update not available on ${Pfs.type}');
      return;
    }

    final newest = result.$1;

    newestBuild.value = newest;

    if (!force && newest <= build) {
      Loggers.app.info('Update ignored: $build >= $newest');
      return;
    }
    Loggers.app.info('Update available: $newest');

    final fileUrl = AppUpdate.url;
    if (fileUrl == null) {
      Loggers.app.warning('Update file not available: $fileUrl');
      return;
    }

    final changelog = AppUpdate.changelog ?? '~';

    if (!context.mounted) return;
    final size = MediaQuery.sizeOf(context);

    void showUpdateDialog([bool force = false]) {
      context.showRoundDialog(
        title: 'v1.0.$newest',
        child: SizedBox(
          width: size.width * 0.8,
          child: SingleChildScrollView(
            child: SimpleMarkdown(data: changelog),
          ),
        ),
        barrierDismiss: !force,
        actions: [
          TextButton(
            onPressed: () {
              if (!force) context.pop();
              _doUpdate(context, fileUrl);
            },
            child: Text(l10n.update),
          )
        ],
      );
    }

    return switch (result.$2) {
      AppUpdateLevel.normal => context.showSnackBarWithAction(
          content: 'v1.0.$newest',
          action: l10n.update,
          onTap: showUpdateDialog,
        ),
      AppUpdateLevel.recommended => showUpdateDialog(),
      AppUpdateLevel.forced => showUpdateDialog(true),
      AppUpdateLevel.nil => (),
    };
  }

  static Future<void> _doUpdate(BuildContext context, String url) async {
    switch (Pfs.type) {
      case Pfs.windows || Pfs.linux || Pfs.ios || Pfs.macos || Pfs.android:
        await url.launchUrl();
        break;
      default:
        context.showRoundDialog(
          title: 'Error',
          child: Text('Unsupported platform: ${Pfs.type}'),
        );
        break;
    }
  }
}
