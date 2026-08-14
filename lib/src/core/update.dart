import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';

abstract final class AppUpdateIface {
  static final newestBuild = ValueNotifier<int?>(null);

  /// - [noticeBuilder] is shown above the release notes, for whatever this
  ///   particular app has to say alongside an update — which build the user is
  ///   running, where else it can be had. Returning null shows nothing.
  static Future<void> doUpdate({
    required BuildContext context,
    required String githubReleasesUrl,
    required int build,
    String? storeUrl,
    bool force = false,
    bool beta = false,
    Widget? Function(BuildContext ctx)? noticeBuilder,
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
    final notes = AppUpdate.releaseNotes;
    final title = AppUpdate.versionName ?? 'v1.0.$newest';

    if (!context.mounted) return;
    final size = MediaQuery.sizeOf(context);

    void showUpdateDialog([bool force = false]) {
      context.showRoundDialog(
        title: title,
        childBuilder: (ctx) {
          final notice = noticeBuilder?.call(ctx);
          return SizedBox(
            width: size.width * 0.8,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (notice != null) ...[notice, const SizedBox(height: 13)],
                  _changelogView(ctx, changelog, notes),
                ],
              ),
            ),
          );
        },
        barrierDismiss: !force,
        actions: [
          TextButton(
            onPressed: () {
              if (!force) context.popDialog();
              _doUpdate(context, fileUrl);
            },
            child: Text(l10n.update),
          )
        ],
      );
    }

    return switch (result.$2) {
      AppUpdateLevel.normal => context.showSnackBarWithAction(
          content: title,
          action: l10n.update,
          onTap: showUpdateDialog,
        ),
      AppUpdateLevel.recommended => showUpdateDialog(),
      AppUpdateLevel.forced => showUpdateDialog(true),
      AppUpdateLevel.nil => (),
    };
  }

  /// The notes of every version the user is about to skip over.
  ///
  /// Each version is one collapsed row, the way a finished tool call is one row
  /// in the agent view: several release bodies at full length would push the
  /// update button off the screen. Only the version being installed is open,
  /// since that is the one the user came for.
  static Widget _changelogView(
    BuildContext context,
    String changelog,
    List<AppUpdateReleaseNote> notes,
  ) {
    // One version, or a source that has no per-version notes (the JSON
    // manifest): the dialog title already names it, so an expander would only
    // hide the text behind a tap.
    if (notes.length <= 1) return SimpleMarkdown(data: changelog);

    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (idx, note) in notes.indexed)
          ExpandTile(
            initiallyExpanded: idx == 0,
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 11),
            title: Row(
              children: [
                Expanded(
                  child: Text(
                    note.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                if (note.date != null)
                  Text(
                    note.date!.ymd(),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            children: [SimpleMarkdown(data: note.body)],
          ),
      ],
    );
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
