import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fl_lib/fl_lib.dart';
import 'package:fl_lib/src/res/l10n.dart';
import 'package:flutter/material.dart';
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

    if (args.heroTag != null) {
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
          icon: const Icon(Icons.delete),
        ),
      ],
    );
  }
}

Future<String> _getImgData(String url) async {
  if (url.startsWith('http')) {
    final resp = await myDio.get(
      url,
      options: Options(responseType: ResponseType.bytes),
    );
    final data = resp.data as Uint8List;
    final path = '${Paths.temp}/gptbox_temp_${data.md5Sum}.jpg';
    final file = File(path);
    await file.writeAsBytes(data);
    return file.path;
  } else if (url.startsWith('assets')) {
    // Write assets to tmp dir
    final data = (await rootBundle.load(url)).buffer.asUint8List();
    final path = '${Paths.temp}/gptbox_temp_${data.md5Sum}.jpg';
    final file = File(path);
    await file.writeAsBytes(data);
    return file.path;
  }

  final file = File(url);
  if (!(await file.exists())) await file.readAsBytes();
  return file.path;
}
