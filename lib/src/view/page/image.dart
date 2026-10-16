import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

final class ImagePageArgs {
  final String? title;
  final String? heroTag;
  final ImageProvider image;
  final String url;

  const ImagePageArgs({
    this.title,
    required this.heroTag,
    required this.image,
    required this.url,
  });
}

final class ImagePageRet {
  final bool isDeleted;

  const ImagePageRet({
    this.isDeleted = false,
  });
}

final class ImagePage extends StatelessWidget {
  final ImagePageArgs args;

  const ImagePage({super.key, required this.args});

  static const route = AppRouteArg<ImagePageRet, ImagePageArgs>(
    page: ImagePage.new,
    path: '/image',
  );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: _buildAppBar(context),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    Widget child = Image(image: args.image, fit: BoxFit.contain).expanded();

    // child = InteractiveViewer(
    //   constrained: false,
    //   maxScale: 3,
    //   child: child,
    // );

    // No flight from the thumbnail under reduced motion.
    if (args.heroTag != null && !MediaQuery.disableAnimationsOf(context)) {
      child = Hero(
        tag: args.heroTag!,
        transitionOnUserGestures: true,
        child: child,
      );
    }

    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: child,
    );
  }

  CustomAppBar _buildAppBar(BuildContext context) {
    return CustomAppBar(
      actions: [
        // Share
        IconButton(
          onPressed: () async {
            final (path, err) = await context.showLoadingDialog(
              fn: () => _getImgData(args.url),
            );
            if (err != null || path == null) return;
            await Pfs.sharePaths(
              paths: [path],
              title: args.title,
            );
          },
          tooltip: l10n.share,
          icon: const Icon(Icons.share),
        ),
        // Delete
        IconButton(
          onPressed: () async {
            final sure = await context.showRoundDialog(
              title: l10n.delete,
              child: Text(l10n.delFmt(args.title ?? '???', l10n.image)),
              actions: Btnx.oks,
            );
            if (sure != true || !context.mounted) return;
            context.pop(const ImagePageRet(isDeleted: true));
          },
          tooltip: l10n.delete,
          icon: const Icon(Icons.delete),
        ),
      ],
    );
  }
}

/// The most a shared image may be. Any photo fits; a URL that serves
/// something else entirely is stopped before it fills memory or the disk.
const _kMaxShareBytes = 64 * 1024 * 1024;

/// Where the copies made for sharing go.
///
/// One directory, emptied at the start of every share, rather than a file
/// removed once the share is done: on desktop "sharing" reveals the file in
/// the file manager, which needs it to still be there afterwards. So at most
/// the last share's copy is left behind.
Future<Directory> _shareDir() async {
  final dir = Directory('${Paths.temp}/image_share');
  if (await dir.exists()) await dir.delete(recursive: true);
  return dir.create(recursive: true);
}

Exception _tooLarge() =>
    Exception(l10n.tooLargeFmt(_kMaxShareBytes.bytes2Str));

Future<String> _getImgData(String url) async {
  if (url.startsWith('http')) {
    final resp = await myDio.get<ResponseBody>(
      url,
      options: Options(responseType: ResponseType.stream),
    );
    final body = resp.data!;
    if (body.contentLength > _kMaxShareBytes) throw _tooLarge();
    final file = File('${(await _shareDir()).path}/image.jpg');
    final sink = file.openWrite();
    var received = 0;
    try {
      // Counted as it arrives: a missing or wrong Content-Length is not a
      // limit.
      await for (final chunk in body.stream) {
        received += chunk.length;
        if (received > _kMaxShareBytes) throw _tooLarge();
        sink.add(chunk);
      }
    } catch (_) {
      await sink.close();
      await file.delete();
      rethrow;
    }
    await sink.close();
    return file.path;
  } else if (url.startsWith('assets')) {
    // Write assets to tmp dir
    final data = (await rootBundle.load(url)).buffer.asUint8List();
    final file = File('${(await _shareDir()).path}/image.jpg');
    await file.writeAsBytes(data);
    return file.path;
  }

  final file = File(url);
  if (!await file.exists()) throw PathNotFoundException(url, const OSError());
  return file.path;
}
