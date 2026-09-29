import 'package:fl_lib/fl_lib.dart';
import 'package:material_ui/material_ui.dart';

final class ImageCard extends StatefulWidget {
  final String imageUrl;
  final String? heroTag;
  final void Function(ImagePageRet)? onRet;

  /// Whether to show the large image when clicked.
  final bool showLarge;

  final double? size;

  final ImageProvider imageProvider;

  final BorderRadius? radius;

  ImageCard({
    super.key,
    required this.imageUrl,
    this.heroTag,
    this.showLarge = true,
    this.onRet,
    this.size,
    this.radius,
  }) : imageProvider = imageUrl.imageProvider;

  @override
  State<ImageCard> createState() => _ImageCardState();
}

class _ImageCardState extends State<ImageCard> {
  @override
  Widget build(BuildContext context) {
    Widget child = CardX(radius: widget.radius, child: _buildImage());
    // No flight to the full-screen page under reduced motion.
    if (widget.heroTag != null && !MediaQuery.disableAnimationsOf(context)) {
      child = Hero(tag: widget.heroTag!, child: child);
    }
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: child,
    );
  }

  Widget _buildImage() {
    final imageWidget = Image(
      image: widget.imageProvider,
      fit: BoxFit.cover,
      loadingBuilder: (context, child, loadingProgress) {
        if (loadingProgress == null) return child;

        final loadedBytes = loadingProgress.cumulativeBytesLoaded.bytes2Str;
        final totalBytes = loadingProgress.expectedTotalBytes?.bytes2Str;
        final progress = '$loadedBytes / $totalBytes';

        return Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedLoading.medium,
            UIs.height13,
            Text(progress),
          ],
        );
      },
      errorBuilder: (context, error, stackTrace) {
        return _buildErr(error, stackTrace);
      },
    );

    if (!widget.showLarge) return imageWidget;

    return InkWell(
      onTap: () async {
        if (!widget.showLarge) return;

        final ret = await ImagePage.route.go(
          context,
          ImagePageArgs(
            heroTag: widget.heroTag,
            image: widget.imageProvider,
            url: widget.imageUrl,
          ),
        );
        if (ret != null) widget.onRet?.call(ret);
      },
      child: imageWidget,
    );
  }

  Widget _buildErr(Object? err, StackTrace? trace) {
    return InkWell(
      onTap: () {
        context.showErrDialog(err, trace);
      },
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.broken_image, size: 50),
          UIs.height13,
          Text('${libL10n.error} Log'),
        ],
      ),
    );
  }
}
